# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Path-condition normal form. `if x; if y; act` and `if x && y; act`
  # and `act if x && y` all reduce to the same guarded action with
  # path condition {x, y}. Mining the PATH CONDITION (not the syntactic
  # if) is what makes nested control flow and flat conjunction the same
  # decision -- the user's "is `if x / if y` related to `if x && y`?".
  #
  # A site = an effectful leaf (call / assignment) reached under >= 2
  # guard atoms. Scatter = the same guard set reached in >= 2 (file,
  # def) units. Neglected = a guarded action that is a high-support
  # guard set minus exactly one atom.
  class PathCondition
    Site = Struct.new(:guards, :action, :file, :defn, :line, keyword_init: true)

    def self.scan(files)
      sites = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, [], [])
        sites.concat(e.sites)
      end
      Report.new(sites)
    end

    attr_reader :sites

    def initialize(file, lines)
      @file = file
      @lines = lines
      @sites = []
    end

    # guards: array of [text, negated?] atoms currently in scope.
    def walk(node, defstack, guards)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)

      case node.type
      when :IF, :UNLESS
        cond, a, b = node.children
        atoms = cond_atoms(cond)
        then_g = node.type == :IF ? atoms : negate(atoms)
        else_g = node.type == :IF ? negate(atoms) : atoms
        walk(a, defstack, guards + then_g) if a
        walk(b, defstack, guards + else_g) if b
        # the condition itself may contain nested constructs
        walk(cond, defstack, guards)
        return
      when :CALL, :FCALL, :VCALL, :ATTRASGN, :LASGN, :IASGN, :OPCALL
        record(node, defstack, guards) if guards.size >= 2
      end

      node.children.each { |c| walk(c, defstack, guards) }
    end

    private

    def cond_atoms(cond)
      Ast.flatten_and(cond).map do |a|
        t = Ast.slice(a, @lines)
        text, neg = Ast.canon_polarity(t)
        [text, neg]
      end
    end

    def negate(atoms)
      atoms.map { |t, n| [t, !n] }
    end

    def record(node, defstack, guards)
      members = guards.map { |t, n| (n ? "!" : "") + t }.uniq.sort
      return if members.size < 2

      @sites << Site.new(guards: members, action: Ast.slice(node, @lines)[0, 80],
                         file: @file, defn: defstack.last || "(top-level)",
                         line: node.first_lineno)
    end

    class Report
      def initialize(sites)
        @sites = sites
        @groups = sites.group_by(&:guards)
      end

      def scattered(min_scatter: 2)
        @groups.filter_map do |gs, sts|
          scatter = sts.map { |s| [s.file, s.defn] }.uniq.size
          next if scatter < min_scatter

          { guards: gs, support: sts.size, scatter: scatter,
            rank: sts.size * scatter,
            sites: sts.map { |s| "#{s.file}:#{s.defn}:#{s.line}" } }
        end.sort_by { |h| -h[:rank] }
      end

      def neglected(min_support: 3)
        popular = @groups.select { |_g, s| s.size >= min_support }
                         .map { |g, s| [g, s.size] }
        out = []
        @sites.each do |s|
          popular.each do |gs, sup|
            next unless (gs - s.guards).size == 1 && (s.guards - gs).empty?
            next if s.guards == gs

            out << { pattern: gs, support: sup,
                     missing: (gs - s.guards).first,
                     at: "#{s.file}:#{s.defn}:#{s.line}", action: s.action }
          end
        end
        out.uniq.sort_by { |h| -h[:support] }
      end
    end
  end
end
