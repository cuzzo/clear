#!/usr/bin/env ruby
# frozen_string_literal: true

# Report mutually exclusive Big-O proof categories for a FactMine profile.
# The classifier is language-neutral; repository names are presentation-only.

require "json"
require "optparse"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "espalier"

options = { source_root: nil, repositories: [], focus: nil, json: false }
OptionParser.new do |parser|
  parser.banner = "Usage: report_big_o_proof_metrics.rb --source-root PATH [options] PROFILE.json"
  parser.on("--source-root PATH") { |path| options[:source_root] = File.expand_path(path) }
  parser.on("--repository NAME") { |name| options[:repositories] << name }
  parser.on("--focus NAME") { |name| options[:focus] = name }
  parser.on("--json") { options[:json] = true }
end.parse!
abort "expected one FactMine profile" unless ARGV.length == 1
abort "--source-root is required" unless options[:source_root]

profile = JSON.parse(File.read(ARGV.fetch(0)))
source_root = options.fetch(:source_root)
repositories = options.fetch(:repositories)
if repositories.empty?
  repositories = Array(profile["methods"]).filter_map do |method|
    path = method.fetch("path")
    path.delete_prefix("#{source_root}/").split("/", 2).first if path.start_with?("#{source_root}/")
  end.uniq.sort
end
focus = options[:focus] || repositories.find { |name| name.downcase.delete("-") == "javapoet" } || repositories.first

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

qualities_by_repository = repositories.to_h do |repository|
  prefix = File.join(source_root, repository, "")
  modules = Espalier::StaticEvidence.project_modules(evidence_for(profile, prefix))
  qualities = Espalier::Aggregator.new.aggregate(modules).flat_map do |mod|
    Array(mod[:functions]).map { |function| function.fetch(:quality_metrics, {}) }
  end
  [repository, qualities]
end

all_qualities = qualities_by_repository.values.flatten
summaries = { "all" => Espalier::BigOProofMetrics.summarize(all_qualities) }
qualities_by_repository.each do |repository, qualities|
  summaries[repository] = Espalier::BigOProofMetrics.summarize(qualities)
end

if options[:json]
  puts JSON.pretty_generate({ schema: "espalier.big-o-proof-metrics.v1", summaries: summaries })
  exit
end

all = summaries.fetch("all")
focused = summaries.fetch(focus)
percentage = ->(count, total) { total.zero? ? 0.0 : count * 100.0 / total }
metric_width = 43
value_width = 20

puts format("%-#{metric_width}s %#{value_width}s %#{value_width}s", "Metric", "All (#{all[:functions]})", "#{focus} (#{focused[:functions]})")
Espalier::BigOProofMetrics::CATEGORY_LABELS.each_with_index do |(key, label), index|
  all_count = all.dig(:categories, key, :count)
  focus_count = focused.dig(:categories, key, :count)
  puts format(
    "%-#{metric_width}s %#{value_width}s %#{value_width}s",
    "#{index + 1}. #{label}",
    format("%d — %.2f%%", all_count, percentage.call(all_count, all[:functions])),
    format("%d — %.2f%%", focus_count, percentage.call(focus_count, focused[:functions]))
  )
end

puts
puts "Exact underlying buckets:"
puts format("%-#{metric_width}s %#{value_width}s %#{value_width}s", "Bucket", "All", focus)
Espalier::BigOProofMetrics::BUCKET_LABELS.each do |key, label|
  all_count = all.dig(:buckets, key, :count)
  focus_count = focused.dig(:buckets, key, :count)
  next if key == :unknowable && all_count.zero? && focus_count.zero?

  puts format("%-#{metric_width}s %#{value_width}d %#{value_width}d", label, all_count, focus_count)
end
