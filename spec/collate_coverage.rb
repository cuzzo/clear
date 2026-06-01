#!/usr/bin/env ruby
# Merge multi-source coverage entries (RSpec-w1-..., transpile-tests-...,
# clear-cli-..., etc.) from coverage/.resultset.json into a single
# "RSpec" entry that RubyCritic's coverage analyser can read.
#
# Why: RubyCritic reads `results.first` from the resultset
# (vendor/.../analysers/coverage.rb:16). With multiple entries it sees
# only one slice. Without this collation the simple_cov_index report
# shows partial coverage for the first entry only.
#
# How: SimpleCov's own ResultMerger.merge_results does the per-line
# arithmetic (handling never_lines, branch coverage, etc.) correctly.
# A hand-rolled "max hits per line" merge gets relevant_lines wrong
# because some entries trace files they didn't actually load (zero
# hits but inflated relevant counts), which my merge counted as
# uncovered when SimpleCov drops them.
#
# Usage:
#   bundle exec prspec spec/                                # spec coverage
#   COVERAGE=1 bundle exec ruby transpile-tests/gen.rb         # .cht compile/lower coverage
#   bundle exec ruby spec/collate_coverage.rb               # collate -> RSpec
#   bundle exec rubycritic src/ --no-browser                # consume

require "simplecov"
require "json"

resultset_path = File.expand_path("../coverage/.resultset.json", __dir__)
unless File.exist?(resultset_path)
  warn "no #{resultset_path} -- run specs first"
  exit 1
end

# SimpleCov needs an active config (filters, root) for ResultMerger to
# do its arithmetic. Calling SimpleCov.start would register an at_exit
# that writes a fresh empty "RSpec" entry over our work; instead just
# configure without starting.
SimpleCov.configure do
  enable_coverage :branch
  add_filter "/spec/"
  add_filter "/transpile-tests/"
  add_filter "/vendor/"
  add_filter "/examples/"
  add_filter "/benchmarks/"
  add_filter do |source_file|
    source_file.filename.start_with?(File.join(SimpleCov.root, "tools/"))
  end
  add_group "Tools", "src/tools"
end

original_keys = JSON.parse(File.read(resultset_path)).keys
merged = SimpleCov::ResultMerger.merge_results(resultset_path, ignore_timeout: true)
abort "merge produced nothing" unless merged

# Persist back as a single "RSpec" entry. SimpleCov::Result#to_hash
# already returns the right shape ({ command_name => { coverage:, timestamp: } });
# we rename the command to "RSpec" so RubyCritic's `results.first` always
# points at the merged data regardless of which entry was lexically first.
hash_form = merged.to_hash
_, payload = hash_form.first
File.write(resultset_path, JSON.pretty_generate("RSpec" => payload))

puts "Collated #{original_keys.size} entries (#{payload['coverage'].size} files) -> single 'RSpec' " \
     "(%.2f%% line coverage)" % merged.covered_percent

# Re-run Cobertura formatter on the merged result so coverage/coverage.xml
# reflects the union of all workers, not just the last one to write it.
# Per-worker writes are racy: each parallel_rspec child invokes its
# at_exit and overwrites coverage.xml with its narrow slice. Doing this
# explicitly post-collate produces a single accurate file for upload.
begin
  require "simplecov-cobertura"
  SimpleCov::Formatter::CoberturaFormatter.new.format(merged)
  puts "Wrote #{File.expand_path('../coverage/coverage.xml', __dir__)}"
rescue LoadError
  warn "simplecov-cobertura not installed; skipping XML emit"
end
