#!/usr/bin/env bash
# check_packages.sh — validate the packaged release artifacts in a dist dir.
#
#   scripts/check_packages.sh <dist_dir> <version>
#
# It looks for every Ontomeme-<version>-*.{zip,dmg,AppImage,tar.gz} that is
# present in <dist_dir> and checks each is non-empty and structurally valid:
#
#   *zip       -> ZIP magic; if `unzip` is present, it must contain the
#                 expected inner entry (Ontomeme.exe / Ontomeme.app/...).
#   *.dmg      -> non-empty, > 1 MB, and carries a recognizable disk-image
#                 marker (UDIF / HFS / ISO9660).
#   *AppImage  -> its own --appimage-extract (no appimagetool or FUSE needed)
#                 must give an AppDir with AppRun, an executable
#                 usr/bin/Ontomeme and a .desktop file with Exec= and Icon=.
#                 CHECK_PACKAGES_NO_EXEC=1 (a host that can't run it) checks
#                 only the squashfs magic and skips its content audit.
#   *.tar.gz   -> must list the runnable executable.
#
# The pack inside each Windows zip, macOS zip, AppImage and tar.gz must pass
# the release content audit, scripts/check_pck_contents.sh: application code
# and assets only, nothing from docs/, tests/, media/ and the like. A .dmg is
# not opened here: it is built from the macOS zip, which release.yml audits.
#
# It also checks dist/SHA256SUMS.txt exists and references every artifact.
#
# Exit code 0 = every present artifact is valid (and at least one was found);
# 1 = a required artifact is missing, malformed, or checksums are incomplete.
# This is the test that pins the per-platform packaging: it is what
# .github/workflows/release.yml runs after the Package step, and it can be run
# locally (e.g. in a container) against a freshly built dist/.
set -uo pipefail

