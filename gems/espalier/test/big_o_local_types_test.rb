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

  # A call nothing can price leaves its caller incomplete rather than letting
  # the surrounding loops stand as a complete bound.
  def test_an_unpriced_call_leaves_its_caller_incomplete
    evidence = Espalier::StaticEvidence.build([File.join(ROOT, "unpriced.cs")], root: ROOT)
    manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
    metrics = manifest.flat_map { |owner| owner.fetch(:functions) }
                      .find { |fn| fn.fetch(:name) == "Count" }
                      .fetch(:quality_metrics)
    assert_equal false, metrics[:big_o_complete]
  end

  # With the declared types in hand nothing here is a mystery, so none of these
  # may fall back to incomplete.
  TYPED = {
    # Appending each element of a collection sums to that collection, so none
    # of these is quadratic - the same shape Go's VariableArgumentWrite pins.
    "typed.cs" => { "SumLengths" => "O(N)", "Has" => "O(N)", "Join" => "O(N)", "Copy" => "O(N)" },
    "typed.ts" => { "sumLengths" => "O(N)", "lookup" => "O(N)", "copy" => "O(N)" }
  }.freeze

  def test_declared_types_leave_nothing_unpriced
    TYPED.each do |file, expected|
      evidence = Espalier::StaticEvidence.build([File.join(ROOT, file)], root: ROOT)
      manifest = Espalier::Aggregator.new.aggregate(Espalier::StaticEvidence.project_modules(evidence))
      functions = manifest.flat_map { |owner| owner.fetch(:functions) }
      functions.each do |function|
        metrics = function.fetch(:quality_metrics)
        assert_equal true, metrics[:big_o_complete], "#{file}:#{function.fetch(:name)}"
      end
      actual = functions.to_h { |fn| [fn.fetch(:name), fn.fetch(:quality_metrics).fetch(:big_o)] }
      expected.each { |name, bound| assert_equal bound, actual[name], "#{file}:#{name}" }
    end
  end

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
