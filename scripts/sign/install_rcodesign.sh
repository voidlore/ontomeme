#!/usr/bin/env bash
# Install rcodesign (apple-codesign 0.29.0), the Linux-capable signer and
# notarizer macos_sign.sh and macos_notarize.sh run, into DEST_DIR.
#
#   RCODESIGN="$(scripts/sign/install_rcodesign.sh "$RUNNER_TEMP/bin")"
#
# Downloads the release tarball for this host with `curl -fsSL -o`, checks its
# sha256 against the value pinned below before extracting anything, and
# installs DEST_DIR/rcodesign (0755). Prints that path on stdout; with
# GITHUB_PATH set (GitHub Actions) it also adds DEST_DIR to later steps' PATH.
# A sha256 mismatch removes the download, extracts nothing and exits 1.
# The pins come from the release's SHA256SUMS:
#   https://github.com/indygreg/apple-platform-rs/releases/tag/apple-codesign%2F0.29.0
set -euo pipefail

RCODESIGN_VERSION=0.29.0
RELEASE_URL="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$RCODESIGN_VERSION"

# host_asset: print "TRIPLE SHA256" of the release tarball for this machine.
host_asset() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) echo "x86_64-unknown-linux-musl dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002" ;;
    Linux/aarch64 | Linux/arm64) echo "aarch64-unknown-linux-musl 4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f" ;;
    Darwin/arm64) echo "aarch64-apple-darwin d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a" ;;
    Darwin/x86_64) echo "x86_64-apple-darwin 14ef11bedd51a8d95eafd767939ae96d5900e5a61511bef75bb21db6e7c74140" ;;
    *)
      echo "install_rcodesign: no pinned apple-codesign $RCODESIGN_VERSION build for $(uname -s) $(uname -m)" >&2
      return 1
      ;;
  esac
}

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
    echo "install_rcodesign: download failed: $url" >&2
    return 1
  fi
  got="$(sha256_of "$out")"
  if [ "$got" != "$want" ]; then
    rm -f "$out"
    echo "install_rcodesign: sha256 mismatch for $url (got $got, pinned $want); nothing installed" >&2
    return 1
  fi
}

# install_from URL SHA256 MEMBER DEST: download and verify the tarball at URL,
# then install its MEMBER (the rcodesign binary) as DEST/rcodesign.
install_from() {
  local url="$1" sha="$2" member="$3" dest="$4" staging status=0
  mkdir -p "$dest"
  dest="$(cd "$dest" && pwd)"
  staging="$(mktemp -d)"
  {
    fetch_verified "$url" "$sha" "$staging/rcodesign.tar.gz" &&
      tar -xzf "$staging/rcodesign.tar.gz" -C "$staging" "$member" &&
      mv -f "$staging/$member" "$dest/rcodesign" &&
      chmod 755 "$dest/rcodesign"
  } || status=$?
  rm -rf "$staging"
  if [ "$status" -ne 0 ]; then return "$status"; fi
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest" >>"$GITHUB_PATH"; fi
  echo "$dest/rcodesign"
}

main() {
  local asset triple sha name
  if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "usage: install_rcodesign.sh DEST_DIR" >&2
    return 2
  fi
  asset="$(host_asset)"
  triple="${asset% *}" sha="${asset#* }"
  name="apple-codesign-$RCODESIGN_VERSION-$triple"
  echo "install_rcodesign: apple-codesign $RCODESIGN_VERSION ($triple) into $1" >&2
  install_from "$RELEASE_URL/$name.tar.gz" "$sha" "$name/rcodesign" "$1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
