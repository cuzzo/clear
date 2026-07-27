#!/usr/bin/env ruby
# frozen_string_literal: true

# Explain incomplete Big-O results in terms of the first missing semantic or
# cost proof. Unlike the presentation-level unknown-operations report, this
# consumes FactMine's exact call IDs, SCIP symbols, and project targets, then
# propagates root causes through incomplete project callees.

require "json"
require "optparse"
require "set"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "espalier"

options = { source_root: nil, repositories: [], examples: 8 }
OptionParser.new do |parser|
  parser.banner = "Usage: diagnose_big_o_gaps.rb [options] PROFILE.json"
  parser.on("--source-root PATH") { |path| options[:source_root] = File.expand_path(path) }
  parser.on("--repository NAME") { |name| options[:repositories] << name }
  parser.on("--examples COUNT", Integer) { |count| options[:examples] = count }
end.parse!
abort "expected one FactMine profile" unless ARGV.length == 1

profile = JSON.parse(File.read(ARGV.fetch(0)))
source_root = options[:source_root]
abort "--source-root is required" unless source_root
repositories = options[:repositories]
if repositories.empty?
  repositories = Array(profile["methods"]).filter_map do |method|
    path = method.fetch("path")
    path.delete_prefix("#{source_root}/").split("/", 2).first if path.start_with?("#{source_root}/")
  end.uniq.sort
end
prefixes = repositories.map { |repository| File.join(source_root, repository, "") }
in_scope = ->(row) { prefixes.any? { |prefix| row.fetch("path", "").start_with?(prefix) } }

scoped_methods = Array(profile["methods"]).select(&in_scope)
method_roles = Espalier::StaticEvidence.method_source_roles(scoped_methods)
methods = scoped_methods.select do |method|
  method_roles.fetch(method.fetch("id").to_s) == "production"
end
method_ids = methods.to_h { |method| [method.fetch("id"), method] }
calls = Array(profile["calls"]).select { |call| method_ids.key?(call["source"]) }
facts = Array(profile["complexity_facts"]).select(&in_scope)
paths = methods.map { |method| method.fetch("path") }.uniq
select_path = ->(rows) { Array(rows).select(&in_scope) }
evidence = {
  "root" => source_root,
  "files" => paths.map do |path|
    { "path" => path, "source_role" => Espalier::StaticEvidence.source_role(path) }
  end,
  "owners" => select_path.call(profile["owners"]),
  "methods" => methods,
  "fields" => select_path.call(profile["fields"]),
  "facts" => {
    "calls" => calls,
    "complexity_facts" => facts,
    "state_accesses" => select_path.call(profile["state_accesses"]),
    "struct_declarations" => select_path.call(profile["struct_declarations"]),
    "state_protocol_records" => select_path.call(profile["state_protocol_records"]),
    "state_param_origin_records" => select_path.call(profile["state_param_origin_records"])
  }
}

manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
results = manifest.flat_map do |mod|
  Array(mod[:functions]).filter_map do |function|
    next if function[:id].to_s.empty?

    quality = function.fetch(:quality_metrics, {})
    [function[:id].to_s, {
      complete: quality[:big_o_complete] == true,
      big_o: quality[:big_o],
      unknowns: Array(quality[:big_o_unknowns]),
      unknown_operation_evidence: quality[:big_o_unknown_operation_evidence] || {},
      evidence_gaps: Array(quality[:big_o_evidence_gaps]),
      path: mod[:file],
      owner: mod[:module],
      name: function[:name],
      line: function[:line]
    }]
  end
end.to_h

facts_by_method = facts.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |fact, index|
  candidates = methods.select do |method|
    method["path"] == fact["path"] && method["owner"] == fact["owner"] &&
      method["name"] == fact["function"] && method["line"].to_i == fact["line"].to_i
  end
  index[candidates.first["id"]] << fact if candidates.one?
end
calls_by_source = calls.group_by { |call| call.fetch("source") }

external_category = lambda do |call|
  call["complexity_missing_kind"] || case call["external_symbol_scope"]
                                      when "stdlib" then "stdlib_cost_model_missing"
                                      when "dependency" then "dependency_cost_model_missing"
                                      else "external_cost_model_missing"
                                      end
end

