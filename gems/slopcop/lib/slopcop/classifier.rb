# frozen_string_literal: true

require "set"
require_relative "../../../boobytrap/lib/boobytrap/coverage_data"

module SlopCop
  # Classifies every never-taken branch arm in a target file into ONE
  # actionable category. AST-structural, never a regex over the arm
  # line. General -- no project lexicon baked in (see ffi_boundary:).
  #
  # Categories (not all gaps are equal):
  #   :type_norm  arm/decision guards a type/nil check (is_a?/kind_of?/
    #               nil?/respond_to?/safe-nav). Likely dead if runtime
    #               contracts were stricter.
  #   :dead       no sibling arm of the decision is ever taken in the
  #               supplied coverage. Audit as unexercised code: it may
  #               be a missing test, or dead only if static reachability
  #               tools agree.
  #   :defensive  live decision, inert/pinned polarity (empty else,
  #               nil, invariant-guaranteed). Accept.
  #   :ffi        a caller-declared external/boundary method -> needs
  #               an integration test.
    #   :diagnostic arm raises or calls caller-declared diagnostic
    #               helpers -> invalid-input only.
  #   :genuine    live, reachable, input-determined, none of the above.
  #               The real gap. Ranked by fix-churn downstream.
  module Classifier
    # The gem ships NO project lexicon -- it is general. The consuming
    # project supplies its external/boundary method names via
    # `ffi_boundary:` (CLEAR passes its set from the CLI). Empty here
    # by design.
    DIAGNOSTIC_MIDS = %i[raise fail abort].freeze # general Ruby
    GUARD_MIDS = %i[is_a? kind_of? instance_of? nil? respond_to?].freeze

    Arm = Struct.new(:file, :defn, :line, :category, :source, keyword_init: true)

    module_function

    def merged_branches(resultset, abspath, root: nil)
      coverage_for(resultset, abspath, root: root)&.branches || {}
    end

    def method_index(lines)
      idx = {}
      stack = []
      lines.each_with_index do |raw, i|
        ln = i + 1
        if (mm = raw.match(/^(\s*)(?:(?:private|public|protected)_class_method\s+)?def\s+(?:(?:self|[A-Z][A-Za-z0-9_]*)\.)?([A-Za-z0-9_?!]+)/))
          ind = mm[1].length
          stack.pop while stack.any? && stack.last[0] >= ind
          stack.push([ind, mm[2], ln]) unless endless_def_line?(raw)
        elsif (e = raw.match(/^(\s*)end\b/))
          ind = e[1].length
          stack.pop if stack.any? && stack.last[0] == ind
        end
        idx[ln] = stack.last ? stack.last[1] : "(top-level)"
      end
      idx
    end

    def endless_def_line?(raw)
      stripped = raw.strip
      return false unless stripped.start_with?("def ", "private_class_method def ", "public_class_method def ", "protected_class_method def ")

      stripped.match?(/\)\s*=/) || stripped.match?(/\A(?:private_class_method |public_class_method |protected_class_method )?def\s+(?:(?:self|[A-Z][A-Za-z0-9_]*)\.)?[A-Za-z0-9_?!]+\s*=/)
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
    def classify_file(resultset, abspath, ffi_boundary: [], diagnostic_mids: [], root: nil)
      file_coverage = coverage_for(resultset, abspath, root: root)
      branches = file_coverage&.branches || {}
      if branches.empty?
        if tree_sitter? && file_coverage&.line_coverage?
          return classify_line_coverage_file(
            abspath,
            file_coverage,
            ffi_boundary: ffi_boundary,
            diagnostic_mids: diagnostic_mids
          )
        end

        return classify_static_file(abspath,
                                    ffi_boundary: ffi_boundary,
                                    diagnostic_mids: diagnostic_mids) if tree_sitter?

        return []
      end

      lines = File.readlines(abspath)
      midx = method_index(lines)
      noise_lines = declaration_noise_lines(lines)
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
          cat = categorize(meth, pkind, anode, any_taken, cond,
                           ffi_boundary, pnode, source_line,
                           noise_lines.include?(sl), diagnostic_mids)
          next if cat.nil?

          out << Arm.new(file: abspath, defn: meth, line: sl, category: cat,
                         source: :coverage)
        end
      end
      out
    end

    def coverage_for(resultset, abspath, root: nil)
      return nil unless resultset

      root ||= File.dirname(abspath)
      coverage_dataset(resultset, root: root)[abspath]
    rescue StandardError
      nil
    end

    def coverage_dataset(resultset, root:)
      @coverage_cache ||= {}
      key = [File.expand_path(resultset), File.expand_path(root)]
      @coverage_cache[key] ||= Boobytrap::CoverageData.load(resultset, root: root)
    end

    def classify_static_file(abspath, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      doc.branch_arms.filter_map do |arm|
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          true,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                category: cat, source: :tree_sitter_static)
      end
    rescue LoadError, StandardError
      []
    end

    def classify_line_coverage_file(abspath, file_coverage, ffi_boundary: [], diagnostic_mids: [])
      return [] unless load_decomplex_syntax
      return [] unless Decomplex::Syntax.supported_source?(abspath, parser: "tree_sitter")

      doc = Decomplex::Syntax.parse(abspath, parser: "tree_sitter")
      covered_arms = Boobytrap::CoverageData.branch_arm_coverage(file_coverage, doc.branch_arms)
      groups = covered_arms.group_by do |arm_cov|
        arm = arm_cov.arm
        [arm.kind, arm.decision_line, arm.decision_span]
      end

      covered_arms.filter_map do |arm_cov|
        next if arm_cov.covered

        arm = arm_cov.arm
        group = groups.fetch([arm.kind, arm.decision_line, arm.decision_span], [])
        sibling_taken = group.any?(&:covered)
        cat = categorize_text(
          arm.function,
          arm.kind,
          arm.body,
          sibling_taken,
          arm.predicate,
          ffi_boundary,
          diagnostic_mids
        )
        next if cat.nil?

        Arm.new(file: abspath, defn: arm.function, line: arm.line,
                category: cat, source: arm_cov.source)
      end
    rescue LoadError, StandardError
      []
    end

    def categorize(method, pkind, anode, sibling_taken, cond = nil, ffi_boundary = [], pnode = nil, source_line = nil, declaration_noise = false, diagnostic_mids = [])
      return nil if coverage_noise?(pnode, sibling_taken, source_line, declaration_noise)
      return :ffi if ffi_boundary.include?(method)
      diag = DIAGNOSTIC_MIDS + diagnostic_mids.map(&:to_sym)
      return :diagnostic if anode && subtree(anode, mids: diag)
      # type/nil guard family: check the decision's CONDITION and the
      # arm body -> the decomplex DecisionPressure class.
      return :type_norm if (cond && type_guard?(cond)) || (anode && type_guard?(anode))
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

    def coverage_noise?(pnode, sibling_taken, source_line, declaration_noise = false)
      return true if declaration_noise
      return true if coverage_artifact_source?(source_line)
      return true if pnode && !decision_node?(pnode) && !sibling_taken

      false
    end

    def declaration_noise_lines(lines)
      noise = Set.new
      sig_depth = nil
      lines.each_with_index do |raw, i|
        ln = i + 1
        stripped = raw.strip
        if sig_depth
          noise << ln
          sig_depth = nil if stripped == "end"
          next
        end

        if stripped == "sig do"
          noise << ln
          sig_depth = true
          next
        end

        noise << ln if declaration_source?(stripped)
      end
      noise
    end

    def coverage_artifact_source?(source_line)
      return false if source_line.nil?
      stripped = source_line.to_s.strip
      stripped.empty? || stripped == "end" || declaration_source?(stripped)
    end

    def declaration_source?(stripped)
      stripped.start_with?(
        "sig {", "def ", "private_class_method def ",
        "public_class_method def ", "protected_class_method def ",
        "class ", "module ", "include ", "extend ", "attr_",
        "const :", "prop :", "params(", ").returns", ").void", "VALID_"
      )
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

    def categorize_text(method, pkind, body, sibling_taken, predicate = nil,
                        ffi_boundary = [], diagnostic_mids = [])
      return :ffi if ffi_boundary.include?(method)
      return :diagnostic if diagnostic_text?(body, diagnostic_mids)
      return :type_norm if type_guard_text?(predicate) || type_guard_text?(body)
      return :dead unless sibling_taken
      return :defensive if trivial_text?(body)

      if %i[case if unless ternary while until for loop].include?(pkind)
        :genuine
      else
        :defensive
      end
    end

    def diagnostic_text?(text, diagnostic_mids = [])
      names = DIAGNOSTIC_MIDS.map(&:to_s) + diagnostic_mids.map(&:to_s)
      source = text.to_s
      names.any? { |name| source.match?(/(?:\A|[^\w!?])#{Regexp.escape(name)}[!?]?(?:\s*\(|\b)/) } ||
        source.match?(/\b(?:panic|unreachable|throw)\b/) ||
        source.match?(/\breturn\s+error[.\w]*/)
    end

    def type_guard_text?(text)
      source = text.to_s
      source.match?(/\b(?:nil|null|none|undefined)\b/i) ||
        source.match?(/\b(?:is_a\?|kind_of\?|instance_of\?|respond_to\?|isinstance|typeof|typeid)\b/) ||
        source.match?(/@typeInfo\b/) ||
        source.match?(/\bkind\s*(?:==|!=)/)
    end

    def trivial_text?(text)
      stripped = text.to_s.strip
      return true if stripped.empty?

      stripped.match?(/\A(?:nil|null|None|undefined|true|false|0|1|break|continue|unreachable)\s*;?\z/) ||
        stripped.match?(/\Areturn\s+(?:nil|null|None|undefined|true|false|0|1)\s*;?\z/)
    end

    def tree_sitter?
      ENV.fetch("DECOMPLEX_PARSER", "rubyvm").to_s.tr("-", "_") == "tree_sitter"
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      require "decomplex/syntax"
      true
    rescue LoadError
      sibling = File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      return false unless File.file?("#{sibling}.rb")

      require sibling
      true
    end
  end
end
