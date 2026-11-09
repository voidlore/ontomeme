#!/usr/bin/env bash
# Checks the README people read on GitHub. Fails, naming the line, when:
#   1. a relative link, image, or HTML src/href names a path that doesn't
#      exist, an empty file or an empty folder;
#   2. such a path is not published: it fails .publish/allow or matches
#      .publish/deny (.publish/select.sh, the filter publish.sh copies by);
#   3. a word in a code span names a file of this repo that is not published,
#      such as `AGENTS.md`;
#   4. an `Ontomeme-<version>-...` download in the install table is missing
#      from the release body in .github/workflows/release.yml, where
#      ${{ env.VERSION }} stands for <version>;
#   5. a <video> or <source> src is a relative path: GitHub doesn't play a
#      video from the repository, so show an image and link the video.
# Checks 2 and 3 need .publish/, so the public repo, where every file is
# published, skips them. Web links (any scheme), #anchors and GitHub's own
# pages (../../releases, ../../issues, ...) are not checked. Fenced code
# blocks are skipped, and a code span is not a link.
# Usage: scripts/check_readme.sh [README]
#   README defaults to README.md at the repository root (the folder above
#   scripts/); paths resolve against that root whichever file is checked.
#   Prints RESULT: ALL PASS, or exits 1 after naming each problem.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
readme="${1:-$root/README.md}"
[ -f "$readme" ] || { echo "check_readme.sh: no such file: $readme" >&2; exit 2; }
name="$(basename "$readme")"
selector="$root/.publish/select.sh"
release_yml="$root/.github/workflows/release.yml"
github_route='^(\.\./)+(releases|issues|discussions|security|pulls|wiki)(/|$)'

# Prints one tab-separated record per thing to check, outside fenced code:
#   link <line> <target>                 [text](target), ![alt](target), [ref]: target
#   html <line> <tag> <attr> <value>     src= and href= of an HTML tag, which
#                                        may span lines; <line> is the value's
#   code <line> <in a table row: 0|1> <code span>
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
function emit_link(t) { if (t != "") print "link\t" FNR "\t" t }
function count_newlines(s) { return gsub(/\n/, "", s) }
# Every src= and href= in one HTML tag; attribute names in any case. The tag
# starts on line ln and may span lines (joined by "\n"): each value is
# reported on the line it is on.
function emit_attrs(tag, ln,   flat, tname, lower, at, v, q, e, used) {
  flat = tag
  gsub(/\n/, " ", flat)   # same length, so offsets in flat are offsets in tag
  tname = tolower(flat)
  sub(/^</, "", tname)
  sub(/[^a-z0-9].*$/, "", tname)
  lower = tolower(flat)
  used = 0
  while (match(lower, /[ \t\/](src|href)[ \t]*=[ \t]*/)) {
    at = substr(lower, RSTART + 1, RLENGTH - 1)
    sub(/[ \t]*=.*$/, "", at)
    used += RSTART + RLENGTH - 1
    v = substr(flat, RSTART + RLENGTH)
    flat = v
    lower = substr(lower, RSTART + RLENGTH)
    q = substr(v, 1, 1)
    if (q == "\"" || q == "\047") {
      v = substr(v, 2)
      e = index(v, q)
      if (e) v = substr(v, 1, e - 1)
    } else {
      sub(/[ \t>].*$/, "", v)
    }
    print "html\t" (ln + count_newlines(substr(tag, 1, used))) "\t" tname "\t" at "\t" v
  }
}
{
  line = $0
  sub(/\r$/, "", line)
  if (fence) {
    n = fence_run(line)
    if (n >= fence && fence_char == open_char && fence_rest ~ /^[ \t]*$/) fence = 0
    next
  }
  n = fence_run(line)
  if (n && !(fence_char == "`" && index(fence_rest, "`"))) { fence = n; open_char = fence_char; pending = ""; next }
  if (line ~ /^[ \t]*$/) { pending = ""; next }   # a tag never spans a blank line

  prose = cut_code_spans(line)
  table = (prose ~ /^[ \t]*\|/) ? 1 : 0
  for (k = 1; k <= nspans; k++) print "code\t" FNR "\t" table "\t" spans[k]
  if (prose ~ /^ ? ? ?\[[^]]+\]:[ \t]*[^ \t]/) {
    t = prose
    sub(/^ ? ? ?\[[^]]+\]:[ \t]*/, "", t)
    sub(/[ \t].*$/, "", t)
    gsub(/^<|>$/, "", t)
    emit_link(t)
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
    emit_link(t)
  }
  # HTML tags. One the line leaves open, such as "<video" or a wrapped
  # "<img src=..." (Prettier writes them so), is pending: it goes on over the
  # next lines of the paragraph until its ">".
  rest = prose
  if (pending != "") {
    e = index(rest, ">")
    if (!e) { pending = pending "\n" rest; next }
    emit_attrs(pending "\n" substr(rest, 1, e), pending_line)
    pending = ""
    rest = substr(rest, e + 1)
  }
  while (match(rest, /<[A-Za-z][A-Za-z0-9]*[^>]*>/)) {
    tag = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    emit_attrs(tag, FNR)   # its own match() moves RSTART and RLENGTH
  }
  # No ">" follows any "<name" left in rest, so the first one is still open.
  # (An autolink, <https://...>, is not a tag.)
  if (match(rest, /<[A-Za-z][A-Za-z0-9]*([ \t\/]|$)/)) {
    pending = substr(rest, RSTART)
    pending_line = FNR
  }
}
'

