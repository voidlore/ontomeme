# shellcheck shell=bash
# Zip helpers for macos_sign.sh and macos_notarize.sh. Source it:
#   . "$here/lib_zip.sh"
# A macOS app zip must come back out with its file modes (Contents/MacOS/*
# stays 0755) and its symlinks, or the signed app will not launch. Info-ZIP's
# unzip and zip do that and are on GitHub's runners; where they are missing
# (this dev box has neither), bsdtar extracts and python3's zipfile writes.

# zip_copy_through IN OUT: OUT becomes a byte-for-byte copy of IN (the skip
# path of the signing scripts); nothing to do when they are the same file.
zip_copy_through() {
  if [ -e "$2" ] && [ "$1" -ef "$2" ]; then return 0; fi
  cp -f -- "$1" "$2"
}

# zip_extract ZIP DIR: extract ZIP into DIR (created), restoring the modes the
# zip records whatever the caller's umask is.
zip_extract() {
  local zip="$1" dir="$2"
  mkdir -p "$dir"
  if command -v unzip >/dev/null 2>&1; then
    (umask 022 && unzip -q -o "$zip" -d "$dir")
  elif command -v bsdtar >/dev/null 2>&1; then
    (umask 022 && bsdtar -x -p -f "$zip" -C "$dir")
  else
    echo "zip_extract: needs unzip or bsdtar to extract $zip" >&2
    return 1
  fi
}

# zip_single_app DIR: print the path of the one X.app that DIR holds at its
# top level; fail when DIR holds anything else, so a re-zip loses nothing.
zip_single_app() {
  local dir="$1" entry app=""
  local -a entries=()
  for entry in "$dir"/* "$dir"/.[!.]*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then entries+=("$entry"); fi
  done
  if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ] && [[ ${entries[0]} == *.app ]]; then
    app="${entries[0]}"
  fi
  if [ -z "$app" ]; then
    echo "zip_single_app: expected the zip to hold one X.app and nothing else, found: ${entries[*]##*/}" >&2
    return 1
  fi
  echo "$app"
}

# zip_create DIR ENTRY OUT: zip DIR/ENTRY (a file or a directory, recursively)
# into OUT, replacing it, with paths relative to DIR. Unix modes are kept and
# symlinks are stored as links, like `zip -qry`.
zip_create() {
  local dir="$1" entry="$2" out="$3"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  rm -f -- "$out"
  if command -v zip >/dev/null 2>&1; then
    (cd "$dir" && zip -qry "$out" "$entry")
  else
    python3 -I - "$dir" "$entry" "$out" <<'PY'
import os, shutil, stat, sys, time, zipfile

base, entry, out = sys.argv[1:4]


def unix_info(rel, st):
    stamp = time.localtime(max(st.st_mtime, 315532800))[:6]  # zip times start in 1980
    info = zipfile.ZipInfo(rel, stamp)
    info.create_system = 3  # Unix, so unzip and bsdtar restore the mode bits
    info.external_attr = (st.st_mode & 0xFFFF) << 16
    return info


with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
    def add(rel):
        full = os.path.join(base, rel)
        st = os.lstat(full)
        if stat.S_ISLNK(st.st_mode):
            archive.writestr(unix_info(rel, st), os.readlink(full), zipfile.ZIP_STORED)
        elif stat.S_ISDIR(st.st_mode):
            info = unix_info(rel + "/", st)
            info.external_attr |= 0x10  # MS-DOS directory bit
            archive.writestr(info, b"", zipfile.ZIP_STORED)
            for name in sorted(os.listdir(full)):
                add(os.path.join(rel, name))
        elif stat.S_ISREG(st.st_mode):
            info = unix_info(rel, st)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.file_size = st.st_size
            with open(full, "rb") as src, archive.open(info, "w", force_zip64=st.st_size > 0x7FFFFFFF) as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
        else:
            sys.exit(f"zip_create: {full} is not a file, directory or symlink")

    add(entry)
PY
  fi
}
