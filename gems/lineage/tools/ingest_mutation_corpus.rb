#!/usr/bin/env ruby
# frozen_string_literal: true

# Ingest a Test Miser mutation corpus into lineage.db.
#
# Accepts either a canonical corpus envelope (mutation-corpus.json.zst, as
# published by the test-miser GitHub workflow) or an already-materialized
# directory containing mutant-facts-*.json and weak-tests.sarif. Runs
# `lineage ingest-mutants` for every per-suite facts file and
# `lineage ingest-sarif` for the combined Weak Tests SARIF, completing the
# checkpoint -> ledger path described in
# gems/test-miser/docs/agents/lineage-sync.md.
#
# Usage:
#   ruby ingest_mutation_corpus.rb --db lineage.db --repo . \
#     (--corpus mutation-corpus.json.zst | --materialized DIR) [--commit SHA]

require "json"
require "open3"
require "optparse"
require "tmpdir"

TOOL_ROOT = File.expand_path("../../..", __dir__)

options = {
  db: "lineage.db",
  repo: ".",
  corpus: nil,
  materialized: nil,
  commit: nil,
  lineage_bin: File.expand_path("../target/release/lineage", __dir__),
  artifact_exe: File.join(TOOL_ROOT, "gems/test-miser/exe/test-miser-artifact")
}

OptionParser.new do |opts|
  opts.banner = "Usage: ingest_mutation_corpus.rb [options]"
  opts.on("--db=PATH", "lineage database (default lineage.db)") { |v| options[:db] = v }
  opts.on("--repo=PATH", "repository root (default .)") { |v| options[:repo] = v }
  opts.on("--corpus=FILE", "mutation-corpus.json.zst envelope") { |v| options[:corpus] = v }
  opts.on("--materialized=DIR", "already-materialized corpus directory") { |v| options[:materialized] = v }
  opts.on("--commit=SHA", "commit override (default: the corpus commit)") { |v| options[:commit] = v }
  opts.on("--lineage-bin=PATH", "lineage binary") { |v| options[:lineage_bin] = v }
  opts.on("--test-miser-artifact=PATH", "test-miser-artifact executable") { |v| options[:artifact_exe] = v }
end.parse!

def run!(command, chdir: nil)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir || Dir.pwd)
  unless status.success?
    abort "command failed (#{status.exitstatus}): #{command.join(" ")}\n#{stderr}\n#{stdout}"
  end
  stdout
end

abort "exactly one of --corpus or --materialized is required" unless [options[:corpus], options[:materialized]].compact.size == 1
abort "lineage binary not executable: #{options[:lineage_bin]}" unless File.executable?(options[:lineage_bin])

repo = File.expand_path(options[:repo])
db = File.expand_path(options[:db])

ingest = lambda do |directory|
  facts_files = Dir[File.join(directory, "mutant-facts-*.json")].sort
  abort "no mutant-facts-*.json in #{directory}" if facts_files.empty?

  ingested = 0
  commit_used = nil
  facts_files.each do |facts_path|
    facts = JSON.parse(File.read(facts_path))
    commit = options[:commit] || facts.dig("test_miser", "commit")
    abort "#{facts_path} carries no test_miser.commit; pass --commit" unless commit
    commit_used ||= commit
    suite = facts.dig("test_miser", "suite") || File.basename(facts_path)
    out = run!([
                 options[:lineage_bin], "ingest-mutants",
                 "--db", db, "--repo", repo,
                 "--input", facts_path, "--commit", commit
               ])
    puts "#{suite}: #{out.strip}"
    ingested += 1
  end

  sarif_path = File.join(directory, "weak-tests.sarif")
  if File.file?(sarif_path)
    out = run!([
                 options[:lineage_bin], "ingest-sarif",
                 "--db", db, "--repo", repo,
                 "--input", sarif_path, "--source", "test-miser",
                 "--commit", commit_used, "--replace"
               ])
    puts "weak-tests: #{out.strip}"
  else
    warn "weak-tests.sarif missing in #{directory}; skipped Weak Tests ingestion"
  end
  puts "ingested #{ingested} mutant-facts file(s) at commit #{commit_used}"
end

if options[:materialized]
  ingest.call(File.expand_path(options[:materialized]))
else
  abort "test-miser-artifact not found: #{options[:artifact_exe]}" unless File.file?(options[:artifact_exe])
  Dir.mktmpdir("mutation-corpus-") do |dir|
    run!(["ruby", options[:artifact_exe], "materialize",
          "--corpus", File.expand_path(options[:corpus]), "--output", dir])
    ingest.call(dir)
  end
end
