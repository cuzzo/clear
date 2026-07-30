# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

# A bound is read, not solved. Rendering collapses a long sum; the stored bound
# keeps every term, so nothing downstream of storage may change.
class BigOBoundRenderingTest < Minitest::Test
  COLLAPSED = {
    "O(N)" => "O(N)",
    "O(1)" => "O(1)",
    "O(N + M)" => "O(N + M)",
    "O(N + M + L)" => "O(N#3)",
    "O(N + R + R2 + R3 + R4)" => "O(N#5)",
    "O(N^2 + M)" => "O(N^2)",
    "O(N^2 + M + K + L)" => "O(N^2)",
    "O(N*M*K + N*M*L)" => "O(N*M*K + N*M*L)",
    "O(N*M*K + N*M*L + N*M*P)" => "O((N*M*K)#3)",
    "O(N log N + M log M + K log K)" => "O((N log N)#3)",
    "O(N^3*R^2 log N)" => "O(N^3*R^2 log N)"
  }.freeze

  def test_rendering_reports_the_largest_term_and_counts_its_siblings
    COLLAPSED.each do |stored, rendered|
      assert_equal rendered, Espalier::SymbolicComplexity.collapse_bound(stored), stored
    end
  end

  # The count starts at the third sibling, so a pair still reads as a pair.
  def test_a_pair_is_never_collapsed
    assert_equal "O(N + M)", Espalier::SymbolicComplexity.collapse_bound("O(N + M)")
    assert_equal "O(N*M + K*L)", Espalier::SymbolicComplexity.collapse_bound("O(N*M + K*L)")
  end
end
