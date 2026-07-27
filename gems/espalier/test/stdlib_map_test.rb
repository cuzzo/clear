# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class StdlibMapTest < Minitest::Test
  class FakeRunner
    def initialize(raw_call_gaps: 0)
      @raw_call_gaps = raw_call_gaps
    end

    def run!(command, chdir:, env: {})
      raise "missing cwd" unless File.directory?(chdir)
      raise "unexpected env" unless env.is_a?(Hash)

      if command.first == "fake-index"
        File.write(command.fetch(1), "scip")
      elsif command.include?("profile")
        output = command.fetch(command.index("--output") + 1)
        sources = command.drop(command.index("--output") + 2)
        if (summary_index = sources.index("--complexity-summary"))
          sources.slice!(summary_index, 2)
        end
        File.write(output, JSON.generate({
          "input_coverage" => {
            "selected_files" => sources.length,
            "parsed_files" => sources.length
          },
          "semantic_indexes" => [{"tool" => "fake-scip", "version" => "1.2.3"}],
          "methods" => [{"source_export_eligible" => true}],
          "calls" => [],
          "call_resolution_coverage" => {
            "raw_calls_not_normalized_inside_function" => @raw_call_gaps
          }
        }))
      elsif File.basename(command.fetch(1)) == "export_complexity_summary.rb"
        output = command.last
        Zlib::GzipWriter.open(output) do |gzip|
          gzip.write(JSON.generate({
            "schema" => Espalier::StdlibMap::SUMMARY_SCHEMA,
            "source" => {
              "complete_symbol_count" => 1,
              "source_proven_method_count" => 1,
              "profile_sha256" => "sha256:test",
              "indexer" => "fake-scip@1.2.3"
            },
            "symbols" => {
              "fake pkg std 1 demo/run()." => {
                "time" => "O(1)",
                "space" => "O(1)"
              }
            }
          }))
        end
      else
        raise "unexpected command: #{command.inspect}"
      end
    end

    def capture(command, chdir:, env: {})
      raise "missing cwd" unless File.directory?(chdir)
      raise "unexpected env" unless env.is_a?(Hash)

      if command == ["fake-version"]
        ["fake-1\n", "", FakeStatus.new(true)]
      else
        raise "unexpected captured command: #{command.inspect}"
      end
    end

    FakeStatus = Struct.new(:success?)
  end

  def test_manifest_drives_index_profile_validation_export_and_publication
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      work = File.join(directory, "work")
      output = File.join(directory, "published", "stdlib.json.gz")
      binary = File.join(directory, "fact-mine-rust")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "keep.go"), "package demo\n")
      File.write(File.join(source, "skip_test.go"), "package demo\n")
      File.write(binary, "binary")
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: go
        source:
          root: source
          revision: fake-1
          revision_check:
            command: ["fake-version"]
            equals: fake-1
          include: ["**/*.go"]
          exclude: ["**/*_test.go"]
        index:
          command: ["fake-index", "{index}"]
          output: fake.scip
          expected:
            tool: fake-scip
            version: 1.2.3
        soundness:
          minimum_export_eligible_methods: 1
        summary:
          corpus: fake-stdlib
          output: #{output}
          minimum_symbols: 1
          expected_symbol_prefix: "fake pkg std 1 "
      YAML

      report = Espalier::StdlibMap.new(
        manifest,
        work_dir: work,
        fact_mine: binary,
        runner: FakeRunner.new
      ).run

      assert_equal 1, report.fetch("source_files")
      assert_equal "fake-1", report.fetch("source_revision")
      assert_equal 1, report.dig("summary", "symbols")
      assert_equal 0, report.dig("summary", "verified_join_call_sites")
      assert_equal 1, report.dig("profile", "source_export_eligible_methods")
      assert File.size?(output)
      assert File.exist?(File.join(work, "stdlib-map-report.json"))
    end
  end

  def test_manifest_rejects_partial_symbol_relocation
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "source"))
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: java
        source:
          root: source
          revision: fake-1
          revision_check:
            command: ["fake-version"]
            equals: fake-1
          include: ["**/*.java"]
        index:
          path: index.scip
          expected:
            tool: scip-java
            version: 1
        summary:
          corpus: jdk
          output: jdk.json.gz
          symbol_relocation:
            from: "temporary "
      YAML

      error = assert_raises(ArgumentError) { Espalier::StdlibMap.new(manifest) }
      assert_includes error.message, "requires from and to"
    end
  end

  def test_soundness_gate_rejects_parser_call_loss_before_publication
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      work = File.join(directory, "work")
      output = File.join(directory, "published", "stdlib.json.gz")
      binary = File.join(directory, "fact-mine-rust")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "keep.go"), "package demo\n")
      File.write(binary, "binary")
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: go
        source:
          root: source
          revision: fake-1
          revision_check:
            command: ["fake-version"]
            equals: fake-1
          include: ["**/*.go"]
        index:
          command: ["fake-index", "{index}"]
          expected:
            tool: fake-scip
            version: 1.2.3
        summary:
          corpus: fake-stdlib
          output: #{output}
      YAML

      error = assert_raises(RuntimeError) do
        Espalier::StdlibMap.new(
          manifest,
          work_dir: work,
          fact_mine: binary,
          runner: FakeRunner.new(raw_call_gaps: 1)
        ).run
      end
      assert_includes error.message, "parser calls without complete gap evidence"
      refute File.exist?(output)
    end
  end

  def test_source_revision_must_match_before_indexing
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, "source"))
      File.write(File.join(directory, "source", "keep.go"), "package demo\n")
      File.write(File.join(directory, "fact-mine-rust"), "binary")
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: go
        source:
          root: source
          revision: fake-2
          revision_check:
            command: ["fake-version"]
            equals: fake-2
          include: ["**/*.go"]
        index:
          command: ["fake-index", "{index}"]
          expected:
            tool: fake-scip
            version: 1.2.3
        summary:
          corpus: fake-stdlib
          output: stdlib.json.gz
      YAML

      error = assert_raises(RuntimeError) do
        Espalier::StdlibMap.new(
          manifest,
          work_dir: File.join(directory, "work"),
          fact_mine: File.join(directory, "fact-mine-rust"),
          runner: FakeRunner.new
        ).run
      end
      assert_includes error.message, "source revision mismatch"
    end
  end
end
