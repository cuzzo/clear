# frozen_string_literal: true

require "set"
require_relative "local_flow"
require_relative "structural_topology"

module Decomplex
  # Scores the reader burden of a method after conservatively inlining
  # same-owner bare/self helper calls. This catches "small" orchestration
  # methods whose complexity was moved into private/single-use helpers.
  class WeightedInlinedCognitiveComplexity
    MethodBody = Struct.new(:id, :owner, :name, :file, :line, :span, :node, keyword_init: true)
    LocalScore = Struct.new(:id, :owner, :name, :file, :line, :span, :score, :signals, keyword_init: true)
    Contribution = Struct.new(:callee_id, :callee_name, :score, :weight, :depth, :chain, keyword_init: true)

    DEFAULT_MIN_SCORE = 12.0
    DEFAULT_MIN_HIDDEN = 15.0
    DEFAULT_MAX_DEPTH = 2
    DEPTH_WEIGHTS = [1.0, 1.0, 0.6, 0.35].freeze
    EDGE_WEIGHTS = { always: 1.0, conditional: 0.75, iterates: 1.15 }.freeze
    def self.scan(files, min_score: DEFAULT_MIN_SCORE, min_hidden: DEFAULT_MIN_HIDDEN, max_depth: DEFAULT_MAX_DEPTH)
      new(files, min_score: min_score, min_hidden: min_hidden, max_depth: max_depth).scan
    end

    def initialize(files, min_score:, min_hidden:, max_depth:)
      @files = files
      @min_score = min_score.to_f
      @min_hidden = min_hidden.to_f
      @max_depth = max_depth.to_i
    end

    def scan
      topology = StructuralTopology.scan(@files)
      bodies = LocalFlow.scan(@files).map { |summary| method_body(summary) }
      scores = bodies.to_h do |body|
        score = LocalScorer.new.score(body.node)
        [body.id, LocalScore.new(
          id: body.id,
          owner: body.owner,
          name: body.name,
          file: body.file,
          line: body.line,
          span: body.span,
          score: score[:score],
          signals: score[:signals]
        )]
      end

      Analyzer.new(topology, scores, @min_score, @min_hidden, @max_depth).findings
    end

    private

    def method_body(summary)
      owner = summary.owner == "(top-level)" ? "(top-level:#{summary.file})" : summary.owner
      MethodBody.new(
        id: "#{owner}##{summary.name}",
        owner: owner,
        name: summary.name,
        file: summary.file,
        line: summary.line,
        span: summary.span,
        node: summary.node
      )
    end

    class LocalScorer
      def score(method_node)
        signals = Hash.new(0)
        {
          score: round(score_node(method_node, nesting: 0, signals: signals)),
          signals: signals.to_h
        }
      end

      private

      def score_node(node, nesting:, signals:)
        return 0.0 unless tree_sitter_node?(node)

        score_tree_sitter_node(node, nesting: nesting, signals: signals)
      end

      def boolean_count(node)
        tree_sitter_boolean_count(node)
      end

      def score_tree_sitter_node(node, nesting:, signals:)
        return 0.0 if skip_tree_sitter_nested?(node)

        if tree_sitter_branch?(node)
          signals[:branches] += 1
          signals[:nested] += 1 if nesting.positive?
          return branch_cost(nesting) +
                 tree_sitter_predicate_cost(node, signals) +
                 score_tree_sitter_children(node, nesting: nesting + 1, signals: signals)
        end

        if tree_sitter_loop?(node)
          signals[:loops] += 1
          signals[:nested] += 1 if nesting.positive?
          return branch_cost(nesting) +
                 score_tree_sitter_children(node, nesting: nesting + 1, signals: signals)
        end

        if tree_sitter_case?(node)
          signals[:cases] += 1
          return 0.5 + score_tree_sitter_children(node, nesting: nesting + 1, signals: signals)
        end

        if tree_sitter_rescue?(node)
          signals[:rescues] += 1
          return branch_cost(nesting) +
                 score_tree_sitter_children(node, nesting: nesting + 1, signals: signals)
        end

        if tree_sitter_early_exit?(node)
          signals[:early_exits] += 1
          exit_cost = nesting.positive? ? 0.5 + (nesting * 0.25) : 0.0
          return exit_cost + score_tree_sitter_children(node, nesting: nesting, signals: signals)
        end

        if tree_sitter_boolean_node?(node)
          signals[:boolean_ops] += 1
          return 0.25 + score_tree_sitter_children(node, nesting: nesting, signals: signals)
        end

        score_tree_sitter_children(node, nesting: nesting, signals: signals)
      end

      def score_tree_sitter_children(node, nesting:, signals:)
        node.children.sum { |child| score_node(child, nesting: nesting, signals: signals) }
      end

      def tree_sitter_predicate_cost(node, signals)
        predicate = tree_sitter_condition_node(node)
        bools = tree_sitter_boolean_count(predicate)
        signals[:boolean_ops] += bools
        bools * 0.5
      end

      def tree_sitter_condition_node(node)
        return node.named_children.last if tree_sitter_modifier_if?(node)
        return node.named_children.first if node.kind == "body_statement"

        node.named_children.first
      end

      def tree_sitter_boolean_count(node)
        return 0 unless tree_sitter_node?(node)

        own = tree_sitter_boolean_node?(node) ? 1 : 0
        own + node.children.sum { |child| tree_sitter_boolean_count(child) }
      end

      def tree_sitter_boolean_node?(node)
        tree_sitter_node?(node) &&
          %w[binary binary_expression boolean_operator conjunction_expression disjunction_expression].include?(node.kind) &&
          node.children.any? { |child| !child.named? && %w[&& || and or].include?(child.text.to_s) }
      end

      def tree_sitter_branch?(node)
        return false unless tree_sitter_node?(node)
        return true if %w[if unless if_statement if_expression if_modifier unless_modifier].include?(node.kind) &&
                       node.named_children.any?

        tree_sitter_hidden_if?(node) || tree_sitter_modifier_if?(node)
      end

      def tree_sitter_hidden_if?(node)
        return true if node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("if ")

        %w[body_statement block statements statement_list].include?(node.kind) &&
          node.children.first &&
          !node.children.first.named? &&
          %w[if unless].include?(node.children.first.kind.to_s)
      end

      def tree_sitter_modifier_if?(node)
        return true if %w[if_modifier unless_modifier].include?(node.kind)
        return false unless node.kind == "body_statement"

        seen_named = false
        node.children.any? do |child|
          seen_named ||= child.named?
          seen_named && !child.named? && %w[if unless].include?(child.kind.to_s)
        end
      end

      def tree_sitter_loop?(node)
        return false unless tree_sitter_node?(node)
        return true if %w[while until while_statement for for_statement for_in_statement do_block].include?(node.kind)
        return true if tree_sitter_hidden_loop?(node)

        (node.kind == "expression_statement" && node.text.to_s.lstrip.match?(/\A(?:for|while|loop)\b/)) ||
          (node.kind == "labeled_statement" && node.text.to_s.lstrip.start_with?("for "))
      end

      def tree_sitter_hidden_loop?(node)
        %w[body_statement block statements statement_list].include?(node.kind) &&
          node.children.first &&
          !node.children.first.named? &&
          %w[for while loop].include?(node.children.first.kind.to_s)
      end

      def tree_sitter_case?(node)
        tree_sitter_node?(node) &&
          (%w[case switch_statement switch_expression match_statement match_expression].include?(node.kind) ||
           (node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("match ")))
      end

      def tree_sitter_rescue?(node)
        tree_sitter_node?(node) && %w[rescue rescue_modifier rescue_clause rescue_body].include?(node.kind)
      end

      def tree_sitter_early_exit?(node)
        tree_sitter_node?(node) &&
          %w[return break next redo retry return_statement break_statement continue_statement].include?(node.kind)
      end

      def skip_tree_sitter_nested?(node)
        %w[class module lambda].include?(node.kind)
      end

      def tree_sitter_node?(node)
        node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def branch_cost(nesting)
        1.1 + nesting
      end

      def round(value)
        (value * 10).round / 10.0
      end
    end

    class Analyzer
      def initialize(topology, scores, min_score, min_hidden, max_depth)
        @topology = topology
        @scores = scores
        @min_score = min_score
        @min_hidden = min_hidden
        @max_depth = max_depth
      end

      def findings
        @scores.values.filter_map { |score| finding_for(score) }
               .sort_by { |row| [-row[:hidden], -row[:inlined], row[:file].to_s, row[:method].to_s] }
      end

      private

      def finding_for(score)
        contributions = inlined_contributions(score.id, depth: 1, visited: Set[score.id])
        hidden = round(contributions.sum(&:score))
        total = round(score.score + hidden)
        return nil if total < @min_score || hidden < @min_hidden

        direct_single_caller = single_caller_callees(score.id)
        at = "#{score.file}:#{score.name}:#{score.line}"
        {
          at: at,
          owner: score.owner,
          method: score.name,
          local: score.score,
          inlined: total,
          hidden: hidden,
          depth: contributions.map(&:depth).max || 0,
          single_caller_callees: direct_single_caller,
          call_chain: strongest_chain(score, contributions),
          reason: reason(score, hidden, direct_single_caller),
          signals: score.signals,
          spans: { at => score.span }
        }
      end

      def inlined_contributions(method_id, depth:, visited:)
        return [] if depth > @max_depth

        grouped_edges(method_id).flat_map do |edge|
          next [] if visited.include?(edge.callee)

          callee = @scores[edge.callee]
          next [] unless callee

          weight = contribution_weight(edge, depth)
          direct = Contribution.new(
            callee_id: edge.callee,
            callee_name: edge.callee_name,
            score: round(callee.score * weight),
            weight: round(weight),
            depth: depth,
            chain: [edge.callee_name]
          )
          nested = inlined_contributions(edge.callee, depth: depth + 1, visited: visited + [edge.callee])
          nested = nested.map do |contribution|
            Contribution.new(
              callee_id: contribution.callee_id,
              callee_name: contribution.callee_name,
              score: round(contribution.score * weight),
              weight: round(contribution.weight * weight),
              depth: contribution.depth,
              chain: [edge.callee_name] + contribution.chain
            )
          end
          [direct] + nested
        end
      end

      def grouped_edges(method_id)
        @topology.internal_calls(method_id)
                 .group_by(&:callee)
                 .values
                 .map { |edges| edges.max_by { |edge| EDGE_WEIGHTS.fetch(edge.type, 1.0) } }
      end

      def contribution_weight(edge, depth)
        caller_factor = @topology.single_internal_caller?(edge.callee) ? 1.0 : 0.35
        visibility_factor = shared_public_step?(edge) ? 0.6 : 1.0
        depth_factor = DEPTH_WEIGHTS.fetch(depth, DEPTH_WEIGHTS.last)
        edge_factor = EDGE_WEIGHTS.fetch(edge.type, 1.0)
        caller_factor * visibility_factor * depth_factor * edge_factor
      end

      def shared_public_step?(edge)
        @topology.visibility(edge.callee) == :public && !@topology.single_internal_caller?(edge.callee)
      end

      def single_caller_callees(method_id)
        grouped_edges(method_id).filter_map do |edge|
          edge.callee_name if @topology.single_internal_caller?(edge.callee)
        end.sort
      end

      def strongest_chain(score, contributions)
        chain = contributions.max_by(&:score)&.chain || []
        [score.name] + chain
      end

      def reason(score, hidden, single_caller_callees)
        if single_caller_callees.empty?
          "same-owner call chain adds #{hidden} weighted cognitive points"
        else
          "#{single_caller_callees.size} single-caller helper(s) add #{hidden} weighted cognitive points"
        end
      end

      def round(value)
        (value * 10).round / 10.0
      end
    end
  end
end
