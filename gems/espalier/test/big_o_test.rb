# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/espalier/big_o_analyzer"
require_relative "../lib/espalier/structural_big_o"

class BigOTest < Minitest::Test
  def test_symbolic_complexity_renders_callback_cost_as_a_distinct_parameter
    expression = Espalier::SymbolicComplexity.parameterized_cost(
      id: "cost:call-1",
      name: "predicate.apply",
      source_kind: "callback_cost",
      multiplicity_domain: "param:items",
      domains: [{
        "id" => "param:items", "name" => "items", "source_kind" => "parameter"
      }]
    )

    rendered, variables = Espalier::SymbolicComplexity.render(expression)
    assert_equal "O(N*C)", rendered
    assert_equal ["parameter", "callback_cost"], variables.map { |row| row[:source_kind] }
  end

  def test_language_neutral_nested_independent_domains_render_a_product
    fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "big_o", "nested_independent_domains.json")))
    consumer = Espalier::StructuralBigO.new(
      facts_by_method: { "matrix-fill" => [fixture] }
    )

    hint = consumer.hints_for(nil, { id: "matrix-fill", name: "fill", line: 1 }, "Matrix").first
    assert_equal "O(N*M)", hint.fetch(:complexity)
    assert hint.fetch(:time_complete)
    assert_equal %w[rows columns], hint.fetch(:symbolic_time).then { |expression|
      Espalier::SymbolicComplexity.render(expression).last.map { |variable| variable[:name] }
    }
  end

  def test_complexity_arithmetic_and_ranking
    analyzer = Espalier::BigOAnalyzer.new
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(1)", "O(N)")
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(N)", "O(1)")
    assert_equal "O(N^2)", analyzer.send(:multiply_complexity, "O(N)", "O(N)")
    assert_equal "O(N^5)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N^3)")
    assert_equal "O(N^2 log N)", analyzer.send(:multiply_complexity, "O(N log N)", "O(N)")
    assert_equal "O(N log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(N)")
    assert_equal "O(log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(log N)")
    assert_equal "O(2^N)", analyzer.send(:multiply_complexity, "O(2^N)", "O(N)")
    assert_equal "O(N!)", analyzer.send(:multiply_complexity, "O(N!)", "O(N^3)")

    expected = {
      nil => 1, "O(1)" => 1, "O(log N)" => 2, "O(N)" => 10,
      "O(N log N)" => 11, "O(N * M)" => 14, "O(N^2)" => 14,
      "O(N^2 log N)" => 15, "O(2^N)" => 100, "O(N!)" => 200,
      "unknown" => 1
    }
    expected.each { |value, rank| assert_equal rank, analyzer.send(:complexity_rank, value) }
  end

  def test_type_resolution_and_fact_mine_normalized_operations
    nil_kill = Object.new
    def nil_kill.method_signatures
      {
        "Owner#items" => "sig { returns(T::Array[String]) }",
        "User#address" => "def address() -> Address"
      }
    end
    def nil_kill.state_types
      { "Address" => { "@city" => "City" }, "FunctionCFG" => { "@blocks" => "Array" } }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Owner", ivar_types: { "@cfg" => "FunctionCFG", "@values" => "Hash" },
      nil_kill: nil_kill,
      local_types: {
        "users" => "T.nilable(T::Array[User])",
        "tokens" => "T.nilable(T::Array[AST::Token])",
        "table" => "T::Hash[String, T::Array[AST::Token]]",
        "text" => "String"
      }
    )
    assert_equal "Owner", analyzer.send(:resolve_type, "self", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "items", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "users", 1)
    assert_equal "AST::Token", analyzer.send(:resolve_type, "tokens[position]", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "table[key]", 1)
    assert_equal "String", analyzer.send(:resolve_type, "text[position]", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "cfg.blocks", 1)

    result = analyzer.analyze_method("sort", [
      { type: :call, receiver: "cfg", method: "blocks", line: 2,
        known_time_complexity: "O(1)", known_space_complexity: "O(1)" },
      { type: :call, receiver: "cfg", method: "sort_by", line: 2,
        known_time_complexity: "O(N log N)", known_space_complexity: "O(N)" }
    ])
    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert result[:time_complete]
    assert result[:space_complete]

    chain = analyzer.analyze_method("join", [
      { type: :call, receiver: "values", method: "map", line: 3,
        known_time_complexity: "O(N)", known_space_complexity: "O(N)" },
      { type: :call, receiver: "values", method: "join", line: 3,
        known_time_complexity: "O(N)", known_space_complexity: "O(N)" }
    ])
    assert_equal "O(N)", chain[:lower_bound_complexity]
  end

  def test_analyze_method_nodes_and_space
    analyzer = Espalier::BigOAnalyzer.new(nil_kill_evidence: { "10" => { "items" => "Array" } })
    result = analyzer.analyze_method("work", [
      { type: :call, receiver: "items", method: "sort", line: 10 },
      { type: :loop, line: 11 }, { type: :loop, line: 12 },
      { type: :callback, line: 13 },
      { type: :structural, line: 14, complexity: "O(N^2)", space: "O(log N)",
        operation: "normalized_ast", reason: "normalized fact", is_dynamic: true,
        trigger: "line 10" }
    ])
    assert_equal "unknown", result[:lower_bound_complexity]
    assert_equal "unknown", result[:space_complexity]
    assert_equal "O(N^2)", result[:known_time_component]
    assert_equal "O(log N)", result[:known_space_component]
    assert result[:is_dynamic]
    assert_equal "line 10", result[:trigger]
    assert result[:warnings].any? { |warning| warning.include?("Function pointer") }
    assert result[:warnings].any? { |warning| warning.include?("normalized fact") }
  end

  def test_type_name_and_signature_normalization
    analyzer = Espalier::BigOAnalyzer.new
    assert_nil analyzer.send(:clean_type_name, nil)
    assert_equal "User", analyzer.send(:clean_type_name, "T.nilable(User)")
    assert_equal "User", analyzer.send(:clean_type_name, "T.any(NilClass, User)")
    assert_equal "Array", analyzer.send(:clean_type_name, "T::Array[User]")
    assert_equal "Hash", analyzer.send(:clean_type_name, "T.Hash[String, Integer]")
    assert_equal "User", analyzer.send(:clean_type_name, "User")
    assert_equal "Result", analyzer.send(:extract_return_type, "sig { returns(Result) }")
    assert_equal "Result", analyzer.send(:extract_return_type, "def run() -> Result")
    assert_nil analyzer.send(:extract_return_type, nil)
  end

  def test_unknown_and_known_receiver_warnings
    analyzer = Espalier::BigOAnalyzer.new(class_name: "Owner", ivar_types: { "@thing" => "Widget" })
    result = analyzer.analyze_method("unknowns", [
      { type: :call, receiver: "thing", method: "work", line: 1, evidence_gap: "unmodeled_typed_operation" },
      { type: :call, receiver: "mystery", method: "work", line: 2, evidence_gap: "unresolved_receiver_type" },
      { type: :yield, line: 3 }
    ])
    assert_includes result[:unknown_operations], "Widget#work"
    assert_includes result[:unknown_operations], "mystery.work"
    assert_equal "unknown", result[:lower_bound_complexity]
    assert_equal "O(1)", result[:known_time_component]
    refute result[:time_complete]
    refute result[:space_complete]
    assert_equal 3, result[:warnings].size
    assert_equal 1, result.dig(:unknown_operation_evidence, "Widget#work", "typed_unmodeled_occurrences")
    assert_equal({ "unmodeled_typed_operation" => 1 }, result.dig(:unknown_operation_evidence, "Widget#work", "evidence_gaps"))
    assert_equal({ "unresolved_receiver_type" => 1 }, result.dig(:unknown_operation_evidence, "mystery.work", "evidence_gaps"))
  end

  def test_declared_struct_fields_are_constant_without_hiding_methods
    analyzer = Espalier::BigOAnalyzer.new(
      local_types: { "node" => "AST::BinaryOp" },
      declared_fields: { "AST::BinaryOp" => %w[left right] }
    )

    field = analyzer.analyze_method("field", [
      { type: :call, receiver: "node", method: "left", line: 1 }
    ])
    assert_equal "O(1)", field[:lower_bound_complexity]
    assert_equal "O(1)", field[:space_complexity]
    assert field[:time_complete]
    assert field[:space_complete]
    assert_empty field[:unknown_operations]

    method = analyzer.analyze_method("method", [
      { type: :call, receiver: "node", method: "rewrite", line: 2 }
    ])
    assert_equal "unknown", method[:lower_bound_complexity]
    assert_includes method[:unknown_operations], "AST::BinaryOp#rewrite"
  end

  def test_internal_calls_are_complete_but_callbacks_are_not
    analyzer = Espalier::BigOAnalyzer.new
    internal = analyzer.analyze_method("wrapper", [{
      type: :call, receiver: "self", method: "helper", line: 2, internal_call: true
    }])
    assert_equal "O(1)", internal[:lower_bound_complexity]
    assert_equal "O(1)", internal[:known_time_component]
    assert internal[:time_complete]
    assert internal[:space_complete]

    callback = analyzer.analyze_method("callback", [{ type: :callback, line: 3 }])
    assert_equal "unknown", callback[:lower_bound_complexity]
    assert_equal "unknown", callback[:space_complexity]
    assert_equal "O(1)", callback[:known_time_component]
    assert_equal "O(1)", callback[:known_space_component]
    refute callback[:time_complete]
    refute callback[:space_complete]
  end

  def test_structural_unknown_preserves_proven_components
    analyzer = Espalier::BigOAnalyzer.new
    result = analyzer.analyze_method("partial", [
      { type: :structural, line: 4, complexity: "O(N)", space: "O(N)" },
      { type: :structural, line: 5, complexity: "unknown", space: "unknown" }
    ])
    assert_equal "unknown", result[:lower_bound_complexity]
    assert_equal "unknown", result[:space_complexity]
    assert_equal "O(N)", result[:known_time_component]
    assert_equal "O(N)", result[:known_space_component]
    refute result[:time_complete]
    refute result[:space_complete]
  end

  def test_structural_big_o_only_consumes_normalized_facts
    facts = {
      "method-1" => [{
        "line" => 7, "parameters" => ["items"],
        "iterations" => [{
          "line" => 7, "power" => 2, "execution_multiplicity" => "O(N^2)",
          "cardinality_relation" => "independent_of"
        }],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 8, "message" => "callee", "execution_multiplicity" => "O(N)", "power" => 1,
          "argument_cardinality_relation" => "independent_of"
        }]
      }],
      ["Owner", "fallback"] => [{
        "line" => 2, "parameters" => ["n"], "iterations" => [],
        "recursion" => { "calls" => 2, "shrinking_calls" => 2, "unknown_progress_calls" => 0 }
      }]
    }
    consumer = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Owner" => { "callee" => "O(N log N)" } }
    )

    hints = consumer.hints_for("/path/that/does/not/exist.rb", { id: "method-1", name: "work", line: 1 }, "Owner")
    assert_equal 2, hints.size
    assert_equal "O(N^2)", hints.first[:complexity]
    assert_equal "fact_mine", hints.first[:fact_source]
    assert_equal "normalized_complexity_facts", hints.first[:operation]
    assert_equal "O(N^2 log N)", hints.last[:complexity]

    fallback = consumer.hints_for(nil, { name: "fallback", line: 2 }, "Owner")
    assert_equal "O(2^N)", fallback.first[:complexity]
    assert_equal "O(N)", fallback.first[:space]
    assert_empty consumer.hints_for("missing.rb", { id: "none", name: "none", line: 1 }, "Owner")
    assert_equal "O(N!)", consumer.send(:multiply, "O(N!)", "O(N)")
    assert_equal "O(2^N)", consumer.send(:multiply, "O(N)", "O(2^N)")
    assert_equal "O(log N)", consumer.send(:multiply, "O(log N)", "O(log N)")
    assert_equal "O(1)", consumer.send(:multiply, "O(1)", "O(1)")
    assert_equal "O(N^3 log N)", consumer.send(:multiply, "O(N^2 log N)", "O(N)")
    assert_equal "unknown", consumer.send(:multiply, "unknown", "O(N)")
    assert_equal [nil, nil], consumer.send(:allocation_complexity, [], [])
    assert_equal ["unknown", nil], consumer.send(:allocation_complexity, [{ "cardinality_relation" => "unknown" }], [])
    assert_equal ["O(N)", nil], consumer.send(:allocation_complexity, [{ "bound_classification" => "input" }], [])
    assert_equal ["O(1)", nil], consumer.send(:allocation_complexity, [{ "bound_classification" => "fixed" }], [])
    assert_equal "O(N)", consumer.send(:max_space_complexity, nil, "O(N)")
    assert_equal "O(N)", consumer.send(:max_space_complexity, "O(N)", nil)
    assert_equal "unknown", consumer.send(:max_space_complexity, "unknown", "O(N)")
    assert_equal "O(N)", consumer.send(:max_space_complexity, "O(N)", "O(log N)")
    assert_equal "O(N)", consumer.send(:propagated_call_complexity, {
      "execution_multiplicity" => "O(N)", "argument_cardinality_relation" => "partition_of"
    }, "O(N)")
    assert_equal "O(N^2)", consumer.send(:propagated_call_complexity, {
      "execution_multiplicity" => "O(N)", "argument_cardinality_relation" => "unknown"
    }, "O(N)")
    assert_equal "O(N)", consumer.send(:propagated_call_complexity, {
      "execution_multiplicity" => "O(N)", "argument_cardinality_relation" => "unknown"
    }, "O(1)")

    recursive_consumer = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Owner" => { "callee" => "O(N)" } },
      internal_calls: { "Owner" => { "work" => ["callee"] } },
      recursive_edges: { ["Owner", "work", "callee"] => true }
    )
    recursive_hints = recursive_consumer.hints_for(nil, { id: "method-1", name: "work", line: 1 }, "Owner")
    assert_equal "unknown", recursive_hints.last[:complexity]
    assert_equal "unknown", recursive_hints.last[:space]
    mutual_facts = {
      ["Owner", "even_step"] => [{
        "line" => 20, "parameters" => ["n"], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{ "line" => 21, "message" => "odd_step", "argument_progress" => "shrinking" }]
      }],
      ["Owner", "odd_step"] => [{
        "line" => 24, "parameters" => ["n"], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{ "line" => 25, "message" => "even_step", "argument_progress" => "halving" }]
      }]
    }
    mutual_consumer = Espalier::StructuralBigO.new(
      facts_by_method: mutual_facts,
      method_complexities: { "Owner" => { "even_step" => "O(1)", "odd_step" => "O(1)" } },
      internal_calls: { "Owner" => { "even_step" => ["odd_step"], "odd_step" => ["even_step"] } },
      recursive_edges: {
        ["Owner", "even_step", "odd_step"] => true,
        ["Owner", "odd_step", "even_step"] => true
      }
    )
    mutual_hint = mutual_consumer.hints_for(nil, { name: "even_step", line: 20 }, "Owner").last
    assert_equal "O(N)", mutual_hint[:complexity]
    assert_equal "O(N)", mutual_hint[:space]
    assert_equal "high", mutual_hint[:confidence]
    assert_includes mutual_hint[:reason], "size-change proof"
    assert_equal ["O(N)", "O(log N)", "multiple halving recursive branches"],
      consumer.send(:recursion_complexity, { "calls" => 2, "halving_calls" => 2 }, 1)
    assert_equal ["O(log N)", "O(log N)", "halving recursive progress"],
      consumer.send(:recursion_complexity, { "calls" => 1, "halving_calls" => 1 }, 1)
    assert_equal ["O(N)", "O(N)", "single shrinking recursive progress"],
      consumer.send(:recursion_complexity, { "calls" => 1, "shrinking_calls" => 1 }, 1)
    assert_equal ["O(N)", "O(N)", "visited-set guarded structural recursion"],
      consumer.send(:recursion_complexity, {
        "calls" => 2, "visited_guarded_calls" => 2, "unknown_progress_calls" => 0
      }, 2)
    assert_equal ["O(N)", "O(N)", "recursive descent into a projection of the input"],
      consumer.send(:recursion_complexity, {
        "calls" => 2, "structural_calls" => 2, "unknown_progress_calls" => 0
      }, 2)
    structural = consumer.send(:summary_hint, {
      "line" => 8, "parameters" => ["node"], "iterations" => [], "allocations" => [],
      "size_domains" => [], "recursion" => {
        "calls" => 2, "structural_calls" => 2, "unknown_progress_calls" => 0
      }
    }, { line: 8, name: "walk" })
    assert_equal "O(N)", structural[:complexity]
    assert_equal "upper_bound_structural_descent", structural[:complexity_bound_quality]
    assert_includes structural[:complexity_assumptions].first, "finite and acyclic"
    unknown = consumer.send(:summary_hint, {
      "line" => 9, "parameters" => ["items"], "recursion" => { "calls" => 0 },
      "iterations" => [{ "power" => 1, "cardinality_relation" => "unknown", "execution_multiplicity" => "unknown" }]
    }, { line: 9 })
    assert_equal "unknown", unknown[:complexity]
  end

  def test_interprocedural_domains_are_attributed_to_the_callee
    domain = {
      "id" => "state:Helper:@items", "name" => "@items", "source_kind" => "state",
      "path" => "helper.py", "span" => [20, 4, 20, 15]
    }
    callee_symbolic = Espalier::SymbolicComplexity.from_fact(
      { "factors" => [{ "domain_id" => domain["id"], "exponent" => 1 }], "complete" => true },
      [domain]
    )
    facts = {
      "caller-id" => [{
        "owner" => "Caller", "function" => "render", "line" => 3,
        "parameters" => [], "iterations" => [], "size_domains" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{ "line" => 4, "message" => "helper" }]
      }],
      ["Caller", "helper"] => [{
        "owner" => "Caller", "function" => "helper", "line" => 20,
        "parameters" => [], "iterations" => [], "size_domains" => [domain],
        "recursion" => { "calls" => 0 }, "call_contexts" => []
      }]
    }
    consumer = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Caller" => { "helper" => "O(N)" } },
      method_symbolic_time: { "Caller" => { "helper" => callee_symbolic } }
    )

    hint = consumer.hints_for(nil, { id: "caller-id", name: "render", line: 3 }, "Caller").last
    variable = Espalier::SymbolicComplexity.render(hint[:symbolic_time]).last.first
    assert_equal "Caller", variable[:origin_owner]
    assert_equal "helper", variable[:origin_function]
    assert_equal({ owner: "Caller", function: "render", message: "helper", line: 4 },
      variable[:propagated_via].transform_keys(&:to_sym))
  end

  def test_state_replay_requires_generic_protocol_domain_progress_and_branching_evidence
    statement = {
      "line" => 1, "parameters" => [], "iterations" => [],
      "recursion" => { "calls" => 0 },
      "call_contexts" => [
        { "message" => "speculate", "line" => 2 },
        { "message" => "parse_value", "line" => 3 }
      ]
    }
    speculate = {
      "line" => 5, "parameters" => [], "iterations" => [],
      "recursion" => { "calls" => 0 },
      "call_contexts" => [{ "message" => "parse_value", "line" => 7 }],
      "state_replays" => [{
        "state_domain" => "state:Walker:@cursor",
        "replayed_calls" => [{ "message" => "parse_value", "line" => 7 }]
      }]
    }
    value = {
      "line" => 10, "parameters" => [], "iterations" => [],
      "recursion" => { "calls" => 0 },
      "call_contexts" => [{ "message" => "parse_statement", "line" => 12 }],
      "state_progress" => [{
        "state_domain" => "state:Walker:@cursor", "direction" => "advance"
      }],
      "state_cursor_domains" => [{
        "cursor_domain" => "state:Walker:@cursor",
        "collection_domain" => "state:Walker:@items"
      }]
    }
    facts = {
      ["Walker", "parse_statement"] => [statement],
      ["Walker", "speculate"] => [speculate],
      ["Walker", "parse_value"] => [value]
    }
    graph = {
      "Walker" => {
        "parse_statement" => %w[speculate parse_value],
        "speculate" => ["parse_value"],
        "parse_value" => ["parse_statement"]
      }
    }
    recursive_edges = {
      ["Walker", "parse_statement", "speculate"] => true,
      ["Walker", "parse_statement", "parse_value"] => true,
      ["Walker", "speculate", "parse_value"] => true,
      ["Walker", "parse_value", "parse_statement"] => true
    }
    consumer = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      internal_calls: graph,
      recursive_edges: recursive_edges
    )

    hint = consumer.hints_for(nil, { name: "parse_statement", line: 1 }, "Walker").first
    assert_equal "O(2^N)", hint[:complexity]
    assert_equal "O(N)", hint[:space]
    assert_includes hint[:reason], "checkpoint restoration"

    without_cursor_domain = Marshal.load(Marshal.dump(facts))
    without_cursor_domain[["Walker", "parse_value"]][0]["state_cursor_domains"] = []
    rejected = Espalier::StructuralBigO.new(
      facts_by_method: without_cursor_domain,
      internal_calls: graph,
      recursive_edges: recursive_edges
    ).hints_for(nil, { name: "parse_statement", line: 1 }, "Walker").first
    refute_equal "O(2^N)", rejected[:complexity]
  end

  def test_structural_big_o_propagates_unique_cross_owner_targets
    facts = {
      ["Caller", "run"] => [{
        "line" => 2, "parameters" => [], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 3, "message" => "work", "execution_multiplicity" => "O(1)",
          "argument_cardinality_relation" => "same"
        }]
      }]
    }
    consumer = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Target" => { "work" => "O(N)" } },
      method_spaces: { "Target" => { "work" => "O(1)" } },
      method_time_complete: { "Target" => { "work" => true } },
      method_space_complete: { "Target" => { "work" => true } },
      resolved_calls: {
        ["Caller", "run", "work", 3] => ["Target", "work"]
      }
    )

    hints = consumer.hints_for(nil, { name: "run", line: 2 }, "Caller")
    propagated = hints.find { |hint| hint[:operation] == "work" }
    assert_equal "O(N)", propagated[:complexity]
    assert_equal "O(1)", propagated[:space]
    assert propagated[:time_complete]
    assert propagated[:space_complete]
    assert_same hints, consumer.hints_for(nil, { name: "run", line: 2 }, "Caller")

    consumer.apply_summary_delta!(nil, "Target", "work", {
      time: "O(N^2)", space: "O(1)", time_complete: true, space_complete: true,
      symbolic_time: nil, bound_qualities: [], assumptions: []
    })
    changed_hints = consumer.hints_for(nil, { name: "run", line: 2 }, "Caller")
    refute_same hints, changed_hints
    assert_equal "O(N^2)", changed_hints.find { |hint| hint[:operation] == "work" }[:complexity]

    recursive = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Target" => { "work" => "O(N)" } },
      resolved_calls: { ["Caller", "run", "work", 3] => ["Target", "work"] },
      resolved_recursive_edges: { ["Caller", "run", "Target", "work"] => true }
    ).hints_for(nil, { name: "run", line: 2 }, "Caller")
      .find { |hint| hint[:operation] == "work" }
    assert_equal "unknown", recursive[:complexity]
    assert_equal "unknown", recursive[:space]
    refute recursive[:time_complete]
    refute recursive[:space_complete]
    assert_includes recursive[:evidence_gaps], "unresolved_recursive_progress"
  end

  # An exact recursive edge whose progress cannot be proven is not a proven
  # exponential: it is an unproven bound. Reporting O(2^N) as complete both
  # asserts a bound nothing established and hides the missing proof from the
  # gap diagnostics, which key on evidence gaps.
  def test_resolved_recursive_edge_without_progress_proof_is_unknown_not_exponential
    facts = {
      ["Walker", "visit"] => [{
        "line" => 1, "parameters" => ["node"], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 2, "message" => "visit", "execution_multiplicity" => "O(1)",
          "argument_progress" => "unknown", "argument_cardinality_relation" => "same"
        }]
      }]
    }
    hint = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Walker" => { "visit" => "O(N)" } },
      resolved_calls: { ["Walker", "visit", "visit", 2] => ["Walker", "visit"] },
      resolved_recursive_edges: { ["Walker", "visit", "Walker", "visit"] => true }
    ).hints_for(nil, { name: "visit", line: 1 }, "Walker")
      .find { |row| row[:operation] == "visit" }

    assert_equal "unknown", hint[:complexity]
    assert_equal "unknown", hint[:space]
    refute hint[:time_complete]
    refute hint[:space_complete]
    assert_includes hint[:evidence_gaps], "unresolved_recursive_progress"
    assert_nil hint[:complexity_bound_quality]
  end

  # A recursive call over a loop's own partition binding reaches each element
  # once. The shrinking-token heuristic must not outrank that proof: ordering
  # the loop-contained branch first reports O(N!) for a plain traversal.
  def test_loop_contained_recursion_over_a_partition_is_linear_not_factorial
    facts = {
      ["Tree", "walk"] => [{
        "line" => 1, "parameters" => ["node"], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 2, "message" => "walk", "execution_multiplicity" => "O(N)",
          "argument_progress" => "shrinking",
          "argument_cardinality_relation" => "partition_of"
        }]
      }]
    }
    hint = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Tree" => { "walk" => "O(N)" } },
      resolved_calls: { ["Tree", "walk", "walk", 2] => ["Tree", "walk"] },
      resolved_recursive_edges: { ["Tree", "walk", "Tree", "walk"] => true }
    ).hints_for(nil, { name: "walk", line: 1 }, "Tree")
      .find { |row| row[:operation] == "walk" }

    assert_equal "O(N)", hint[:complexity]
    assert hint[:time_complete]
    assert hint[:space_complete]
  end

  # Structural descent is the shape most recursive visitors have: no operand
  # shrinks arithmetically, so it used to have no bound at all. Descending one
  # level into a finite structure reaches each node once.
  def test_structural_descent_recursion_is_linear_in_the_structure
    facts = {
      ["Walker", "visit"] => [{
        "line" => 1, "parameters" => ["node"], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 2, "message" => "visit", "execution_multiplicity" => "O(1)",
          "argument_progress" => "structural",
          "argument_cardinality_relation" => "same"
        }]
      }]
    }
    hint = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      method_complexities: { "Walker" => { "visit" => "O(N)" } },
      resolved_calls: { ["Walker", "visit", "visit", 2] => ["Walker", "visit"] },
      resolved_recursive_edges: { ["Walker", "visit", "Walker", "visit"] => true }
    ).hints_for(nil, { name: "visit", line: 1 }, "Walker")
      .find { |row| row[:operation] == "visit" }

    assert_equal "O(N)", hint[:complexity]
    assert hint[:time_complete]
    assert_equal "upper_bound_structural_descent", hint[:complexity_bound_quality]
    assert_includes hint[:complexity_assumptions].first, "acyclic"
    # The conditional bound must not masquerade as an unconditional proof.
    assert_equal "partial", hint[:confidence]
  end

  # Unresolved mutual recursion already degrades to unknown, but published no
  # evidence gap, so the diagnostics could not attribute the incompleteness.
  def test_unproven_mutual_recursion_publishes_a_recursive_progress_gap
    facts = {
      ["Pair", "ping"] => [{
        "line" => 1, "parameters" => [], "iterations" => [],
        "recursion" => { "calls" => 0 },
        "call_contexts" => [{
          "line" => 2, "message" => "pong", "execution_multiplicity" => "O(1)",
          "argument_cardinality_relation" => "same"
        }]
      }]
    }
    hint = Espalier::StructuralBigO.new(
      facts_by_method: facts,
      internal_calls: { "Pair" => { "ping" => ["pong"] } },
      recursive_edges: { ["Pair", "ping", "pong"] => true }
    ).hints_for(nil, { name: "ping", line: 1 }, "Pair")
      .find { |row| row[:operation] == "pong" }

    assert_equal "unknown", hint[:complexity]
    refute hint[:time_complete]
    assert_includes hint[:evidence_gaps], "unresolved_recursive_progress"
  end

  def test_remaining_complexity_lattice_and_type_resolution_paths
    nil_kill = Object.new
    def nil_kill.method_signatures
      { "Owner#child" => "sig { returns(Child) }" }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Owner", ivar_types: { "@items" => "Array" }, nil_kill: nil_kill
    )
    assert_equal "Array", analyzer.send(:resolve_type, "@items", 1)
    assert_equal "Child", analyzer.send(:resolve_type, "child", 1)
    assert_equal "Child", analyzer.send(:resolve_type, "self.child", 1)
    assert_equal "O(N^5 log N)", analyzer.send(:multiply_complexity, "O(N^2 log N)", "O(N^3 log N)")
    assert_equal "O(N^2 log N)", analyzer.send(:multiply_complexity, "O(N log N)", "O(N log N)")
    assert_equal 10, analyzer.send(:space_complexity_rank, "O(N)")
    assert_equal 20, analyzer.send(:space_complexity_rank, "O(N*M)")
    assert_equal 1, analyzer.send(:space_complexity_rank, "unknown")
  end

  def test_normalized_call_execution_context_multiplies_operation_cost
    analyzer = Espalier::BigOAnalyzer.new(local_types: { "items" => "Array" })
    result = analyzer.analyze_method("repeated_sort", [{
      type: :call, receiver: "items", method: "sort", line: 4,
      execution_complexity: "O(N)", known_time_complexity: "O(N log N)",
      known_space_complexity: "O(N)"
    }])
    assert_equal "O(N^2 log N)", result[:lower_bound_complexity]
  end

  def test_normalized_call_costs_do_not_depend_on_an_espalier_language_registry
    analyzer = Espalier::BigOAnalyzer.new(language: :unknown)
    result = analyzer.analyze_method("typed_call", [{
      type: :call,
      receiver: "items",
      method: "sort",
      line: 4,
      known_time_complexity: "O(N log N)",
      known_space_complexity: "O(N)"
    }])
    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_equal "O(N)", result[:space_complexity]
    assert result[:time_complete]
    assert result[:space_complete]
    assert_empty result[:unknown_operations]
  end

  def test_unknown_loop_call_with_collection_argument_stays_unknown
    analyzer = Espalier::BigOAnalyzer.new(ivar_types: { "@widget" => "Widget" })
    result = analyzer.analyze_method("unknown", [{
      type: :call, receiver: "widget", method: "transform", line: 4,
      execution_complexity: "O(N)", collection_arguments: ["items"]
    }])
    assert_equal "unknown", result[:lower_bound_complexity]
    assert result[:warnings].any? { |warning| warning.include?("known collection parameter") }
    unresolved = analyzer.analyze_method("unknown_receiver", [{
      type: :call, receiver: "mystery", method: "transform", line: 5,
      execution_complexity: "O(N)", collection_arguments: ["items"]
    }])
    assert_equal "unknown", unresolved[:lower_bound_complexity]
  end

  def test_fact_mine_evidence_gaps_are_preserved_without_language_fallbacks
    analyzer = Espalier::BigOAnalyzer.new
    result = analyzer.analyze_method("partial", [{
      type: :call,
      receiver: "items",
      method: "custom_scan",
      line: 8,
      evidence_gap: "unmodeled_typed_operation"
    }])

    assert_equal "unknown", result[:lower_bound_complexity]
    assert_equal ["unmodeled_typed_operation"], result[:evidence_gaps]
    assert result[:warnings].first.include?("Fact-Mine did not provide")
  end

  def test_symbolic_collection_growth_preserves_all_input_domains_for_space
    rows = [
      { "id" => "param:Build:rows", "name" => "rows", "source_kind" => "parameter" },
      { "id" => "param:Build:columns", "name" => "columns", "source_kind" => "parameter" }
    ]
    fact = {
      "line" => 1, "parameters" => %w[rows columns], "iterations" => [],
      "recursion" => { "calls" => 0 }, "size_domains" => rows,
      "allocations" => [{
        "line" => 4, "kind" => "collection_growth", "cardinality_relation" => "same",
        "bound_classification" => "input", "symbolic_size" => {
          "factors" => [
            { "domain_id" => "param:Build:rows", "exponent" => 1 },
            { "domain_id" => "param:Build:columns", "exponent" => 1 }
          ], "complete" => true
        }
      }]
    }
    hint = Espalier::StructuralBigO.new(facts_by_method: { "build" => [fact] })
      .hints_for(nil, { id: "build", name: "build", line: 1 }, "Build").first

    assert_equal "O(N*M)", hint[:space]
    assert_equal %w[columns rows], Espalier::SymbolicComplexity.render(hint[:symbolic_space]).last.map { |value| value[:name] }
  end
end
