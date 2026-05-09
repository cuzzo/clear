#!/usr/bin/env bash
set -euo pipefail

bundle exec prspec spec/
./clear test transpile-tests/

find examples benchmarks -type f -name '*.cht' -print0 |
  sort -z |
  while IFS= read -r -d '' file; do
    ruby src/backends/transpiler.rb "$file" >/dev/null
  done
