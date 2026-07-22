# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"
require_relative "../lib/slopcop"

class SlopcopReportCovTest < Minitest::Test
  # --- Classifier Tests ---
  def test_classifier_merged_branches
    Dir.mktmpdir do |dir|
      resultset = "#{dir}/rs.json"
      File.write(resultset, "{}")
      SlopCop::CoverageData.stub :load, {} do
        assert_equal({}, SlopCop::Classifier.merged_branches(resultset, "a.rb", root: dir))
      end
    end
  end

  def test_coverage_data_merges_branch_hashes_with_missing_arm_defaults
    dir = Dir.mktmpdir
    file = File.join(dir, "a.rb")
    File.write(file, "def f\n  1\nend\n")

    first = SlopCop::CoverageData::Dataset.new(
      path: "first",
      files: {
        file => SlopCop::CoverageData::FileCoverage.new(
          file: file,
          lines: [1],
          branches: { "if:1" => { "then" => 1 } },
          format: :simplecov,
          branch_arms: [],
          source_path: "a.rb",
          language: :ruby
        )
      }
    )
    second = SlopCop::CoverageData::Dataset.new(
      path: "second",
      files: {
        file => SlopCop::CoverageData::FileCoverage.new(
          file: file,
          lines: [1],
          branches: { "if:1" => { "else" => 2 } },
          format: :simplecov,
          branch_arms: [],
          source_path: "a.rb",
          language: :ruby
        )
      }
    )

    merged = SlopCop::CoverageData.merge_datasets("merged", [first, second])

    assert_equal({ "then" => 1, "else" => 2 }, merged.files.fetch(file).branches.fetch("if:1"))
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def test_classifier_classify_static_file_error
    SlopCop::Classifier.stub :get_branch_arms, ->(*) { raise StandardError, "forced error" } do
      assert_equal [], SlopCop::Classifier.classify_static_file("a.rb")
    end
  end

  def test_classifier_classify_coverage_file_error
    SlopCop::Classifier.stub :get_branch_arms, ->(*) { raise StandardError, "forced error" } do
      assert_equal [], SlopCop::Classifier.classify_coverage_file("a.rb", nil)
    end
  end

  def test_classifier_get_branch_arms_not_executable
    ENV["DECOMPLEX_RUST_BINARY"] = "/missing-binary-path"
    assert_equal [], SlopCop::Classifier.get_branch_arms("a.rb")
    ENV["DECOMPLEX_RUST_BINARY"] = nil
  end

  def test_classifier_get_branch_arms_failed_execution
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bad-bin")
      File.write(bin, "#!/bin/sh\nexit 1\n")
      FileUtils.chmod("+x", bin)
      ENV["DECOMPLEX_RUST_BINARY"] = bin
      assert_raises(RuntimeError) do
        SlopCop::Classifier.get_branch_arms("a.rb")
      end
    end
    ENV["DECOMPLEX_RUST_BINARY"] = nil
  end

  def test_classifier_language_for
    c = SlopCop::Classifier
    assert_equal :ruby, c.language_for("a.rb")
    assert_equal :python, c.language_for("a.py")
    assert_equal :javascript, c.language_for("a.js")
    assert_equal :javascript, c.language_for("a.jsx")
    assert_equal :javascript, c.language_for("a.mjs")
    assert_equal :javascript, c.language_for("a.cjs")
    assert_equal :java, c.language_for("a.java")
    assert_equal :typescript, c.language_for("a.ts")
    assert_equal :typescript, c.language_for("a.tsx")
    assert_equal :swift, c.language_for("a.swift")
    assert_equal :kotlin, c.language_for("a.kt")
    assert_equal :kotlin, c.language_for("a.kts")
    assert_equal :go, c.language_for("a.go")
    assert_equal :rust, c.language_for("a.rs")
    assert_equal :zig, c.language_for("a.zig")
    assert_equal :lua, c.language_for("a.lua")
    assert_equal :c, c.language_for("a.c")
    assert_equal :c, c.language_for("a.h")
    assert_equal :cpp, c.language_for("a.cpp")
    assert_equal :cpp, c.language_for("a.cc")
    assert_equal :cpp, c.language_for("a.cxx")
    assert_equal :cpp, c.language_for("a.hpp")
    assert_equal :cpp, c.language_for("a.hh")
    assert_equal :cpp, c.language_for("a.hxx")
    assert_equal :csharp, c.language_for("a.cs")
    assert_equal :php, c.language_for("a.php")
    assert_nil c.language_for("a.unknown")
  end

  def test_classify_file_static_fallback
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rb")
      File.write(file, "def foo\n  x = 1\nend\n")
      
      mock_arm = {
        "file" => file,
        "function" => "foo",
        "kind" => "if",
        "line" => 2,
        "span" => [2, 0, 2, 10],
        "decision_span" => [2, 0, 2, 10],
        "predicate" => "x == 1",
        "body" => "1"
      }
      
      SlopCop::Classifier.stub :get_branch_arms, [mock_arm] do
        arms = SlopCop::Classifier.classify_file(nil, file)
        assert_equal 1, arms.size
        assert_equal :tree_sitter_static, arms.first.source
      end
    end
  end

  def test_classifier_coverage_for_rescue
    SlopCop::CoverageData.stub :load, ->(*) { raise StandardError, "load error" } do
      assert_nil SlopCop::Classifier.coverage_for("/some/file", "a.rb")
    end
  end

  def test_classifier_tree_sitter_helper
    assert SlopCop::Classifier.tree_sitter?
  end

  def test_classifier_get_branch_arms_success_parsing
    payload = {
      "documents" => [
        { "branch_arms" => [{ "function" => "foo" }] }
      ]
    }
    
    File.stub :executable?, true do
      IO.stub :popen, ->(*_args, &block) { system("true"); block.call(StringIO.new(payload.to_json)) } do
        arms = SlopCop::Classifier.get_branch_arms("a.rb")
        assert_equal 1, arms.size
        assert_equal "foo", arms.first["function"]
      end
    end
  end

  def test_classifier_categorize_text_fallback
    cat = SlopCop::Classifier.categorize_text("foo", :other_kind, "body", true)
    assert_equal :defensive, cat
  end

  # --- DecomplexVerdict Tests ---
  def test_decomplex_verdict_detector_title_and_tier
    t1, tr1 = SlopCop::DecomplexVerdict.detector_title_and_tier("semantic_predicate_aliases")
    assert_equal "Semantic Predicate Aliases", t1
    assert_equal 1, tr1

    t2, tr2 = SlopCop::DecomplexVerdict.detector_title_and_tier("exact_predicate_aliases")
    assert_equal "Exact Predicate Aliases", t2
    assert_equal 1, tr2
  end

  def test_decomplex_verdict_lookup_fallback_coarse
    verdict = {
      spans: {},
      m_all: { ["a.rb", "foo"] => { "Decision Pressure" => true } },
      m_spur: { ["a.rb", "foo"] => false },
      m_devw: { ["a.rb", "foo"] => { "Decision Pressure" => 1 } }
    }
    res = SlopCop::DecomplexVerdict.lookup(verdict, "a.rb", "foo", 5)
    refute_nil res
    refute res[:precise]
    assert_equal 1, res[:deviance]
    assert_includes res[:detectors], "Decision Pressure"
  end

  def test_decomplex_verdict_load_facts_file
    Dir.mktmpdir do |dir|
      file = File.join(dir, "facts.json")
      File.write(file, JSON.dump({ "detectors" => { "foo" => 1 } }))
      
      ENV["DECOMPLEX_FACTS_FILE"] = file
      res = SlopCop::DecomplexVerdict.send(:load_decomplex_facts, ["a.rb"])
      assert_equal :ok, res[:status]
      assert_equal 1, res[:detectors]["foo"]
    ensure
      ENV["DECOMPLEX_FACTS_FILE"] = nil
    end
  end

  # --- Rollup Tests ---
  def test_rollup_run_with_churn_file
    Dir.mktmpdir do |dir|
      churn_file = File.join(dir, "churn.json")
      File.write(churn_file, JSON.dump({ "a.rb" => 10.0 }))
      
      ENV["BOOBYTRAP_CHURN_FILE"] = churn_file
      
      # Mock Coverage data and DecomplexVerdict
      SlopCop::CoverageData.stub :load, {} do
        SlopCop::DecomplexVerdict.stub :index, { status: :ok, spans: {}, m_all: {}, m_spur: {}, m_devw: {} } do
          out = SlopCop::Rollup.run(files: ["a.rb"], repo: dir, resultset: nil)
          assert_equal :ok, out[:decomplex_status]
        end
      end
    ensure
      ENV["BOOBYTRAP_CHURN_FILE"] = nil
    end
  end

  def test_rollup_run_bugspots_standard_error
    Dir.mktmpdir do |dir|
      SlopCop::Bugspots.stub :from_git, ->(*) { raise StandardError, "git error" } do
        SlopCop::DecomplexVerdict.stub :index, { status: :ok, spans: {}, m_all: {}, m_spur: {}, m_devw: {} } do
          out = SlopCop::Rollup.run(files: ["a.rb"], repo: dir, resultset: nil)
          assert_equal :ok, out[:decomplex_status]
        end
      end
    end
  end

  def test_rollup_run_full_integration
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rb")
      File.write(file, "def foo\n  if x == 1\n    1\n  else\n    2\n  end\nend\n")
      
      mock_arm_1 = {
        "file" => file,
        "function" => "foo",
        "kind" => "if",
        "line" => 2,
        "span" => [2, 0, 6, 5],
        "decision_line" => 2,
        "decision_span" => [2, 0, 6, 5],
        "predicate" => "x == 1",
        "body" => "do_something"
      }
      mock_arm_2 = {
        "file" => file,
        "function" => "bar",
        "kind" => "if",
        "line" => 10,
        "span" => [10, 0, 14, 5],
        "decision_line" => 10,
        "decision_span" => [10, 0, 14, 5],
        "predicate" => "y == 2",
        "body" => "do_something_else"
      }
      
      SlopCop::Classifier.stub :get_branch_arms, [mock_arm_1, mock_arm_2] do
        dummy_covered_arm_1 = Struct.new(:arm, :covered, :source).new(
          Struct.new(:file, :function, :kind, :line, :span, :decision_line, :decision_span, :predicate, :member, :body).new(
            file, "foo", :if, 2, [2,0,6,5], 2, [2,0,6,5], "x == 1", "", "do_something"
          ),
          false,
          :coverage
        )
        dummy_covered_arm_1_sibling = Struct.new(:arm, :covered, :source).new(
          Struct.new(:file, :function, :kind, :line, :span, :decision_line, :decision_span, :predicate, :member, :body).new(
            file, "foo", :if, 2, [2,0,6,5], 2, [2,0,6,5], "x == 1", "", "do_something_else"
          ),
          true,
          :coverage
        )
        dummy_covered_arm_2 = Struct.new(:arm, :covered, :source).new(
          Struct.new(:file, :function, :kind, :line, :span, :decision_line, :decision_span, :predicate, :member, :body).new(
            file, "bar", :if, 10, [10,0,14,5], 10, [10,0,14,5], "y == 2", "", "do_something_else"
          ),
          false,
          :coverage
        )
        dummy_covered_arm_2_sibling = Struct.new(:arm, :covered, :source).new(
          Struct.new(:file, :function, :kind, :line, :span, :decision_line, :decision_span, :predicate, :member, :body).new(
            file, "bar", :if, 10, [10,0,14,5], 10, [10,0,14,5], "y == 2", "", "do_something_else_2"
          ),
          true,
          :coverage
        )
        
        # Stub tree_sitter_coverage_file? to force it into coverage path
        SlopCop::Classifier.stub :tree_sitter_coverage_file?, true do
          SlopCop::CoverageData.stub :branch_arm_coverage, [dummy_covered_arm_1, dummy_covered_arm_1_sibling, dummy_covered_arm_2, dummy_covered_arm_2_sibling] do
            mock_detectors = {
              "false_simplicity" => {
                "sites" => ["#{file}:foo:2"],
                "spans" => { "#{file}:foo:2" => [2, 0, 6, 5] }
              },
              "missing_abstractions" => {
                "sites" => ["#{file}:bar:10"],
                "spans" => { "#{file}:bar:10" => [10, 0, 14, 5] }
              }
            }
            SlopCop::DecomplexVerdict.stub :load_decomplex_facts, { detectors: mock_detectors, status: :ok } do
              dummy_facts = Class.new do
                def active?; true; end
                def label; "mut.json"; end
                def status_for(rel, defn)
                  Class.new do
                    def summary; "summary"; end
                    def kill_rate; 0.5; end
                    def gate_status; "gate"; end
                    def weak?; true; end
                    def strong?; false; end
                    def moderate?; false; end
                  end.new
                end
              end.new
              
              SlopCop::MutationFacts.stub :load, dummy_facts do
                SlopCop::Bugspots.stub :from_git, { "a.rb" => 5.0 } do
                  SlopCop::DecomplexRisk.stub :source_file?, true do
                    out = SlopCop::Rollup.run(files: ["a.rb"], repo: dir, resultset: "/dummy-cov.json")
                    assert_equal :ok, out[:decomplex_status]
                    refute_empty out[:top_gaps]
                    gap = out[:top_gaps].first
                    assert_equal "a.rb", gap[:file]
                    assert_equal "foo", gap[:method]
                    assert_equal 2, gap[:line]
                    assert gap[:precise]
                    assert_includes gap[:detectors], "False Simplicity"
                    refute_includes gap[:detectors], "Missing Abstractions"
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # --- Report Tests ---
  def test_report_initialize_and_methods
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rb")
      File.write(file, "def foo\n  if x == 1\n    do_something\n  end\nend\n")
      
      mock_arm = {
        "file" => file,
        "function" => "foo",
        "kind" => "if",
        "line" => 2,
        "span" => [2, 0, 6, 5],
        "decision_line" => 2,
        "decision_span" => [2, 0, 6, 5],
        "predicate" => "x == 1",
        "body" => "do_something"
      }
      
      SlopCop::Classifier.stub :get_branch_arms, [mock_arm] do
        SlopCop::DecomplexRisk.stub :source_file?, true do
          report = SlopCop::Report.new(files: ["a.rb"], repo: dir, resultset: nil)
          
          assert_includes report.decomplex_banner(:error), "decomplex signal UNAVAILABLE"
          assert_includes report.decomplex_banner(:absent), "decomplex not available"
          
          md = report.to_markdown
          assert_includes md, "SlopCop Report"
          
          json_out = report.to_json
          assert_includes json_out, "2.1.0"
        end
      end
    end
  end

  def test_report_empty_gaps
    report = SlopCop::Report.allocate
    report.instance_variable_set(:@repo, "/repo")
    report.instance_variable_set(:@top, 50)
    report.instance_variable_set(:@link_root, Pathname.new("/repo"))
    
    r_data = {
      top_gaps: [],
      per_file: {},
      totals: {},
      grand: 0,
      decomplex_status: :ok,
      sources: {}
    }
    report.instance_variable_set(:@r, r_data)
    
    md = report.to_markdown
    assert_includes md, "None."
  end

  def test_report_markdown_with_mutation_facts
    report = SlopCop::Report.allocate
    report.instance_variable_set(:@repo, "/repo")
    report.instance_variable_set(:@top, 50)
    report.instance_variable_set(:@link_root, Pathname.new("/repo"))
    
    r_data = {
      top_gaps: [
        {
          file: "a.rb",
          line: 10,
          method: "foo",
          churn: 0.5,
          deviance: 2,
          detectors: ["Decision Pressure"],
          precise: true,
          verification: "90% killed / clean",
          risk_profile: "hardened veteran"
        }
      ],
      per_file: { "a.rb" => { total: 1, counts: { genuine: 1 }, churn: 0.5 } },
      totals: { genuine: 1 },
      grand: 1,
      decomplex_status: :ok,
      mutation_label: "mutant-facts.json",
      sources: { coverage: 1 }
    }
    report.instance_variable_set(:@r, r_data)
    
    md = report.to_markdown
    assert_includes md, "profile"
    assert_includes md, "hardened veteran"
    assert_includes md, "Decision Pressure"
    assert_includes md, "Branch source: coverage=1"
  end

  def test_report_markdown_coarse_dup
    report = SlopCop::Report.allocate
    report.instance_variable_set(:@repo, "/repo")
    report.instance_variable_set(:@top, 50)
    report.instance_variable_set(:@link_root, Pathname.new("/repo"))
    
    r_data = {
      top_gaps: [
        {
          file: "a.rb",
          line: 10,
          method: "foo",
          churn: 0.5,
          deviance: 2,
          detectors: ["Missing Abstractions"],
          precise: false,
          coarse_dup: true
        }
      ],
      per_file: { "a.rb" => { total: 1, counts: { genuine: 1 }, churn: 0.5 } },
      totals: { genuine: 1 },
      grand: 1,
      decomplex_status: :ok,
      sources: {}
    }
    report.instance_variable_set(:@r, r_data)
    
    md = report.to_markdown
    assert_includes md, "† ⚠dup?"
    assert_includes md, "Missing Abstractions"
  end

  def test_report_to_h_and_sarif
    report = SlopCop::Report.allocate
    report.instance_variable_set(:@repo, "/repo")
    report.instance_variable_set(:@top, 50)
    
    r_data = {
      top_gaps: [
        {
          file: "a.rb",
          line: 10,
          method: "foo",
          churn: 0.5,
          deviance: 2,
          detectors: ["Decision Pressure"],
          precise: true
        }
      ],
      per_file: { "a.rb" => { total: 1, counts: { genuine: 1 }, churn: 0.5 } },
      totals: { genuine: 1 },
      grand: 1,
      decomplex_status: :ok,
      sources: { coverage: 1 },
      coverage_label: "cov.json",
      mutation_label: "mut.json",
      dark_arms: [
        {
          file: "a.rb",
          line: 10,
          method: "foo",
          category: :genuine,
          message: "dark arm: genuine",
          source: :coverage
        }
      ]
    }
    report.instance_variable_set(:@r, r_data)
    
    hash = report.to_h
    assert_equal "slopcop.report.v1", hash["format"]
    
    sarif = JSON.parse(report.to_sarif)
    assert_equal "2.1.0", sarif["version"]
  end

  # --- DarkArmOverlay Tests ---
  def test_dark_arm_overlay_build_missing_file
    Dir.mktmpdir do |dir|
      overlay = SlopCop::DarkArmOverlay.build(files: ["missing.rb"], repo: dir, resultset: nil)
      assert_empty overlay["dark_arms"]
    end
  end

  def test_dark_arm_overlay_to_sarif
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rb")
      File.write(file, "def foo; end")
      
      # Mock Classifier.classify_file
      arm = SlopCop::Classifier::Arm.new(
        file: file,
        defn: "foo",
        line: 1,
        span: [1, 0, 1, 10],
        decision_span: [1, 0, 1, 10],
        category: :genuine,
        source: :coverage
      )
      
      SlopCop::Classifier.stub :classify_file, [arm] do
        sarif = JSON.parse(SlopCop::DarkArmOverlay.to_json(files: ["a.rb"], repo: dir, resultset: nil))
        assert_equal "2.1.0", sarif["version"]
        assert_equal "slopcop.dark-arms.sarif.v1", sarif.dig("runs", 0, "properties", "format")
      end
    end
  end

  # --- Sarif Tests ---
  def test_sarif_unique_rules
    rules = [
      { "id" => "rule-1" },
      { "id" => "rule-1" }, # duplicate
      { "id" => "" },       # empty id
      { "id" => :rule_2 }   # symbol id
    ]
    unique = SlopCop::Sarif.send(:unique_rules, rules)
    assert_equal 2, unique.size
    assert_equal "rule-1", unique[0]["id"]
    assert_equal "rule_2", unique[1]["id"]
  end

  def test_sarif_locations_empty_path
    assert_equal [], SlopCop::Sarif.send(:sarif_locations, path: nil, line: 1)
    assert_equal [], SlopCop::Sarif.send(:sarif_locations, path: "", line: 1)
  end

  def test_sarif_positive_int
    assert_nil SlopCop::Sarif.send(:positive_int, nil)
    assert_equal 5, SlopCop::Sarif.send(:positive_int, 5)
    assert_equal 5, SlopCop::Sarif.send(:positive_int, "5")
    assert_nil SlopCop::Sarif.send(:positive_int, -5)
    assert_equal 1, SlopCop::Sarif.send(:positive_int, -5, 1)
  end

  # --- Lexicons Tests ---
  def test_lexicons
    # Ruby
    ruby = SlopCop.language_lexicon(:ruby)
    assert ruby.type_guard?("x.is_a?(Type)")
    assert ruby.diagnostic?("raise 'error'")
    assert ruby.trivial?("next")
    
    # Python
    python = SlopCop.language_lexicon(:python)
    assert python.type_guard?("isinstance(x, Type)")
    assert python.diagnostic?("sys.exit(1)")
    assert python.trivial?("pass")
    
    # JavaScript
    js = SlopCop.language_lexicon(:javascript)
    assert js.type_guard?("typeof x === 'string'")
    assert js.diagnostic?("process.exit(1)")
    assert js.trivial?("break")
    
    # Go
    go = SlopCop.language_lexicon(:go)
    assert go.type_guard?("x.(type)")
    assert go.diagnostic?("panic('error')")
    assert go.trivial?("fallthrough")
    
    # Rust
    rust = SlopCop.language_lexicon(:rust)
    assert rust.type_guard?("matches!(x, Pattern)")
    assert rust.diagnostic?("return Err(x)")
    assert rust.trivial?("unreachable!")
    
    # Zig
    zig = SlopCop.language_lexicon(:zig)
    assert zig.type_guard?("if (x) |y|")
    assert zig.diagnostic?("unreachable")
    assert zig.trivial?("null")
    
    # Generic
    generic = SlopCop.language_lexicon(:unsupported)
    assert generic.type_guard?("typeid(x)")
    assert generic.diagnostic?("return error.Foo")
    assert generic.trivial?("continue")
  end

  # --- LanguageProvider Tests ---
  # scan_hazards is now provider-owned (FactMine-backed - see
  # ConstraintsSystemsProviderTest and ConstraintsGoProviderTest for
  # per-provider coverage); LanguageProvider.findings is the remaining
  # shared logic (line-matching against `additions`, coverage gating via
  # Evidence, Finding construction), tested here against a stubbed
  # scan_hazards so it doesn't depend on any provider's real detection.
  def test_language_provider_finding_generation
    provider = SlopCop::Constraints::RustProvider
    evidence = SlopCop::Constraints::Evidence.allocate
    evidence.stub :known_type?, false do
      hazards = [
        { path: "src/lib.rs", line: 1, source: "unsafe { ptr.read() }", hazard_type: "rust_unsafe_block", required_evidence: "miri", label: "unsafe block" },
        { path: "src/lib.rs", line: 1, source: "unsafe { ptr.read() }", hazard_type: "rust_unsafe_operation", required_evidence: "miri", label: "unsafe operation inside unsafe context" },
        { path: "src/lib.rs", line: 5, source: "let x = 1;", hazard_type: "rust_unsafe_block", required_evidence: "miri", label: "unsafe block" }
      ]
      provider.stub :scan_hazards, hazards do
        res = SlopCop::Constraints::LanguageProvider.findings(
          provider,
          repo: Dir.tmpdir,
          additions: { "src/lib.rs" => [1] },
          evidence: evidence
        )
        assert_equal 2, res.size # only the two hazards on the changed line (1), not line 5
        assert_equal "src/lib.rs", res.first.path
        assert_equal 1, res.first.line
      end
    end
  end

  # --- ZigProvider Tests ---
  def test_zig_provider_scan_hazards
    Dir.mktmpdir do |dir|
      site1 = { file: "zig/runtime/a.zig", line: 5, source: "atomic" }
      site2 = { file: "zig/runtime/b.zig", line: 10, source: "milliTimestamp", category: :time }
      
      LoomAtomicCoverage.stub :scan_atomic_sites, [site1] do
        VoprCoverage.stub :scan_sites, [site2] do
          loop = WaitLoopCoverage::Loop.new(
            tag: "queue.wait",
            file: "zig/runtime/c.zig",
            begin_line: 3,
            end_line: 8
          )
          WaitLoopCoverage.stub :scan_source_files, [] do
            WaitLoopCoverage.stub :parse_loops, [[loop], []] do
              hazards = SlopCop::Constraints::ZigProvider.scan_hazards(repo: dir)
              assert_equal 3, hazards.size
              assert_equal "zig_loom_atomic", hazards[0][:hazard_type]
              assert_equal "zig_vopr_time", hazards[1][:hazard_type]
              assert_equal "zig_wait_loop", hazards[2][:hazard_type]
              assert_equal "hammer", hazards[2][:required_evidence]
            end
          end
        end
      end
    end
  end

  def test_zig_provider_wait_loop_tag_mismatch
    out = []
    # Test unpaired begin tag
    SlopCop::Constraints::ZigProvider.add_wait_loop_finding(
      out,
      Dir.tmpdir,
      { loop_tags: Set.new, cover_tags: Set.new },
      "zig/runtime/a.zig",
      5,
      "// HAMMER-WAIT-LOOP-BEGIN: tag=tag1"
    )
    assert_equal 1, out.size
    assert_equal "slopcop-zig-wait-loop-unpaired", out.first.rule_id

    # Test unpaired cover tag
    out = []
    SlopCop::Constraints::ZigProvider.add_wait_loop_finding(
      out,
      Dir.tmpdir,
      { loop_tags: Set.new, cover_tags: Set.new },
      "zig/runtime/a.zig",
      10,
      "// HAMMER-COVERS: tag2"
    )
    assert_equal 1, out.size
    assert_equal "slopcop-zig-wait-loop-unpaired", out.first.rule_id
  end

  def test_zig_provider_wait_loop_indexes
    Dir.mktmpdir do |dir|
      # Stub WaitLoopCoverage methods
      WaitLoopCoverage.stub :scan_source_files, [] do
        WaitLoopCoverage.stub :scan_hammer_test_files, [] do
          WaitLoopCoverage.stub :parse_loops, [[], []] do
            WaitLoopCoverage.stub :parse_covers, [] do
              indexes = SlopCop::Constraints::ZigProvider.wait_loop_indexes(dir)
              assert_empty indexes[:loop_tags]
              assert_empty indexes[:cover_tags]
            end
          end
        end
      end
    end
  end

  def test_zig_provider_vopr_covered_non_retry
    evidence = SlopCop::Constraints::Evidence.allocate
    evidence.stub :known_type?, true do
      evidence.stub :line_covered?, true do
        assert SlopCop::Constraints::ZigProvider.vopr_covered?(evidence, "a.zig", 5, :time)
      end
    end
  end
end
