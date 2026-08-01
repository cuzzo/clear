#!/usr/bin/env ruby
# frozen_string_literal: true

# Ingest a Test Miser mutation corpus into lineage.db.
#
# Accepts either a canonical corpus envelope (mutation-corpus.json.zst, as
# published by the test-miser GitHub workflow) or an already-materialized
# directory containing mutant-facts-*.json, weak-tests.sarif, and the required
# advanced evidence.sarif artifact. Runs
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
  db: "gigasail.db",
  repo: ".",
  corpus: nil,
  materialized: nil,
  commit: nil,
  giga_bin: File.expand_path("../target/release/giga", __dir__),
  artifact_exe: File.join(TOOL_ROOT, "gems/test-miser/exe/test-miser-artifact")
}

OptionParser.new do |opts|
  opts.banner = "Usage: ingest_mutation_corpus.rb [options]"
  opts.on("--db=PATH", "gigasail database (default gigasail.db)") { |v| options[:db] = v }
  opts.on("--repo=PATH", "repository root (default .)") { |v| options[:repo] = v }
  opts.on("--corpus=FILE", "mutation-corpus.json.zst envelope") { |v| options[:corpus] = v }
  opts.on("--materialized=DIR", "already-materialized corpus directory") { |v| options[:materialized] = v }
  opts.on("--commit=SHA", "commit override (default: the corpus commit)") { |v| options[:commit] = v }
  opts.on("--giga-bin=PATH", "giga binary") { |v| options[:giga_bin] = v }
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
abort "giga binary not executable: #{options[:giga_bin]}" unless File.executable?(options[:giga_bin])

repo = File.expand_path(options[:repo])
db = File.expand_path(options[:db])

ingest = lambda do |directory|
  facts_files = Dir[File.join(directory, "mutant-facts-*.json")].sort
  abort "no mutant-facts-*.json in #{directory}" if facts_files.empty?

  # Every mutant-facts file in one materialized directory must carry the
  # SAME commit. The combined weak-tests.sarif is a single, un-partitioned
  # artifact tagged with one commit below - silently picking whichever
  # commit happened to sort first would tag that SARIF (and thus every
  # weak-test finding in it) against the wrong commit for any suite whose
  # facts came from a different one, corrupting the ledger's history
  # without any visible error.
  commits = facts_files.filter_map do |facts_path|
    facts = JSON.parse(File.read(facts_path))
    options[:commit] || facts.dig("test_miser", "commit")
  end.uniq
  abort "#{facts_files.first} carries no test_miser.commit; pass --commit" if commits.empty?
  if commits.size > 1
    abort "mutant-facts files in #{directory} span multiple commits (#{commits.join(", ")}); " \
          "ingest each commit's corpus separately, or pass --commit to force one"
  end
  commit_used = commits.first

  ingested = 0
  facts_files.each do |facts_path|
    facts = JSON.parse(File.read(facts_path))
    suite = facts.dig("test_miser", "suite") || File.basename(facts_path)
    out = run!([
                 options[:giga_bin], "ingest-mutants",
                 "--db", db, "--repo", repo,
                 "--input", facts_path, "--commit", commit_used
               ])
    puts "#{suite}: #{out.strip}"
    ingested += 1
  end

  # weak-tests.sarif is not optional output - it completes the checkpoint ->
  # ledger path this tool exists to run (see the file header). A missing
  # SARIF means the corpus this ingestion was explicitly asked to ingest is
  # incomplete; report that loudly rather than silently ingesting a partial
  # result that looks like success.
  sarif_path = File.join(directory, "weak-tests.sarif")
  abort "weak-tests.sarif missing in #{directory}; the corpus is incomplete" unless File.file?(sarif_path)
  out = run!([
               options[:giga_bin], "ingest-sarif",
               "--db", db, "--repo", repo,
               "--input", sarif_path, "--source", "test-miser",
               "--commit", commit_used, "--replace"
             ])
  puts "weak-tests: #{out.strip}"
  evidence_path = File.join(directory, "evidence.sarif")
  abort "evidence.sarif missing in #{directory}; the corpus is incomplete" unless File.file?(evidence_path)
  out = run!([
               options[:giga_bin], "ingest-sarif",
               "--db", db, "--repo", repo,
               "--input", evidence_path, "--source", "test-miser-evidence",
               "--commit", commit_used, "--replace"
             ])
  puts "evidence: #{out.strip}"
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
