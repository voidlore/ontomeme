#!/usr/bin/env bash
# Find dead links between the Markdown files of a tree. Every [text](target)
# link, [label]: target definition and backticked `name.md` reference must name
# a file or folder that exists, relative to the linking file's folder or to
# <root>. Skipped: web links (any scheme, such as https: or mailto:), #anchors
# and GitHub's own pages (../../releases, ../../issues, ...). A #... or ?...
# part is cut off a target before the check. Fenced code blocks and code spans
# are not links.
#   scripts/check_md_links.sh <root> [file.md ...]
# Without files it checks every *.md under <root>. Prints "file:line: target"
# for each dead link and exits 1 if there is any.
set -euo pipefail
root="${1:?usage: scripts/check_md_links.sh <root> [file.md ...]}"
shift
cd "$root"

# Prints "file<TAB>line<TAB>target" for every link-like target in the files.
# shellcheck disable=SC2016  # an awk program: its $0 is awk's, not the shell's
extract='
function fence_run(s,   c, n) {
  sub(/^ ? ? ?/, "", s)
  c = substr(s, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0
  while (substr(s, n + 1, 1) == c) n++
  if (n < 3) return 0
  fence_char = c
  fence_rest = substr(s, n + 1)
  return n
}
# Replaces code spans by a space and keeps their contents in spans[1..nspans].
function cut_code_spans(s,   out, i, n, run, j, m, stop) {
  out = ""; nspans = 0; i = 1; n = length(s)
  while (i <= n) {
    if (substr(s, i, 1) != "`") { out = out substr(s, i, 1); i++; continue }
    run = 0
    while (substr(s, i + run, 1) == "`") run++
    stop = 0; j = i + run
    while (j <= n) {
      if (substr(s, j, 1) != "`") { j++; continue }
      m = 0
      while (substr(s, j + m, 1) == "`") m++
      if (m == run) { stop = j; break }
      j += m
    }
    if (!stop) { out = out substr(s, i, run); i += run; continue }
    spans[++nspans] = substr(s, i + run, stop - i - run)
    out = out " "
    i = stop + run
  }
  return out
}
function emit(target) { if (target != "") print file "\t" FNR "\t" target }
FNR == 1 { file = FILENAME; sub(/^\.\//, "", file); fence = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  if (fence) {
    n = fence_run(line)
    if (n >= fence && fence_char == open_char && fence_rest ~ /^[ \t]*$/) fence = 0
    next
  }
  n = fence_run(line)
  if (n && !(fence_char == "`" && index(fence_rest, "`"))) { fence = n; open_char = fence_char; next }

  prose = cut_code_spans(line)
  for (k = 1; k <= nspans; k++) {
    s = spans[k]
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    if (s ~ /\.md$/ && s !~ /[ \t*<>{}$|]/ && s !~ /(^|\/)\.md$/) emit(s)
  }
  if (prose ~ /^ ? ? ?\[[^]]+\]:[ \t]*[^ \t]/) {
    t = prose
    sub(/^ ? ? ?\[[^]]+\]:[ \t]*/, "", t)
    sub(/[ \t].*$/, "", t)
    gsub(/^<|>$/, "", t)
    emit(t)
  }
  rest = prose
  while (match(rest, /\]\(/)) {
    rest = substr(rest, RSTART + 2)
    if (substr(rest, 1, 1) == "<") {
      t = substr(rest, 2)
      sub(/>.*$/, "", t)
    } else {
      t = rest
      sub(/[ \t)].*$/, "", t)
    }
    emit(t)
  }
}
'

links() {
  if [ "$#" -gt 0 ]; then
    awk "$extract" "$@"
  else
    find . -name .git -prune -o -type f -name '*.md' -print0 | xargs -0 awk "$extract"
  fi
}

github_route='^(\.\./)+(releases|issues|discussions|security|pulls|wiki)(/|$)'
found="$(links "$@" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n)"
dead=0
while IFS="$(printf '\t')" read -r file line target; do
  t="${target%%#*}"
  t="${t%%\?*}"
  t="${t//%20/ }"
  [ -n "$t" ] || continue
  [[ $t =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && continue
  [[ $t =~ $github_route ]] && continue
  dir="."
  case "$file" in */*) dir="${file%/*}" ;; esac
  if [ "${t#/}" != "$t" ]; then
    [ -e ".$t" ] && continue
  elif [ -e "$dir/$t" ] || [ -e "$t" ]; then
    continue
  fi
  echo "$file:$line: $target"
  dead=$((dead + 1))
done <<<"$found"

if [ "$dead" -gt 0 ]; then
  echo "$dead dead link(s) under $root" >&2
  exit 1
fi
