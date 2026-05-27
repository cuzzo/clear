# frozen_string_literal: true

require "json"

module SlopCop
  # Classifies every never-taken branch arm in a target file into ONE
  # actionable category. AST-structural, never a regex over the arm
  # line. General -- no project lexicon baked in (see ffi_boundary:).
  #
  # Categories (not all gaps are equal):
  #   :type_norm  arm/decision guards a type/nil check (is_a?/kind_of?/
  #               nil?/respond_to?/safe-nav). Likely dead if the
  #               contract were strictly typed.
  #   :dead       no sibling arm of the decision is ever taken in the
  #               supplied coverage. Audit as unexercised code: it may
  #               be a missing test, or dead only if static reachability
  #               tools agree.
  #   :defensive  live decision, inert/pinned polarity (empty else,
  #               nil, invariant-guaranteed). Accept.
  #   :ffi        a caller-declared external/boundary method -> needs
  #               an integration test.
  #   :diagnostic arm raises/diagnoses -> invalid-input only.
  #   :genuine    live, reachable, input-determined, none of the above.
  #               The real gap. Ranked by fix-churn downstream.
  module Classifier
    # The gem ships NO project lexicon -- it is general. The consuming
    # project supplies its external/boundary method names via
    # `ffi_boundary:` (CLEAR passes its set from the CLI). Empty here
    # by design.
    DIAGNOSTIC_MIDS = %i[raise fail abort].freeze # general Ruby
    GUARD_MIDS = %i[is_a? kind_of? instance_of? nil? respond_to?].freeze

    Arm = Struct.new(:file, :defn, :line, :category, keyword_init: true)

    module_function

    def merged_branches(resultset, abspath)
      m = {}
      JSON.parse(File.read(resultset)).each_value do |e|
        (e["coverage"] || {}).each do |p, c|
          next unless p == abspath && c.is_a?(Hash) && c["branches"]

          c["branches"].each do |par, arms|
            d = (m[par] ||= Hash.new(0))
            arms.each { |a, n| d[a] = d[a] + (n || 0) }
          end
        end
      end
      m
    end

    def method_index(lines)
      idx = {}
      stack = []
      lines.each_with_index do |raw, i|
        ln = i + 1
        if (mm = raw.match(/^(\s*)def\s+(self\.)?([A-Za-z0-9_?!]+)/))
          ind = mm[1].length
          stack.pop while stack.any? && stack.last[0] >= ind
          stack.push([ind, mm[3], ln])
        elsif (e = raw.match(/^(\s*)end\b/))
          ind = e[1].length
          stack.pop if stack.any? && stack.last[0] == ind
        end
        idx[ln] = stack.last ? stack.last[1] : "(top-level)"
      end
      idx
    end

    def ast_nodes(abspath)
      root = RubyVM::AbstractSyntaxTree.parse(File.read(abspath), keep_script_lines: true)
      acc = []
      w = ->(n) { return unless n.is_a?(RubyVM::AbstractSyntaxTree::Node); acc << n; n.children.each { |c| w.call(c) } }
      w.call(root)
      acc
    rescue SyntaxError, StandardError
      []
    end

    def node_for(nodes, sl, sc, el, ec)
      sp = ->(n) { [n.first_lineno, n.first_column, n.last_lineno, n.last_column] }
      ex = nodes.find { |n| sp.call(n) == [sl, sc, el, ec] }
      return ex if ex

      cov = nodes.select do |n|
        a = sp.call(n)
        (a[0] < sl || (a[0] == sl && a[1] <= sc)) && (a[2] > el || (a[2] == el && a[3] >= ec))
      end
      cov.min_by { |n| (n.last_lineno - n.first_lineno) * 1000 + n.children.size }
    end

    def subtree(node, types: nil, mids: nil)
      st = [node]
      until st.empty?
        n = st.pop
        next unless n.is_a?(RubyVM::AbstractSyntaxTree::Node)
        return true if types&.include?(n.type)

        if mids && %i[CALL FCALL VCALL QCALL OPCALL].include?(n.type)
          mid = n.children[%i[CALL OPCALL QCALL].include?(n.type) ? 1 : 0]
          return true if mids.include?(mid)
          return true if n.type == :QCALL # safe-nav = nil decision
        end
        n.children.each { |c| st << c }
      end
      false
    end

    def trivial?(node)
      return true if node.nil?
      return true if node.type == :NIL
      return true if node.type == :BEGIN && node.children.compact.empty?
      return false if has_any_call?(node)
      return false if subtree(node, types: %i[LASGN IASGN OP_ASGN ATTRASGN MASGN GASGN CVASGN RETURN NEXT BREAK YIELD])

      !subtree(node, types: %i[LIT STR SYM INTEGER FLOAT LVAR IVAR DVAR CONST ARRAY HASH TRUE FALSE])
    end

    def has_any_call?(node)
      subtree(node, types: %i[CALL FCALL VCALL OPCALL QCALL])
    end

    # -> [Arm, ...] for every dark arm in abspath.
    def classify_file(resultset, abspath, ffi_boundary: [])
      branches = merged_branches(resultset, abspath)
      return [] if branches.empty?

      lines = File.readlines(abspath)
      midx = method_index(lines)
      nodes = ast_nodes(abspath)
      out = []

      branches.each do |parent, arms|
        p = parent.gsub(/[\[\]:]/, "").split(",").map(&:strip)
        pkind = p[0].to_sym
        # The decision's CONDITION (where a type/nil guard lives) is the
        # parent node's first child, not the dark arm's body.
        pnode = node_for(nodes, p[2].to_i, p[3].to_i, p[4].to_i, p[5].to_i)
        cond = if pnode && %i[IF UNLESS WHILE UNTIL CASE].include?(pnode.type)
                 pnode.children[0]
               else
                 pnode
               end
        any_taken = arms.values.any? { |v| v.to_i.positive? }
        arms.each do |arm, count|
          next unless count.to_i.zero?

          a = arm.gsub(/[\[\]:]/, "").split(",").map(&:strip)
          sl, sc, el, ec = a[2].to_i, a[3].to_i, a[4].to_i, a[5].to_i
          meth = midx[sl] || "(top-level)"
          anode = node_for(nodes, sl, sc, el, ec)
          source_line = sl > lines.length ? "" : lines[sl - 1]
          cat = categorize(meth, pkind, anode, any_taken, cond, ffi_boundary, pnode, source_line)
          out << Arm.new(file: abspath, defn: meth, line: sl, category: cat)
        end
      end
      out
    end

    def categorize(method, pkind, anode, sibling_taken, cond = nil, ffi_boundary = [], pnode = nil, source_line = nil)
      return :ffi if ffi_boundary.include?(method)
      return :diagnostic if anode && subtree(anode, mids: DIAGNOSTIC_MIDS)
      # type/nil guard family: check the decision's CONDITION and the
      # arm body -> the decomplex DecisionPressure class.
      return :type_norm if (cond && type_guard?(cond)) || (anode && type_guard?(anode))
      return :defensive if !sibling_taken && coverage_artifact_source?(source_line)
      return :defensive if pnode && !decision_node?(pnode) && !sibling_taken
      return :dead unless sibling_taken          # decision never executes
      return :defensive if trivial?(anode)

      if %i[case when & |].include?(pkind) || %i[if unless ternary while until for].include?(pkind)
        :genuine
      else
        :defensive
      end
    end

    def decision_node?(node)
      %i[IF UNLESS WHILE UNTIL CASE].include?(node.type)
    end

    def coverage_artifact_source?(source_line)
      return false if source_line.nil?
      stripped = source_line.to_s.strip
      stripped.empty? || stripped == "end" || stripped.start_with?("sig {")
    end

    def type_guard?(node)
      st = [node]
      until st.empty?
        n = st.pop
        next unless n.is_a?(RubyVM::AbstractSyntaxTree::Node)
        return true if n.type == :QCALL # x&.m : implicit nil decision

        if %i[CALL OPCALL].include?(n.type) && GUARD_MIDS.include?(n.children[1])
          return true
        end

        n.children.each { |c| st << c }
      end
      false
    end
  end
end
