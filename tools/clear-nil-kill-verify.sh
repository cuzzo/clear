#!/usr/bin/env bash
set -euo pipefail

bundle exec srb tc
bundle exec prspec spec/
bundle exec prspec gems/nil-kill/spec
bundle exec ruby -c tools/nil-kill
bundle exec ruby -c gems/nil-kill/lib/nil_kill.rb
bundle exec ruby -c gems/nil-kill/lib/nil_kill/runtime_trace.rb
bundle exec ruby -c gems/nil-kill/lib/nil_kill/z3_solver.rb
