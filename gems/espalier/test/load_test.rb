# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class EspalierLoadTest < Minitest::Test
  def test_loading_public_entrypoint_has_no_constant_warnings
    lib = File.expand_path("../lib", __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-w",
      "-I",
      lib,
      "-e",
      'require "espalier"'
    )

    assert status.success?, stderr
    refute_includes stderr, "already initialized constant Espalier::ROOT"
  end

  def test_static_evidence_can_be_loaded_without_public_entrypoint
    lib = File.expand_path("../lib", __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      lib,
      "-e",
      'require "espalier/static_evidence"'
    )

    assert status.success?, stderr
  end
end
