# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class CStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PROBE = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "c",
    "semantic_environment.rb"
  )

  def test_environment_probe_attests_unversioned_c_symbols
    Dir.mktmpdir do |directory|
      compiler = fake_tool(directory, "clang", <<~SH)
        case "$1" in
          --version) echo "test clang 20" ;;
          -dumpmachine) echo "x86_64-test-linux-gnu" ;;
          *) echo "#define TEST_ABI 1" ;;
        esac
      SH
      indexer = fake_tool(directory, "scip-clang", 'echo "scip-clang 0.4.0"')
      libc = fake_tool(directory, "libc.so.6", 'echo "test glibc 2.39"')
      header = File.join(directory, "string.h")
      File.write(header, "void *memcpy(void *, const void *, unsigned long);\n")
      File.write(
        File.join(directory, "compile_commands.json"),
        JSON.generate([{
          "arguments" => [compiler, "-std=c17", "-DTEST=1", "-c", "probe.c"]
        }])
      )
      output = File.join(directory, "environment.json")
      stdout, stderr, status = Open3.capture3(
        {
          "SCIP_CLANG" => indexer,
          "C_LIBC_BINARY" => libc,
          "C_LIBC_HEADERS" => header
        },
        "ruby",
        PROBE,
        directory,
        output
      )
      assert status.success?, "#{stdout}\n#{stderr}"

      environment = JSON.parse(File.read(output))
      assert_equal "fact-mine.semantic-environment.v1", environment.fetch("schema")
      claims = environment.fetch("claims")
      assert_equal "test glibc 2.39", claims.fetch("c.libc.release")
      assert_equal "x86_64-test-linux-gnu", claims.fetch("c.compiler.target")
      assert_equal "scip-clang 0.4.0", claims.fetch("c.scip_clang.version")
      assert claims.fetch("c.libc.binary.sha256").start_with?("sha256:")
      assert claims.fetch("c.preprocessor_macros.sha256").start_with?("sha256:")
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
