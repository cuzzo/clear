# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/weighted_inlined_cognitive_complexity"

class WeightedInlinedCognitiveComplexityTest < Minitest::Test
  def test_flags_low_local_orchestrator_hiding_single_caller_helpers
    out = scan(<<~RB, min_score: 10, min_hidden: 5)
      class BillingService
        def checkout(user, cart)
          validate_user(user)
          apply_discount(cart)
          process_payment(user, cart)
        end

        private

        def validate_user(user)
          return false unless user
          if user.active? && !user.suspended?
            true
          else
            false
          end
        end

        def apply_discount(cart)
          if cart.total > 100 && eligible?
            if holiday?
              20
            else
              10
            end
          end
        end

        def process_payment(user, cart)
          if gateway.ready?
            if cart.total > 0 && user.active?
              charge(user, cart)
            end
          end
        rescue Timeout
          retry
        end
      end
    RB

    checkout = out.find { |row| row[:method] == "checkout" }
    refute_nil checkout
    assert_equal 0.0, checkout[:local]
    assert_operator checkout[:hidden], :>=, 10.0
    assert_equal %w[apply_discount process_payment validate_user], checkout[:single_caller_callees]
    assert_equal "checkout", checkout[:call_chain].first
    assert_includes checkout[:reason], "single-caller helper"
  end

  def test_inlines_nested_single_caller_chain_with_depth_weighting
    out = scan(<<~RB, min_score: 2, min_hidden: 1, max_depth: 2)
      class Pipeline
        def run(input)
          prepare(input)
        end

        def prepare(input)
          validate(input)
        end

        def validate(input)
          if input.ready?
            if input.valid? && !input.locked?
              true
            end
          end
        end
      end
    RB

    run = out.find { |row| row[:method] == "run" }
    refute_nil run
    assert_equal 2, run[:depth]
    assert_equal %w[run prepare validate], run[:call_chain]
    assert_operator run[:hidden], :>, 1.0
  end

  def test_shared_public_helper_is_dampened
    out = scan(<<~RB, min_score: 4, min_hidden: 4)
      class SharedPolicy
        def left(item)
          helper(item)
        end

        def right(item)
          helper(item)
        end

        def helper(item)
          if item.ready?
            if item.valid? && !item.locked?
              if item.total > 100
                true
              end
            end
          end
        end
      end
    RB

    refute out.any? { |row| %w[left right].include?(row[:method]) }
  end

  def test_case_dispatch_is_not_treated_like_many_independent_branches
    out = scan(<<~RB, min_score: 0, min_hidden: 0)
      class Dispatcher
        def choose(kind)
          case kind
          when :a then 1
          when :b then 2
          when :c then 3
          when :d then 4
          when :e then 5
          when :f then 6
          when :g then 7
          else 0
          end
        end
      end
    RB

    choose = out.find { |row| row[:method] == "choose" }
    refute_nil choose
    assert_operator choose[:local], :<=, 1.0
    assert_equal 0.0, choose[:hidden]
  end

  def test_mutual_recursion_does_not_inline_forever
    out = scan(<<~RB, min_score: 0, min_hidden: 0, max_depth: 3)
      class RecursiveFlow
        def left(item)
          right(item)
        end

        def right(item)
          left(item)
          if item.ready?
            true
          end
        end
      end
    RB

    left = out.find { |row| row[:method] == "left" }
    refute_nil left
    assert_operator left[:depth], :<=, 1
    assert_equal %w[left right], left[:call_chain]
  end

  def test_handles_modules_inline_visibility_loops_rescue_and_shared_reason
    out = scan(<<~RB, min_score: 0, min_hidden: 0, max_depth: 1)
      class EmptyOwner; end

      module Workflows
        class Runner
          def left
            inline_helper
          end

          def right
            inline_helper
          end

          def choose(kind)
            case
            when ready? && allowed?
              inline_helper
            else
              true
            end
          end

          private def inline_helper
            while pending?
              next if done?
            end
          rescue IOError
            false
          end

          def self.build; end
          def Runner.explicit; end
        end
      end
    RB

    left = out.find { |row| row[:owner] == "Workflows::Runner" && row[:method] == "left" }
    helper = out.find { |row| row[:owner] == "Workflows::Runner" && row[:method] == "inline_helper" }
    choose = out.find { |row| row[:owner] == "Workflows::Runner" && row[:method] == "choose" }

    refute_nil left
    refute_nil helper
    refute_nil choose
    assert_empty left[:single_caller_callees]
    assert_includes left[:reason], "same-owner call chain"
    assert_operator helper[:signals].fetch(:loops), :>=, 1
    assert_operator helper[:signals].fetch(:rescues), :>=, 1
    assert_operator choose[:signals].fetch(:cases), :>=, 1
  end

  private

  def scan(code, min_score:, min_hidden:, max_depth: Decomplex::WeightedInlinedCognitiveComplexity::DEFAULT_MAX_DEPTH)
    file = Tempfile.new(["wicc", ".rb"])
    file.write(code)
    file.close
    Decomplex::WeightedInlinedCognitiveComplexity.scan(
      [file.path],
      min_score: min_score,
      min_hidden: min_hidden,
      max_depth: max_depth
    )
  ensure
    file&.unlink
  end
end
