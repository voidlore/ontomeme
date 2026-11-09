#!/usr/bin/env bash
# Install jsign 7.5, the Java Authenticode signer windows_sign.sh runs, into
# DEST_DIR. It signs from Linux with any key jsign supports: a PKCS12 file,
# Azure Trusted Signing, SSL.com eSigner and the cloud HSMs.
#
#   JSIGN="$(scripts/sign/install_jsign.sh "$RUNNER_TEMP/bin")"
#
# Downloads the release jar with `curl -fsSL -o` and checks its sha256 against
# the value pinned below before anything is installed; a mismatch removes the
# download and exits 1. Installs DEST_DIR/jsign-7.5.jar and DEST_DIR/jsign, a
# wrapper running `java -jar` on it (ubuntu-latest has Java). Prints the
# wrapper's path on stdout; with GITHUB_PATH set it also adds DEST_DIR to later
# steps' PATH. The pin is GitHub's sha256 digest of the release asset:
#   https://github.com/ebourg/jsign/releases/tag/7.5
set -euo pipefail

JSIGN_VERSION=7.5
JSIGN_SHA256=602a51c3545a6dc4fb99bd2ea7152b26d1345916d0c93ddfbd5936cb735af91c
JSIGN_URL="https://github.com/ebourg/jsign/releases/download/$JSIGN_VERSION/jsign-$JSIGN_VERSION.jar"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# fetch_verified URL SHA256 OUT: download URL to OUT; on a sha256 mismatch
# remove OUT and fail.
fetch_verified() {
  local url="$1" want="$2" out="$3" got
  if ! curl -fsSL -o "$out" "$url"; then
    rm -f "$out"
    echo "install_jsign: download failed: $url" >&2
    return 1
  fi
  got="$(sha256_of "$out")"
  if [ "$got" != "$want" ]; then
    rm -f "$out"
    echo "install_jsign: sha256 mismatch for $url (got $got, pinned $want); nothing installed" >&2
    return 1
  fi
}

# install_from URL SHA256 DEST: download and verify the jar at URL, then
# install it as DEST/jsign-$JSIGN_VERSION.jar with the DEST/jsign wrapper.
install_from() {
  local url="$1" sha="$2" dest="$3" jar staging status=0
  mkdir -p "$dest"
  dest="$(cd "$dest" && pwd)"
  jar="jsign-$JSIGN_VERSION.jar"
  staging="$(mktemp -d)"
  fetch_verified "$url" "$sha" "$staging/$jar" && mv -f "$staging/$jar" "$dest/$jar" || status=$?
  rm -rf "$staging"
  if [ "$status" -ne 0 ]; then return "$status"; fi
  chmod 644 "$dest/$jar"
  printf '#!/bin/sh\n# jsign %s, installed by scripts/sign/install_jsign.sh\nexec java -jar "$(dirname "$0")/%s" "$@"\n' \
    "$JSIGN_VERSION" "$jar" >"$dest/jsign"
  chmod 755 "$dest/jsign"
  if ! command -v java >/dev/null 2>&1; then
    echo "install_jsign: warning: java is not on PATH, and jsign needs it (Java 8 or later)" >&2
  fi
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest" >>"$GITHUB_PATH"; fi
  echo "$dest/jsign"
}

main() {
  if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "usage: install_jsign.sh DEST_DIR" >&2
    return 2
  fi
  echo "install_jsign: jsign $JSIGN_VERSION into $1" >&2
  install_from "$JSIGN_URL" "$JSIGN_SHA256" "$1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
