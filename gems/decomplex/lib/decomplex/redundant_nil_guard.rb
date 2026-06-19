# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Finds nil checks or safe-navigation performed after the same stable subject
  # is already proven non-nil on the current intra-method path.
  class RedundantNilGuard
    def self.scan(files)
      findings = files.flat_map do |file|
        Syntax.parse(file, parser: "tree_sitter").redundant_nil_guard_findings
      end
      dedupe(findings)
        .sort_by { |finding| [finding.file, finding.line, finding.local, finding.guard] }
        .map(&:to_h)
    end

    def self.dedupe(findings)
      findings.group_by do |finding|
        [finding.file, finding.defn, finding.line, finding.local, finding.guard.to_s.delete_suffix("()")]
      end.values.map do |group|
        group.max_by { |finding| finding.guard.to_s.length }
      end
    end
  end
end
