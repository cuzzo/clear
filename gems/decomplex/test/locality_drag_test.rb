# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/locality_drag"

class LocalityDragTest < Minitest::Test
  def test_flags_dormant_local_in_complex_method
    out = scan(<<~RB)
      class Importer
        def run(user, cart, logger)
          receipt_id = user.id

          total = cart.total
          if total > 100
            if cart.discountable?
              discount = 10
            end
          end
          if cart.taxable?
            if cart.region
              tax = total * 0.2
            end
          end
          if logger.enabled?
            if logger.debug?
              logger.info(total)
            end
          end
          if cart.valid?
            if cart.ready?
              status = :ready
            end
          end

          emit(receipt_id)
        end
      end
    RB

    finding = out.find { |row| row[:variable] == "receipt_id" }

    refute_nil finding
    assert_equal "run", finding[:method]
    assert_operator finding[:unrelated_statements], :>=, 4
    assert_operator finding[:gap_lines], :>=, 8
    assert_operator finding[:boundary_crossings], :>=, 1
    assert_includes finding[:definition_deps], "user"
    assert_includes finding[:use_reads], "receipt_id"
  end

  def test_ignores_low_complexity_long_gap
    out = scan(<<~RB)
      class Importer
        def run(user, cart)
          receipt_id = user.id

          total = cart.total
          tax = cart.tax
          subtotal = total + tax
          label = subtotal.to_s
          normalized = label.strip

          emit(receipt_id)
        end
      end
    RB

    assert_empty out
  end

  def test_does_not_count_related_pipeline_as_unrelated
    out = scan(<<~RB, min_local_complexity: 1.0, min_score: 1)
      class Importer
        def run(user, cart)
          receipt_id = user.id

          normalized_user = user.name
          display_user = normalized_user.strip
          if cart.valid?
            if cart.ready?
              status = :ready
            end
          end
          if cart.total > 10
            if cart.discountable?
              total = cart.total
            end
          end
          if cart.taxable?
            if cart.region
              tax = total * 0.2
            end
          end
          if cart.discounted?
            if cart.coupon
              discount = 10
            end
          end

          emit(receipt_id)
        end
      end
    RB

    finding = out.find { |row| row[:variable] == "receipt_id" }

    refute_nil finding
    assert_operator finding[:related_statements], :>=, 2
    assert_operator finding[:unrelated_statements], :>=, 4
  end

  def test_rewrite_before_read_is_not_a_dormant_initialization
    out = scan(<<~RB)
      class Importer
        def run(user, cart, logger)
          receipt_id = user.id

          if cart.total > 100
            if cart.discountable?
              discount = 10
            end
          end
          if cart.taxable?
            if cart.region
              tax = cart.total * 0.2
            end
          end
          if logger.enabled?
            if logger.debug?
              logger.info(tax)
            end
          end
          if cart.valid?
            if cart.ready?
              status = :ready
            end
          end

          receipt_id = cart.id
          emit(receipt_id)
        end
      end
    RB

    refute out.any? { |row| row[:variable] == "receipt_id" }
  end

  def test_ignores_source_location_locals
    out = scan(<<~RB, min_local_complexity: 1.0, min_score: 1)
      class Parser
        def parse(input, cart)
          saved_pos = input.pos

          if cart.total > 100
            if cart.discountable?
              discount = 10
            end
          end
          if cart.taxable?
            if cart.region
              tax = cart.total * 0.2
            end
          end
          if cart.valid?
            if cart.ready?
              status = :ready
            end
          end

          restore(saved_pos)
        end
      end
    RB

    assert_empty out
  end

  def test_ignores_same_prefix_constructor_staging_batch
    out = scan(<<~RB, min_local_complexity: 1.0, min_score: 1)
      class Capabilities
        def with(input, cart)
          next_ownership = input.ownership
          next_sync = input.sync
          next_layout = input.layout
          next_rank = input.rank
          next_collection = input.collection

          if cart.total > 100
            if cart.discountable?
              discount = 10
            end
          end
          if cart.taxable?
            if cart.region
              tax = cart.total * 0.2
            end
          end

          Result.new(next_ownership, next_sync, next_layout, next_rank, next_collection)
        end
      end
    RB

    assert_empty out
  end

  def test_ignores_literal_setup_cluster_before_algorithm_body
    out = scan(<<~RB, min_local_complexity: 1.0, min_score: 1)
      class Graph
        def tarjan(nodes)
          index = {}
          lowlink = {}
          on_stack = {}
          stack = []
          next_index = 0

          nodes.each do |root|
            if index.key?(root)
              next
            end
            visit(root, index, lowlink, on_stack, stack, next_index)
          end
        end
      end
    RB

    assert_empty out
  end

  private

  def scan(
    code,
    min_unrelated_statements: Decomplex::LocalityDrag::DEFAULT_MIN_UNRELATED_STATEMENTS,
    min_gap_lines: Decomplex::LocalityDrag::DEFAULT_MIN_GAP_LINES,
    min_local_complexity: Decomplex::LocalityDrag::DEFAULT_MIN_LOCAL_COMPLEXITY,
    min_score: Decomplex::LocalityDrag::DEFAULT_MIN_SCORE
  )
    file = Tempfile.new(["locality_drag", ".rb"])
    file.write(code)
    file.close
    Decomplex::LocalityDrag.scan(
      [file.path],
      min_unrelated_statements: min_unrelated_statements,
      min_gap_lines: min_gap_lines,
      min_local_complexity: min_local_complexity,
      min_score: min_score
    )
  ensure
    file&.unlink
  end
end
