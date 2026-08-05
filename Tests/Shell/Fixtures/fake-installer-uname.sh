#!/bin/sh
set -eu

case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' "$INSTALL_TEST_ARCH" ;;
  *) printf '%s\n' Linux ;;
esac
