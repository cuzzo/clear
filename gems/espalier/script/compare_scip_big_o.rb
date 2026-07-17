#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare method-level Big-O completeness for two FactMine profiles produced
# from the same files, typically without and with --scip-index.

require "json"
require "optparse"
require "set"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "espalier"

options = { source_root: nil, repositories: [] }
OptionParser.new do |parser|
  parser.banner = "Usage: compare_scip_big_o.rb [options] BASELINE.json SCIP.json"
  parser.on("--source-root PATH") { |path| options[:source_root] = File.expand_path(path) }
  parser.on("--repository NAME") { |name| options[:repositories] << name }
end.parse!
abort "expected baseline and SCIP profile paths" unless ARGV.length == 2

baseline_profile = JSON.parse(File.read(ARGV[0]))
scip_profile = JSON.parse(File.read(ARGV[1]))
source_root = options[:source_root]

def evidence_for(profile, prefix)
  methods = Array(profile["methods"]).select { |row| row.fetch("path").start_with?(prefix) }
  method_ids = methods.to_h { |row| [row.fetch("id"), true] }
  paths = methods.map { |row| row.fetch("path") }.uniq
  select_path = ->(rows) { Array(rows).select { |row| row.fetch("path", "").start_with?(prefix) } }
  {
    "root" => prefix,
    "files" => paths.map { |path| { "path" => path, "source_role" => "production" } },
    "owners" => select_path.call(profile["owners"]),
    "methods" => methods,
    "fields" => select_path.call(profile["fields"]),
    "facts" => {
      "calls" => Array(profile["calls"]).select { |row| method_ids[row["source"]] },
      "complexity_facts" => select_path.call(profile["complexity_facts"]),
      "state_accesses" => select_path.call(profile["state_accesses"]),
      "struct_declarations" => select_path.call(profile["struct_declarations"]),
      "state_protocol_records" => select_path.call(profile["state_protocol_records"]),
      "state_param_origin_records" => select_path.call(profile["state_param_origin_records"])
    }
  }
end

def function_rows(profile, prefixes)
  prefixes.each_with_object({}) do |(repository, prefix), rows|
    evidence = evidence_for(profile, prefix)
    modules = Espalier::StaticEvidence.project_modules(evidence)
    Espalier::Aggregator.new.aggregate(modules).each do |mod|
      Array(mod[:functions]).each do |function|
        quality = function.fetch(:quality_metrics, {})
        key = [mod[:file], function[:span], mod[:module], function[:name]]
        rows[key] = {
          repository: repository,
          file: mod[:file],
          owner: mod[:module],
          name: function[:name],
          span: function[:span],
          time_complete: quality[:big_o_complete],
          space_complete: quality[:big_o_space_complete],
          big_o: quality[:big_o],
          big_o_space: quality[:big_o_space],
          bound_qualities: Array(quality[:big_o_bound_qualities]),
          complexity_assumptions: Array(quality[:big_o_assumptions]),
          unknowns: Array(quality[:big_o_unknowns]),
          evidence_gaps: Array(quality[:big_o_evidence_gaps])
        }
      end
    end
  end
end

def counts(rows)
  bound_quality_counts = rows.flat_map { |row| row[:bound_qualities] }.tally.sort.to_h
  {
    functions: rows.length,
    time_known: rows.count { |row| row[:time_complete] },
    time_unknown: rows.count { |row| !row[:time_complete] },
    space_known: rows.count { |row| row[:space_complete] },
    space_unknown: rows.count { |row| !row[:space_complete] },
    bound_quality_counts: bound_quality_counts
  }
end

paths = Array(baseline_profile["methods"]).map { |method| method.fetch("path") }
repositories = options[:repositories]
if repositories.empty?
  abort "--source-root is required when repositories are not explicit" unless source_root
  repositories = paths.filter_map do |path|
    path.delete_prefix("#{source_root}/").split("/", 2).first if path.start_with?("#{source_root}/")
  end.uniq.sort
end
prefixes = repositories.to_h do |repository|
  prefix = source_root ? File.join(source_root, repository, "") : "#{repository}/"
  [repository, prefix]
end

baseline = function_rows(baseline_profile, prefixes)
enhanced = function_rows(scip_profile, prefixes)
abort "profile function sets differ" unless baseline.keys.to_set == enhanced.keys.to_set

changed = baseline.keys.filter_map do |key|
  before = baseline.fetch(key)
  after = enhanced.fetch(key)
  { key: key, before: before, after: after } unless before == after
end

summary = {
  baseline: counts(baseline.values),
  scip: counts(enhanced.values),
  by_repository: repositories.to_h do |repository|
    before = baseline.values.select { |row| row[:repository] == repository }
    after = enhanced.values.select { |row| row[:repository] == repository }
    [repository, { baseline: counts(before), scip: counts(after) }]
  end,
  transitions: {
    time_unknown_to_known: changed.count { |row| !row[:before][:time_complete] && row[:after][:time_complete] },
    time_known_to_unknown: changed.count { |row| row[:before][:time_complete] && !row[:after][:time_complete] },
    space_unknown_to_known: changed.count { |row| !row[:before][:space_complete] && row[:after][:space_complete] },
    space_known_to_unknown: changed.count { |row| row[:before][:space_complete] && !row[:after][:space_complete] }
  },
  changed_functions: changed
}
puts JSON.pretty_generate(summary)
