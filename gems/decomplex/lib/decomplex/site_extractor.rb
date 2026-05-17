# frozen_string_literal: true

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

  # Walks one file's AST (stdlib parser, zero deps) and emits Sites.
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
      src = File.read(file)
      root = RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true)
      new(file, src.lines).tap { |e| e.walk(root, []) }.sites
    end

    attr_reader :sites

    def initialize(file, lines)
      @file = file
      @lines = lines
      @sites = []
    end

    def walk(node, defstack, parent_type = nil)
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      case node.type
      when :DEFN
        defstack = defstack + [node.children[0].to_s]
      when :DEFS
        defstack = defstack + [node.children[1].to_s]
      when :CASE
        record_case(node, defstack)
      when :AND
        # Record only the OUTERMOST && of a chain; `a && b && c` parses
        # as AND(AND(a,b),c) -- the inner AND is the same decision, not
        # a second one.
        record_conjunction(node, defstack) unless parent_type == :AND
      end

      node.children.each { |c| walk(c, defstack, node.type) }
    end

    private

    def cur_def(defstack)
      defstack.last || "(top-level)"
    end

    # case <pred> when ... -- skip predicate-less `case` (that is an
    # if/elsif chain in disguise, a different signal) and case/in.
    def record_case(node, defstack)
      pred = node.children[0]
      return unless pred # predicate-less => not dispatch

      pats = []
      whenn = node.children[1]
      while whenn.is_a?(RubyVM::AbstractSyntaxTree::Node) && whenn.type == :WHEN
        plist = whenn.children[0]
        if plist.is_a?(RubyVM::AbstractSyntaxTree::Node)
          plist.children.each do |p|
            next unless p.is_a?(RubyVM::AbstractSyntaxTree::Node)

            pats << slice(p)
          end
        end
        whenn = whenn.children[2]
      end
      pats = pats.compact.uniq.sort
      return if pats.size < 2

      @sites << Site.new(kind: :case_dispatch, members: pats, file: @file,
                         defn: cur_def(defstack), line: node.first_lineno,
                         span: [node.first_lineno, node.first_column,
                                node.last_lineno, node.last_column])
    end

    # Flatten a left-leaning && chain into its operand set.
    def record_conjunction(node, defstack)
      ops = flatten_and(node).map { |n| slice(n) }.compact.uniq.sort
      return if ops.size < 2

      @sites << Site.new(kind: :conjunction, members: ops, file: @file,
                         defn: cur_def(defstack), line: node.first_lineno,
                         span: [node.first_lineno, node.first_column,
                                node.last_lineno, node.last_column])
    end

    def flatten_and(node)
      return [node] unless node.is_a?(RubyVM::AbstractSyntaxTree::Node) && node.type == :AND

      # `a && b && c` may parse either as nested binary AND(AND(a,b),c)
      # or as one :AND with N children, depending on Ruby version --
      # flatten every child either way.
      node.children.flat_map { |c| flatten_and(c) }
    end

    # Slice exact source for a node and normalize trivial formatting.
    def slice(node)
      sl = node.first_lineno
      el = node.last_lineno
      sc = node.first_column
      ec = node.last_column
      text =
        if sl == el
          @lines[sl - 1][sc...ec]
        else
          parts = [@lines[sl - 1][sc..]]
          parts.concat(@lines[(sl)...(el - 1)])
          parts << @lines[el - 1][0...ec]
          parts.join
        end
      text.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
