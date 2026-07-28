# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class JavascriptStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PROBE = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "javascript",
    "semantic_environment.rb"
  )

  def test_environment_probe_attests_node_and_v8
    Dir.mktmpdir do |directory|
      node = fake_tool(
        directory,
        "node",
        "echo '{\"node\":\"22.1.0\",\"v8\":\"12.4-test\",\"modules\":\"127\"}'"
      )
      indexer = fake_tool(directory, "scip-typescript", 'echo "scip-typescript 0.3.17"')
      output = File.join(directory, "environment.json")
      stdout, stderr, status = Open3.capture3(
        {"NODE" => node, "SCIP_TYPESCRIPT" => indexer},
        "ruby",
        PROBE,
        directory,
        output
      )
      assert status.success?, "#{stdout}\n#{stderr}"

      claims = JSON.parse(File.read(output)).fetch("claims")
      assert_equal "node", claims.fetch("javascript.runtime")
      assert_equal "22.1.0", claims.fetch("javascript.node.version")
      assert_equal "12.4-test", claims.fetch("javascript.v8.version")
      assert_equal "127", claims.fetch("javascript.node.modules_abi")
      assert claims.fetch("javascript.node.sha256").start_with?("sha256:")
    end
  end

  private

  def fake_tool(directory, name, body)
    path = File.join(directory, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end
end
