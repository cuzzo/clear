# frozen_string_literal: true

module SlopCop
  module Constraints
    Finding = Struct.new(
      :path,
      :line,
      :rule_id,
      :message,
      :source,
      :hazard_type,
      :required_evidence,
      :severity,
      keyword_init: true
    ) do
      def to_h
        {
          path: path,
          line: line,
          rule_id: rule_id,
          message: message,
          source: source,
          hazard_type: hazard_type,
          required_evidence: required_evidence,
          severity: severity || "warning"
        }
      end
    end
  end
end
