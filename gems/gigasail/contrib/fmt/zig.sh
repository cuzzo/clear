#!/bin/sh
# Recommended Zig pre-test gate. Runs `zig fmt --check` on the changed .zig files
# (from $GIGA_CHANGED). Skips cleanly when zig is unavailable. Fails when a file
# is not formatted.
set -eu

if ! command -v zig >/dev/null 2>&1; then
  echo "contrib:fmt:zig - zig not installed, skipping"
  exit 0
fi

files=""
for f in ${GIGA_CHANGED:-}; do
  case "$f" in *.zig) [ -f "$f" ] && files="$files $f" ;; esac
done

if [ -z "$files" ]; then
  echo "contrib:fmt:zig - no changed .zig files"
  exit 0
fi

echo "contrib:fmt:zig - zig fmt --check$files"
exec zig fmt --check $files
