#!/bin/sh
set -eu

output=
previous=
for argument in "$@"; do
  if [ "$previous" = "-o" ]; then
    output=$argument
    break
  fi
  previous=$argument
done

case "$output" in
  *checksums.txt) cp "$INSTALL_TEST_CHECKSUMS" "$output" ;;
  *) cp "$INSTALL_TEST_ARCHIVE" "$output" ;;
esac
