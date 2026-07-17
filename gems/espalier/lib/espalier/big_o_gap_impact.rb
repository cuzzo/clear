# frozen_string_literal: true

require "set"

module Espalier
  # Language-neutral propagation from direct Big-O evidence gaps to every
  # incomplete caller affected by those roots.
  module BigOGapImpact
    module_function

    def analyze(results:, calls:)
      incomplete = results.filter_map { |id, row| id.to_s unless row[:complete] }.to_set
      calls_by_source = Array(calls).group_by { |call| value(call, :source).to_s }
      dependencies = incomplete.to_h do |method_id|
        targets = Array(calls_by_source[method_id]).filter_map do |call|
          target = value(call, :target).to_s
          target if incomplete.include?(target)
        end.to_set
        [method_id, targets]
      end

      direct_roots = incomplete.select do |method_id|
        row = results.fetch(method_id)
        !Array(row[:unknowns]).empty? || !Hash(row[:unknown_operation_evidence]).empty?
      end.to_set
      roots_by_method = incomplete.to_h do |method_id|
        [method_id, direct_roots.include?(method_id) ? Set[method_id] : Set.new]
      end
      incomplete.length.times do
        changed = false
        incomplete.each do |method_id|
          dependencies.fetch(method_id).each do |callee_id|
            before = roots_by_method.fetch(method_id).length
            roots_by_method.fetch(method_id).merge(roots_by_method.fetch(callee_id))
            changed ||= before != roots_by_method.fetch(method_id).length
          end
        end
        break unless changed
      end

      roots = direct_roots.map do |root_id|
        result = results.fetch(root_id)
        affected = incomplete.select { |method_id| roots_by_method.fetch(method_id).include?(root_id) }
        root_calls = Array(calls_by_source[root_id]).select do |call|
          value(call, :target).nil? && value(call, :known_time_complexity).nil?
        end
        categories = root_categories(result, root_calls)
        {
          id: root_id,
          path: result[:path],
          line: result[:line],
          owner: result[:owner],
          function: result[:name],
          operations: Array(result[:unknowns]),
          categories: categories,
          affected_incomplete_functions: affected.length,
          affected_function_ids: affected.sort
        }
      end.sort_by { |row| [-row[:affected_incomplete_functions], row[:id]] }

      category_counts = roots.flat_map { |root| root[:categories].map { |category| [category, root] } }
        .group_by(&:first).transform_values do |entries|
          root_rows = entries.map(&:last)
          {
            direct_root_functions: root_rows.length,
            affected_incomplete_functions: root_rows.flat_map { |root| root[:affected_function_ids] }.uniq.length
          }
        end.sort.to_h

      {
        incomplete_functions: incomplete.length,
        direct_root_functions: direct_roots.length,
        propagated_only_functions: incomplete.length - direct_roots.length,
        unique_unknown_operations: direct_roots.flat_map { |id| Array(results.fetch(id)[:unknowns]) }.uniq.length,
        untraced_incomplete_functions: roots_by_method.count { |_, roots_for_method| roots_for_method.empty? },
        categories: category_counts,
        roots: roots
      }
    end

    def root_categories(result, calls)
      categories = Set.new
      gaps = Array(result[:evidence_gaps]).map(&:to_s)
      categories << "receiver_identity_missing" if gaps.include?("unresolved_receiver_type")
      categories << "call_target_missing" if gaps.include?("unresolved_call_target")
      categories << "normalized_cost_fact_missing" if gaps.include?("unmodeled_typed_operation")

      Array(calls).each do |call|
        boundary = value(call, :dispatch_boundary).to_s
        categories << "dynamic_or_reflective_dispatch" unless boundary.empty?
        categories << "callback_origin_or_cost_missing" if value(call, :callback_receiver) == true
        symbol = value(call, :semantic_symbol).to_s
        categories << "external_symbol_cost_missing" unless symbol.empty?
        reason = value(call, :resolution_missing_proof).to_s
        categories << "callback_origin_or_cost_missing" if reason.include?("callback")
      end
      categories << "unclassified_normalization_gap" if categories.empty?
      categories.to_a.sort
    end

    def value(hash, key)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end
    private_class_method :root_categories, :value
  end
end
