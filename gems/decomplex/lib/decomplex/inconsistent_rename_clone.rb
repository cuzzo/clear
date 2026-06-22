# frozen_string_literal: true

require_relative "local_flow"

module Decomplex
  # Narrow clone bug detector: a pasted block was renamed, but one
  # occurrence kept the old spelling. This is intentionally not a
  # general Type-2/Type-3 clone detector; the structural similarity
  # scanner owns that broader signal.
  class InconsistentRenameClone
    Block = Struct.new(:skeleton, :names, :file, :defn, :line, :span,
                       keyword_init: true)

    MIN_TOKENS = 8

    def self.scan(files)
      blocks = LocalFlow.scan(files).filter_map do |method|
        next if method.statements.size < 3

        new.add_block(method)
      end
      Report.new(blocks).inconsistent_renames
    end

    def add_block(method)
      skeleton = []
      names = []
      method.statements.each { |statement| tokenize(statement.source, skeleton, names) }
      return nil if skeleton.size < MIN_TOKENS

      Block.new(
        skeleton: skeleton,
        names: names,
        file: method.file,
        defn: method.name,
        line: method.statements.first.line,
        span: [
          method.statements.first.span[0],
          method.statements.first.span[1],
          method.statements.last.span[2],
          method.statements.last.span[3]
        ]
      )
    end

    private

    def tokenize(source, skeleton, names)
      source.to_s.scan(/[A-Za-z_]\w*[!?=]?|@\w+|\d+(?:\.\d+)?|:[A-Za-z_]\w*|\"[^\"]*\"|'[^']*'|\S/) do |token|
        case token
        when /\A[@A-Za-z_]\w*[!?=]?\z/
          skeleton << :ID
          names << token.delete_prefix("@").delete_suffix("=")
        when /\A(?::[A-Za-z_]\w*|\d+(?:\.\d+)?|\"[^\"]*\"|'[^']*')\z/
          skeleton << :LIT
        else
          skeleton << token
        end
      end
    end

    class Report
      def initialize(blocks)
        @groups = blocks.group_by(&:skeleton).select { |_s, b| b.size >= 2 }
      end

      def inconsistent_renames
        @groups.values.flat_map { |members| findings_for(members) }
               .uniq
               .sort_by { |h| [-h[:clone_size], h[:at]] }
      end

      private

      def findings_for(members)
        return [] unless members.map { |m| [m.file, m.defn] }.uniq.size >= 2

        members.combination(2).flat_map do |ref, candidate|
          next [] if same_unit?(ref, candidate)

          inconsistent_pairs(ref, candidate)
        end
      end

      def inconsistent_pairs(ref, candidate)
        ref_classes(ref).flat_map do |ref_name, positions|
          spellings = positions.filter_map { |pos| candidate.names[pos] }.uniq
          next [] if spellings.size < 2

          [finding(ref, candidate, ref_name, spellings)]
        end
      end

      def ref_classes(ref)
        classes = Hash.new { |h, k| h[k] = [] }
        ref.names.each_with_index { |name, index| classes[name] << index }
        classes.select { |_name, positions| positions.size >= 2 }
      end

      def same_unit?(left, right)
        left.file == right.file && left.defn == right.defn
      end

      def finding(ref, candidate, ref_name, spellings)
        at = "#{candidate.file}:#{candidate.defn}:#{candidate.line}"
        ref_at = "#{ref.file}:#{ref.defn}:#{ref.line}"
        {
          file: candidate.file, defn: candidate.defn, line: candidate.line,
          at: at, ref_at: ref_at,
          spans: { at => candidate.span, ref_at => ref.span },
          ref_name: ref_name, divergent: spellings,
          clone_size: 2
        }
      end
    end
  end
end
