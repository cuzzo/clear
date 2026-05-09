#!/usr/bin/env bash
set -euo pipefail

bundle exec srb tc
bundle exec ruby -c tools/nil-kill.rb
bundle exec ruby -c tools/nil-kill/runtime_trace.rb
