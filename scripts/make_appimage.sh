#!/usr/bin/env bash
# Build an AppImage from an already-exported Linux binary.
#
#   scripts/make_appimage.sh <version> <exported_binary> <out_appimage>
#
# The exported binary is the output of the "Linux x86_64" Godot export preset
# (e.g. build/linux/Ontomeme.x86_64). The script assembles an AppDir
# (usr/bin/Ontomeme + Ontomeme.desktop + icon) and wraps it into an AppImage
# with appimagetool.
#
# It is used by .github/workflows/release.yml (Linux job) and is also runnable
# locally, e.g. inside a container that has network access:
#
#   docker run --rm -v "$PWD":/w -w /w debian:12 \
#     bash -lc 'apt-get update -qq && apt-get install -y -qq squashfs-tools \
#       librsvg2-bin file curl ca-certificates >/dev/null; scripts/make_appimage.sh 0.1.0 \
#       build/linux/Ontomeme.x86_64 dist/Ontomeme-0.1.0-linux-x86_64.AppImage'
#
# A built AppImage is validated by scripts/check_packages.sh.
set -euo pipefail

version="${1:?usage: make_appimage.sh <version> <exported_binary> <out_appimage>}"
src="${2:?need the exported Linux binary}"
out="${3:?need the output AppImage path}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$src" ] || { echo "::error::exported binary not found or not executable: $src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- appimagetool and the AppImage runtime, pinned --------------------------
# Both come from a fixed release and must match its SHA-256. A "continuous"
# build changes under us from one tag to the next (one began to need file(1)
# and broke a build), and the runtime is the code every user's AppImage
# starts with. Left alone, appimagetool downloads the newest type2-runtime
# itself; --runtime-file hands it the pinned one, whichever appimagetool runs.
# To move a pin: take the release's tag and the sha256 its GitHub release page
# lists for the x86_64 file, build, and run scripts/check_packages.sh.
APPIMAGETOOL_RELEASE="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
RUNTIME_RELEASE="20251108"
RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

# check_sha256 <file> <sha256>: the pinned bytes, or stop.
check_sha256() {
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || {
    echo "::error::$1 has SHA-256 $got, expected the pinned $2" >&2
    exit 1
  }
}

# appimagetool ships from the AppImage/appimagetool repo (AppImageKit is its
# pre-rename home). Run with --appimage-extract-and-run it self-extracts to a
# temp dir and runs the embedded tool, so no FUSE is needed: this works in
# Docker and on CI runners. APPIMAGETOOL or an appimagetool on PATH is the
# caller's own and is not checked; the runtime always is.
tool=""
tool_extra=()
if [ -n "${APPIMAGETOOL:-}" ]; then
  tool="$APPIMAGETOOL"          # caller-supplied, already usable as a command
elif command -v appimagetool >/dev/null 2>&1; then
  tool="$(command -v appimagetool)"
  tool_extra=()
else
  tool="$work/appimagetool-x86_64.AppImage"
  echo "appimagetool not found; downloading appimagetool $APPIMAGETOOL_RELEASE to $tool" >&2
  # -o $tool, not -O: -O saves into the current directory, and the download
  # runs with $work as the target, so -O would leave the file where the next
  # chmod +x "$tool" cannot find it.
  curl -fsSL -o "$tool" \
    "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_RELEASE/appimagetool-x86_64.AppImage"
  check_sha256 "$tool" "$APPIMAGETOOL_SHA256"
  chmod +x "$tool"
  tool_extra=(--appimage-extract-and-run)
fi
# The runtime: APPIMAGE_RUNTIME (a local copy, for a build without network),
# else downloaded. Either way it must be the pinned one.
runtime="${APPIMAGE_RUNTIME:-}"
if [ -z "$runtime" ]; then
  runtime="$work/runtime-x86_64"
  echo "downloading the AppImage type2-runtime $RUNTIME_RELEASE to $runtime" >&2
  curl -fsSL -o "$runtime" \
    "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_RELEASE/runtime-x86_64"
fi
[ -s "$runtime" ] || { echo "::error::AppImage runtime not found: $runtime" >&2; exit 1; }
check_sha256 "$runtime" "$RUNTIME_SHA256"
# mksquashfs is required to create the AppImage, and appimagetool refuses to
# start without file(1).
command -v mksquashfs >/dev/null 2>&1 || \
  { echo "::error::mksquashfs (squashfs-tools) is required to build an AppImage" >&2; exit 1; }
command -v file >/dev/null 2>&1 || \
  { echo "::error::file(1) (package file) is required by appimagetool" >&2; exit 1; }

# --- icon -------------------------------------------------------------------
# Prefer rsvg-convert (clean SVG rendering), fall back to ImageMagick, then a
# solid-color placeholder so the build never stalls on icon tooling.
icon_dst="$repo_root/icon.svg"
gen_icon_png() { # $1 = destination 256x256 png
  local dst="$1"
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 256 -h 256 -o "$dst" "$icon_dst"
  elif command -v convert >/dev/null 2>&1; then
    convert -background none -resize 256x256 "$icon_dst" "$dst"
  elif command -v magick >/dev/null 2>&1; then
    magick -background none -resize 256x256 "$icon_dst" "$dst"
  else
    echo "no SVG rasterizer found; emitting a placeholder icon" >&2
    python3 - "$dst" <<'PY'
import struct, sys, zlib
w = h = 256
dst = sys.argv[1]
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
row = b"\x00" + b"\x40\x40\xc0" * w
idat = zlib.compress(row * h)
open(dst, "wb").write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))
PY
  fi
}

