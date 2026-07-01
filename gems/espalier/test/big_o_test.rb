# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/big_o_analyzer"
require_relative "../lib/espalier/nil_kill_evidence"

class BigOTest < Minitest::Test
  def test_multiply_complexity
    analyzer = Espalier::BigOAnalyzer.new
    
    # Basic multiplications
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(1)", "O(N)")
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(N)", "O(1)")
    assert_equal "O(N^2)", analyzer.send(:multiply_complexity, "O(N)", "O(N)")
    assert_equal "O(N^3)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N)")
    assert_equal "O(N^5)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N^3)")
    assert_equal "O(N^2 log N)", analyzer.send(:multiply_complexity, "O(N log N)", "O(N)")
    assert_equal "O(N^3 log N)", analyzer.send(:multiply_complexity, "O(N^2 log N)", "O(N)")
    assert_equal "O(log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(1)")
    assert_equal "O(2^N)", analyzer.send(:multiply_complexity, "O(2^N)", "O(N)")
    assert_equal "O(N!)", analyzer.send(:multiply_complexity, "O(N!)", "O(N^3)")
  end

  def test_resolve_type_with_nil_kill_evidence
    ivar_types = {
      "@receiver_state" => "ReceiverState",
      "@items" => "Array"
    }

    # Mock NilKillEvidence signatures
    nil_kill = Object.new
    def nil_kill.method_signatures
      {
        "ReceiverState#scopes" => "sig { returns(T::Array[Scope]) }",
        "SemanticAnnotator#receiver_state" => "def receiver_state() -> ReceiverState"
      }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "SemanticAnnotator",
      ivar_types: ivar_types,
      nil_kill: nil_kill
    )

    # 1. Resolve 'self'
    assert_equal "SemanticAnnotator", analyzer.send(:resolve_type, "self", 10)

    # 2. Resolve ivar with @
    assert_equal "ReceiverState", analyzer.send(:resolve_type, "@receiver_state", 10)

    # 3. Resolve ivar without @
    assert_equal "Array", analyzer.send(:resolve_type, "items", 10)

    # 4. Resolve method call on self
    assert_equal "ReceiverState", analyzer.send(:resolve_type, "receiver_state", 10)

    # 5. Resolve dotted chain
    assert_equal "Array", analyzer.send(:resolve_type, "receiver_state.scopes", 10)
  end

  def test_analyze_method
    nil_kill_evidence = {
      "10" => { "items" => "Array" }
    }
    
    analyzer = Espalier::BigOAnalyzer.new(nil_kill_evidence: nil_kill_evidence)
    
    ast_mock = [
      { type: :call, receiver: "items", method: "sort", line: 10 },
      { type: :loop, line: 11 },
      { type: :callback, line: 12 }
    ]
    
    result = analyzer.analyze_method("process_items", ast_mock)
    
    assert_equal "process_items", result[:method]
    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
    assert_equal 1, result[:warnings].size
    assert_match(/Function pointer \/ callback/, result[:warnings].first)
  end

  def test_param_type_drives_sort_by_complexity
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method(
      "renumber",
      [{ type: :call, receiver: "segments", method: "sort_by", line: 10 }],
      local_types: { "segments" => "T::Array[Segment]" }
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
  end

  def test_hash_sort_is_n_log_n
    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Snapshot",
      ivar_types: { "@alloc_kinds" => "Hash" }
    )

    assert_equal "Array", analyzer.send(:resolve_type, "alloc_kinds.map", 10)

    result = analyzer.analyze_method(
      "summary",
      [{ type: :call, receiver: "alloc_kinds", method: "sort", line: 10 }]
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
  end

  def test_flattened_chain_uses_stdlib_return_type
    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Snapshot",
      ivar_types: { "@alloc_kinds" => "Hash" }
    )

    result = analyzer.analyze_method(
      "summary",
      [
        { type: :call, receiver: "alloc_kinds", method: "map", line: 10 },
        { type: :call, receiver: "alloc_kinds", method: "join", line: 10 }
      ]
    )

    assert_equal "O(N)", result[:lower_bound_complexity]
    refute_includes result[:unknown_operations], "Hash#join"
  end

  def test_flattened_same_line_chain_uses_accessor_return_type
    nil_kill = Object.new
    def nil_kill.method_signatures
      {}
    end
    def nil_kill.state_types
      { "FunctionCFG" => { "@blocks" => "Array" } }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "OwnershipDataflow",
      ivar_types: { "@cfg" => "FunctionCFG" },
      nil_kill: nil_kill
    )

    result = analyzer.analyze_method(
      "analyze!",
      [
        { type: :call, receiver: "cfg", method: "blocks", line: 20 },
        { type: :call, receiver: "cfg", method: "sort_by", line: 20 }
      ]
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    refute_includes result[:unknown_operations], "FunctionCFG#sort_by"

    accessor_result = analyzer.analyze_method(
      "blocks_only",
      [{ type: :call, receiver: "cfg", method: "blocks", line: 20 }]
    )

    assert_equal "O(1)", accessor_result[:lower_bound_complexity]
    refute_includes accessor_result[:unknown_operations], "FunctionCFG#blocks"
  end

  def test_flat_sequential_loop_evidence_does_not_imply_nested_exponent
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("sequential_loops", [
      { type: :loop, line: 10 },
      { type: :loop, line: 20 },
      { type: :loop, line: 30 }
    ])

    assert_equal "O(N)", result[:lower_bound_complexity]
  end

  def test_structural_hint_promotes_loop_contained_linear_work
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("fixpoint", [
      { type: :loop, line: 10 },
      {
        type: :structural,
        line: 12,
        complexity: "O(N^2)",
        operation: "items.each",
        reason: "linear stdlib call inside loop"
      }
    ])

    assert_equal "O(N^2)", result[:lower_bound_complexity]
    assert_match(/Structural Big-O hint/, result[:warnings].first)
  end

  def test_structural_hint_ranks_super_polynomial_work
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("search", [
      { type: :structural, line: 10, complexity: "O(N^4)", operation: "nested", reason: "nested loop containment depth 4" },
      { type: :structural, line: 20, complexity: "O(2^N)", operation: "fib", reason: "multiple recursive branches" },
      { type: :structural, line: 30, complexity: "O(N!)", operation: "permute", reason: "recursive branching over shrinking collection" }
    ])

    assert_equal "O(N!)", result[:lower_bound_complexity]
    assert_equal 3, result[:warnings].size
  end
end
