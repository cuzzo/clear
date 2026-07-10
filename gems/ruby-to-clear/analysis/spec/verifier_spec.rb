# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_to_clear/analysis"

class RubyToClearAnalysisVerifierSpec < Minitest::Test
  Verifier = RubyToClear::Analysis::Verifier
  Reporter = RubyToClear::Analysis::Reporter

  def test_failure_classification_is_conservative
    assert_equal "C0", Verifier.classify("ParserError: unexpected token")
    assert_equal "C0", Verifier.classify("lexer.rb:290:in `read': Lexer Error: Unclosed interpolation")
    assert_equal "C1", Verifier.classify("REQUIRE error: file not found")
    assert_equal "C2", Verifier.classify("type mismatch: expected Int")
    assert_equal "C3", Verifier.classify("MIR ownership verification failed")
    assert_equal "C4", Verifier.classify("NoMethodError in emitter")
    assert_equal "Z0", Verifier.classify("anything", backend: true)
    assert_equal "H0", Verifier.classify("anything", timed_out: true, backend: true)
  end

  def test_aggregate_credits_complete_files_and_source_loc_only
    units = [
      unit(10, "pass", "pass", "pass", "pass"),
      unit(90, "pass", "pass", "fail", "skipped", "C3")
    ]

    aggregate = Reporter.aggregate(units)

    assert_equal 1, aggregate.dig("gates", "g4", "passed_files")
    assert_equal 10, aggregate.dig("gates", "g4", "passed_source_loc")
    assert_equal 10.0, aggregate.dig("gates", "g4", "source_loc_percent")
    assert_equal({ "C3" => 1 }, aggregate.fetch("failure_codes"))
  end

  def test_node_metrics_do_not_credit_failed_builds_as_compile_exercised
    passing = unit(1, "pass", "pass", "pass", "pass").merge("prism_nodes" => { "CallNode" => 2 })
    failing = unit(1, "pass", "pass", "fail", "skipped", "C3").merge("prism_nodes" => { "CallNode" => 7 })

    metrics = Reporter.node_metrics([passing, failing]).fetch("CallNode")

    assert_equal 9, metrics.fetch("encountered")
    assert_equal 9, metrics.fetch("handler_present")
    assert_equal 2, metrics.fetch("compile_exercised")
    assert_equal 0, metrics.fetch("behavior_verified")
  end

  def test_fingerprint_removes_unstable_paths_addresses_and_numbers
    fingerprint = Verifier.fingerprint("/tmp/run/file.clear:123: error at 0xdeadbeef")

    assert_equal "<path>:<n>: error at <hex>", fingerprint
  end

  def test_fingerprint_ignores_clear_test_wrapper
    fingerprint = Verifier.fingerprint("\e[31mTEST FAILED\e[0m\nfile.zig:13:7: error: unused local constant\n")

    assert_equal "error: unused local constant", fingerprint
  end

  def test_fingerprint_keeps_ruby_exception_message_and_relative_dependency
    exception = Verifier.fingerprint("/repo/lexer.rb:290:in `read': Lexer Error: Unclosed interpolation (RuntimeError)\n")
    dependency = Verifier.fingerprint("missing generated dependency: ast/type.clear")

    assert_equal "Lexer Error: Unclosed interpolation (RuntimeError)", exception
    assert_equal "missing generated dependency: ast/type.clear", dependency
  end

  def test_fingerprint_prefers_structured_compiler_message_over_exception_wrapper
    diagnostic = "/repo/source_error.rb:44:in `error!':  (CompilerError)\n" \
                 "[Compiler Error] Field 'borrowed' expected Bool, got NIL\n"

    assert_equal "[Compiler Error] Field 'borrowed' expected Bool, got NIL", Verifier.fingerprint(diagnostic)
    assert_equal "C2", Verifier.classify(diagnostic)
  end

  private

  def unit(loc, g1, g2, g3, g4, failure = nil)
    value = {
      "source_loc" => loc,
      "gates" => { "g0" => "pass", "g1" => g1, "g2" => g2, "g3" => g3, "g4" => g4, "g5" => "not_configured" },
      "prism_nodes" => {},
      "autofix" => { "g4" => "not_run" }
    }
    value["failure"] = { "code" => failure, "fingerprint" => "failure" } if failure
    value
  end
end