dist="${1:?usage: check_packages.sh <dist_dir> <version>}"
version="${2:?need the release version}"
[ -d "$dist" ] || { echo "::error::dist dir not found: $dist" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1" >&2; fail=$((fail+1)); }

first_bytes() { # first 4 bytes of a file, as hex
  head -c 4 "$1" | od -An -tx1 | tr -d ' \n'
}

contains_squashfs_magic() {
  # squashfs superblock magic is "hsqs" (0x68 0x73 0x71 0x73)
  grep -qa 'hsqs' "$1" >/dev/null 2>&1
}

# check_pck <file holding the pack> <label>: the release content audit.
check_pck() {
  local out
  if out="$("$here/check_pck_contents.sh" "$1" 2>&1)"; then
    ok "$2: pack holds only app code and assets ($(sed -n 's/^pack  .*: \([0-9]*\) files$/\1/p' <<<"$out") files)"
  else
    bad "$2: release content audit (scripts/check_pck_contents.sh) failed"
    printf '%s\n' "$out" | sed 's/^/        /' >&2
  fi
}

check_zip() { # $1=artifact $2=required inner entry (may be empty to skip)
  local f="$1" inner="$2" magic
  magic="$(first_bytes "$f")"
  [ "$magic" = "504b0304" ] || { bad "$f: not a ZIP (magic $magic)"; return 1; }
  if command -v unzip >/dev/null 2>&1 && [ -n "$inner" ]; then
    unzip -l "$f" 2>/dev/null | grep -q "$inner" \
      || { bad "$f: ZIP does not contain '$inner'"; return 1; }
  fi
  ok "$f (zip)"
}

check_dmg() {
  local f="$1"
  [ "$(stat -c%s "$f")" -gt 1048576 ] || { bad "$f: too small to be a .dmg"; return 1; }
  if grep -aE -m1 'koly|UDIF|Apple_Boot|HFS\+|CD001' "$f" >/dev/null 2>&1; then
    ok "$f (dmg)"
  else
    bad "$f: no recognizable disk-image marker"
  fi
}

check_appimage() {
  local f="$1" abs tmp root desktop
  [ -s "$f" ] || { bad "$f: empty"; return 1; }
  if [ "${CHECK_PACKAGES_NO_EXEC:-}" = 1 ]; then
    if contains_squashfs_magic "$f"; then
      ok "$f (appimage, squashfs magic only: CHECK_PACKAGES_NO_EXEC=1)"
    else
      bad "$f: no squashfs magic found"
    fi
    return
  fi
  [ -x "$f" ] || { bad "$f: not executable"; return 1; }
  abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  tmp="$(mktemp -d)"
  root="$tmp/squashfs-root"
  if ! ( cd "$tmp" && "$abs" --appimage-extract >/dev/null 2>&1 ); then
    bad "$f: --appimage-extract failed"
  elif [ ! -e "$root/AppRun" ]; then
    bad "$f: the AppDir has no AppRun"
  elif [ ! -x "$root/usr/bin/Ontomeme" ]; then
    bad "$f: the AppDir has no executable usr/bin/Ontomeme"
  else
    desktop="$(find "$root" -maxdepth 1 -name '*.desktop' | head -n 1)"
    if [ -z "$desktop" ] || ! grep -q '^Exec=' "$desktop" || ! grep -q '^Icon=' "$desktop"; then
      bad "$f: the AppDir has no .desktop file with Exec= and Icon="
    else
      ok "$f (appimage: AppRun, usr/bin/Ontomeme, $(basename "$desktop"))"
      check_pck "$root/usr/bin/Ontomeme" "$f"
    fi
  fi
  rm -rf "$tmp"
}

check_targz() { # $1=artifact $2=expected executable path fragment
  local f="$1" frag="$2"
  if tar -tzf "$f" 2>/dev/null | grep -q "$frag"; then
    ok "$f (tar.gz)"
  else
    bad "$f: tar.gz does not list '$frag'"
    return 1
  fi
}

found=0
# Windows: zipped .exe
for f in "$dist"/Ontomeme-"$version"-windows*.zip; do
  [ -e "$f" ] || continue
  found=$((found+1)); check_zip "$f" "Ontomeme.exe" && check_pck "$f" "$f"
done
# macOS: a .dmg, or a zipped .app
for f in "$dist"/Ontomeme-"$version"-macos*.dmg; do
  [ -e "$f" ] || continue
  found=$((found+1)); check_dmg "$f"
done
for f in "$dist"/Ontomeme-"$version"-macos*.zip; do
  [ -e "$f" ] || continue
  found=$((found+1)); check_zip "$f" "Ontomeme.app/Contents/MacOS/Ontomeme" && check_pck "$f" "$f"
done
# Linux: AppImage and/or tar.gz
for f in "$dist"/Ontomeme-"$version"-linux*.AppImage; do
  [ -e "$f" ] || continue
  found=$((found+1)); check_appimage "$f"
done
for f in "$dist"/Ontomeme-"$version"-linux*.tar.gz; do
  [ -e "$f" ] || continue
  found=$((found+1)); check_targz "$f" "Ontomeme.x86_64" && check_pck "$f" "$f"
done

# Checksums
if [ -f "$dist/SHA256SUMS.txt" ]; then
  n_art=0
  for f in "$dist"/Ontomeme-"$version"-*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in SHA256SUMS.txt) continue;; esac
    n_art=$((n_art+1))
  done
  n_sum="$(grep -cE "Ontomeme-$version" "$dist/SHA256SUMS.txt")"
  if [ "$n_art" -eq "$n_sum" ]; then
    ok "SHA256SUMS.txt covers $n_sum artifact(s)"
  else
    bad "SHA256SUMS.txt lists $n_sum but $n_art artifact(s) are present"
  fi
else
  bad "SHA256SUMS.txt missing"
fi

echo
if [ "$found" -eq 0 ]; then
  echo "NO ARTIFACTS found for version $version in $dist" >&2
  exit 1
fi
echo "$pass passed, $fail failed, $found artifact(s)"
[ "$fail" -eq 0 ] || exit 1
echo "RESULT: ALL PASS"
