# frozen_string_literal: true

require "minitest/autorun"
require "open3"
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
