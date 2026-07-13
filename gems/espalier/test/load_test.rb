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
end
