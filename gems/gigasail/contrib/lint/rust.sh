#!/bin/sh
# Recommended Rust pre-test gate. Runs `rustfmt --check` on the changed .rs files
# (from $GIGA_CHANGED). Skips cleanly when rustfmt is unavailable. Fails when a
# file is not formatted.
set -eu

if ! command -v rustfmt >/dev/null 2>&1; then
  echo "contrib:lint:rust - rustfmt not installed, skipping"
  exit 0
fi

files=""
for f in ${GIGA_CHANGED:-}; do
  case "$f" in *.rs) [ -f "$f" ] && files="$files $f" ;; esac
done

if [ -z "$files" ]; then
  echo "contrib:lint:rust - no changed .rs files"
  exit 0
fi

echo "contrib:lint:rust - rustfmt --check$files"
exec rustfmt --edition 2021 --check $files
