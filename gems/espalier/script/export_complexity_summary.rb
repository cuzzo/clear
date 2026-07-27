#!/usr/bin/env ruby
# frozen_string_literal: true

# Export complete Espalier method bounds under compiler-proven declaration
# symbols. The resulting sidecar can be ingested by FactMine without merging
# excluded/generated/dependency methods into the product's reported corpus.

require "json"
require "digest"
require "optparse"
require "zlib"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "espalier"

metadata = {
  producer_version: Espalier.const_defined?(:VERSION) ? Espalier::VERSION : "unknown",
  corpus: nil,
  source_revision: nil,
  indexer: nil
}
OptionParser.new do |opts|
  opts.banner = "usage: export_complexity_summary.rb [options] PROFILE.json [OUTPUT.json[.gz]]"
  opts.on("--corpus ID", "Stable corpus identity (for example go-stdlib)") { |value| metadata[:corpus] = value }
  opts.on("--source-revision REV", "Source commit or release") { |value| metadata[:source_revision] = value }
  opts.on("--indexer ID", "SCIP indexer and version") { |value| metadata[:indexer] = value }
  opts.on("--producer-version VERSION", "Override the Espalier producer version") { |value| metadata[:producer_version] = value }
end.parse!
abort "usage: export_complexity_summary.rb [options] PROFILE.json [OUTPUT.json[.gz]]" unless (1..2).cover?(ARGV.length)

profile_bytes = File.binread(ARGV.fetch(0))
profile = JSON.parse(profile_bytes)
paths = Array(profile["methods"]).map { |method| method.fetch("path") }.uniq
evidence = {
  "root" => "/",
  # This is an isolated profile whose methods are intentionally analyzed as
  # production within the summary job. They are not merged into the caller's
  # profile, so this does not change the reported product corpus.
  "files" => paths.map { |path| { "path" => path, "source_role" => "production" } },
  "owners" => Array(profile["owners"]),
  "methods" => Array(profile["methods"]),
  "fields" => Array(profile["fields"]),
  "facts" => {
    "calls" => Array(profile["calls"]),
    "complexity_facts" => Array(profile["complexity_facts"]),
    "state_accesses" => Array(profile["state_accesses"]),
    "struct_declarations" => Array(profile["struct_declarations"]),
    "state_protocol_records" => Array(profile["state_protocol_records"]),
    "state_param_origin_records" => Array(profile["state_param_origin_records"])
  }
}

results = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
  .flat_map { |mod| Array(mod[:functions]) }
  .to_h { |function| [function[:id].to_s, function.fetch(:quality_metrics, {})] }

symbols = Array(profile["methods"]).filter_map do |method|
  symbol = method["semantic_symbol"].to_s
  quality = results[method["id"].to_s]
  next if symbol.empty? || !quality || quality[:big_o_complete] != true || quality[:big_o_space_complete] != true

  source_qualities = Array(quality[:big_o_bound_qualities]).map(&:to_s).reject(&:empty?)
  source_assumptions = Array(quality[:big_o_assumptions]).map(&:to_s).reject(&:empty?)
  bound_quality = if source_qualities.empty? || source_qualities.all? { |item| item.include?("exact") }
                    "upper_bound_exact_symbol"
                  elsif source_qualities.include?("upper_bound_modeled_world")
                    "upper_bound_modeled_world"
                  else
                    source_qualities.sort.first
                  end
  [symbol, {
    "time" => quality[:big_o],
    "space" => quality[:big_o_space],
    "provenance" => "analyzed_source_summary",
    "bound_quality" => bound_quality,
    "assumptions" => (source_assumptions +
      ["summary generated from the analyzed declaration body"]).uniq
  }]
end

# A compiler can attach an interface/trait declaration symbol to a call while
# separately providing the closed implementation set visible in this index.
# When every candidate has a complete analyzed bound, publish the conservative
# maximum under that declaration symbol. This is language-neutral and retains
# the closed-world assumption explicitly.
candidate_symbols = Array(profile["calls"]).filter_map do |call|
  symbol = call["semantic_symbol"].to_s
  candidate_ids = Array(call["candidate_targets"]).map(&:to_s).reject(&:empty?).uniq.sort
  next if symbol.empty? || candidate_ids.empty?

  candidate_qualities = candidate_ids.map { |id| results[id] }
  next if candidate_qualities.any? do |quality|
    !quality || quality[:big_o_complete] != true || quality[:big_o_space_complete] != true
  end

  worst_time = candidate_qualities.map { |quality| quality[:big_o] }
    .max_by { |value| Espalier::SymbolicComplexity.rank_string(value) }
  worst_space = candidate_qualities.map { |quality| quality[:big_o_space] }
    .max_by { |value| Espalier::SymbolicComplexity.rank_string(value) }
  assumptions = candidate_qualities.flat_map { |quality| Array(quality[:big_o_assumptions]) }
  reason = call["candidate_reason"].to_s
  assumptions << "#{reason.empty? ? 'compiler-provided' : reason} implementation set is closed for this analysis"
  [symbol, {
    "time" => worst_time,
    "space" => worst_space,
    "provenance" => "analyzed_candidate_summary",
    "bound_quality" => "upper_bound_closed_candidate_max",
    "candidates" => candidate_ids,
    "assumptions" => assumptions.map(&:to_s).reject(&:empty?).uniq
  }]
end
symbols.concat(candidate_symbols)

# A compiler symbol should identify one declaration. Omit conflicting symbols
# instead of selecting by order if an index violates that contract; one
# producer defect must not prevent independent summaries from being exported.
grouped = symbols.group_by(&:first)
conflicts = grouped.filter_map do |symbol, rows|
  values = rows.map(&:last).map { |row| [row["time"], row["space"]] }.uniq
  [symbol, values] if values.length > 1
end
unless conflicts.empty?
  warn "omitting conflicting complexity summaries for #{conflicts.map(&:first).join(', ')}"
  conflicts.each { |symbol, _values| grouped.delete(symbol) }
end

output = {
  "schema" => "fact-mine.external-complexity-summary.v2",
  "producer" => {
    "name" => "espalier",
    "version" => metadata[:producer_version].to_s
  },
  "source" => {
    "profile_sha256" => "sha256:#{Digest::SHA256.hexdigest(profile_bytes)}",
    "method_count" => Array(profile["methods"]).length,
    "complete_symbol_count" => grouped.length,
    "corpus" => metadata[:corpus],
    "source_revision" => metadata[:source_revision],
    "indexer" => metadata[:indexer],
    "languages" => Array(profile["methods"]).map { |method| method["language"].to_s }.reject(&:empty?).uniq.sort
  }.compact,
  "symbols" => grouped.to_h do |symbol, rows|
    merged = rows.first.last.dup
    merged["candidates"] = rows.flat_map { |row| Array(row.last["candidates"]) }.uniq.sort
    merged["assumptions"] = rows.flat_map { |row| Array(row.last["assumptions"]) }.uniq.sort
    [symbol, merged]
  end
}
rendered = JSON.pretty_generate(output)
if ARGV[1]
  if File.extname(ARGV[1]) == ".gz"
    Zlib::GzipWriter.open(ARGV[1]) do |gzip|
      gzip.mtime = 0
      gzip.orig_name = ""
      gzip.write(rendered)
    end
  else
    File.write(ARGV[1], rendered)
  end
else
  puts rendered
end
