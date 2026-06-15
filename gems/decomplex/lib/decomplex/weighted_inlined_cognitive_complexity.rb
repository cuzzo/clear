# frozen_string_literal: true

require "set"
require_relative "ast"
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
    OWNER_TYPES = %i[CLASS MODULE].freeze
    METHOD_TYPES = %i[DEFN DEFS].freeze
    SKIP_NESTED_TYPES = %i[CLASS MODULE DEFN DEFS LAMBDA].freeze
    BRANCH_TYPES = %i[IF UNLESS].freeze
    LOOP_TYPES = %i[WHILE UNTIL FOR ITER].freeze
    CASE_TYPES = %i[CASE CASE2].freeze
    RESCUE_TYPES = %i[RESCUE RESBODY].freeze
    EARLY_EXIT_TYPES = %i[RETURN BREAK NEXT REDO RETRY].freeze
    BOOLEAN_TYPES = %i[AND OR].freeze

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
      parsed = parse_files
      topology = StructuralTopology.scan(@files)
      bodies = parsed.flat_map do |file, (root, lines)|
        MethodBodyCollector.new(file, lines).scan(root)
      end
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

    def parse_files
      @files.each_with_object({}) do |file, out|
        out[file] = Ast.parse(file)
      end
    end

    class MethodBodyCollector
      def initialize(file, lines)
        @file = file
        @lines = lines
      end

      def scan(root)
        out = []
        top_level_methods(root).each do |method_node|
          out << method_body(method_node, top_level_owner)
        end
        walk(root, [], out)
        out
      end

      private

      def top_level_methods(root)
        top_level_statements(root).select { |stmt| Ast.node?(stmt) && METHOD_TYPES.include?(stmt.type) }
      end

      def walk(node, owners, out)
        return unless Ast.node?(node)

        if OWNER_TYPES.include?(node.type)
          owner = (owners + [owner_segment(node)]).join("::")
          owner_methods(node).each do |method_node|
            out << method_body(method_node, owner)
          end
          node.children.each { |child| walk(child, owners + [owner_segment(node)], out) }
        else
          node.children.each { |child| walk(child, owners, out) }
        end
      end

      def owner_methods(owner_node)
        body = owner_body(owner_node)
        return [] unless Ast.node?(body)

        owner_statements(body).flat_map do |stmt|
          next [] unless Ast.node?(stmt)

          if METHOD_TYPES.include?(stmt.type)
            [stmt]
          elsif visibility_call?(stmt)
            inline_methods(stmt)
          else
            []
          end
        end
      end

      def method_body(node, owner)
        name = method_name(node)
        MethodBody.new(
          id: "#{owner}##{name}",
          owner: owner,
          name: name,
          file: @file,
          line: node.first_lineno,
          span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
          node: node
        )
      end

      def inline_methods(stmt)
        args = stmt.children[1]
        return [] unless Ast.node?(args)

        args.children.compact.select { |arg| Ast.node?(arg) && METHOD_TYPES.include?(arg.type) }
      end

      def owner_body(owner_node)
        scope = owner_node.children[owner_node.type == :CLASS ? 2 : 1]
        return nil unless Ast.node?(scope) && scope.type == :SCOPE

        scope.children[2]
      end

      def owner_statements(body)
        body.type == :BLOCK ? body.children.compact : [body]
      end

      def top_level_statements(root)
        return [] unless Ast.node?(root)

        root.children.compact.flat_map do |child|
          Ast.node?(child) && child.type == :BLOCK ? child.children.compact : [child]
        end
      end

      def visibility_call?(node)
        node.type == :FCALL && StructuralTopology::VISIBILITY_MIDS.include?(node.children[0])
      end

      def method_name(node)
        if node.type == :DEFS
          receiver = node.children[0]
          prefix = Ast.node?(receiver) && receiver.type == :SELF ? "self" : Ast.slice(receiver, @lines)
          "#{prefix}.#{node.children[1]}"
        else
          node.children[0].to_s
        end
      end

      def owner_segment(node)
        text = Ast.slice(node.children[0], @lines)
        text.empty? ? "(anonymous)" : text
      end

      def top_level_owner
        "(top-level:#{@file})"
      end
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
        return 0.0 unless Ast.node?(node)
        return 0.0 if skip_nested?(node)

        case node.type
        when *BRANCH_TYPES
          score_branch(node, nesting, signals)
        when *LOOP_TYPES
          score_loop(node, nesting, signals)
        when *CASE_TYPES
          score_case(node, nesting, signals)
        when *RESCUE_TYPES
          score_rescue(node, nesting, signals)
        when *EARLY_EXIT_TYPES
          score_early_exit(node, nesting, signals)
        when *BOOLEAN_TYPES
          score_boolean_node(node, nesting, signals)
        else
          score_children(node, nesting: nesting, signals: signals)
        end
      end

      def skip_nested?(node)
        SKIP_NESTED_TYPES.include?(node.type) && !METHOD_TYPES.include?(node.type)
      end

      def score_branch(node, nesting, signals)
        signals[:branches] += 1
        signals[:nested] += 1 if nesting.positive?
        condition = node.children[0]
        positive = node.children[1]
        negative = node.children[2]
        branch_cost(nesting) +
          predicate_cost(condition, signals) +
          score_node(positive, nesting: nesting + 1, signals: signals) +
          score_node(negative, nesting: nesting + 1, signals: signals)
      end

      def score_loop(node, nesting, signals)
        signals[:loops] += 1
        signals[:nested] += 1 if nesting.positive?
        branch_cost(nesting) + score_children(node, nesting: nesting + 1, signals: signals)
      end

      def score_case(node, nesting, signals)
        signals[:cases] += 1
        0.5 + score_case_children(node, nesting, signals)
      end

      def score_case_children(node, nesting, signals)
        node.children.sum do |child|
          if Ast.node?(child) && child.type == :WHEN
            score_when(child, nesting, signals)
          else
            score_node(child, nesting: nesting, signals: signals)
          end
        end
      end

      def score_when(node, nesting, signals)
        body = node.children[1]
        next_when = node.children[2]
        score_node(body, nesting: nesting + 1, signals: signals) +
          score_node(next_when, nesting: nesting, signals: signals)
      end

      def score_rescue(node, nesting, signals)
        signals[:rescues] += 1
        branch_cost(nesting) + score_children(node, nesting: nesting + 1, signals: signals)
      end

      def score_early_exit(node, nesting, signals)
        signals[:early_exits] += 1
        exit_cost = nesting.positive? ? 0.5 + (nesting * 0.25) : 0.0
        exit_cost + score_children(node, nesting: nesting, signals: signals)
      end

      def score_boolean_node(node, nesting, signals)
        signals[:boolean_ops] += 1
        0.25 + score_children(node, nesting: nesting, signals: signals)
      end

      def score_children(node, nesting:, signals:)
        node.children.sum { |child| score_node(child, nesting: nesting, signals: signals) }
      end

      def predicate_cost(node, signals)
        bools = boolean_count(node)
        signals[:boolean_ops] += bools
        bools * 0.5
      end

      def boolean_count(node)
        return 0 unless Ast.node?(node)

        own = BOOLEAN_TYPES.include?(node.type) ? 1 : 0
        own + node.children.sum { |child| boolean_count(child) }
      end

      def branch_cost(nesting)
        1.0 + nesting
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
