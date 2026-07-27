# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class StdlibMapTest < Minitest::Test
  class FakeRunner
    def initialize(raw_call_gaps: 0)
      @raw_call_gaps = raw_call_gaps
      @index_working_directory = nil
    end

    attr_reader :index_working_directory

    def run!(command, chdir:, env: {})
      raise "missing cwd" unless File.directory?(chdir)
      raise "unexpected env" unless env.is_a?(Hash)

      if command.first == "fake-index"
        @index_working_directory = chdir
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
            "raw_calls_not_normalized_inside_function" => @raw_call_gaps,
            "source_export_eligible_methods_overlapping_raw_call_loss" => @raw_call_gaps
          }
        }))
      elsif command.length > 1 && File.basename(command.fetch(1)) == "export_complexity_summary.rb"
        output = command.last
        prefix = if command.include?("--symbol-prefix-from")
                   command.fetch(command.index("--symbol-prefix-to") + 1)
                 else
                   "fake pkg std 1 "
                 end
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
              "#{prefix}demo/run()." => {
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
      elsif File.basename(command.fetch(1, "")) == "check_big_o_coverage.rb"
        [
          JSON.generate({
            "coverage" => {
              "functions" => 1,
              "mapped" => 1,
              "incomplete" => 0,
              "mapped_percent" => 100.0
            }
          }),
          "",
          FakeStatus.new(true)
        ]
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
      FileUtils.mkdir_p(File.join(directory, "consumer"))
      File.write(File.join(source, "keep.go"), "package demo\n")
      File.write(File.join(source, "skip_test.go"), "package demo\n")
      File.write(File.join(directory, "consumer", "use.go"), "package consumer\n")
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
          expected_symbol_prefix: "fake consumer std 1 "
          symbol_relocation:
            from: "fake pkg std 1 "
            to: "fake consumer std 1 "
        consumers:
          - name: fake-consumer
            source_root: consumer
            include: ["*.go"]
            index:
              command: ["fake-index", "{index}"]
              output: consumer.scip
            minimum_complete_percent: 100
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
      assert_equal 0, report.dig("producer_summary", "verified_join_call_sites")
      assert_equal 1, report.dig("profile", "source_export_eligible_methods")
      assert_equal 1, report.fetch("consumers").length
      assert_equal 100.0, report.dig("consumers", 0, "after", "mapped_percent")
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
      assert_includes error.message, "analyzer eligibility revocation is unsound"
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

  def test_git_source_requires_a_full_pinned_commit
    Dir.mktmpdir do |directory|
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: java
        source:
          revision: jdk-21
          git:
            repository: https://example.test/jdk.git
            commit: deadbeef
          include: ["**/*.java"]
        index:
          path: index.scip
          expected:
            tool: scip-java
            version: 1
        summary:
          corpus: jdk
          output: jdk.json.gz
      YAML

      error = assert_raises(ArgumentError) { Espalier::StdlibMap.new(manifest) }
      assert_includes error.message, "full 40-character commit"
    end
  end

  def test_selected_source_can_be_staged_for_indexers_that_scan_the_whole_workspace
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      work = File.join(directory, "work")
      binary = File.join(directory, "fact-mine-rust")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "keep.py"), "def keep(): pass\n")
      File.write(File.join(source, "broken.py"), "this indexer must not see me\n")
      File.write(binary, "binary")
      manifest = File.join(directory, "stdlib.yml")
      File.write(manifest, <<~YAML)
        schema: fact-mine.stdlib-map.v1
        language: python
        source:
          root: source
          revision: fake-1
          revision_check:
            command: ["fake-version"]
            equals: fake-1
          include: ["keep.py"]
          stage_selected_files: true
        index:
          command: ["fake-index", "{index}"]
          expected:
            tool: fake-scip
            version: 1.2.3
        summary:
          corpus: fake-stdlib
          output: stdlib.json.gz
      YAML
      runner = FakeRunner.new

      report = Espalier::StdlibMap.new(
        manifest,
        work_dir: work,
        fact_mine: binary,
        runner: runner
      ).run

      assert_equal File.join(work, "selected-source"), runner.index_working_directory
      assert File.file?(File.join(work, "selected-source", "keep.py"))
      refute File.exist?(File.join(work, "selected-source", "broken.py"))
      assert_equal File.join(work, "selected-source"), report.fetch("analysis_root")
    end
  end

  def test_support_inventory_has_artifacts_for_bundled_languages_and_reasons_for_blocked_ones
    root = File.expand_path("../..", __dir__)
    directory = File.join(root, "fact-mine", "config", "stdlib_maps")
    support = YAML.safe_load(
      File.read(File.join(directory, "support.yml")),
      permitted_classes: [],
      aliases: false
    )
    assert_equal "fact-mine.stdlib-map-support.v1", support.fetch("schema")
    refute_empty support.fetch("languages")

    support.fetch("languages").each do |language, entry|
      case entry.fetch("status")
      when "bundled"
        manifest_path = File.join(directory, entry.fetch("manifest"))
        assert File.file?(manifest_path), "#{language} manifest is missing"
        manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
        output = File.expand_path(
          manifest.fetch("summary").fetch("output"),
          File.dirname(manifest_path)
        )
        assert File.size?(output), "#{language} generated summary is missing"
      when "blocked"
        refute_empty entry.fetch("blocker"), "#{language} blocker is missing"
        refute_empty entry.fetch("required_fix"), "#{language} required fix is missing"
      else
        flunk "#{language} has unsupported stdlib-map status #{entry['status'].inspect}"
      end
    end
  end
end
