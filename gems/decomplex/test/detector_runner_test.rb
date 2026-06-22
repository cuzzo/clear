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

  def test_native_command_language_for_recognizes_jvm_and_swift_extensions
    assert_equal "java", Decomplex::Native::Command.language_for("Example.java")
    assert_equal "kotlin", Decomplex::Native::Command.language_for("Example.kt")
    assert_equal "kotlin", Decomplex::Native::Command.language_for("Example.kts")
    assert_equal "swift", Decomplex::Native::Command.language_for("Example.swift")
  end

  def test_detector_cli_json_outputs_canonical_json
    stdout, stderr, status = Open3.capture3(
      "ruby",
      "gems/decomplex/exe/decomplex",
      "detector",
      "co-update",
      "--engine=ruby",
      "--json",
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
end
