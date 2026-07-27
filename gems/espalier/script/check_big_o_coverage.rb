#!/usr/bin/env ruby
# frozen_string_literal: true

# Enforce production function-level Big-O coverage for a FactMine profile.
# The report separates proof tiers and fails closed when FactMine reports raw
# executable calls that did not reach normalized call facts.

require "json"
require "optparse"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "espalier"

options = {
  source_root: nil,
  repositories: [],
  minimum: Espalier::BigOProofMetrics::DEFAULT_MINIMUM_PERCENT,
  include_lambdas: true
}
OptionParser.new do |parser|
  parser.banner = "Usage: check_big_o_coverage.rb --source-root PATH [options] PROFILE.json"
  parser.on("--source-root PATH", "Root used to select and relativize profile paths") do |path|
    options[:source_root] = File.expand_path(path)
  end
  parser.on("--repository NAME", "Limit scope to a direct child of SOURCE_ROOT (repeatable)") do |name|
    options[:repositories] << name
  end
  parser.on("--minimum PERCENT", Float, "Required mapped production functions (default: 85)") do |value|
    options[:minimum] = value
  end
  parser.on("--exclude-lambdas", "Exclude lambda/closure methods from the denominator") do
    options[:include_lambdas] = false
  end
end.parse!

abort "expected one FactMine profile" unless ARGV.length == 1
abort "--source-root is required" unless options[:source_root]

profile = JSON.parse(File.read(ARGV.fetch(0)))
source_root = options.fetch(:source_root)
prefixes =
  if options[:repositories].empty?
    ["#{source_root}/"]
  else
    options[:repositories].map { |repository| "#{File.join(source_root, repository)}/" }
  end
in_scope = lambda do |row|
  path = row.fetch("path", "")
  prefixes.any? { |prefix| path.start_with?(prefix) }
end
select_path = ->(rows) { Array(rows).select(&in_scope) }
methods = select_path.call(profile["methods"])
method_roles = Espalier::StaticEvidence.method_source_roles(methods)
production_methods = methods.select do |method|
  method_roles.fetch(method.fetch("id").to_s) == "production"
end
method_ids = production_methods.to_h { |method| [method.fetch("id"), true] }
paths = methods.map { |method| method.fetch("path") }.uniq
evidence = {
  "root" => source_root,
  "input_coverage" => profile["input_coverage"],
  "files" => paths.map do |path|
    { "path" => path, "source_role" => Espalier::StaticEvidence.source_role(path) }
  end,
  "owners" => select_path.call(profile["owners"]),
  "methods" => production_methods,
  "fields" => select_path.call(profile["fields"]),
  "facts" => {
    "calls" => Array(profile["calls"]).select { |call| method_ids[call["source"]] },
    "complexity_facts" => select_path.call(profile["complexity_facts"]),
    "state_accesses" => select_path.call(profile["state_accesses"]),
    "struct_declarations" => select_path.call(profile["struct_declarations"]),
    "state_protocol_records" => select_path.call(profile["state_protocol_records"]),
    "state_param_origin_records" => select_path.call(profile["state_param_origin_records"])
  }
}

modules = Espalier::StaticEvidence.project_modules(evidence, source_roles: ["production"])
manifest = Espalier::Aggregator.new.aggregate(modules)
method_by_id = methods.to_h { |method| [method.fetch("id").to_s, method] }
rows = manifest.flat_map do |mod|
  Array(mod[:functions]).filter_map do |function|
    method = method_by_id[function[:id].to_s]
    next unless method

    {
      source_role: method_roles.fetch(method.fetch("id").to_s),
      language: method["language"] || mod[:language],
      kind: method["kind"],
      quality: function.fetch(:quality_metrics, {})
    }
  end
end

report = Espalier::BigOProofMetrics.coverage_gate(
  rows,
  call_coverage: profile["call_resolution_coverage"] || {},
  minimum_percent: options.fetch(:minimum),
  include_lambdas: options.fetch(:include_lambdas)
)
report[:scope] = {
  source_root: source_root,
  repositories: options[:repositories].sort,
  profile: File.expand_path(ARGV.fetch(0))
}
puts JSON.pretty_generate(report)
exit(report[:passed] ? 0 : 1)
