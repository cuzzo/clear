# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "yaml"
require "zlib"

class KotlinStdlibMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  MAP_DIR = File.join(ROOT, "fact-mine", "config", "stdlib_maps")
  SUMMARY = File.join(
    ROOT,
    "fact-mine",
    "config",
    "complexity_summaries",
    "kotlin-stdlib.kotlin2.2.0.json.gz"
  )

  def test_manifest_pins_source_runtime_and_corrected_indexer
    manifest = YAML.safe_load(
      File.read(File.join(MAP_DIR, "kotlin-2.2.0.yml")),
      permitted_classes: [],
      aliases: false
    )
    assert_equal "kotlin", manifest.fetch("language")
    assert_equal "0.12.3", manifest.dig("index", "expected", "version").to_s
    assert_equal(
      "semanticdb maven . . kotlin/",
      manifest.dig("summary", "symbol_relocation", "from")
    )
    assert_equal(
      "scip-java maven . . kotlin/",
      manifest.dig("summary", "symbol_relocation", "to")
    )

    materializer = File.read(File.join(MAP_DIR, "kotlin", "materialize_source.rb"))
    assert_includes materializer, "967ad9599254e3a60d96d6c789547cc35c22d770d9c8fb1e3f15fac3b4c3b65d"
    assert_includes materializer, "65d12d85a3b865c160db9147851712a64b10dadd68b22eea22a95bf8a8670dca"

    patch = File.read(
      File.join(MAP_DIR, "kotlin", "scip-kotlin-top-level-symbols.patch")
    )
    assert_includes patch, "symbolProvider.getTopLevelCallableSymbols"
    assert_includes patch, "-                is FirFileSymbol -> containingSymbol.fir.declarations"
    assert_includes patch, "+                is FirFileSymbol ->"
  end

  def test_bundle_is_fail_closed_on_exact_runtime_digest
    summary = Zlib::GzipReader.open(SUMMARY) { |gzip| JSON.parse(gzip.read) }
    assert_equal "fact-mine.external-complexity-summary.v3", summary.fetch("schema")
    assert_operator summary.fetch("symbols").length, :>=, 80
    assert summary.fetch("symbols").keys.all? do |symbol|
      symbol.start_with?("scip-java maven . . kotlin/")
    end
    assert_equal(
      "sha256:65d12d85a3b865c160db9147851712a64b10dadd68b22eea22a95bf8a8670dca",
      summary.dig("compatibility", "claims", "kotlin.stdlib.binary.sha256")
    )
  end
end