call_resolution_category = lambda do |call|
  if call["target"]
    call["target_provenance"] == "scip" ? "exact_project_target_scip" : "exact_project_target_native"
  elsif call["known_time_complexity"] || call["known_space_complexity"]
    "modeled_nonproject_call"
  elsif !call["semantic_symbol"].to_s.empty?
    external_category.call(call)
  else
    "semantic_identity_missing"
  end
end

incomplete_ids = results.filter_map { |id, result| id unless result[:complete] }.to_set
direct_causes = Hash.new { |hash, key| hash[key] = Set.new }
callee_dependencies = Hash.new { |hash, key| hash[key] = Set.new }
cause_calls = Hash.new { |hash, key| hash[key] = [] }

incomplete_ids.each do |method_id|
  method = method_ids.fetch(method_id)
  contexts = Array(facts_by_method[method_id]).flat_map { |fact| Array(fact["call_contexts"]) }
  Array(calls_by_source[method_id]).each do |call|
    if call["target"]
      target_id = call["target"].to_s
      if incomplete_ids.include?(target_id)
        callee_dependencies[method_id] << target_id
      elsif !results.key?(target_id)
        direct_causes[method_id] << "project_or_excluded_target_summary_unavailable"
      else
        has_context = contexts.any? do |context|
          context["message"].to_s == call["message"].to_s &&
            context["line"].to_i == call["line"].to_i
        end
        same_owner = method_ids[target_id]&.fetch("owner", nil) == method["owner"]
        implicit = %w[self this].include?(call["receiver"].to_s) || call["receiver"].to_s.empty?
        unless has_context || (same_owner && implicit)
          direct_causes[method_id] << "project_call_complexity_context_missing"
          cause_calls["project_call_complexity_context_missing"] << call
        end
      end
      next
    end
    next if call["known_time_complexity"] || call["known_space_complexity"]

    category = if call["semantic_symbol"].to_s.empty?
                 "semantic_identity_missing"
               else
                 external_category.call(call)
               end
    direct_causes[method_id] << category
    cause_calls[category] << call
  end

  result = results.fetch(method_id)
  gaps = result[:evidence_gaps]
  direct_causes[method_id] << "recursive_progress_unproven" if gaps.any? { |gap| gap.include?("recurs") }
  direct_causes[method_id] << "iteration_bound_unproven" if Array(facts_by_method[method_id]).any? do |fact|
    Array(fact["iterations"]).any? { |iteration| iteration["cardinality_relation"] == "unknown" }
  end
  direct_causes[method_id] << "allocation_bound_unproven" if Array(facts_by_method[method_id]).any? do |fact|
    Array(fact["allocations"]).any? { |allocation| allocation["cardinality_relation"] == "unknown" }
  end
  if direct_causes[method_id].empty? && callee_dependencies[method_id].empty?
    direct_causes[method_id] << if result[:unknowns].any?
                                  "normalized_unknown_operation_unclassified"
                                else
                                  "complexity_summary_gap_unclassified"
                                end
  end
end

root_causes = direct_causes.transform_values(&:dup)
incomplete_ids.length.times do
  changed = false
  incomplete_ids.each do |method_id|
    callee_dependencies[method_id].each do |target_id|
      before = root_causes[method_id].length
      root_causes[method_id].merge(root_causes[target_id])
      changed ||= before != root_causes[method_id].length
    end
  end
  break unless changed
end
incomplete_ids.each do |method_id|
  if root_causes[method_id].empty?
    root_causes[method_id] << "project_callee_summary_gap_unclassified"
  end
end

priority = %w[
  semantic_identity_missing
  callback_cost_missing
  reflective_target_cost_missing
  stdlib_cost_model_missing
  dependency_cost_model_missing
  external_cost_model_missing
  project_call_complexity_context_missing
  recursive_progress_unproven
  iteration_bound_unproven
  allocation_bound_unproven
  project_or_excluded_target_summary_unavailable
  normalized_unknown_operation_unclassified
  complexity_summary_gap_unclassified
  project_callee_summary_gap_unclassified
].each_with_index.to_h
primary = incomplete_ids.to_h do |method_id|
  cause = root_causes[method_id].min_by { |candidate| priority.fetch(candidate, priority.length) }
  [method_id, cause]
end

location = lambda do |method_id|
  result = results.fetch(method_id)
  {
    id: method_id,
    path: result[:path],
    line: result[:line],
    owner: result[:owner],
    function: result[:name]
  }
