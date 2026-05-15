# frozen_string_literal: true

module Decomplex
  # Shared AST primitives for the v1 detectors. Kept separate from the
  # shipped v0 modules (site_extractor / co_update / predicate_alias)
  # so adding it cannot destabilise them (design principle 3); they
  # will be migrated onto this once it has proven itself.
  module Ast
    module_function

    def parse(file)
      src = File.read(file)
      [RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true), src.lines]
    end

    def node?(n)
      n.is_a?(RubyVM::AbstractSyntaxTree::Node)
    end

    # Exact source text of a node, trivial formatting normalised.
    def slice(node, lines)
      return "" unless node?(node)

      sl = node.first_lineno
      el = node.last_lineno
      txt =
        if sl == el
          lines[sl - 1][node.first_column...node.last_column]
        else
          ([lines[sl - 1][node.first_column..]] +
            lines[sl...(el - 1)] +
            [lines[el - 1][0...node.last_column]]).join
        end
      txt.to_s.strip.gsub(/\s+/, " ")
    end

    # Flatten a && chain (binary-nested OR n-ary, version dependent).
    def flatten_and(node)
      return [node] unless node?(node) && node.type == :AND

      node.children.flat_map { |c| flatten_and(c) }
    end

    # Enclosing def name for a walk; pushes on DEFN/DEFS.
    def def_push(node, stack)
      case node.type
      when :DEFN then stack + [node.children[0].to_s]
      when :DEFS then stack + [node.children[1].to_s]
      else stack
      end
    end

    # Polarity-canonical predicate text: strip a single leading `!`,
    # fold `x == nil`/`x.nil?` style is left as-is (handled by callers).
    # Returns [canonical_text, negated?].
    def canon_polarity(text)
      t = text.strip
      if t.start_with?("!")
        [t[1..].sub(/\A\(/, "").sub(/\)\z/, "").strip, true]
      else
        [t, false]
      end
    end

    # Statements of a method body (BLOCK children, or the single expr).
    def body_stmts(defn_node)
      scope = defn_node.children[defn_node.type == :DEFS ? 2 : 1]
      return [] unless node?(scope) && scope.type == :SCOPE

      body = scope.children[2]
      return [] unless node?(body)

      body.type == :BLOCK ? body.children.compact : [body]
    end
  end
end