# --- AppDir -----------------------------------------------------------------
appdir="$work/Ontomeme-$version-appimage"
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/icons/hicolor/256x256/apps"
cp "$src" "$appdir/usr/bin/Ontomeme"
chmod +x "$appdir/usr/bin/Ontomeme"
# The entry point the AppImage runtime starts; appimagetool refuses an AppDir
# without one. A relative link keeps it valid wherever the AppDir is mounted.
ln -s usr/bin/Ontomeme "$appdir/AppRun"
# The icon is embedded in the AppImage header from the AppDir root
# (Ontomeme.png next to Ontomeme.desktop); a copy in the hicolor dir is what a
# mounted AppDir would use as its menu icon.
gen_icon_png "$appdir/Ontomeme.png"
cp "$appdir/Ontomeme.png" "$appdir/usr/share/icons/hicolor/256x256/apps/Ontomeme.png"

cat > "$appdir/Ontomeme.desktop" <<'EOF'
[Desktop Entry]
Name=Ontomeme
Comment=Immersive notes, folders and a learning journey, built on Godot
Exec=Ontomeme
Icon=Ontomeme
Terminal=false
Type=Application
Categories=Education;
EOF

mkdir -p "$(dirname "$out")"
echo "wrapping AppDir into $out (appimagetool)" >&2
"$tool" "${tool_extra[@]}" --runtime-file "$runtime" "$appdir" "$out"

[ -s "$out" ] || { echo "::error::AppImage was not produced" >&2; exit 1; }
[ -x "$out" ] || { echo "::error::AppImage is not executable: $out" >&2; exit 1; }

# Smoke test: an AppImage carries a squashfs payload; the squashfs magic
# "hsqs" must appear inside the file. (Deeper validation — running the binary
# out of the AppImage — happens on a desktop runner, not under Docker.)
# Piped, grep -q would exit before head finishes and pipefail would flag the
# SIGPIPE as failure; read the head into a file first instead.
head -c 52428800 "$out" > "$work/payload.head"
grep -q "hsqs" "$work/payload.head" || \
  { echo "::error::AppImage is missing its squashfs payload: $out" >&2; exit 1; }
echo "built $out" >&2
