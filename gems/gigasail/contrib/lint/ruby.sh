#!/bin/sh
# Recommended Ruby pre-test gate. Lints only the changed .rb files (from
# $GIGA_CHANGED) with rubocop. Skips cleanly when rubocop is unavailable - a
# recommended gate should not become a hard dependency. Fails on violations.
set -eu

if ! command -v rubocop >/dev/null 2>&1; then
  echo "contrib:lint:ruby - rubocop not installed, skipping"
  exit 0
fi

files=""
for f in ${GIGA_CHANGED:-}; do
  case "$f" in *.rb) [ -f "$f" ] && files="$files $f" ;; esac
done

if [ -z "$files" ]; then
  echo "contrib:lint:ruby - no changed .rb files"
  exit 0
fi

echo "contrib:lint:ruby - rubocop$files"
exec rubocop --force-exclusion $files
