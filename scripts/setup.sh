#!/bin/sh
# Download and install the Monaspace Krypton font (needed by neovide, see
# lua config guifont). Pinned to a release tag so the link stays stable.
# Idempotent: skips the download if the fonts are already installed.
#
# Usage: scripts/setup.sh

set -eu

version="v1.400"
url="https://github.com/githubnext/monaspace/releases/download/$version/monaspace-static-$version.zip"

case "$(uname)" in
  Darwin) fontdir="$HOME/Library/Fonts/monaspace" ;;
  *)      fontdir="$HOME/.local/share/fonts/monaspace" ;;
esac

if ls "$fontdir"/MonaspaceKrypton-*.otf >/dev/null 2>&1; then
  echo "Monaspace Krypton already installed in $fontdir"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Monaspace $version ..."
curl -fsSL -o "$tmp/monaspace.zip" "$url"
unzip -q "$tmp/monaspace.zip" -d "$tmp"

mkdir -p "$fontdir"
find "$tmp" -name 'MonaspaceKrypton-*.otf' -exec cp {} "$fontdir/" \;

if ls "$fontdir"/MonaspaceKrypton-*.otf >/dev/null 2>&1; then
  echo "Installed $(ls "$fontdir"/MonaspaceKrypton-*.otf | wc -l | tr -d ' ') Krypton faces to $fontdir"
else
  echo "error: no MonaspaceKrypton-*.otf found in release zip" >&2
  exit 1
fi

command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$fontdir"
