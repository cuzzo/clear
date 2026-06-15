# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Fat-union detector: Missing-Abstractions for product-vs-sum
  # decomposition. A `case <disc> when ClassA when ClassB ...`
  # dispatch where the arms read mostly the SAME members of <disc>
  # (and/or <disc> members are read OUTSIDE the dispatch in the same
  # method) is a union whose common core should be a struct, with a
  # SMALL union for the genuinely-varying part. Every such fat union
  # is a Neglected-Updates / Missing-Abstractions generator (the
  # storage/provenance invariant-#16 shape at the type level).
  #
  # decomplex MEASURES and ranks the use-site cohesion evidence; the
  # extraction is value-object work, nil-kill's owned territory
  # (design.md nil-kill boundary). Output routes there.
  #
  # v1 scope (principle 4, exact before semantic): `case` over CLASS
  # CONSTANTS only. `is_a?` if/elsif chains and `:kind`-tagged hashes
  # are a documented future scope limit, reported absent not
  # approximated. Zero deps, AST only, no points-to.
  class FatUnion
    CONST_TYPES = %i[CONST COLON2 COLON3].freeze
    Site = Struct.new(:variant_set, :arm_members, :outside, :file,
                      :defn, :line, :span, keyword_init: true)

    def self.scan(files, min_variants: 3, min_common: 2, ratio: 0.6)
      sites = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, "(top-level)", nil)
        sites.concat(e.sites)
      end
      Report.new(sites, min_variants: min_variants,
                 min_common: min_common, ratio: ratio)
    end

    attr_reader :sites

    def initialize(file, lines)
      @file = file
      @lines = lines
      @sites = []
    end

    # Carries the enclosing def NAME and NODE so "accessed outside the
    # dispatch but in the same method" (the strongest common-core
    # tell) is computable by pruning the case subtree.
    def walk(node, defn, defn_node)
      return unless Ast.node?(node)

      case node.type
      when :DEFN then defn = node.children[0].to_s; defn_node = node
      when :DEFS then defn = node.children[1].to_s; defn_node = node
      when :CASE
        s = record_case(node, defn, defn_node)
        @sites << s if s
      end
      node.children.each { |c| walk(c, defn, defn_node) }
    end

    private

    def record_case(node, defn, defn_node)
      disc = node.children[0]
      return nil unless Ast.node?(disc) # predicate-less = if-chain

      disc_txt = Ast.slice(disc, @lines)
      arms = {} # "ClassName" => [member, ...]
      whenn = node.children[1]
      while Ast.node?(whenn) && whenn.type == :WHEN
        consts = const_patterns(whenn.children[0])
        unless consts.empty? # class-constant dispatch only (v1 scope)
          mem = subtree_members(whenn.children[1], disc_txt)
          consts.each { |c| (arms[c] ||= []).concat(mem) }
        end
        whenn = whenn.children[2]
      end
      return nil if arms.size < 2

      arms.transform_values!(&:uniq)
      Site.new(variant_set: arms.keys.sort, arm_members: arms,
               outside: outside_members(defn_node, node, disc_txt),
               file: @file, defn: defn, line: node.first_lineno,
               span: [node.first_lineno, node.first_column,
                      node.last_lineno, node.last_column])
    end

    # disc-members read in the enclosing method but NOT inside this
    # case. Pruned by the case's LINE SPAN, not object identity; adapters
    # are free to materialize fresh wrapper nodes per traversal. Empty
    # for a top-level case (no enclosing method) -- documented limit.
    def outside_members(defn_node, case_node, disc_txt)
      return [] unless Ast.node?(defn_node)

      acc = []
      collect(defn_node, disc_txt, case_node.first_lineno,
              case_node.last_lineno, acc)
      acc.uniq
    end

    def collect(node, disc_txt, cfl, cll, acc)
      return unless Ast.node?(node)
      # entire subtree lies within the case -> it is inside, skip.
      return if node.first_lineno >= cfl && node.last_lineno <= cll

      m = member_access(node, disc_txt)
      acc << m if m
      node.children.each { |c| collect(c, disc_txt, cfl, cll, acc) }
    end

    def subtree_members(body, disc_txt)
      acc = []
      stack = [body]
      until stack.empty?
        n = stack.pop
        next unless Ast.node?(n)

        m = member_access(n, disc_txt)
        acc << m if m
        n.children.each { |c| stack << c }
      end
      acc.uniq
    end

    # `<disc>.foo` / `.foo(..)` / `<disc> << x` / `<disc>.foo = x`
    # -> "foo" / "<<" / "foo". nil otherwise.
    def member_access(n, disc_txt)
      return nil unless %i[CALL OPCALL ATTRASGN].include?(n.type)

      recv, mid, = n.children
      return nil unless Ast.node?(recv) && Ast.slice(recv, @lines) == disc_txt

      mid.to_s.sub(/=\z/, "")
    end

    def const_patterns(plist)
      return [] unless Ast.node?(plist)

      plist.children.filter_map do |p|
        Ast.slice(p, @lines) if Ast.node?(p) && CONST_TYPES.include?(p.type)
      end
    end

    class Report
      def initialize(sites, min_variants:, min_common:, ratio:)
        @sites = sites
        @min_variants = min_variants
        @min_common = min_common
        @ratio = ratio
      end

      # [{ variant_set:, common:[], variant:[], degenerate:, support:,
      #    scatter:, rank:, kind:, members:, at:, sites:[], spans:{} }]
      def fat_unions
        @sites.group_by(&:variant_set).filter_map do |vset, group|
          v = vset.size
          next if v < @min_variants

          # member -> distinct variant-classes accessing it, across
          # every dispatch site of this variant-set.
          vcls = Hash.new { |h, k| h[k] = {} }
          outside = {}
          group.each do |s|
            s.arm_members.each { |cls, ms| ms.each { |m| vcls[m][cls] = true } }
            s.outside.each { |m| outside[m] = true }
          end
          # member universe = accessed in an arm OR only outside the
          # dispatch (a member read ONLY outside is the strongest
          # 'belongs in the common struct' signal -- it must not be
          # dropped just because no arm names it).
          keys = vcls.keys | outside.keys
          common = keys.select do |m|
            outside[m] || (vcls[m] && vcls[m].size >= v)
          end
          variant = keys.select do |m|
            !outside[m] && vcls[m] && vcls[m].size == 1
          end
          total = common.size + variant.size
          next if common.size < @min_common
          next if total.zero? || common.size.to_f / total < @ratio

          locs = group.map { |s| "#{s.file}:#{s.defn}:#{s.line}" }
          {
            variant_set: vset, common: common.sort,
            variant: variant.sort, degenerate: variant.empty?,
            support: group.size,
            scatter: group.map { |s| [s.file, s.defn] }.uniq.size,
            rank: group.size * common.size,
            kind: :case_dispatch, members: vset,
            at: locs.first, sites: locs.uniq,
            spans: group.to_h { |s| ["#{s.file}:#{s.defn}:#{s.line}", s.span] }
          }
        end.sort_by { |h| [h[:degenerate] ? 0 : 1, -h[:rank]] }
      end
    end
  end
end
