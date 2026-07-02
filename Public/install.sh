#!/bin/sh
# SwiftServe installer — fetches the latest release binary into ~/.local/bin.
# Usage:  curl -fsSL https://swiftserve.dev/install.sh | sh
# Override the destination:  BINDIR=/usr/local/bin sh install.sh
set -eu

REPO="nanoncore/swiftserve"
BINDIR="${BINDIR:-$HOME/.local/bin}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Darwin) platform="macos-universal" ;;
  Linux)
    case "$arch" in
      x86_64) platform="linux-x86_64" ;;
      aarch64|arm64) platform="linux-aarch64" ;;
      *) echo "unsupported Linux arch: $arch — build from source: https://github.com/$REPO" >&2; exit 1 ;;
    esac ;;
  *) echo "unsupported OS: $os — build from source: https://github.com/$REPO" >&2; exit 1 ;;
esac

echo "🍦 SwiftServe installer"
tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
if [ -z "$tag" ]; then
  echo "No releases yet. Build from source instead:" >&2
  echo "  git clone https://github.com/$REPO && cd swiftserve && make install" >&2
  exit 1
fi

asset="swiftserve-$tag-$platform.tar.gz"
url="https://github.com/$REPO/releases/download/$tag/$asset"
sums="https://github.com/$REPO/releases/download/$tag/checksums.txt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "→ downloading $asset ($tag)"
curl -fsSL "$url" -o "$tmp/$asset"
curl -fsSL "$sums" -o "$tmp/checksums.txt"

echo "→ verifying checksum"
expected=$(grep " $asset\$" "$tmp/checksums.txt" | cut -d' ' -f1)
actual=$(shasum -a 256 "$tmp/$asset" 2>/dev/null | cut -d' ' -f1 \
  || sha256sum "$tmp/$asset" | cut -d' ' -f1)
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "checksum mismatch — refusing to install" >&2
  exit 1
fi

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$BINDIR"
install -m 0755 "$tmp/swiftserve" "$BINDIR/swiftserve"

echo "✅ swiftserve $tag → $BINDIR/swiftserve"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "⚠️  Add to PATH:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac
echo "Try:  swiftserve find --capability \"noise cancellation\" --platform macos"
