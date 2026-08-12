#!/bin/bash
# Build the self-hosted parser using the Sorbet-stripped mirror (2.2x faster:
# 203s -> 93s). Swaps compiler/.ruby-rbs in for compiler/ruby, always restores.
# ROOT=<dir> selects the generated CLEAR tree (default compiler/src).
set -uo pipefail
cd /home/yahn/cheat

# An interrupted run leaves the Sorbet-stripped mirror sitting where
# compiler/ruby belongs. The state is recognizable -- the mirror has no sigs --
# and healing it is exactly what the EXIT trap would have done, so do that
# rather than block every later build.
if [ -f compiler/ruby/ast/type.rb ] && ! grep -q '^  sig {' compiler/ruby/ast/type.rb; then
  echo "[selfhost] restoring compiler/ruby after an interrupted run" >&2
  if [ -e compiler/.ruby-original ]; then
    rm -rf compiler/ruby && mv compiler/.ruby-original compiler/ruby
  else
    # The saved copy is gone too; compiler/ruby is fully tracked, so git has it.
    git checkout -- compiler/ruby || exit 1
  fi
elif [ -e compiler/.ruby-original ]; then
  echo "compiler/.ruby-original exists and compiler/ruby is NOT the mirror." >&2
  echo "Inspect both, then keep the one you want as compiler/ruby." >&2
  exit 1
fi

# The mirror is generated from compiler/ruby. If it is stale, this script
# silently builds against pre-fix compiler sources -- which once reproduced a
# bug that had already been fixed.
newest_src=$(find compiler/ruby -name '*.rb' -newer compiler/.ruby-rbs/ast/type.rb -print -quit 2>/dev/null)
if [ ! -d compiler/.ruby-rbs ] || [ -n "$newest_src" ]; then
  echo "[selfhost] compiler/.ruby-rbs is stale -- regenerating" >&2
  ruby tools/sorbet_strip.rb >/dev/null || exit 1
fi

restore() {
  if [ -e compiler/.ruby-original ]; then
    rm -rf compiler/ruby && mv compiler/.ruby-original compiler/ruby
  fi
}
trap restore EXIT INT TERM

mv compiler/ruby compiler/.ruby-original
mkdir -p compiler/ruby
(cd compiler/.ruby-rbs && find . -name '*.rb' -not -path './sig/*' -exec cp --parents {} ../ruby/ \;)

export CLEAR_EXTRA_LINK_LIBS=pcre2-8
timeout 1800 ruby tools/parser_compat.rb --out tmp/parser-compat --keep \
  --generated-root "/home/yahn/cheat/${ROOT:-compiler/src}" 2>&1 \
  | grep -vE '^\s*--pkg|sorbet-runtime|_methods\.rb|^\s+from |\[Warning\]|\[Info\]|^\s*$' \
  | sed 's/--pkg [^ ]*//g' | tail -"${TAIL:-14}"
