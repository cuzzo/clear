# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

# A slice is Rust's idiomatic collection parameter. Without it the element is
# untyped, no library bound resolves for a call on it, and a per-element cost is
# multiplied by the loop rather than summed over it.
class BigORustTest < Minitest::Test
  ROOT = File.expand_path("fixtures/big_o_rust", __dir__)

  def test_slice_element_costs
    evidence = Espalier::StaticEvidence.build(
      [File.join(ROOT, "src/lib.rs"), File.join(ROOT, "src/paths.rs")],
      root: ROOT,
      scip_indexes: [File.join(ROOT, "index.scip")]
    )
    manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
    actual = manifest.flat_map { |owner| owner.fetch(:functions) }
                     .to_h { |fn| [fn.fetch(:name), fn.fetch(:quality_metrics).fetch(:big_o)] }

    # Each name is scanned once, so the strips sum to the input.
    assert_equal "O(N)", actual["strip_each"]
    # Appending each name copies that name, which also sums to the input.
    assert_equal "O(N)", actual["join_each"]
    # Every iteration rescans the accumulated buffer.
    assert_equal "O(N^2)", actual["scan_accumulated"]
    # PathBuf answers to Path's methods, so each strip reads one path.
    assert_equal "O(N)", actual["strip_paths"]
  end
end