end

category_rows = root_causes.values.flat_map(&:to_a).uniq.sort.to_h do |category|
  affected = incomplete_ids.select { |method_id| root_causes[method_id].include?(category) }
  direct = incomplete_ids.select { |method_id| direct_causes[method_id].include?(category) }
  rows = cause_calls[category]
  top_symbols = rows.group_by { |call| call["semantic_symbol"].to_s }.map do |symbol, symbol_calls|
    {
      symbol: symbol.empty? ? nil : symbol,
      calls: symbol_calls.length,
      functions: symbol_calls.map { |call| call["source"] }.uniq.length
    }
  end.sort_by { |row| [-row[:functions], -row[:calls], row[:symbol].to_s] }.first(15)
  [category, {
    affected_incomplete_functions: affected.length,
    direct_incomplete_functions: direct.length,
    direct_call_sites: rows.length,
    top_symbols: top_symbols,
    examples: (direct.empty? ? affected : direct).first(options[:examples]).map(&location)
  }]
end

call_categories = calls.group_by(&call_resolution_category).transform_values do |rows|
  { calls: rows.length, functions: rows.map { |call| call["source"] }.uniq.length }
end

normalized_unknown_operations = Hash.new do |operations, operation|
  operations[operation] = {
    occurrences: 0,
    direct_incomplete_functions: Set.new,
    evidence_gaps: Hash.new(0)
  }
end
incomplete_ids.each do |method_id|
  result = results.fetch(method_id)
  result[:unknowns].each do |operation|
    row = normalized_unknown_operations[operation]
    row[:direct_incomplete_functions] << method_id
    evidence = result[:unknown_operation_evidence][operation] ||
      result[:unknown_operation_evidence][operation.to_sym] || {}
    occurrences = evidence[:occurrences] || evidence["occurrences"] || 1
    row[:occurrences] += occurrences.to_i
    gaps = evidence[:evidence_gaps] || evidence["evidence_gaps"] || {}
    if gaps.respond_to?(:each_pair)
      gaps.each_pair { |gap, count| row[:evidence_gaps][gap.to_s] += count.to_i }
    else
      result[:evidence_gaps].each { |gap| row[:evidence_gaps][gap.to_s] += 1 }
    end
  end
end
normalized_unknown_operations = normalized_unknown_operations.map do |operation, row|
  {
    operation: operation,
    occurrences: row[:occurrences],
    direct_incomplete_functions: row[:direct_incomplete_functions].length,
    evidence_gaps: row[:evidence_gaps].sort_by { |gap, count| [-count, gap] }.to_h,
    examples: row[:direct_incomplete_functions].first(options[:examples]).map(&location)
  }
end.sort_by do |row|
  [-row[:direct_incomplete_functions], -row[:occurrences], row[:operation].to_s]
end

direct_blockers = direct_causes.values.flat_map(&:to_a).uniq.sort.to_h do |category|
  affected = incomplete_ids.select { |method_id| direct_causes[method_id].include?(category) }
  [category, {
    incomplete_functions: affected.length,
    call_sites: cause_calls[category].length
  }]
end

report = {
  schema: "espalier.big-o-gap-diagnostics.v1",
  scope: {
    source_root: source_root,
    repositories: repositories,
    source_roles: ["production"]
  },
  summary: {
    functions: results.length,
    complete_time_bounds: results.count { |_, result| result[:complete] },
    incomplete_time_bounds: incomplete_ids.length,
    normalized_calls: calls.length
  },
  call_resolution: call_categories.sort.to_h,
  direct_big_o_blockers: direct_blockers,
  primary_root_cause_partition: primary.values.tally.sort_by { |_, count| -count }.to_h,
  root_cause_categories: category_rows,
  normalized_unknown_operations: normalized_unknown_operations.first(50),
  semantic_identity_missing_breakdown: calls
    .select { |call| call_resolution_category.call(call) == "semantic_identity_missing" }
    .group_by { |call| call["resolution_missing_proof"] || call["unresolved_reason"] || "unknown" }
    .transform_values(&:length)
    .sort_by { |_, count| -count }.to_h
}
report[:root_cause_impact] = Espalier::BigOGapImpact.analyze(results: results, calls: calls)
puts JSON.pretty_generate(report)
