# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Narrow clone bug detector: a pasted block was renamed, but one
  # occurrence kept the old spelling. This is intentionally not a
  # general Type-2/Type-3 clone detector; Flay owns that broader signal.
  #
  # The important false-positive guard is cross-method evidence. Local
  # branch symmetry inside one method often has the same skeleton with
  # different receiver/container variables, but that is not a pasted
  # rename bug.
  class InconsistentRenameClone
    Block = Struct.new(:skeleton, :names, :file, :defn, :line, :span,
                       keyword_init: true)

    HOLE_TYPES = %i[LVAR DVAR IVAR LASGN DASGN IASGN].freeze
    MIN_TOKENS = 8

    def self.scan(files)
      blocks = []
      files.each do |f|
        root, = Ast.parse(f)
        new(f).collect(root, [], blocks)
      end
      Report.new(blocks).inconsistent_renames
    end

    def initialize(file)
      @file = file
    end

    def collect(node, defstack, blocks)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)
      if node.type == :BLOCK
        stmts = node.children.compact
        add_block(stmts, defstack, blocks) if stmts.size >= 3
      end
      node.children.each { |child| collect(child, defstack, blocks) }
    end

    private

    def add_block(stmts, defstack, blocks)
      skeleton = []
      names = []
      stmts.each { |stmt| tokenize(stmt, skeleton, names) }
      return if skeleton.size < MIN_TOKENS

      blocks << Block.new(skeleton: skeleton, names: names, file: @file,
                          defn: defstack.last || "(top-level)",
                          line: stmts.first.first_lineno,
                          span: [stmts.first.first_lineno,
                                 stmts.first.first_column,
                                 stmts.last.last_lineno,
                                 stmts.last.last_column])
    end

    def tokenize(node, skeleton, names)
      return unless Ast.node?(node)

      case node.type
      when *HOLE_TYPES
        skeleton << :ID
        names << node.children[0].to_s
      when :VCALL
        skeleton << :ID
        names << node.children[0].to_s
      when :CALL, :FCALL
        skeleton << node.type
        mid = node.children[node.type == :CALL ? 1 : 0]
        skeleton << :MID
        names << mid.to_s
      when :LIT, :STR, :SYM, :INTEGER, :FLOAT
        skeleton << node.type
      else
        skeleton << node.type
      end
      node.children.each { |child| tokenize(child, skeleton, names) }
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
