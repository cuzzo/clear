# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # A single decision site mined from one source file.
  #
  #   kind        :case_dispatch | :conjunction
  #   members     normalized predicate/pattern source texts (a Set-as-sorted-Array)
  #   file/def/ln  where the decision is made (def granularity = scatter unit)
  # span = [first_line, first_col, last_line, last_col] of the decision
  # node -- additive; lets a consumer test whether a point (an
  # uncovered branch arm) falls INSIDE this decision, not just "same
  # method" (the decomplex authority unit stays (file, defn)).
  Site = Struct.new(:kind, :members, :file, :defn, :line, :span,
                    keyword_init: true)

  # Emits decision sites from Decomplex's language-neutral syntax facade.
  # v0 mines exactly two shapes, both exact-match, no alias/polarity
  # canonicalization yet (that is v1 -- documented in the gemspec):
  #
  #   * :case_dispatch -- a `case <disc> when P1 when P2 ...` ladder.
  #     members = the SET of all `when` pattern texts. This is the
  #     densest, most regular decision structure in a compiler and the
  #     one with zero alias ambiguity (arms are class constants).
  #   * :conjunction   -- an `a && b && c` guard (flattened). members =
  #     the operand texts. Directly answers "these N conditions checked
  #     together many times".
  class SiteExtractor
    def self.extract(file)
      Syntax.parse(file).decision_sites.map do |site|
        Site.new(
          kind: site.kind,
          members: site.members,
          file: site.file,
          defn: site.function,
          line: site.line,
          span: site.span
        )
      end
    end
  end
end
