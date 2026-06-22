# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Flags boolean predicates with too many independent condition atoms.
  #
  # The intent is not "shorter code"; it is to surface places where a
  # long inline predicate probably wants an existing domain helper or a
  # newly named predicate. Nested parentheses still count because Ruby's
  # AST preserves the same AND/OR tree either way.
  class OversizedPredicate
    LIMIT = 3

    def self.scan(files, limit: LIMIT)
      findings = []
      files.each do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        new(file, limit).tap do |scanner|
          scanner.collect(document)
          findings.concat(scanner.findings)
        end
      end
      Result.new(findings)
    end

    Result = Struct.new(:findings)

    attr_reader :findings

    def initialize(file, limit)
      @file = file
      @limit = limit
      @findings = []
    end

    def collect(document)
      document.decision_sites.each { |site| record_predicate(site) }
    end

    private

    def record_predicate(site)
      return if predicate_helper?(site.function)

      atoms = condition_atoms(site.predicate)
      return unless atoms.size > @limit

      defn = site.function || "<top>"
      at = "#{@file}:#{defn}:#{site.line}"
      @findings << {
        at: at,
        count: atoms.size,
        predicate: site.predicate,
        atoms: atoms,
        spans: { at => site.enclosing_span || site.span },
      }
    end

    def condition_atoms(predicate)
      predicate.to_s
               .split(/\s*(?:&&|\|\||\band\b|\bor\b)\s*/)
               .map { |atom| atom.gsub(/[()]/, "").strip }
               .reject(&:empty?)
    end

    def predicate_helper?(name)
      name.to_s.end_with?("?")
    end
  end
end
