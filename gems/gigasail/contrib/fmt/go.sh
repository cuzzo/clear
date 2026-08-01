#!/bin/sh
# Recommended Go pre-test gate. Runs `gofmt -l` on the changed .go files (from
# $GIGA_CHANGED) and fails if any are unformatted. Skips cleanly when the Go
# toolchain is unavailable.
set -eu

if ! command -v gofmt >/dev/null 2>&1; then
  echo "contrib:fmt:go - gofmt not installed, skipping"
  exit 0
fi

files=""
for f in ${GIGA_CHANGED:-}; do
  case "$f" in *.go) [ -f "$f" ] && files="$files $f" ;; esac
done

if [ -z "$files" ]; then
  echo "contrib:fmt:go - no changed .go files"
  exit 0
fi

unformatted=$(gofmt -l $files)
if [ -n "$unformatted" ]; then
  echo "contrib:fmt:go - unformatted files:"
  echo "$unformatted"
  exit 1
fi
echo "contrib:fmt:go - ok$files"
