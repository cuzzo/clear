# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/symbolic_complexity"

class SymbolicComplexityTest < Minitest::Test
  def domain(id, name, line)
    { "id" => id, "name" => name, "source_kind" => "parameter", "path" => "sample.rb", "span" => [line, 0, line, 4] }
  end

  def expression(factors, domains)
    Espalier::SymbolicComplexity.from_fact(
      { "factors" => factors.map { |id, exponent| { "domain_id" => id, "exponent" => exponent } }, "complete" => true },
      domains
    )
  end

  def test_renders_repeated_and_independent_domains_differently
    xs = domain("param:f:xs", "xs", 1)
    ys = domain("param:f:ys", "ys", 2)

    repeated = expression({ xs["id"] => 2 }, [xs])
    independent = expression({ xs["id"] => 1, ys["id"] => 1 }, [xs, ys])

    assert_equal "O(N^2)", Espalier::SymbolicComplexity.render(repeated).first
    rendered, variables = Espalier::SymbolicComplexity.render(independent)
    assert_equal "O(N*M)", rendered
    assert_equal %w[xs ys], variables.map { |variable| variable[:name] }
    assert_equal [[1, 0, 1, 4], [2, 0, 2, 4]], variables.map { |variable| variable[:span] }
  end

  def test_preserves_non_dominated_sequential_terms_and_substitutes_callee_domains
    xs = domain("caller:xs", "xs", 1)
    ys = domain("callee:ys", "ys", 8)
    left = expression({ xs["id"] => 1 }, [xs])
    right = expression({ ys["id"] => 1 }, [ys])
    sum = Espalier::SymbolicComplexity.sum(left, right)
    assert_equal "O(N + M)", Espalier::SymbolicComplexity.render(sum).first

    substituted = Espalier::SymbolicComplexity.substitute(
      right,
      { ys["id"] => [xs["id"]] },
      caller_domains: { xs["id"] => xs }
    )
    product = Espalier::SymbolicComplexity.multiply(left, substituted)
    assert_equal "O(N^2)", Espalier::SymbolicComplexity.render(product).first
  end

  def test_assigns_n_to_the_highest_exponent_and_renders_canonical_factor_order
    outer = domain("param:f:outer", "outer", 1)
    inner = domain("param:f:inner", "inner", 2)
    value = expression({ outer["id"] => 1, inner["id"] => 2 }, [outer, inner])

    rendered, variables = Espalier::SymbolicComplexity.render(value)
    assert_equal "O(N^2*M)", rendered
    assert_equal %w[inner outer], variables.map { |variable| variable[:name] }

    polynomial = Espalier::SymbolicComplexity.sum(
      expression({ outer["id"] => 1 }, [outer]),
      expression({ inner["id"] => 2 }, [inner])
    )
    assert_equal "O(N^2 + M)", Espalier::SymbolicComplexity.render(polynomial).first

    third = domain("param:f:third", "third", 3)
    product_then_linear = Espalier::SymbolicComplexity.sum(
      expression({ outer["id"] => 1 }, [outer]),
      expression({ inner["id"] => 1, third["id"] => 1 }, [inner, third])
    )
    rendered, variables = Espalier::SymbolicComplexity.render(product_then_linear)
    assert_equal "O(N*M + K)", rendered
    assert_equal %w[inner third outer], variables.map { |variable| variable[:name] }
  end

  def test_logarithms_remain_attached_to_their_source_domain
    outer = domain("param:f:outer", "outer", 1)
    sorted = domain("param:f:sorted", "sorted", 2)
    loop_work = expression({ outer["id"] => 1 }, [outer, sorted])
    sort_work = Espalier::SymbolicComplexity.relative_call(
      "O(N log N)",
      receiver_domains: [sorted["id"]],
      argument_domains: [],
      domains: [outer, sorted]
    )

    rendered, variables = Espalier::SymbolicComplexity.render(
      Espalier::SymbolicComplexity.multiply(loop_work, sort_work)
    )
    assert_equal "O(N*M log N)", rendered
    assert_equal %w[sorted outer], variables.map { |variable| variable[:name] }

    logarithmic = Espalier::SymbolicComplexity.relative_call(
      "O(log N)",
      receiver_domains: [sorted["id"]],
      argument_domains: [],
      domains: [sorted]
    )
    assert_equal "O(log N)", Espalier::SymbolicComplexity.render(logarithmic).first
  end
end
