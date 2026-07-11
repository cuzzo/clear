# frozen_string_literal: true

module SarifResultCap
  module_function

  def select(results, limit)
    results = Array(results)
    return [results, counts(results, results)] unless limit&.positive? && results.length > limit

    indexed = results.each_with_index.group_by { |(result, _index)| rule_id(result) }
    buckets = indexed.transform_values { |rows| rows.sort_by { |result, index| result_key(result, index) } }
    ordered_rules = buckets.keys.sort_by { |rule| [bucket_tier(buckets.fetch(rule)), rule] }
    selected = []

    # Preserve detector/rule diversity before allowing prolific rules to use
    # the remaining budget.
    ordered_rules.first(limit).each do |rule|
      selected << buckets.fetch(rule).shift
    end

    weighted_schedule = ordered_rules.flat_map do |rule|
      [rule] * tier_weight(bucket_tier(buckets.fetch(rule), selected, rule))
    end
    while selected.length < limit && weighted_schedule.any? { |rule| !buckets.fetch(rule).empty? }
      weighted_schedule.each do |rule|
        row = buckets.fetch(rule).shift
        next unless row

        selected << row
        break if selected.length >= limit
      end
    end

    retained = selected.sort_by { |result, index| result_key(result, index) }.map(&:first)
    [retained, counts(results, retained)]
  end

  def counts(original, retained)
    original_counts = rule_counts(original)
    retained_counts = rule_counts(retained)
    {
      "original_by_rule" => original_counts,
      "retained_by_rule" => retained_counts,
      "truncated_by_rule" => original_counts.to_h do |rule, count|
        [rule, count - retained_counts.fetch(rule, 0)]
      end,
    }
  end

  def rule_counts(results)
    Array(results).each_with_object(Hash.new(0)) do |result, out|
      out[rule_id(result)] += 1
    end.sort.to_h
  end

  def rule_id(result)
    result["ruleId"].to_s.empty? ? "(unknown)" : result["ruleId"].to_s
  end

  def tier(result)
    value = result.dig("properties", "tier") || result.dig("properties", "decomplex_finding", "tier")
    parsed = Integer(value, exception: false)
    parsed&.positive? ? parsed : 3
  end

  def bucket_tier(rows, selected = [], rule = nil)
    candidates = rows.map(&:first)
    candidates.concat(selected.filter_map { |result, _index| result if rule_id(result) == rule }) if rule
    candidates.map { |result| tier(result) }.min || 3
  end

  def tier_weight(value)
    case value
    when 1 then 3
    when 2 then 2
    else 1
    end
  end

  def result_key(result, index)
    level_rank = result["level"] == "error" ? 0 : result["level"] == "warning" ? 1 : 2
    [tier(result), level_rank, rule_id(result), index]
  end
end
