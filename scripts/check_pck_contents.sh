#!/usr/bin/env bash
# Check what an Ontomeme export packs: application code and assets only.
#
#   scripts/check_pck_contents.sh [--forbidden <patterns-file>] <artifact>
#
# <artifact> is anything scripts/pck_list.py reads: Ontomeme.x86_64,
# Ontomeme.exe (signed or not), a .pck, the macOS zip, a Windows zip or a
# Linux tarball.
# Fails (exit 1) when the pack holds:
#   - a development or methodology file: anything under docs/ tests/
#     scripts/ skills/ media/ .publish/ .github/ .agents/ .claude/ .foi/ ~/,
#     an AGENTS, CLAUDE, RELEASING, ANALYSIS, PWA-analysis, SECURITY_ANALYSIS,
#     component or contract .md in any folder, index.html or check_js.py;
#   - bytes matching a line of the patterns file (grep -E; by default the
#     repo's .publish/forbidden, the private names publish.sh keeps out of
#     the public repo; skipped with a note where that file isn't, as in the
#     public repo). Scripts are packed as compressed tokens, so this sees the
#     text of data files, not of scripts;
# or when it lacks a file the app can't start or seed without: project.binary,
# note.tscn.remap, mcp/note_guide.md (what the MCP server's get_note_guide
# returns), every ontomeme-notes/*.md and fonts/*.ttf.import of this
# checkout. Prints the number of packed files. Exit 2 on bad arguments.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
forbidden="$repo/.publish/forbidden"
forbidden_given=""

DEV_FILES='^(docs|tests|scripts|skills|media|\.publish|\.github|\.agents|\.claude|\.foi|~)/'
DEV_FILES+='|(^|/)(AGENTS|CLAUDE|RELEASING|ANALYSIS|PWA-analysis|SECURITY_ANALYSIS|component|contract)\.md$'
DEV_FILES+='|^index\.html$|^check_js\.py$'

usage() {
  sed -n 's/^#   \(scripts\/check_pck_contents\.sh .*\)/\1/p' "$0" >&2
  exit 2
}

artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --forbidden) [ $# -ge 2 ] || usage; forbidden="$2"; forbidden_given=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [ -z "$artifact" ] || usage; artifact="$1" ;;
  esac
  shift
done
[ -n "$artifact" ] || usage
if [ -n "$forbidden_given" ]; then
  [ -f "$forbidden" ] || { echo "check_pck_contents: no patterns file $forbidden" >&2; exit 2; }
  forbidden="$(cd "$(dirname "$forbidden")" && pwd)/$(basename "$forbidden")"   # grep runs from a temp dir
fi

# Windows runners name it python; -I keeps the caller's folder off sys.path.
python=""
for p in "${PYTHON:-}" python3 python; do
  if [ -n "$p" ] && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    python="$p"
    break
  fi
done
[ -n "$python" ] || { echo "check_pck_contents: needs Python 3.8 or later (python3 or python)" >&2; exit 2; }
pck_list() { "$python" -I "$here/pck_list.py" "$@"; }

problems=0
problem() {
  echo "FAIL  $*"
  problems=$((problems + 1))
}

# required_files: what every export must pack, one path per line.
required_files() {
  local f
  echo project.binary
  echo note.tscn.remap
  echo mcp/note_guide.md
  for f in "$repo"/ontomeme-notes/*.md; do [ -e "$f" ] && echo "ontomeme-notes/${f##*/}"; done
  for f in "$repo"/fonts/*.ttf; do [ -e "$f" ] && echo "fonts/${f##*/}.import"; done
}

check_dev_files() {
  local hits
  hits="$(printf '%s\n' "$entries" | grep -E "$DEV_FILES")"
  if [ -n "$hits" ]; then
    problem "development or methodology files are packed:"
    printf '%s\n' "$hits" | sed 's/^/        /'
  else
    echo "ok    no development or methodology files"
  fi
}

check_required() {
  local want missing="" lessons fonts
  while IFS= read -r want; do
    printf '%s\n' "$entries" | grep -qxF -- "$want" || missing+="$want"$'\n'
  done < <(required_files)
  lessons="$(required_files | grep -c '^ontomeme-notes/')"
  fonts="$(required_files | grep -c '^fonts/')"
  if [ -n "$missing" ]; then
    problem "required files are missing:"
    printf '%s' "$missing" | sed 's/^/        /'
  else
    echo "ok    packs project.binary, note.tscn.remap, mcp/note_guide.md, $lessons ontomeme-notes lessons and $fonts font imports"
  fi
}

# check_private_bytes: no line of $forbidden matches the bytes holding the
# pack. On a match, name the packed files that hold it.
check_private_bytes() {
  local hits files tmp
  if [ ! -f "$forbidden" ]; then
    echo "note  no ${forbidden#"$repo"/} here, so the private-name byte check was skipped"
    return
  fi
  hits="$(pck_list --cat "$artifact" | LC_ALL=C grep -aoE -f "$forbidden" | LC_ALL=C sort -u | head -n 10)"
  if [ -z "$hits" ]; then
    echo "ok    no bytes match ${forbidden#"$repo"/}"
    return
  fi
  tmp="$(mktemp -d)"
  pck_list --extract "$tmp" "$artifact"
  files="$(cd "$tmp" && LC_ALL=C grep -rlaE -f "$forbidden" . | sed 's|^\./||' | sort)"
  rm -rf "$tmp"
  problem "bytes match ${forbidden#"$repo"/}: $(printf '%s\n' "$hits" | paste -sd ' ' -)"
  printf '%s\n' "${files:-(outside the packed files)}" | sed 's/^/        in /'
}

if ! entries="$(pck_list "$artifact")"; then
  echo "FAIL  $artifact: no pack to check"
  exit 1
fi
count="$(printf '%s\n' "$entries" | grep -c .)"
echo "pack  $artifact: $count files"
check_dev_files
check_required
check_private_bytes
if [ "$problems" -eq 0 ]; then
  echo "PASS  $artifact"
else
  echo "FAIL  $artifact: $problems problems"
  exit 1
fi
