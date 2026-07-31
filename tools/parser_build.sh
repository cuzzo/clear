#!/bin/bash
# Build the manually-fixed self-hosted parser and show the first error.
cd /home/yahn/cheat
timeout 1800 ruby tools/parser_compat.rb --out tmp/parser-compat --keep 2>&1 \
  | grep -vE '^\s*--pkg|sorbet-runtime|_methods\.rb|^\s+from |\[Warning\]|\[Info\]|^\s*$' \
  | sed 's/--pkg [^ ]*//g' | tail -14
