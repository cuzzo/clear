# typed: false

require "rspec"
require "benchmark"
require_relative "../../ruby/ast/parser"

RSpec.describe "frontend resource-budget integration" do
  def parse(source, budget: FrontendResourceBudget.new)
    tokens = Lexer.new(source, budget: budget).tokenize
    ClearParser.new(tokens, source, budget: budget).parse
  end

  it "returns a stable ParserError before a deeply nested grammar reaches Ruby's stack limit" do
    budget = FrontendResourceBudget.new(max_nesting: 24)
    source = "value = #{'(' * 100}1_i64#{')' * 100};"

    expect { parse(source, budget: budget) }
      .to raise_error(ParserError, /Frontend nesting resource limit exceeded \(limit 24\)/)
  end

  it "returns a stable ParserError for a token budget" do
    budget = FrontendResourceBudget.new(max_tokens: 8)
    expect { parse("a = 1_i64; b = 2_i64;", budget: budget) }
      .to raise_error(ParserError, /Frontend tokens resource limit exceeded \(limit 8\)/)
  end

  it "keeps flat parsing geometric rather than replaying prefixes" do
    elapsed = [400, 800].map do |count|
      source = Array.new(count) { |index| "v#{index} = #{index}_i64;" }.join("\n")
      Benchmark.realtime { parse(source) }
    end

    # Doubling a linear input should remain far below the 4x quadratic slope.
    # The margin absorbs shared-runner scheduling noise while still catching
    # the former recursive prefix replay.
    expect(elapsed.last).to be < (elapsed.first * 3.5)
  end
end
