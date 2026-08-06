#!/bin/sh
set -eu

# The fallback is Linux-specific: construct a PATH that contains sha256sum but
# deliberately omits shasum, then run the real installer against local assets.
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "installer checksum fallback: skipped (sha256sum unavailable)"
  exit 0
fi

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
payload="$scratch/payload"
mkdir -p "$fake_bin" "$payload" "$scratch/install"

for tool in mktemp rm grep cut tar gzip mkdir install cp sha256sum; do
  tool_path=$(command -v "$tool")
  ln -s "$tool_path" "$fake_bin/$tool"
done

host_arch=$(uname -m)
case "$host_arch" in
  x86_64) platform=linux-x86_64 ;;
  aarch64|arm64) platform=linux-aarch64 ;;
  *) echo "installer checksum fallback: skipped (unsupported test arch)"; exit 0 ;;
esac

printf '#!/bin/sh\nexit 0\n' > "$payload/swiftserve"
chmod +x "$payload/swiftserve"
mkdir -p \
  "$payload/SwiftServe_SwiftServeCLI.resources/Resources" \
  "$payload/SwiftServe_SwiftServeEvidence.resources/Resources"
printf '{}\n' > "$payload/SwiftServe_SwiftServeCLI.resources/Resources/denylist.seed.json"
printf '{}\n' > "$payload/SwiftServe_SwiftServeEvidence.resources/Resources/capability-dataset.json"
asset="swiftserve-v0.7.0-$platform.tar.gz"
archive="$scratch/$asset"
tar -czf "$archive" -C "$payload" \
  swiftserve SwiftServe_SwiftServeCLI.resources SwiftServe_SwiftServeEvidence.resources
checksum=$(sha256sum "$archive" | cut -d' ' -f1)
printf '%s  %s\n' "$checksum" "$asset" > "$scratch/checksums.txt"

cp "$root/Tests/Shell/Fixtures/fake-installer-curl.sh" "$fake_bin/curl"
chmod +x "$fake_bin/curl"
cp "$root/Tests/Shell/Fixtures/fake-installer-uname.sh" "$fake_bin/uname"
chmod +x "$fake_bin/uname"

PATH="$fake_bin" \
INSTALL_TEST_ARCHIVE="$archive" \
INSTALL_TEST_CHECKSUMS="$scratch/checksums.txt" \
INSTALL_TEST_ARCH="$host_arch" \
BINDIR="$scratch/install" \
/bin/sh "$root/Public/install.sh" v0.7.0 >/dev/null

test -x "$scratch/install/swiftserve"
test -f "$scratch/install/SwiftServe_SwiftServeCLI.resources/Resources/denylist.seed.json"
test -f "$scratch/install/SwiftServe_SwiftServeEvidence.resources/Resources/capability-dataset.json"
echo "installer checksum fallback: sha256sum path passed"
