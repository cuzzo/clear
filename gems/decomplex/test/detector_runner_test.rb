# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require_relative "../lib/decomplex"

class DetectorRunnerTest < Minitest::Test
  FIXTURE = "gems/decomplex/test/fixtures/co_update_sample.rb"

  def test_co_update_ruby_engine_canonical_json_is_frozen
    expected = <<~JSON
      {"co_written_pairs":[{"pair":["provenance","storage"],"sites":["gems/decomplex/test/fixtures/co_update_sample.rb:stable_one","gems/decomplex/test/fixtures/co_update_sample.rb:stable_two","gems/decomplex/test/fixtures/co_update_sample.rb:stable_three"],"support":3}],"neglected_updates":[{"at":"gems/decomplex/test/fixtures/co_update_sample.rb:misses_provenance:17","has":"storage","missing":"provenance","pair":["provenance","storage"],"recv":"node","spans":{"gems/decomplex/test/fixtures/co_update_sample.rb:misses_provenance:17":[17,2,17,22]},"support":3}]}
    JSON

    assert_equal expected, Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby")
  end

  def test_co_update_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("co-update", [FIXTURE])

    assert ok, diff_message(ruby_json, rust_json)
    assert_equal ruby_json, rust_json
  end

  def test_miner_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-miner", ".rb"]) do |file|
      file.write(<<~RUBY)
        def one(a, b, c)
          a && b && c
        end

        def two(a, b, c)
          a && b && c
        end

        def three(a, b, c)
          a && b && c
        end

        def broken(a, b)
          a && b
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("miner", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_semantic_alias_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-semantic-alias", ".rb"]) do |file|
      file.write(<<~RUBY)
        def frame?; @provenance == :frame; end
        def is_frame?; provenance == :frame; end
        def heap?; @provenance == :heap; end
        def somewhere(node)
          return 1 if node.provenance == :frame
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("semantic-alias", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_predicate_alias_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-predicate-alias", ".rb"]) do |file|
      file.write(<<~RUBY)
        def first?; true; end
        def second?; true; end

        def nil_body; nil; end
        def other_nil_body; nil; end

        def setup
          super
          self[:type_params] ||= []
        end

        def type_params
          self[:type_params] ||= []
        end

        def emit_one
          <<~ZIG.chomp
            hi
          ZIG
        end

        def emit_two
          <<~ZIG.chomp
            bye
          ZIG
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("predicate-alias", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_decision_pressure_rust_engine_matches_ruby_engine_byte_for_byte
    skip "cargo is not available" unless cargo_available?

    Tempfile.create(["decomplex-decision-pressure", ".rb"]) do |file|
      file.write(<<~RUBY)
        def scan(node)
          value = node.respond_to?(:symbol) ? node.symbol&.reg : nil
          value.nil?
        ensure
          node&.cleanup
        end
      RUBY
      file.flush

      ok, ruby_json, rust_json = Decomplex::DetectorRunner.compare("decision-pressure", [file.path])

      assert ok, diff_message(ruby_json, rust_json)
      assert_equal ruby_json, rust_json
    end
  end

  def test_detector_cli_compare_engines_outputs_canonical_json
    skip "cargo is not available" unless cargo_available?

    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--compare-engines",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
  end

  def test_detector_cli_compare_engines_accepts_jobs
    skip "cargo is not available" unless cargo_available?

    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--compare-engines",
      "--jobs=2",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
  end

  def test_detector_cli_benchmark_keeps_json_stdout_canonical
    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--engine=ruby",
      "--json",
      "--benchmark",
      FIXTURE
    )

    assert status.success?, stderr
    assert_equal Decomplex::DetectorRunner.canonical_json("co-update", [FIXTURE], engine: "ruby"), stdout
    assert_match(/decomplex detector=co-update engine=ruby files=1 elapsed=\d+\.\d+s/, stderr)
  end

  private

  def cargo_available?
    system("cargo", "--version", out: File::NULL, err: File::NULL)
  end

  def diff_message(left, right)
    "ruby and rust detector output differed\n--- ruby\n#{left}\n--- rust\n#{right}"
  end
end
