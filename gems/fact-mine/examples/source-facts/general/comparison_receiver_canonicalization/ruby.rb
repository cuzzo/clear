# frozen_string_literal: true

class SourceFactComparisonReceiverCanonicalization
  def tree_sitter?
    ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_") == "tree_sitter"
  end

  def dark_arm_result(rule, rule_id)
    rule.fetch("id") == rule_id
  end
end
