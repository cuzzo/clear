# frozen_string_literal: true

# Rewrites spec/fixtures/golden_shard from a collect's widest shard.
#
# Run this only when a change to the trace document is intended: the fixture
# exists to make an unintended one fail.
#
#   bundle exec tools/nil-kill collect -- <workload>
#   bundle exec ruby gems/nil-kill/tools/record_golden_shard.rb

require "fileutils"
require "json"
require "zlib"
require_relative "../lib/nil_kill"

runs = Dir.glob(File.join(NilKill::RUNTIME_DIR, "runs", "*", "command-*"))
abort "no collect shards under #{NilKill::RUNTIME_DIR}; run a collect first" if runs.empty?

# The widest shard, so a byte-compare against it exercises the most rules.
widest = runs.max_by do |shard|
  calls = Dir.glob(File.join(shard, "runtime-calls-*.jsonl.gz")).first
  calls ? Zlib::GzipReader.open(calls) { |gz| gz.each_line.count } : -1
end

fixture = File.expand_path("../spec/fixtures/golden_shard", __dir__)
FileUtils.rm_rf(fixture)
FileUtils.mkdir_p(File.join(fixture, "input"))
Dir.glob(File.join(widest, "*.jsonl.gz")).each { |path| FileUtils.cp(path, File.join(fixture, "input")) }
FileUtils.cp(Dir.glob(File.join(widest, "collector-raw-*.json.gz")).first, File.join(fixture, "input"))
FileUtils.cp(File.join(widest, "runtime-trace.json.gz"), File.join(fixture, "expected-runtime-trace.json.gz"))

# Only the digest is read from the plan, and the plan itself is ten megabytes.
plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
digest = plan.dig("runtime_evidence", "plan_digest") || plan["plan_digest"]
File.write(File.join(fixture, "plan-digest.json"), JSON.generate("plan_digest" => digest))

puts "recorded #{File.basename(widest)} to #{fixture}"
