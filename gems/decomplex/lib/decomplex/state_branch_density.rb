# frozen_string_literal: true

require "set"
require_relative "syntax"

module Decomplex
  # StateBranchDensity -- branches whose predicate reads mutable or
  # object-owned state. This is the "state + control flow" surface:
  # branch decisions over ivars, globals, or receiver attributes.
  class StateBranchDensity
    Decision = Struct.new(:file, :defn, :line, :span, :predicate,
                          :state_refs, keyword_init: true)

    def self.scan(files)
      documents = files.to_h do |file|
        [file, Syntax.parse(file, parser: "tree_sitter")]
      end
      immutable_readers = Hash.new { |h, k| h[k] = Set.new }
      immutable_reader_types = Hash.new { |h, k| h[k] = {} }
      type_aliases = {}

      documents.each_value do |document|
        document.immutable_struct_readers.each do |name, readers|
          immutable_readers[name].merge(readers)
        end
        document.immutable_struct_reader_types.each do |name, readers|
          immutable_reader_types[name].merge!(readers)
        end
        type_aliases.merge!(document.type_aliases)
      end

      decisions = documents.flat_map do |file, document|
        new(
          file,
          document,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases
        ).decisions
      end
      Report.new(decisions)
    end

    attr_reader :decisions

    def initialize(file, document, immutable_readers:, immutable_reader_types:, type_aliases:)
      @file = file
      @document = document
      @decisions = semantic_decisions(
        immutable_readers: immutable_readers,
        immutable_reader_types: immutable_reader_types,
        type_aliases: type_aliases
      )
    end

    private

    def semantic_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
      branch_decisions = @document.branch_decisions(
        immutable_readers: immutable_readers,
        immutable_reader_types: immutable_reader_types,
        type_aliases: type_aliases
      )
      filter_wrapper_decisions(branch_decisions).map do |decision|
        Decision.new(
          file: @file,
          defn: decision.function,
          line: decision.line,
          span: decision.span,
          predicate: decision.predicate,
          state_refs: decision.state_refs.uniq.sort
        )
      end
    end

    def filter_wrapper_decisions(decisions)
      decisions.reject do |decision|
        wrapper_predicate?(decision.predicate) && nested_state_decision?(decision, decisions)
      end
    end

    def wrapper_predicate?(predicate)
      predicate.to_s.match?(/\A(?:if|unless|while|until)\b/)
    end

    def nested_state_decision?(decision, decisions)
      decisions.any? do |candidate|
        next false if candidate.equal?(decision)
        next false unless candidate.function == decision.function
        next false unless encloses?(decision.span, candidate.span)

        (Array(candidate.state_refs) - Array(decision.state_refs)).empty?
      end
    end

    def encloses?(outer, inner)
      return false unless outer && inner

      starts_before = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1])
      ends_after = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3])
      starts_before && ends_after
    end

    class Report
      def initialize(decisions)
        @decisions = decisions
      end

      def findings
        @decisions.group_by { |d| [d.file, d.defn] }.map do |(file, defn), ds|
          refs = ds.flat_map(&:state_refs).uniq.sort
          {
            at: "#{file}:#{defn}:#{ds.first.line}",
            file: file,
            method: defn,
            decisions: ds.size,
            state_refs: refs,
            predicate: ds.first.predicate,
            score: ds.size * [refs.size, 1].max,
            sites: ds.map { |d| "#{d.file}:#{d.defn}:#{d.line}" },
            spans: ds.to_h { |d| ["#{d.file}:#{d.defn}:#{d.line}", d.span] }
          }
        end.sort_by { |h| [-h[:score], -h[:decisions], h[:file], h[:method]] }
      end
    end
  end
end
