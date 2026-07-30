# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

# Accumulating into a string copies the accumulated value every iteration. The
# bound depends on resolving the local's type from its declaration, with no
# compiler index available.
class BigOLocalTypesTest < Minitest::Test
  ROOT = File.expand_path("fixtures/big_o_langs", __dir__)

  EXPECTED = {
    "concat.cs" => ["Build", "O(N^2)"],
    "concat.ts" => ["build", "O(N^2)"]
  }.freeze

  def test_string_accumulation_is_quadratic
    EXPECTED.each do |file, (function, bound)|
      evidence = Espalier::StaticEvidence.build([File.join(ROOT, file)], root: ROOT)
      manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
      actual = manifest.flat_map { |owner| owner.fetch(:functions) }
                       .to_h { |fn| [fn.fetch(:name), fn.fetch(:quality_metrics).fetch(:big_o)] }
      assert_equal bound, actual[function], file
    end
  end
end
