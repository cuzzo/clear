#!/usr/bin/env bash
# Type-check the merged self-host package's emitted Zig WITHOUT linking.
#
# `./clear build` re-transpiles 24 units and then links; when only the Zig is
# in question that is ~15 minutes for an answer `zig build-obj` gives in
# seconds -- against the exact file whose line numbers the errors quote.
#
#   tools/scc_zig_check.sh [package-name]
#
# Reads the newest .clear-cache entry containing the package's .zig, so run it
# after any build that emitted one.
set -uo pipefail
cd "$(dirname "$0")/.."
pkg="${1:-scc_function_return_24}"
zig_bin="${CLEAR_ZIG:-$HOME/zig-x86_64-linux-0.16.0/zig}"

cache=$(ls -td zig/.clear-cache/*/ 2>/dev/null | while read -r d; do
  [ -f "$d/$pkg.zig" ] && echo "$d" && break
done)
if [ -z "$cache" ]; then
  echo "scc_zig_check: no .clear-cache entry holds $pkg.zig -- build once first" >&2
  exit 2
fi

echo "scc_zig_check: $cache$pkg.zig"
tmp_obj=$(mktemp -u --suffix=.o)
out=$(cd "$cache" && "$zig_bin" build-obj "$pkg.zig" -femit-bin="$tmp_obj" 2>&1)
status=$?
rm -f "$tmp_obj"
if [ -z "$out" ]; then
  echo "scc_zig_check: 0 errors"
  exit 0
fi
echo "$out" | grep -E "error:" | head -"${SCC_ERROR_LIMIT:-40}"
echo "--- classes:"
echo "$out" | grep -E "error:" | sed 's/.*error: //' | sort | uniq -c | sort -rn | head -15
exit $status
