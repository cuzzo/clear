# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "zlib"

class CsharpStdlibMapTest < Minitest::Test
  SCRIPT = File.expand_path(
    "../../fact-mine/config/stdlib_maps/csharp/build_symbol_bridge.rb",
    __dir__
  )

  def test_bridge_maps_only_runtime_backed_corelib_owners
    Dir.mktmpdir do |directory|
      summary = File.join(directory, "summary.json.gz")
      output = File.join(directory, "bridge.json")
      Zlib::GzipWriter.open(summary) do |gzip|
        gzip.write(JSON.generate({
          "symbols" => {
            "scip-dotnet nuget . . System/String#Trim()." => {},
            "scip-dotnet nuget . . Generic/List#Add()." => {},
            "scip-dotnet nuget . . Collections/ArrayList#Count." => {},
            "scip-dotnet nuget . . Collections/ListDictionaryInternal#Add()." => {}
          }
        }))
      end

      assert system(RbConfig.ruby, SCRIPT, summary, output, "10.0.0.0")
      bridge = JSON.parse(File.read(output))
      assert_equal "fact-mine.symbol-bridge.v1", bridge.fetch("schema")
      assert_equal(
        "scip-dotnet nuget System.Runtime 10.0.0.0 System/String#Trim().",
        bridge.dig("symbols", "scip-dotnet nuget . . System/String#Trim().")
      )
      assert_equal(
        "scip-dotnet nuget System.Collections 10.0.0.0 Generic/List#Add().",
        bridge.dig("symbols", "scip-dotnet nuget . . Generic/List#Add().")
      )
      assert_equal(
        "scip-dotnet nuget System.Collections.NonGeneric 10.0.0.0 Collections/ArrayList#Count.",
        bridge.dig("symbols", "scip-dotnet nuget . . Collections/ArrayList#Count.")
      )
      refute bridge.fetch("symbols").key?(
        "scip-dotnet nuget . . Collections/ListDictionaryInternal#Add()."
      )
    end
  end
end