problems=0
fail() {   # <line|""> <message>
  problems=$((problems + 1))
  echo "FAIL  $name${1:+:$1}: $2"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::error file=$name${1:+,line=$1}::$2"
  fi
}

# A link target as a repository path: no #fragment or ?query, %20 as a space,
# no ./ or a/../ parts ("" for the root). Returns 1 if it leaves the repo.
repo_path() {
  local t="$1" part
  local -a parts out=()
  t="${t%%#*}"
  t="${t%%\?*}"
  t="${t//%20/ }"
  IFS=/ read -r -a parts <<<"$t"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..)
        [ "${#out[@]}" -gt 0 ] || return 1
        out=("${out[@]:0:${#out[@]}-1}")
        ;;
      *) out+=("$part") ;;
    esac
  done
  (IFS=/; printf '%s\n' "${out[*]-}")
}

publish_checks=0
if [ -x "$selector" ]; then publish_checks=1; fi

# Is the file at this repository path published? A folder is published when
# one of its files is.
published() {
  if [ -d "$root/$1" ]; then
    [ -n "$( (cd "$root" && find "$1" -type f) | "$selector" --stdin)" ]
  else
    [ "$(printf '%s\n' "$1" | "$selector" --stdin)" = "$1" ]
  fi
}

# Checks 1 and 2 for one link or src target.
check_target() {   # <line> <target>
  local t="$2" p
  [ -n "${t%%#*}" ] || return 0
  [[ $t =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && return 0
  [[ $t =~ $github_route ]] && return 0
  if ! p="$(repo_path "$t")"; then
    fail "$1" "$t points outside the repository"
    return 0
  fi
  [ -n "$p" ] || return 0
  if [ ! -e "$root/$p" ]; then
    fail "$1" "$t does not exist"
  elif [ -f "$root/$p" ] && [ ! -s "$root/$p" ]; then
    fail "$1" "$t is empty"
  elif [ -d "$root/$p" ] && [ -z "$(ls -A "$root/$p")" ]; then
    fail "$1" "$t is an empty folder"
  elif [ "$publish_checks" -eq 1 ] && ! published "$p"; then
    fail "$1" "$t is not published (.publish/allow, .publish/deny): the public README would link to nothing"
  fi
}

# Check 3 for one code span: each word that names a file of this repo.
check_code_words() {   # <line> <code span>
  local w p
  local -a words
  read -r -a words <<<"$2"
  for w in ${words[@]+"${words[@]}"}; do
    w="${w#res://}"
    case "$w" in /* | '~'*) continue ;; esac
    p="$(repo_path "$w")" || continue
    if [ -n "$p" ] && [ -f "$root/$p" ] && ! published "$p"; then
      fail "$1" "\`$w\` is a file of this repo that is not published (.publish/allow, .publish/deny)"
    fi
  done
}

# The text of every "body: |" block in release.yml, ${{ env.VERSION }} as
# <version>.
release_body() {
  awk '
    body && /^[ \t]*$/ { print; next }
    body { match($0, /^[ \t]*/); if (RLENGTH > indent) { print; next }; body = 0 }
    /^[ \t]*body:[ \t]*[|>]/ { match($0, /^[ \t]*/); indent = RLENGTH; body = 1 }
  ' "$release_yml" | sed -E 's/\$\{\{[[:space:]]*env\.VERSION[[:space:]]*\}\}/<version>/g'
}

links=0
spans=0
downloads=()
download_lines=()
while IFS=$'\t' read -r kind line a b c; do
  case "$kind" in
    link)
      links=$((links + 1))
      check_target "$line" "$a"
      ;;
    html)
      links=$((links + 1))
      check_target "$line" "$c"
      if [ "$b" = src ] && { [ "$a" = video ] || [ "$a" = source ]; } \
        && ! [[ $c =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
        fail "$line" "<$a src=\"$c\">: GitHub doesn't play a video from the repository; show an image and link the video"
      fi
      ;;
    code)
      spans=$((spans + 1))
      if [ "$publish_checks" -eq 1 ]; then check_code_words "$line" "$b"; fi
      case "$a:$b" in
        '1:Ontomeme-<version>-'*)
          downloads+=("$b")
          download_lines+=("$line")
          ;;
      esac
      ;;
  esac
done < <(awk "$extract" "$readme")

if [ "${#downloads[@]}" -eq 0 ]; then
  fail "" "the install table names no Ontomeme-<version>-* download"
elif [ ! -f "$release_yml" ]; then
  fail "" "no .github/workflows/release.yml to check the install table's downloads against"
else
  body="$(release_body)"
  for i in "${!downloads[@]}"; do
    if ! grep -qF -- "${downloads[$i]}" <<<"$body"; then
      fail "${download_lines[$i]}" "\`${downloads[$i]}\` is not in the release body of .github/workflows/release.yml"
    fi
  done
fi

if [ "$publish_checks" -eq 0 ]; then
  echo "SKIP  publish checks: no .publish/select.sh here (the public repo publishes every file it has)"
fi
if [ "$problems" -gt 0 ]; then
  echo "RESULT: FAILED ($problems problem(s) in $name)"
  exit 1
fi
echo "RESULT: ALL PASS ($links links and sources, $spans code spans, ${#downloads[@]} downloads in $name)"
