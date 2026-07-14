# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/big_o_analyzer"
require_relative "../lib/espalier/structural_big_o"

class BigOTest < Minitest::Test
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

  def test_type_resolution_and_chained_stdlib_calls
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
      nil_kill: nil_kill, local_types: { "users" => "T.nilable(T::Array[User])" }
    )
    assert_equal "Owner", analyzer.send(:resolve_type, "self", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "items", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "users", 1)
    assert_equal "Array", analyzer.send(:resolve_type, "cfg.blocks", 1)

    result = analyzer.analyze_method("sort", [
      { type: :call, receiver: "cfg", method: "blocks", line: 2 },
      { type: :call, receiver: "cfg", method: "sort_by", line: 2 }
    ])
    assert_equal "O(N log N)", result[:lower_bound_complexity]
    refute_includes result[:unknown_operations], "FunctionCFG#sort_by"

    chain = analyzer.analyze_method("join", [
      { type: :call, receiver: "values", method: "map", line: 3 },
      { type: :call, receiver: "values", method: "join", line: 3 }
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
      { type: :call, receiver: "thing", method: "work", line: 1 },
      { type: :call, receiver: "mystery", method: "work", line: 2 },
      { type: :yield, line: 3 }
    ])
    assert_includes result[:unknown_operations], "Widget#work"
    assert_includes result[:unknown_operations], "mystery.work"
    assert_equal "unknown", result[:lower_bound_complexity]
    assert_equal "O(1)", result[:known_time_component]
    refute result[:time_complete]
    refute result[:space_complete]
    assert_equal 3, result[:warnings].size
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
    assert_nil consumer.send(:allocation_complexity, [])
    assert_equal "unknown", consumer.send(:allocation_complexity, [{ "cardinality_relation" => "unknown" }])
    assert_equal "O(N)", consumer.send(:allocation_complexity, [{ "bound_classification" => "input" }])
    assert_equal "O(1)", consumer.send(:allocation_complexity, [{ "bound_classification" => "fixed" }])
    assert_equal "O(N)", consumer.send(:max_space_complexity, nil, "O(N)")
    assert_equal "O(N)", consumer.send(:max_space_complexity, "O(N)", nil)
    assert_equal "unknown", consumer.send(:max_space_complexity, "unknown", "O(N)")
    assert_equal "O(N)", consumer.send(:max_space_complexity, "O(N)", "O(log N)")
    assert_equal "O(N)", consumer.send(:propagated_call_complexity, {
      "execution_multiplicity" => "O(N)", "argument_cardinality_relation" => "partition_of"
    }, "O(N)")
    assert_equal "unknown", consumer.send(:propagated_call_complexity, {
      "execution_multiplicity" => "O(N)", "argument_cardinality_relation" => "unknown"
    }, "O(N)")

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
    unknown = consumer.send(:summary_hint, {
      "line" => 9, "parameters" => ["items"], "recursion" => { "calls" => 0 },
      "iterations" => [{ "power" => 1, "cardinality_relation" => "unknown", "execution_multiplicity" => "unknown" }]
    }, { line: 9 })
    assert_equal "unknown", unknown[:complexity]
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
    assert_equal 1, analyzer.send(:space_complexity_rank, "unknown")
  end

  def test_normalized_call_execution_context_multiplies_operation_cost
    analyzer = Espalier::BigOAnalyzer.new(local_types: { "items" => "Array" })
    result = analyzer.analyze_method("repeated_sort", [{
      type: :call, receiver: "items", method: "sort", line: 4,
      execution_complexity: "O(N)"
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
end
