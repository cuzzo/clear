# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Derived-state def-use staleness (intra-procedural, the design
  # boundary's "single-method reaching-defs", no whole-program flow).
  #
  # Plague: redundant state that drifts. `b = f(a)` makes b a derived
  # copy of a. If a is then reassigned later in the same method but b
  # is NOT recomputed, every later use of b is stale -- the exact
  # "field copied from elsewhere then used for similar decisions" bug.
  class DerivedState
    Asgn = Struct.new(:name, :deps, :line, keyword_init: true)

    def self.scan(files)
      out = []
      files.each do |f|
        root, lines = Ast.parse(f)
        new(f, lines).each_method(root) do |defn, stmts|
          out.concat(analyze(f, defn, stmts))
        end
      end
      out.sort_by { |h| -h[:gap] }
    end

    def initialize(file, lines)
      @file = file
      @lines = lines
    end

    def each_method(node, defstack = [], &blk)
      return unless Ast.node?(node)

      if %i[DEFN DEFS].include?(node.type)
        name = node.children[node.type == :DEFS ? 1 : 0].to_s
        yield name, Ast.body_stmts(node)
      end
      node.children.each { |c| each_method(c, defstack, &blk) }
    end

    # Flatten statements (incl. inside simple blocks) to ordered LASGNs.
    def self.lasgns(stmts)
      acc = []
      walk = lambda do |n|
        return unless Ast.node?(n)

        if n.type == :LASGN
          acc << n
          n.children.each { |c| walk.call(c) }
        else
          n.children.each { |c| walk.call(c) }
        end
      end
      stmts.each { |s| walk.call(s) }
      acc
    end

    def self.lvars(node, acc = [])
      return acc unless Ast.node?(node)

      acc << node.children[0].to_s if node.type == :LVAR
      node.children.each { |c| lvars(c, acc) }
      acc
    end

    def self.analyze(file, defn, stmts)
      asgns = lasgns(stmts).map do |n|
        Asgn.new(name: n.children[0].to_s,
                 deps: lvars(n.children[1]).uniq,
                 line: n.first_lineno)
      end
      out = []
      asgns.each_with_index do |b, i|
        next if b.deps.empty?

        b.deps.each do |a|
          next if a == b.name

          # a reassigned strictly after b's definition?
          reasn = asgns[(i + 1)..].find { |x| x.name == a }
          next unless reasn

          # b recomputed at or after a's reassignment?
          recomputed = asgns[(i + 1)..].any? do |x|
            x.name == b.name && x.line >= reasn.line
          end
          next if recomputed

          out << {
            file: file, defn: defn,
            derived: b.name, source: a,
            derived_at: b.line, source_reassigned_at: reasn.line,
            gap: reasn.line - b.line,
            at: "#{file}:#{defn}:#{b.line}"
          }
        end
      end
      out
    end
  end
end
