# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/ruby_to_clear/analysis"

class RubyToClearAnalysisVerifierSpec < Minitest::Test
  Verifier = RubyToClear::Analysis::Verifier
  Reporter = RubyToClear::Analysis::Reporter
  Inventory = RubyToClear::Analysis::DiagnosticInventory

  def test_failure_classification_is_conservative
    assert_equal "C0", Verifier.classify("ParserError: unexpected token")
    assert_equal "C0", Verifier.classify("lexer.rb:290:in `read': Lexer Error: Unclosed interpolation")
    assert_equal "C1", Verifier.classify("REQUIRE error: file not found")
    assert_equal "C1", Verifier.classify("[Compiler Error] [TYPO_SUGGESTION_REJECTED] Undefined function 'aST__moved?'")
    assert_equal "C2", Verifier.classify("type mismatch: expected Int")
    assert_equal "C2", Verifier.classify("[Compiler Error] [SELECT_NEEDS_LIST] Cannot SELECT from non-list type Tuple<String@symbol,Type[]>")
    assert_equal "C5", Verifier.classify("[Compiler Error] [ARG_ALIAS_CONFLICT] Cannot pass the same variable twice if one usage is MUTABLE. This violates exclusive mutability.")
    assert_equal "C5", Verifier.classify("[Compiler Error] Argument 1 is MUTABLE, but you passed immutable variable 'self'.")
    assert_equal "C6", Verifier.classify("[Compiler Error] [EFFECT_INFERENCE_VIOLATION] Call requires parameter 'self' to be bound under LOCAL.")
    assert_equal "C3", Verifier.classify("MIR ownership verification failed")
    assert_equal "C4", Verifier.classify("NoMethodError in emitter")
    diagnostic = "[Note] Pipeline accesses 1 of 4 fields (capability). Consider @soa.\n" \
                 "/repo/lowering.rb:42:in `lower': annotation admitted KEEP without retain lifecycle for Bool (RuntimeError)\n"
    assert_equal "/repo/lowering.rb:42:in `lower': annotation admitted KEEP without retain lifecycle for Bool (RuntimeError)", Verifier.primary_diagnostic_line(diagnostic)
    assert_equal "C4", Verifier.classify(diagnostic)
    assert_equal "Z0", Verifier.classify("anything", backend: true)
    assert_equal "H0", Verifier.classify("anything", timed_out: true, backend: true)
  end

  def test_frontend_failure_cannot_reclassify_a_parser_pass
    runner = Class.new do
      def run(argv, stdout_path:, stderr_path:, **)
        {
          "argv" => argv,
          "chdir" => nil,
          "exit_status" => 1,
          "term_signal" => nil,
          "timed_out" => false,
          "success" => false,
          "duration_seconds" => 0.001,
          "stdout_path" => stdout_path,
          "stderr_path" => stderr_path
        }
      end

      def diagnostic_text(_run)
        "[Compiler Error] Cannot infer depth from a fallible value."
      end
    end.new

    Dir.mktmpdir do |dir|
      generated_root = File.join(dir, "generated")
      FileUtils.mkdir_p(generated_root)
      File.write(File.join(generated_root, "example.clear"), "PASS;\n")
      verifier = Verifier.new(
        root: File.expand_path("../../../..", __dir__),
        manifest_path: "unused.json",
        artifacts_dir: dir,
        report_dir: dir,
        runner: runner,
        out: StringIO.new
      )
      verifier.instance_variable_set(:@artifact_root, dir)
      verifier.instance_variable_set(:@timeout_seconds, 1)
      verifier.instance_variable_set(:@manifest, { "packages" => {} })
      verifier.instance_variable_set(:@package_groups, {})
      verifier.instance_variable_set(:@generated_package_paths, {})
      candidate = unit(1, "pass", "pass", "not_run", "not_run").merge(
        "id" => "example",
        "source" => "example.rb",
        "generated_relative" => "example.clear",
        "commands" => {},
        "diagnostics" => []
      )

      verifier.send(:compile_frontend, candidate, generated_root, "raw")

      assert_equal "pass", candidate.dig("gates", "g2")
      assert_equal "fail", candidate.dig("gates", "g3")
      assert_equal "C4", candidate.dig("failure", "code")
    end
  end

  def test_g3_report_selects_prior_failures_without_filtering_generation_units
    Dir.mktmpdir do |dir|
      report_path = File.join(dir, "prior.json")
      File.write(report_path, JSON.generate(
        "units" => [
          { "source" => "compiler/ruby/a.rb", "gates" => { "g3" => "fail" } },
          { "source" => "compiler/ruby/b.rb", "gates" => { "g3" => "pass" } },
        ],
      ))
      verifier = Verifier.new(
        root: File.expand_path("../../../..", __dir__),
        manifest_path: "unused.json",
        artifacts_dir: dir,
        report_dir: dir,
        g3_from_report: report_path,
        out: StringIO.new,
      )
      units = [
        { "source" => "compiler/ruby/a.rb" },
        { "source" => "compiler/ruby/b.rb" },
        { "source" => "compiler/ruby/c.rb" },
      ]

      selected = verifier.send(:selected_g3_units, units)

      assert_equal ["compiler/ruby/a.rb"], selected.map { |unit| unit.fetch("source") }
      assert_equal 3, units.length
    end
  end

  def test_changed_g3_selection_includes_generated_reverse_dependents_and_scc_members
    verifier = Verifier.new(
      root: File.expand_path("../../../..", __dir__), manifest_path: "unused.json",
      artifacts_dir: Dir.tmpdir, report_dir: Dir.tmpdir, changed: "compiler/ruby/a.rb", out: StringIO.new
    )
    a = { "source" => "compiler/ruby/a.rb", "generated_relative" => "a.clear", "generated_dependencies" => [] }
    b = { "source" => "compiler/ruby/b.rb", "generated_relative" => "b.clear", "generated_dependencies" => ["a.clear"] }
    c = { "source" => "compiler/ruby/c.rb", "generated_relative" => "c.clear", "generated_dependencies" => ["b.clear"] }
    sibling = { "source" => "compiler/ruby/sibling.rb", "generated_relative" => "sibling.clear", "generated_dependencies" => ["c.clear"] }
    units = [a, b, c, sibling]
    verifier.instance_variable_set(:@g3_seed_units, [a])
    verifier.instance_variable_set(:@package_groups, { "scc_c_2" => ["c.clear", "sibling.clear"] })

    selected = verifier.send(:selected_changed_g3_units, units)

    assert_equal %w[a.clear b.clear c.clear sibling.clear], selected.map { |unit| unit.fetch("generated_relative") }
  end

  def test_incremental_frontend_rerun_discards_cached_failure_and_diagnostics
    verifier = Verifier.new(
      root: File.expand_path("../../../..", __dir__), manifest_path: "unused.json",
      artifacts_dir: Dir.tmpdir, report_dir: Dir.tmpdir,
      changed: "compiler/ruby/a.rb", out: StringIO.new
    )
    unit = {
      "gates" => { "g2" => "pass", "g3" => "fail", "g4" => "fail" },
      "failure" => { "code" => "C2", "fingerprint" => "old" },
      "diagnostics" => [
        { "stage" => "parser", "fingerprint" => "keep" },
        { "stage" => "frontend", "fingerprint" => "old frontend" },
        { "stage" => "backend", "fingerprint" => "old backend" },
      ],
      "autofix" => { "g4" => "fail" },
    }

    verifier.send(:reset_cached_frontend_result!, unit)

    assert_equal "not_run", unit.dig("gates", "g3")
    assert_equal "not_run", unit.dig("gates", "g4")
    refute unit.key?("failure")
    assert_equal ["keep"], unit.fetch("diagnostics").map { |diagnostic| diagnostic.fetch("fingerprint") }
    assert_equal({ "g4" => "not_run" }, unit.fetch("autofix"))
  end

  def test_incremental_cache_reuses_only_source_identical_raw_artifact
    Dir.mktmpdir do |dir|
      source = File.join(dir, "example.rb")
      File.write(source, "value = 1\n")
      cached_root = File.join(dir, "cached")
      cached_target = File.join(cached_root, "raw", "compiler", "src", "example.clear")
      FileUtils.mkdir_p(File.dirname(cached_target))
      File.write(cached_target, "VALUE = 1;\n")
      report_path = File.join(dir, "prior.json")
      File.write(report_path, "{}")
      verifier = Verifier.new(
        root: dir, manifest_path: "unused.json", artifacts_dir: dir, report_dir: dir,
        changed: "example.rb", reuse_report: report_path, out: StringIO.new
      )
      target = File.join(dir, "run", "example.clear")
      source_sha = Digest::SHA256.file(source).hexdigest
      unit = {
        "source" => "example.rb", "source_absolute" => source, "source_sha256" => source_sha,
        "generated_relative" => "example.clear", "raw_target" => target,
        "gates" => Verifier::GATE_DEFAULTS.dup, "commands" => {}, "diagnostics" => []
      }
      cached = {
        "source" => "example.rb", "source_sha256" => source_sha,
        "gates" => { "g0" => "pass", "g1" => "pass", "g2" => "pass", "g3" => "fail", "g4" => "skipped" },
        "generated_sha256" => "cached", "prism_nodes" => {}, "diagnostics" => []
      }
      verifier.instance_variable_set(:@reuse_artifact_root, cached_root)
      verifier.instance_variable_set(:@reuse_report_path, report_path)
      verifier.instance_variable_set(:@cached_units_by_source, { "example.rb" => cached })
      verifier.instance_variable_set(:@cache_hits, 0)
      verifier.instance_variable_set(:@reuse_frontend_results, false)

      verifier.send(:reuse_unit!, unit)

      assert_equal "pass", unit.dig("gates", "g2")
      assert_equal "not_run", unit.dig("gates", "g3")
      assert_equal "not_run", unit.dig("gates", "g4")
      assert_equal "VALUE = 1;\n", File.read(target)
      assert_equal 1, verifier.instance_variable_get(:@cache_hits)

      unit["source_sha256"] = "changed"
      FileUtils.rm_f(target)
      verifier.send(:reuse_unit!, unit)
      refute File.exist?(target)
    end
  end

  def test_toolchain_change_requires_explicit_focused_mode
    verifier = Verifier.new(
      root: File.expand_path("../../../..", __dir__), manifest_path: "unused.json",
      artifacts_dir: Dir.tmpdir, report_dir: Dir.tmpdir,
      changed: "compiler/ruby/a.rb", reuse_report: "/tmp/prior.json", out: StringIO.new
    )
    verifier.instance_variable_set(:@reuse_report, {
      "configuration" => { "transpiler_toolchain_sha256" => "old" }
    })
    verifier.instance_variable_set(:@transpiler_toolchain_sha256, "new")

    error = assert_raises(RuntimeError) { verifier.send(:validate_reuse_toolchain!) }
    assert_includes error.message, "--allow-toolchain-change"

    focused = Verifier.new(
      root: File.expand_path("../../../..", __dir__), manifest_path: "unused.json",
      artifacts_dir: Dir.tmpdir, report_dir: Dir.tmpdir,
      changed: "compiler/ruby/a.rb", reuse_report: "/tmp/prior.json",
      allow_toolchain_change: true, out: StringIO.new
    )
    focused.instance_variable_set(:@reuse_report, {
      "configuration" => { "transpiler_toolchain_sha256" => "old" }
    })
    focused.instance_variable_set(:@transpiler_toolchain_sha256, "new")
    focused.send(:validate_reuse_toolchain!)

    assert focused.instance_variable_get(:@reuse_toolchain_changed)
  end

  def test_changed_source_reuses_its_require_relative_consumers_for_g0_to_g2
    Dir.mktmpdir do |dir|
      source_root = File.join(dir, "src")
      checked_root = File.join(dir, "checked")
      FileUtils.mkdir_p(source_root)
      FileUtils.mkdir_p(checked_root)
      source_a = File.join(source_root, "a.rb")
      source_b = File.join(source_root, "b.rb")
      File.write(source_a, "VALUE = 1\n")
      File.write(source_b, "require_relative \"a\"\nVALUE\n")
      manifest = {
        "schema_version" => 1,
        "timeout_seconds" => 1,
        "corpus" => { "source_root" => "src", "generated_root" => "checked", "glob" => "**/*.rb", "exclude" => [] },
        "packages" => {}, "forbidden_output_patterns" => []
      }
      manifest_path = File.join(dir, "manifest.json")
      File.write(manifest_path, JSON.generate(manifest))
      cached_root = File.join(dir, "cached")
      %w[a b].each do |name|
        target = File.join(cached_root, "raw", "compiler", "src", "#{name}.clear")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "PASS;\n")
      end
      report = {
        "manifest_sha256" => Digest::SHA256.file(manifest_path).hexdigest,
        "artifact_root" => "cached",
        "configuration" => {
          "compiler_frontend_sha256" => "unavailable",
          "transpiler_toolchain_sha256" => Digest::SHA256.hexdigest(""),
        },
        "units" => [source_a, source_b].map do |source|
          {
            "source" => Pathname.new(source).relative_path_from(Pathname.new(dir)).to_s,
            "source_sha256" => Digest::SHA256.file(source).hexdigest,
            "gates" => { "g0" => "pass", "g1" => "pass", "g2" => "pass", "g3" => "pass", "g4" => "pass" },
            "diagnostics" => []
          }
        end
      }
      report_path = File.join(dir, "report.json")
      File.write(report_path, JSON.generate(report))
      verifier = Verifier.new(
        root: dir, manifest_path: manifest_path, artifacts_dir: File.join(dir, "runs"), report_dir: File.join(dir, "reports"),
        changed: "src/a.rb", reuse_report: report_path, out: StringIO.new
      )

      verifier.send(:load_manifest)
      assert_equal 90, verifier.timeout_seconds
      verifier.send(:prepare_run)
      units = verifier.send(:build_units)
      verifier.send(:prepare_incremental_reuse, units)

      assert_equal ["src/a.rb"], verifier.instance_variable_get(:@invalidated_units).map { |unit| unit.fetch("source") }
      assert_equal %w[src/a.rb src/b.rb], verifier.instance_variable_get(:@g3_seed_units).map { |unit| unit.fetch("source") }
      assert_equal "pass", units.find { |unit| unit.fetch("source") == "src/b.rb" }.dig("gates", "g2")
    end
  end

  def test_repeated_changed_run_preserves_the_reused_artifact_root
    Dir.mktmpdir do |dir|
      source_root = File.join(dir, "src")
      checked_root = File.join(dir, "checked")
      artifacts_dir = File.join(dir, "runs")
      FileUtils.mkdir_p(source_root)
      FileUtils.mkdir_p(checked_root)
      File.write(File.join(source_root, "a.rb"), "VALUE = 1\n")
      manifest = {
        "schema_version" => 1,
        "timeout_seconds" => 1,
        "corpus" => { "source_root" => "src", "generated_root" => "checked", "glob" => "**/*.rb", "exclude" => [] },
        "packages" => {}, "forbidden_output_patterns" => []
      }
      manifest_path = File.join(dir, "manifest.json")
      File.write(manifest_path, JSON.generate(manifest))
      revision = "0123456789abcdef"
      manifest_hash = Digest::SHA256.file(manifest_path).hexdigest[0, 12]
      changed_hash = Digest::SHA256.hexdigest("src/a.rb")[0, 12]
      run_id = "#{revision[0, 12]}-#{manifest_hash}-changed-#{changed_hash}"
      cached_root = File.join(artifacts_dir, run_id)
      cached_file = File.join(cached_root, "raw", "compiler", "src", "a.clear")
      FileUtils.mkdir_p(File.dirname(cached_file))
      File.write(cached_file, "VALUE = 1;\n")
      report_path = File.join(dir, "prior.json")
      File.write(report_path, JSON.generate("artifact_root" => Pathname.new(cached_root).relative_path_from(Pathname.new(dir)).to_s))

      verifier = Verifier.new(
        root: dir, manifest_path: manifest_path, artifacts_dir: artifacts_dir, report_dir: File.join(dir, "reports"),
        changed: "src/a.rb", reuse_report: report_path, out: StringIO.new
      )
      verifier.define_singleton_method(:git_revision) { revision }
      verifier.send(:load_manifest)
      verifier.send(:prepare_run)

      assert File.file?(cached_file), "the reuse source must survive prepare_run"
      refute_equal cached_root, verifier.instance_variable_get(:@artifact_root)
      assert_match(/-reuse-\d+\z/, verifier.instance_variable_get(:@artifact_root))
    end
  end

  def test_runner_cleans_up_its_process_group_when_interrupted
    runner_class = Class.new(RubyToClear::Analysis::Runner) do
      attr_reader :terminated_groups

      def initialize
        super
        @terminated_groups = []
      end

      private

      def terminate_group(pid)
        @terminated_groups << pid
        super
      end
    end
    runner = runner_class.new
    Dir.mktmpdir do |dir|
      interrupted = Queue.new
      thread = Thread.new do
        begin
          runner.run(
            [RbConfig.ruby, "-e", "sleep 30"], stdout_path: File.join(dir, "out"), stderr_path: File.join(dir, "err"),
            timeout_seconds: 60
          )
        rescue Interrupt => error
          interrupted << error
        end
      end
      sleep 0.05 until File.exist?(File.join(dir, "out"))
      thread.raise(Interrupt)
      thread.join

      assert_instance_of Interrupt, interrupted.pop
      assert_equal 1, runner.terminated_groups.length
    end
  end

  def test_partitions_cfg_facts_per_source_before_parallel_transpilation
    Dir.mktmpdir do |dir|
      source_a = File.join(dir, "a.rb")
      source_b = File.join(dir, "b.rb")
      File.write(source_a, "a\n")
      File.write(source_b, "b\n")
      payload = {
        "format" => "syntax-facts",
        "cfg_schema" => "fact-mine.cfg.v1",
        "documents" => [
          { "file" => source_a, "functions" => [{ "name" => "a" }] },
          { "file" => source_b, "functions" => [{ "name" => "b" }] }
        ]
      }
      batch_path = File.join(dir, "fact-mine-cfg.json")
      File.write(batch_path, JSON.generate(payload))
      verifier = Verifier.new(
        root: dir,
        manifest_path: "unused.json",
        artifacts_dir: dir,
        report_dir: dir,
        out: StringIO.new
      )
      verifier.instance_variable_set(:@artifact_root, dir)
      verifier.instance_variable_set(:@cfg_facts_path, batch_path)
      units = [
        { "id" => "a", "source_absolute" => source_a },
        { "id" => "b", "source_absolute" => source_b }
      ]

      verifier.send(:partition_cfg_facts, units)

      paths = verifier.instance_variable_get(:@cfg_facts_by_source)
      refute_equal paths.fetch(source_a), paths.fetch(source_b)
      assert_equal [source_a], JSON.parse(File.read(paths.fetch(source_a))).fetch("documents").map { |doc| doc.fetch("file") }
      assert_equal [source_b], JSON.parse(File.read(paths.fetch(source_b))).fetch("documents").map { |doc| doc.fetch("file") }
      assert_equal "fact-mine.cfg.v1", JSON.parse(File.read(paths.fetch(source_a))).fetch("cfg_schema")
    end
  end

  def test_aggregate_credits_complete_files_and_source_loc_only
    units = [
      unit(10, "pass", "pass", "pass", "pass"),
      unit(90, "pass", "pass", "fail", "skipped", "C3")
    ]

    aggregate = Reporter.aggregate(units)

    assert_equal 1, aggregate.dig("gates", "g4", "passed_files")
    assert_equal 10, aggregate.dig("gates", "g4", "passed_source_loc")
    assert_equal 10.0, aggregate.dig("gates", "g4", "source_loc_percent")
    assert_equal({ "C3" => 1 }, aggregate.fetch("failure_codes"))
  end

  def test_node_metrics_do_not_credit_failed_builds_as_compile_exercised
    passing = unit(1, "pass", "pass", "pass", "pass").merge("prism_nodes" => { "CallNode" => 2 })
    failing = unit(1, "pass", "pass", "fail", "skipped", "C3").merge("prism_nodes" => { "CallNode" => 7 })

    metrics = Reporter.node_metrics([passing, failing]).fetch("CallNode")

    assert_equal 9, metrics.fetch("encountered")
    assert_equal 9, metrics.fetch("handler_present")
    assert_equal 2, metrics.fetch("compile_exercised")
    assert_equal 0, metrics.fetch("behavior_verified")
  end

  def test_aggregate_separates_blocked_dependencies_from_primary_failures
    primary = unit(10, "fail", "skipped", "skipped", "skipped", "T0")
    blocked = unit(20, "pass", "fail", "skipped", "skipped", "C1")
    blocked.fetch("failure")["secondary"] = true
    blocked.fetch("failure")["blocked_by"] = [{ "source" => "provider.rb", "failure_code" => "T0" }]

    aggregate = Reporter.aggregate([primary, blocked])

    assert_equal({ "T0" => 1 }, aggregate.fetch("failure_codes"))
    assert_equal 1, aggregate.fetch("blocked_files")
    assert_equal 1, aggregate.fetch("failure_fingerprints").length
    assert_equal "T0", aggregate.fetch("failure_fingerprints").first.fetch("code")
  end

  def test_fingerprint_removes_unstable_paths_addresses_and_numbers
    fingerprint = Verifier.fingerprint("/tmp/run/file.clear:123: error at 0xdeadbeef")

    assert_equal "<path>:<n>: error at <hex>", fingerprint
  end

  def test_fingerprint_ignores_clear_test_wrapper
    fingerprint = Verifier.fingerprint("\e[31mTEST FAILED\e[0m\nfile.zig:13:7: error: unused local constant\n")

    assert_equal "error: unused local constant", fingerprint
  end

  def test_fingerprint_keeps_ruby_exception_message_and_relative_dependency
    exception = Verifier.fingerprint("/repo/lexer.rb:290:in `read': Lexer Error: Unclosed interpolation (RuntimeError)\n")
    dependency = Verifier.fingerprint("missing generated dependency: ast/type.clear")

    assert_equal "Lexer Error: Unclosed interpolation (RuntimeError)", exception
    assert_equal "missing generated dependency: ast/type.clear", dependency
  end

  def test_fingerprint_prefers_structured_compiler_message_over_exception_wrapper
    diagnostic = "/repo/source_error.rb:44:in `error!':  (CompilerError)\n" \
                 "[Compiler Error] Field 'borrowed' expected Bool, got NIL\n"

    assert_equal "[Compiler Error] Field 'borrowed' expected Bool, got NIL", Verifier.fingerprint(diagnostic)
    assert_equal "C2", Verifier.classify(diagnostic)
  end

  def test_diagnostic_inventory_extracts_each_ownership_violation
    diagnostic = <<~LOG
      /repo/compiler.rb:12:in `compile': MIR ownership verification failed (post-lowering): (RuntimeError)
      [ERRCLEANUP_WITHOUT_TRANSFER] initialize::__tmp_1 -- missing transfer
      [TRANSFER_WITHOUT_ALLOC] initialize::value -- missing allocation
    LOG

    rows = Inventory.extract(diagnostic, fallback_code: "C3", stage: "frontend")

    assert_equal 2, rows.length
    assert_equal %w[ERRCLEANUP_WITHOUT_TRANSFER TRANSFER_WITHOUT_ALLOC], rows.map { |row| row.fetch("subcategory") }
    assert rows.all? { |row| row.fetch("category") == "ownership_lifetime" }
  end

  def test_diagnostic_inventory_separates_mutability_from_ownership
    diagnostic = <<~LOG
      [Compiler Error] [ARG_ALIAS_CONFLICT] Aliasing Error: Cannot pass the same variable twice if one usage is MUTABLE. This violates exclusive mutability.
      Location: Line 12, Column 7
    LOG

    row = Inventory.extract(diagnostic, fallback_code: "C5", stage: "frontend").first

    assert_equal "C5", row.fetch("code")
    assert_equal "mutability", row.fetch("category")
    assert_equal "ARG_ALIAS_CONFLICT", row.fetch("subcategory")
  end

  def test_diagnostic_inventory_separates_effect_contracts_from_ownership
    diagnostic = <<~LOG
      [Compiler Error] [EFFECT_INFERENCE_VIOLATION] Call requires parameter 'self' to be bound under LOCAL.
      Location: Line 23, Column 12
    LOG

    row = Inventory.extract(diagnostic, fallback_code: "C6", stage: "frontend").first

    assert_equal "C6", row.fetch("code")
    assert_equal "effects_capabilities", row.fetch("category")
    assert_equal "EFFECT_INFERENCE_VIOLATION", row.fetch("subcategory")
  end

  def test_diagnostic_inventory_preserves_source_location
    diagnostic = <<~LOG
      [Compiler Error] Undefined function 'name'
      Location: Line 328, Column 38
        328 |   MUTABLE name = capability.var_node.name();
    LOG

    row = Inventory.extract(diagnostic, fallback_code: "C1", stage: "frontend").first

    assert_equal 328, row.fetch("line")
    assert_equal 38, row.fetch("column")
    assert_equal "MUTABLE name = capability.var_node.name();", row.fetch("source_excerpt")
    assert_equal "undefined_function", row.fetch("subcategory")
  end

  def test_diagnostic_aggregate_counts_dependency_amplification
    provider = unit(10, "pass", "pass", "fail", "skipped", "C1").merge(
      "source" => "scope.rb", "generated_relative" => "scope.clear",
      "diagnostics" => [diagnostic("scope.clear", "scope.clear")]
    )
    consumer = unit(20, "pass", "pass", "fail", "skipped", "C1").merge(
      "source" => "parser.rb", "generated_relative" => "parser.clear",
      "diagnostics" => [diagnostic("scope.clear", "parser.clear")]
    )

    inventory = Inventory.aggregate([provider, consumer])
    cluster = inventory.fetch("clusters").first

    assert_equal 1, inventory.fetch("unique_clusters")
    assert_equal 2, cluster.fetch("affected_roots")
    assert_equal 1, cluster.fetch("direct_roots")
    assert_equal 1, cluster.fetch("amplified_roots")
  end

  private

  def unit(loc, g1, g2, g3, g4, failure = nil)
    value = {
      "source_loc" => loc,
      "gates" => { "g0" => "pass", "g1" => g1, "g2" => g2, "g3" => g3, "g4" => g4, "g5" => "not_configured" },
      "prism_nodes" => {},
      "autofix" => { "g4" => "not_run" }
    }
    value["failure"] = { "code" => failure, "fingerprint" => "failure" } if failure
    value
  end

  def diagnostic(provider, observed_root)
    {
      "code" => "C1", "category" => "name_resolution", "subcategory" => "undefined_function",
      "fingerprint" => "[Compiler Error] Undefined function 'name'", "provider" => provider,
      "line" => 328, "generated_relative" => observed_root
    }
  end
end
