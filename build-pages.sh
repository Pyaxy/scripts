#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR="$SCRIPT_DIR/dist"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/snell-alpine"

# Only files copied here are published by Cloudflare Pages.
cp "$SCRIPT_DIR/_redirects" "$DIST_DIR/_redirects"
cp "$SCRIPT_DIR/snell-alpine/snell-alpine-lowspace.sh" \
  "$DIST_DIR/snell-alpine/snell-alpine-lowspace.sh"
