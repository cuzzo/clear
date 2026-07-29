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
  indexer: nil,
  consumer_indexers: [],
  symbol_prefix_from: nil,
  symbol_prefix_to: nil,
  compatibility: nil,
  symbol_map: nil
}
OptionParser.new do |opts|
  opts.banner = "usage: export_complexity_summary.rb [options] PROFILE.json [OUTPUT.json[.gz]]"
  opts.on("--corpus ID", "Stable corpus identity (for example go-stdlib)") { |value| metadata[:corpus] = value }
  opts.on("--source-revision REV", "Source commit or release") { |value| metadata[:source_revision] = value }
  opts.on("--indexer ID", "SCIP indexer and version") { |value| metadata[:indexer] = value }
  opts.on("--consumer-indexer ID", "Compatible consumer SCIP indexer and version (repeatable)") do |value|
    metadata[:consumer_indexers] << value
  end
  opts.on("--producer-version VERSION", "Override the Espalier producer version") { |value| metadata[:producer_version] = value }
  opts.on("--symbol-prefix-from PREFIX", "Relocate producer symbols from this exact prefix") do |value|
    metadata[:symbol_prefix_from] = value
  end
  opts.on("--symbol-prefix-to PREFIX", "Relocate producer symbols to this exact prefix") do |value|
    metadata[:symbol_prefix_to] = value
  end
  opts.on("--compatibility FILE", "Semantic-environment sidecar required by consumers") do |value|
    metadata[:compatibility] = value
  end
  opts.on("--symbol-map FILE", "Exact producer-to-consumer symbol bridge") do |value|
    metadata[:symbol_map] = value
  end
end.parse!
abort "usage: export_complexity_summary.rb [options] PROFILE.json [OUTPUT.json[.gz]]" unless (1..2).cover?(ARGV.length)
if metadata[:symbol_prefix_from].nil? != metadata[:symbol_prefix_to].nil?
  abort "--symbol-prefix-from and --symbol-prefix-to must be supplied together"
end
abort "--symbol-map cannot be combined with prefix relocation" if metadata[:symbol_map] && metadata[:symbol_prefix_from]

compatibility_claims = {}
if metadata[:compatibility]
  environment = JSON.parse(File.read(metadata[:compatibility]))
  unless environment["schema"] == "fact-mine.semantic-environment.v1"
    abort "unsupported semantic environment schema: #{environment['schema'].inspect}"
  end
  compatibility_claims = environment.fetch("claims")
  unless compatibility_claims.is_a?(Hash) &&
      compatibility_claims.all? { |key, value| !key.to_s.empty? && !value.to_s.empty? }
    abort "semantic environment claims must be a mapping of non-empty strings"
  end
end

symbol_map = nil
symbol_map_sha256 = nil
if metadata[:symbol_map]
  symbol_map_bytes = File.binread(metadata[:symbol_map])
  bridge = JSON.parse(symbol_map_bytes)
  unless bridge["schema"] == "fact-mine.symbol-bridge.v1"
    abort "unsupported symbol bridge schema: #{bridge['schema'].inspect}"
  end
  symbol_map = bridge.fetch("symbols")
  unless symbol_map.is_a?(Hash) && symbol_map.all? { |key, value|
      targets = value.is_a?(Array) ? value : [value]
      !key.to_s.empty? && !targets.empty? && targets.all? { |target| !target.to_s.empty? }
    }
    abort "symbol bridge symbols must map non-empty producer symbols to one or more non-empty consumer symbols"
  end
  symbol_map_sha256 = "sha256:#{Digest::SHA256.hexdigest(symbol_map_bytes)}"
end

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
facts_by_location = Array(profile["complexity_facts"]).group_by do |fact|
  [fact["path"].to_s, fact["line"].to_i, fact["function"].to_s]
end
source_proven_ids = Array(profile["methods"]).filter_map do |method|
  quality = results[method["id"].to_s]
  facts = facts_by_location.fetch(
    [method["path"].to_s, method["line"].to_i, method["name"].to_s],
    []
  )
  method["id"].to_s if Espalier::ComplexitySummary.source_method_proven?(method, quality, facts)
end.to_h { |id| [id, true] }

symbols = Array(profile["methods"]).filter_map do |method|
  symbol = method["semantic_symbol"].to_s
  quality = results[method["id"].to_s]
  next if symbol.empty? || !source_proven_ids[method["id"].to_s]

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

# A compiler can attach a declaration symbol to a call while separately
# providing candidate implementations visible in this index. Visibility in a
# producer index is not proof that downstream consumers cannot add another
# implementation. Publish a conservative candidate maximum only when the
# profile carries a separate, explicit consumer-closure proof.
candidate_symbols = Array(profile["calls"]).filter_map do |call|
  symbol = call["semantic_symbol"].to_s
  candidate_ids = Array(call["candidate_targets"]).map(&:to_s).reject(&:empty?).uniq.sort
  next if symbol.empty? || candidate_ids.empty?
  next unless Espalier::ComplexitySummary.consumer_closed_candidate_set?(call)

  candidate_qualities = candidate_ids.map { |id| results[id] }
  next unless candidate_ids.all? { |id| source_proven_ids[id] }

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
symbols = symbols.flat_map do |symbol, row|
  relocated = if symbol_map
                Array(symbol_map[symbol])
              else
                [Espalier::ComplexitySummary.relocate_symbol(
                  symbol,
                  from: metadata[:symbol_prefix_from],
                  to: metadata[:symbol_prefix_to]
                )]
              end
  relocated.compact.map { |target| [target, row] }
end

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
  "schema" => "fact-mine.external-complexity-summary.v3",
  "producer" => {
    "name" => "espalier",
    "version" => metadata[:producer_version].to_s
  },
  "source" => {
    "profile_sha256" => "sha256:#{Digest::SHA256.hexdigest(profile_bytes)}",
    "method_count" => Array(profile["methods"]).length,
    "complete_symbol_count" => grouped.length,
    "source_proven_method_count" => source_proven_ids.length,
    "proof_policy" => "analyzed_bodies_exact_targets_cfg_dfg_v1",
    "corpus" => metadata[:corpus],
    "source_revision" => metadata[:source_revision],
    "indexer" => metadata[:indexer],
    "consumer_indexers" => metadata[:consumer_indexers].uniq.sort,
    "symbol_relocation" => if metadata[:symbol_prefix_from] || metadata[:symbol_prefix_to]
      {
        "from" => metadata[:symbol_prefix_from],
        "to" => metadata[:symbol_prefix_to]
      }
    end,
    "symbol_bridge_sha256" => symbol_map_sha256,
    "languages" => Array(profile["methods"]).map { |method| method["language"].to_s }.reject(&:empty?).uniq.sort
  }.compact,
  "compatibility" => {
    "claims" => compatibility_claims
  },
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
