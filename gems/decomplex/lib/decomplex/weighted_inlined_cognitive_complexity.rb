# frozen_string_literal: true

require "set"
require_relative "syntax"
require_relative "structural_topology"

module Decomplex
  # Scores the reader burden of a method after conservatively inlining
  # same-owner bare/self helper calls. This catches "small" orchestration
  # methods whose complexity was moved into private/single-use helpers.
  class WeightedInlinedCognitiveComplexity
    MethodBody = Struct.new(:id, :owner, :name, :file, :line, :span, :node,
                            :complexity, keyword_init: true)
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
      bodies = syntax_method_bodies
      scores = bodies.to_h do |body|
        score = body.complexity
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

    def syntax_method_bodies
      @files.flat_map do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        score_by_id = document.local_complexity_scores
        document.local_methods.map do |method|
          method_body(method, complexity: score_by_id.fetch(method.id, { score: 0.0, signals: {} }))
        end
      end
    end

    def method_body(summary, complexity:)
      owner = summary.owner == "(top-level)" ? "(top-level:#{summary.file})" : summary.owner
      MethodBody.new(
        id: "#{owner}##{summary.name}",
        owner: owner,
        name: summary.name,
        file: summary.file,
        line: summary.line,
        span: summary.span,
        node: summary.node,
        complexity: complexity
      )
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
