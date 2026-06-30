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
    assert_equal "O(N^2 log N)", analyzer.send(:multiply_complexity, "O(N log N)", "O(N)")
    assert_equal "O(N^3 log N)", analyzer.send(:multiply_complexity, "O(N^2 log N)", "O(N)")
    assert_equal "O(log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(1)")
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

  def test_flat_sequential_loop_evidence_does_not_imply_nested_exponent
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("sequential_loops", [
      { type: :loop, line: 10 },
      { type: :loop, line: 20 },
      { type: :loop, line: 30 }
    ])

    assert_equal "O(N)", result[:lower_bound_complexity]
  end
end
