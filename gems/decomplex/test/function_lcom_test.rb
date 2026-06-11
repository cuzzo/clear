# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/function_lcom"

class FunctionLCOMTest < Minitest::Test
  def test_flags_independent_pipelines_that_only_join_at_terminal_statement
    out = scan(<<~RB)
      class Billing
        def mixed(price, tax, logger)
          subtotal = price + tax
          total = subtotal * 2
          rounded = total.round

          timestamp = Time.now
          buffer = []
          buffer << timestamp
          logger.info(buffer)

          [rounded, buffer]
        end
      end
    RB

    mixed = out.find { |finding| finding[:method] == "mixed" }

    refute_nil mixed
    assert_equal :late_join, mixed[:mode]
    assert_operator mixed[:components], :>=, 2
    assert(mixed[:component_vars].any? { |vars| vars.include?("rounded") && vars.include?("subtotal") })
    assert(mixed[:component_vars].any? { |vars| vars.include?("buffer") && vars.include?("timestamp") })
  end

  def test_flags_fully_disjoint_local_pipelines
    out = scan(<<~RB, min_score: 18, min_locals: 4, min_statements: 4)
      class Worker
        def mixed(left, right)
          left_a = left + 1
          left_b = left_a * 2
          right_a = right.to_s
          right_b = right_a.upcase
          nil
        end
      end
    RB

    mixed = out.find { |finding| finding[:method] == "mixed" }

    refute_nil mixed
    assert_equal :disjoint, mixed[:mode]
    assert_equal 2, mixed[:components]
  end

  def test_does_not_flag_cohesive_chain
    out = scan(<<~RB, min_score: 10, min_locals: 4, min_statements: 4)
      class Billing
        def cohesive(price, tax, rate)
          subtotal = price + tax
          adjusted = subtotal * rate
          rounded = adjusted.round
          "total: \#{rounded}"
        end
      end
    RB

    assert_empty out
  end

  def test_does_not_flag_one_line_copy_builder_lanes
    out = scan(<<~RB, min_score: 10, min_locals: 4, min_statements: 4)
      class Type
        def with(ownership, sync, layout, lock_rank)
          next_ownership = ownership
          next_sync = sync
          next_layout = layout
          next_lock_rank = lock_rank
          Type.new(next_ownership, next_sync, next_layout, next_lock_rank)
        end
      end
    RB

    assert_empty out
  end

  private

  def scan(
    code,
    min_components: Decomplex::FunctionLCOM::DEFAULT_MIN_COMPONENTS,
    min_locals: Decomplex::FunctionLCOM::DEFAULT_MIN_LOCALS,
    min_statements: Decomplex::FunctionLCOM::DEFAULT_MIN_STATEMENTS,
    min_score: Decomplex::FunctionLCOM::DEFAULT_MIN_SCORE
  )
    file = Tempfile.new(["function_lcom", ".rb"])
    file.write(code)
    file.close
    Decomplex::FunctionLCOM.scan(
      [file.path],
      min_components: min_components,
      min_locals: min_locals,
      min_statements: min_statements,
      min_score: min_score
    )
  ensure
    file&.unlink
  end
end
