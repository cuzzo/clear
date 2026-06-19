# frozen_string_literal: true

module Decomplex
  module Syntax
    class Document
      def local_complexity_scores
        @local_complexity_scores ||= adapter.local_complexity_scores(self)
      end
    end

    class TreeSitterAdapter
      def local_complexity_scores(document)
        profile = syntax_profile(document.language)
        document.local_methods.to_h do |method|
          [method.id, profile.local_complexity_score(method.node)]
        end
      end
    end

    class TreeSitterLanguageAdapter
      def local_complexity_score(method_node)
        LocalComplexityScorer.new.score(method_node)
      end

      class LocalComplexityScorer
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
          return 0.0 if skip_nested?(node)

          if branch?(node)
            signals[:branches] += 1
            signals[:nested] += 1 if nesting.positive?
            return branch_cost(nesting) +
                   predicate_cost(node, signals) +
                   score_children(node, nesting: nesting + 1, signals: signals)
          end

          if loop?(node)
            signals[:loops] += 1
            signals[:nested] += 1 if nesting.positive?
            return branch_cost(nesting) +
                   score_children(node, nesting: nesting + 1, signals: signals)
          end

          if case?(node)
            signals[:cases] += 1
            return 0.5 + score_children(node, nesting: nesting + 1, signals: signals)
          end

          if rescue?(node)
            signals[:rescues] += 1
            return branch_cost(nesting) +
                   score_children(node, nesting: nesting + 1, signals: signals)
          end

          if early_exit?(node)
            signals[:early_exits] += 1
            exit_cost = nesting.positive? ? 0.5 + (nesting * 0.25) : 0.0
            return exit_cost + score_children(node, nesting: nesting, signals: signals)
          end

          if boolean_node?(node)
            signals[:boolean_ops] += 1
            return 0.25 + score_children(node, nesting: nesting, signals: signals)
          end

          score_children(node, nesting: nesting, signals: signals)
        end

        def score_children(node, nesting:, signals:)
          node.children.sum { |child| score_node(child, nesting: nesting, signals: signals) }
        end

        def predicate_cost(node, signals)
          predicate = condition_node(node)
          bools = boolean_count(predicate)
          signals[:boolean_ops] += bools
          bools * 0.5
        end

        def condition_node(node)
          return node.named_children.last if modifier_if?(node)
          return node.named_children.first if node.kind == "body_statement"

          node.named_children.first
        end

        def boolean_count(node)
          return 0 unless tree_sitter_node?(node)

          own = boolean_node?(node) ? 1 : 0
          own + node.children.sum { |child| boolean_count(child) }
        end

        def boolean_node?(node)
          tree_sitter_node?(node) &&
            %w[binary binary_expression boolean_operator conjunction_expression disjunction_expression].include?(node.kind) &&
            node.children.any? { |child| !child.named? && %w[&& || and or].include?(child.text.to_s) }
        end

        def branch?(node)
          return false unless tree_sitter_node?(node)
          return true if %w[if unless if_statement if_expression if_modifier unless_modifier].include?(node.kind) &&
                         node.named_children.any?

          hidden_if?(node) || modifier_if?(node)
        end

        def hidden_if?(node)
          return true if node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("if ")
          return false unless %w[body_statement block statements statement_list].include?(node.kind)

          first_token = node.children.first
          first_token && !first_token.named? && %w[if unless].include?(first_token.kind.to_s)
        end

        def modifier_if?(node)
          return true if %w[if_modifier unless_modifier].include?(node.kind)
          return false unless node.kind == "body_statement"

          seen_named = false
          node.children.any? do |child|
            seen_named ||= child.named?
            seen_named && !child.named? && %w[if unless].include?(child.kind.to_s)
          end
        end

        def loop?(node)
          return false unless tree_sitter_node?(node)
          return true if %w[while until while_statement for for_statement for_in_statement do_block].include?(node.kind)
          return true if hidden_loop?(node)

          (node.kind == "expression_statement" && node.text.to_s.lstrip.match?(/\A(?:for|while|loop)\b/)) ||
            (node.kind == "labeled_statement" && node.text.to_s.lstrip.start_with?("for "))
        end

        def hidden_loop?(node)
          %w[body_statement block statements statement_list].include?(node.kind) &&
            node.children.first &&
            !node.children.first.named? &&
            %w[for while loop].include?(node.children.first.kind.to_s)
        end

        def case?(node)
          tree_sitter_node?(node) &&
            (%w[case switch_statement switch_expression match_statement match_expression].include?(node.kind) ||
             (node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("match ")))
        end

        def rescue?(node)
          tree_sitter_node?(node) && %w[rescue rescue_modifier rescue_clause rescue_body].include?(node.kind)
        end

        def early_exit?(node)
          tree_sitter_node?(node) &&
            %w[return break next redo retry return_statement break_statement continue_statement].include?(node.kind)
        end

        def skip_nested?(node)
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
    end
  end
end
