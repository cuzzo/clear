#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BASELINE_DIR CURRENT_DIR CURRENT_STDOUT" >&2
  exit 2
fi

baseline_dir=$1
current_dir=$2
current_stdout=$3
baseline_stdout="${baseline_dir}.stdout"

diff -q "$baseline_stdout" "$current_stdout"
diff -q "$baseline_dir/report.md" "$current_dir/report.md"

ruby -rjson -e '
  baseline = JSON.parse(File.read(ARGV[0]))
  current = JSON.parse(File.read(ARGV[1]))
  baseline.delete("generated_at")
  current.delete("generated_at")
  abort "normalized evidence differs" unless baseline == current
  puts "byte-equivalent: stdout/report identical; evidence identical except generated_at"
' "$baseline_dir/evidence.json" "$current_dir/evidence.json"
