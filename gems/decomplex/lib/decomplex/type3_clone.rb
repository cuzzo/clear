# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Type-3 clone with inconsistent renaming (CP-Miner, Li et al.
  # OSDI'04). The canonical LLM / copy-paste bug: a block is pasted and
  # the variables renamed, but ONE occurrence is missed. Within the
  # pasted copy, an abstract variable that the original uses uniformly
  # is then bound to two different concrete names -- the missed rename.
  #
  # Skeleton = the statement sequence with identifiers holed out
  # (structure + literals kept). Blocks with the same skeleton are
  # clones. In a clone, positions the REFERENCE member spells with the
  # same identifier must, after a correct rename, also be one
  # identifier in every other member. A member that spells them with
  # two names has a missed rename = bug candidate.
  class Type3Clone
    Block = Struct.new(:skeleton, :names, :file, :defn, :line, keyword_init: true)

    HOLE_TYPES = %i[LVAR DVAR IVAR LASGN DASGN IASGN].freeze
    MIN_TOKENS = 8

    def self.scan(files)
      blocks = []
      files.each do |f|
        root, lines = Ast.parse(f)
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
        if stmts.size >= 3
          sk = []
          nm = []
          stmts.each { |s| tokenize(s, sk, nm) }
          if sk.size >= MIN_TOKENS
            blocks << Block.new(skeleton: sk, names: nm, file: @file,
                                defn: defstack.last || "(top-level)",
                                line: stmts.first.first_lineno)
          end
        end
      end
      node.children.each { |c| collect(c, defstack, blocks) }
    end

    private

    # Emit a structural token stream; identifiers become :ID and their
    # concrete spelling is pushed (positionally) into names.
    def tokenize(node, sk, nm)
      return unless Ast.node?(node)

      case node.type
      when *HOLE_TYPES
        sk << :ID
        nm << node.children[0].to_s
      when :VCALL
        # A bare name with no receiver/args: the missed-rename bug
        # turns a bound LVAR into a VCALL. A token-level clone detector
        # (CP-Miner) does not see that distinction; collapse them so
        # the inconsistency is detectable.
        sk << :ID
        nm << node.children[0].to_s
      when :CALL, :FCALL
        sk << node.type
        mid = node.children[node.type == :CALL ? 1 : 0]
        sk << :MID
        nm << mid.to_s
      when :LIT, :STR, :SYM, :INTEGER, :FLOAT
        # Abstract literal VALUE away (CP-Miner): differing constants
        # are normal copy-paste variance, not a structural difference.
        sk << node.type
      else
        sk << node.type
      end
      node.children.each { |c| tokenize(c, sk, nm) }
    end

    class Report
      def initialize(blocks)
        @groups = blocks.group_by(&:skeleton).select { |_s, b| b.size >= 2 }
      end

      def inconsistent_renames
        out = []
        @groups.each_value do |members|
          ref = members.first
          # equivalence classes of name-positions sharing a ref spelling
          classes = Hash.new { |h, k| h[k] = [] }
          ref.names.each_with_index { |n, i| classes[n] << i }
          classes.select! { |_n, ps| ps.size >= 2 }
          next if classes.empty?

          members[1..].each do |m|
            classes.each do |ref_name, positions|
              spellings = positions.map { |p| m.names[p] }.uniq
              next if spellings.size < 2

              out << {
                file: m.file, defn: m.defn, line: m.line,
                at: "#{m.file}:#{m.defn}:#{m.line}",
                ref_at: "#{ref.file}:#{ref.defn}:#{ref.line}",
                ref_name: ref_name, divergent: spellings,
                clone_size: members.size
              }
            end
          end
        end
        out.uniq.sort_by { |h| -h[:clone_size] }
      end
    end
  end
end
