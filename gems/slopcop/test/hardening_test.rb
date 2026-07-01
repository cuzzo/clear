# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../lib/slopcop"

class SlopCopHardeningTest < Minitest::Test
  Arm = Struct.new(:file, :kind, :member, :decision_line, :decision_span, :line, :span, :body, keyword_init: true)

  def test_bugspots_log_scoring_and_blast_radius
    log = <<~LOG
      @@@100\tFix login
      app/a.rb
      app/b.rb

      @@@200\tDocs only
      README.md

      @@@300\tbug fix payment
      app/a.rb
      app/a.rb
      app/c.rb
    LOG
    events = SlopCop::Bugspots.parse_log(log)
    assert_equal 2, events.size
    assert_equal ["app/a.rb", "app/b.rb"], events.first.files
    assert SlopCop::Bugspots.fix?("Closes payment bug", SlopCop::Bugspots::FIX_RE)
    refute SlopCop::Bugspots.fix?("Refactor payment", SlopCop::Bugspots::FIX_RE)

    scores = SlopCop::Bugspots.score(events)
    assert_operator scores.fetch("app/a.rb"), :>, scores.fetch("app/b.rb")
    assert_equal({}, SlopCop::Bugspots.score([]))

    single = SlopCop::Bugspots.score([SlopCop::Bugspots::Event.new(time: 10, subject: "fix", files: ["only.rb"])])
    assert_in_delta 0.5, single.fetch("only.rb"), 0.0001

    blast = SlopCop::Bugspots.blast_radius(events)
    assert_equal "app/a.rb", blast.first.file
    assert_equal 2, blast.first.fixes
    assert_operator blast.first.max_touched, :>=, 2
    assert blast.first.partners.any? { |path, _| path == "app/c.rb" }
    assert_equal [], SlopCop::Bugspots.blast_radius([])
  end

  def test_coverage_data_loads_merges_and_labels_boobytrap_json
    Dir.mktmpdir do |dir|
      file = File.join(dir, "src/app.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "def call\nend\n")
      coverage = File.join(dir, "coverage.json")
      File.write(coverage, JSON.dump(
        "coverage" => {
          "files" => {
            file => {
              "lines" => [1, nil, 0],
              "branches" => { "[:if,0,1,1,1,4]" => { "[:then,1,1,1,1,4]" => 0 } },
              "branch_arms" => [
                {
                  "branch_id" => "b1",
                  "arm_id" => "a1",
                  "kind" => "if",
                  "member" => "then",
                  "decision_span" => [1, 1, 1, 4],
                  "arm_span" => [1, 1, 1, 4],
                  "hits" => 0
                }
              ],
              "source_path" => "src/app.rb",
              "language" => "ruby",
              "format" => "nil_kill_branch"
            }
          }
        }
      ))

      dataset = SlopCop::CoverageData.load(coverage, root: dir)
      assert_equal ["Nil-Kill branch coverage"], [dataset.label]
      assert_equal [:nil_kill_branch], dataset.formats
      assert_equal ["src/app.rb"], dataset.covered_files(root: dir)
      file_cov = dataset[file]
      assert file_cov.line_coverage?
      assert file_cov.branch_coverage?
      assert file_cov.branch_arm_coverage?
      assert file_cov.line_known?(1)
      assert_nil file_cov.line_hits(0)
      assert_equal 1, file_cov.line_hits(1)

      second = SlopCop::CoverageData::Dataset.new(
        path: "second",
        files: {
          File.expand_path(file) => SlopCop::CoverageData::FileCoverage.new(
            file: File.expand_path(file),
            lines: [2, 3, nil],
            branches: { "[:if,0,1,1,1,4]" => { "[:then,1,1,1,1,4]" => 2 } },
            branch_arms: [
              SlopCop::CoverageData::NativeBranchArm.new(
                branch_id: "b1",
                arm_id: "a1",
                kind: "if",
                member: "then",
                decision_span: [1, 1, 1, 4],
                arm_span: [1, 1, 1, 4],
                hits: 2
              )
            ],
            format: :simplecov,
            source_path: "",
            language: ""
          )
        }
      )
      merged = SlopCop::CoverageData.merge_datasets("merged", [dataset, second])
      merged_cov = merged[file]
      assert_equal :multi, merged_cov.format
      assert_equal [3, 3, 0], merged_cov.lines
      assert_equal 2, merged_cov.branches.fetch("[:if,0,1,1,1,4]").fetch("[:then,1,1,1,1,4]")
      assert_equal 2, merged_cov.branch_arms.first.hits

      assert_equal [], SlopCop::CoverageData.coverage_paths(nil)
      assert_equal [coverage], SlopCop::CoverageData.coverage_paths("#{coverage}#{File::PATH_SEPARATOR}#{coverage}")
      assert_equal "kcov Cobertura", SlopCop::CoverageData.format_label(:kcov_cobertura)
      assert_equal :native_branch, SlopCop::CoverageData.branch_source(:nil_kill_branch)

      second_path = File.join(dir, "coverage2.json")
      File.write(second_path, JSON.dump(
        "files" => {
          file => {
            "lines" => [0, 1],
            "branches" => {},
            "branch_arms" => [
              {
                "branch_id" => "b2",
                "arm_id" => "a2",
                "kind" => "if",
                "member" => "else",
                "decision_span" => [1, 1, 1, 4],
                "arm_span" => [2, 1, 2, 4],
                "hits" => 1
              }
            ],
            "source_path" => "",
            "language" => "",
            "format" => "simplecov"
          }
        }
      ))
      loaded_multi = SlopCop::CoverageData.load([coverage, second_path].join(File::PATH_SEPARATOR), root: dir)
      assert_equal :multi, loaded_multi[file].format
      assert_equal 2, loaded_multi[file].branch_arms.size
    end
  end

  def test_coverage_data_resolves_directories_and_branch_arm_coverage_modes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "coverage"))
      resultset = File.join(dir, "coverage/.resultset.json")
      File.write(resultset, "{}")
      assert_equal resultset, SlopCop::CoverageData.resolve(dir)
      glob_root = File.join(dir, "glob")
      FileUtils.mkdir_p(File.join(glob_root, "nested/kcov-merged"))
      glob_cov = File.join(glob_root, "nested/kcov-merged/cobertura.xml")
      File.write(glob_cov, "<coverage/>")
      assert_equal glob_cov, SlopCop::CoverageData.resolve(glob_root)
      assert_nil SlopCop::CoverageData.resolve(File.join(dir, "missing"))

      arms = [
        Arm.new(file: "a.rb", kind: "if", member: "then", decision_line: 10, decision_span: [10, 1, 12, 3], line: 11, span: [11, 1, 11, 5]),
        Arm.new(file: "a.rb", kind: "if", member: "else", decision_line: 10, decision_span: [10, 1, 12, 3], line: 12, span: [12, 1, 12, 5]),
        Arm.new(file: "a.rb", kind: "case", member: "when", decision_line: 20, decision_span: [20, 1, 22, 3], line: 21, span: [21, 1, 21, 5])
      ]

      line_cov = SlopCop::CoverageData::FileCoverage.new(
        file: File.join(dir, "a.rb"),
        lines: Array.new(25).tap { |lines| lines[10] = 0; lines[11] = 2 },
        branches: {},
        branch_arms: [],
        format: :kcov_cobertura,
        source_path: "a.rb",
        language: "ruby"
      )
      line_results = SlopCop::CoverageData.branch_arm_coverage(line_cov, arms)
      refute line_results[0].covered
      assert line_results[1].covered
      assert_equal :tree_sitter_static, line_results[0].source

      tuple_cov = SlopCop::CoverageData::FileCoverage.new(
        file: File.join(dir, "a.rb"),
        lines: [],
        branches: {
          "[:if,0,10,1,12,3]" => {
            "[:then,1,11,1,11,5]" => 0,
            "[:else,2,12,1,12,5]" => 3
          }
        },
        branch_arms: [],
        format: :simplecov,
        source_path: "a.rb",
        language: "ruby"
      )
      tuple_results = SlopCop::CoverageData.branch_arm_coverage(tuple_cov, arms)
      assert_equal [false, true], tuple_results.map(&:covered)
      assert_equal({ 11 => 1 }, SlopCop::CoverageData.dark_branch_misses_by_line(tuple_cov, arms))
      assert SlopCop::CoverageData.branch_kind_compatible?("if", "unless")
      refute SlopCop::CoverageData.branch_kind_compatible?("case", "if")
      assert SlopCop::CoverageData.span_contains?([1, 1, 5, 1], [2, 1, 3, 1])
      refute SlopCop::CoverageData.span_contains?([1, 1], [2, 1, 3, 1])
      assert_nil SlopCop::CoverageData.coverage_tuple("bad")

      native_arm = SlopCop::CoverageData::NativeBranchArm.new(
        branch_id: "b",
        arm_id: "native-else",
        kind: "if",
        member: "else",
        decision_span: [10, 1, 12, 3],
        arm_span: [12, 1, 12, 5],
        hits: 4
      )
      native_cov = SlopCop::CoverageData::FileCoverage.new(
        file: File.join(dir, "a.rb"),
        lines: [],
        branches: {},
        branch_arms: [native_arm],
        format: :nil_kill_branch,
        source_path: "a.rb",
        language: "ruby"
      )
      native_results = SlopCop::CoverageData.branch_arm_coverage(native_cov, arms)
      assert_equal 1, native_results.size
      assert native_results.first.covered
      assert_equal :native_branch, native_results.first.source
      assert_equal "ruby", SlopCop::CoverageData.arm_language(arms.first)
      {
        "a.zig" => "zig",
        "a.py" => "python",
        "a.jsx" => "javascript",
        "a.tsx" => "typescript",
        "a.go" => "go",
        "a.rs" => "rust",
        "a.rb" => "ruby",
        "README" => "unknown"
      }.each do |name, language|
        assert_equal language, SlopCop::CoverageData.arm_language(Arm.new(file: name))
        assert_equal language, SlopCop::CoverageData.language_for(name)
      end
      fallback_id = SlopCop::CoverageData.static_arm_id(
        SlopCop::CoverageData::FileCoverage.new(file: File.join(dir, "fallback.py"), lines: [], branches: {}, branch_arms: [], source_path: "", language: ""),
        Arm.new(file: File.join(dir, "fallback.py"), kind: "if", member: "then", decision_span: [1, 1, 1, 2], span: [1, 1, 1, 2])
      )
      assert_includes fallback_id, "python"
      assert_equal "1:2:3", SlopCop::CoverageData.span_key([1, "2", 3])
    end
  end

  def test_coverage_data_falls_back_to_boobytrap_subprocess_output
    Dir.mktmpdir do |dir|
      raw = File.join(dir, "raw.resultset.json")
      File.write(raw, JSON.dump("RSpec" => { "coverage" => {} }))
      status = Struct.new(:ok) { def success? = ok }

      Open3.stub :capture3, ["", "bad input", status.new(false)] do
        dataset = SlopCop::CoverageData.load_uncached(raw, root: dir)
        assert dataset.empty?
      end

      Open3.stub :capture3, ["not-json", "", status.new(true)] do
        dataset = SlopCop::CoverageData.load_uncached(raw, root: dir)
        assert dataset.empty?
      end

      file = File.join(dir, "a.rb")
      File.write(file, "def call\nend\n")
      output = JSON.dump(
        "files" => {
          file => {
            "lines" => [1],
            "branches" => {},
            "branch_arms" => [],
            "source_path" => "a.rb",
            "language" => "ruby",
            "format" => "simplecov"
          }
        }
      )
      Open3.stub :capture3, [output, "", status.new(true)] do
        dataset = SlopCop::CoverageData.load_uncached(raw, root: dir)
        refute dataset.empty?
        assert_equal 1, dataset[file].line_hits(1)
      end
    end
  end

  def test_coverage_data_builds_branch_catalog_with_stubbed_syntax
    Dir.mktmpdir do |dir|
      file = File.join(dir, "src/app.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "if ok\n  1\nend\n")
      arm = Arm.new(
        file: file,
        kind: "if",
        member: "then",
        decision_line: 1,
        decision_span: [1, 1, 3, 3],
        line: 2,
        span: [2, 1, 2, 3]
      )
      doc = Decomplex::Syntax::Document.new([arm], "ruby")
      SlopCop::CoverageData.stub :load_decomplex_syntax, true do
        Decomplex::Syntax.stub :parse, doc do
          catalog = SlopCop::CoverageData.branch_catalog(["src/app.rb", "missing.rb"], root: dir)
          assert_equal "nil-kill.branch-catalog", catalog.fetch("format")
          assert_equal 1, catalog.fetch("files").size
          entry = catalog.fetch("files").first
          assert_equal "src/app.rb", entry.fetch("path")
          assert_equal "ruby", entry.fetch("language")
          assert_equal "if", entry.fetch("arms").first.fetch("kind")
        end
      end
      SlopCop::CoverageData.stub :load_decomplex_syntax, false do
        assert_empty SlopCop::CoverageData.branch_catalog(["src/app.rb"], root: dir).fetch("files")
      end
    end
  end

  def test_decomplex_risk_reads_fact_files_and_normalizes_sources
    Dir.mktmpdir do |dir|
      file = File.join(dir, "src/a.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "def call\nend\n")
      facts = File.join(dir, "facts.json")
      File.write(facts, JSON.dump(
        "detectors" => {
          "z_detector" => { "nested" => [{ "sites" => ["bad", "#{file}:call:3"] }] },
          "a_detector" => [{ "sites" => ["#{file}:call:3"] }],
          "state_branch_density" => [
            {
              "file" => file,
              "method" => "call",
              "score" => 2.5,
              "decisions" => 3,
              "at" => "#{file}:call:3",
              "state_refs" => ["@x"],
              "predicate" => "@x"
            }
          ]
        }
      ))
      old = ENV["DECOMPLEX_FACTS_FILE"]
      ENV["DECOMPLEX_FACTS_FILE"] = facts
      scores = SlopCop::DecomplexRisk.score([file], root: dir)
      score = scores.fetch(["src/a.rb", "call"])
      assert_equal 2, score.score
      assert_equal %w[z_detector a_detector].sort, score.detectors.sort
      density = SlopCop::DecomplexRisk.state_branch_density([file], root: dir)
      assert_equal "src/a.rb", density.first.fetch(:file)
      assert_equal 3, density.first.fetch(:decisions)
      assert_equal({}, SlopCop::DecomplexRisk.score([], root: dir))
      assert_equal([], SlopCop::DecomplexRisk.state_branch_density([], root: dir))
      assert SlopCop::DecomplexRisk.supported_exts.include?(".rb")
      SlopCop::DecomplexRisk.stub :load_decomplex_source_filter, false do
        assert SlopCop::DecomplexRisk.source_file?(file, root: dir)
        refute SlopCop::DecomplexRisk.source_file?(File.join(dir, "README"), root: dir)
        refute SlopCop::DecomplexRisk.excluded_path?(file, root: dir, exclude: ["src"])
      end
      assert_equal "missing.rb", SlopCop::DecomplexRisk.relpath(File.join(dir, "missing.rb"), dir)
    ensure
      ENV["DECOMPLEX_FACTS_FILE"] = old
    end
  end

  def test_decomplex_risk_uses_external_binary_and_handles_failures
    Dir.mktmpdir do |dir|
      file = File.join(dir, "src/a.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "def call\nend\n")
      bin = File.join(dir, "fake-decomplex")
      File.write(bin, <<~SH)
        #!/bin/sh
        out=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--output" ]; then out="$arg"; fi
          prev="$arg"
        done
        cat > "$out" <<'JSON'
        {"detectors":{"unused_return":[{"sites":["#{file}:call:2"]}],"state_branch_density":[{"file":"#{file}","method":"call","score":1.5,"decisions":2,"state_refs":["@x"],"predicate":"@x"}]}}
        JSON
      SH
      FileUtils.chmod("+x", bin)
      mod = SlopCop::DecomplexRisk
      old = mod.const_get(:DECOMPLEX_RUST_BINARY)
      mod.send(:remove_const, :DECOMPLEX_RUST_BINARY)
      mod.const_set(:DECOMPLEX_RUST_BINARY, bin)
      scores = mod.score([file], root: dir)
      assert_equal 1, scores.fetch(["src/a.rb", "call"]).score
      density = mod.state_branch_density([file], root: dir)
      assert_equal 1.5, density.first.fetch(:score)

      failing = File.join(dir, "failing-decomplex")
      File.write(failing, "#!/bin/sh\nexit 7\n")
      FileUtils.chmod("+x", failing)
      mod.send(:remove_const, :DECOMPLEX_RUST_BINARY)
      mod.const_set(:DECOMPLEX_RUST_BINARY, failing)
      assert_equal({}, mod.score([file], root: dir))
      assert_equal([], mod.state_branch_density([file], root: dir))
    ensure
      if defined?(mod) && defined?(old)
        mod.send(:remove_const, :DECOMPLEX_RUST_BINARY)
        mod.const_set(:DECOMPLEX_RUST_BINARY, old)
      end
    end
  end

  def test_decomplex_syntax_parse_and_batch_parse_with_fake_fact_mine
    Dir.mktmpdir do |dir|
      ruby_file = File.join(dir, "a.rb")
      py_file = File.join(dir, "b.py")
      File.write(ruby_file, "if ok\n  1\nend\n")
      File.write(py_file, "if ok:\n  pass\n")
      bin = File.join(dir, "fact-mine")
      File.write(bin, <<~SH)
        #!/bin/sh
        last=""
        for arg in "$@"; do last="$arg"; done
        cat <<JSON
        {"documents":[{"file":"$last","language":"ruby","branch_arms":[{"kind":"if","member":"then","decision_line":1,"decision_span":[1,1,3,3],"line":2,"span":[2,1,2,3],"body":"1"}]}]}
        JSON
      SH
      FileUtils.chmod("+x", bin)
      old = ENV["FACT_MINE_RUST_BINARY"]
      ENV["FACT_MINE_RUST_BINARY"] = bin
      Decomplex::Syntax.cache = {}
      doc = Decomplex::Syntax.parse(ruby_file)
      assert_equal "ruby", doc.language
      assert_equal 1, doc.branch_arms.size
      assert_equal "then", doc.branch_arms.first.member
      Decomplex::Syntax.batch_parse([ruby_file, py_file])
      assert Decomplex::Syntax.cache.key?([File.expand_path(ruby_file), "tree_sitter", nil])
      assert_equal "python", Decomplex::Syntax.language_for("x.py")

      bad = File.join(dir, "bad-fact-mine")
      File.write(bad, "#!/bin/sh\necho '{bad'\n")
      FileUtils.chmod("+x", bad)
      ENV["FACT_MINE_RUST_BINARY"] = bad
      Decomplex::Syntax.cache = {}
      assert_empty Decomplex::Syntax.parse(ruby_file).branch_arms
      Decomplex::Syntax.batch_parse([ruby_file])
    ensure
      ENV["FACT_MINE_RUST_BINARY"] = old
      Decomplex::Syntax.cache = {}
    end
  end

  def test_mutation_facts_policy_lookup_and_risk_profiles
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src/a.rb"), "")
      data = {
        "subjects" => [
          { "file" => "src/a.rb", "method" => "Owner#call", "kill_rate" => "95%", "gate_status" => "required" },
          { "file" => "src/a.rb", "method" => "Owner#fallback*", "kill_rate" => 0.5, "gate_status" => "advisory" },
          { "file" => "src/b.rb", "method" => "Shared.run", "kill_rate" => 75, "gate_status" => "required" }
        ]
      }
      path = File.join(dir, "mutation.json")
      File.write(path, JSON.dump(data))
      index = SlopCop::MutationFacts.load(path, root: dir)
      assert index.active?
      assert_equal "mutation.json", index.label
      strong = index.lookup("./src/a.rb", "Owner#call")
      assert strong.strong?
      assert_equal "95.0% killed / required", strong.summary
      assert_equal strong, index.lookup("src/a.rb", "call")
      assert index.lookup("src/a.rb", "anything").weak?
      assert_equal "missing", index.status_for("missing.rb", "none").gate_status

      inactive = SlopCop::MutationFacts.empty
      assert_nil inactive.status_for("missing.rb", "none")
      assert SlopCop::MutationFacts.load(File.join(dir, "missing.json"), root: dir).empty?
      bad = File.join(dir, "bad.json")
      File.write(bad, "{bad")
      assert SlopCop::MutationFacts.load(bad, root: dir).empty?

      from_data = SlopCop::MutationFacts.load_from_data(
        { "active" => true, "subjects" => [{ "file" => "x.rb", "method" => "Solo.work", "kill_rate" => 75, "gate_status" => "required" }] },
        label: "inline"
      )
      assert_equal "x.rb", from_data.lookup("other.rb", "work").file
      assert SlopCop::MutationFacts.load_from_data(nil, label: "none").empty?

      assert_nil SlopCop::MutationFacts.parse_kill_rate(nil)
      assert_nil SlopCop::MutationFacts.parse_kill_rate("bad")
      assert_equal 42.0, SlopCop::MutationFacts.parse_kill_rate(0.42)
      assert_equal "", SlopCop::MutationFacts.normalize_file("", root: dir)
      assert_equal "src/a.rb", SlopCop::MutationFacts.normalize_file(File.join(dir, "src/a.rb"), root: dir)
      assert_equal "path/file.rb", SlopCop::MutationFacts.clean_file(".\\path\\file.rb")
      assert_equal ["A::B.run", "run", "B.run"], SlopCop::MutationFacts.method_aliases("A::B.run")

      moderate = SlopCop::MutationFacts::Fact.new(file: "x", method: "m", kill_rate: 75, gate_status: "required")
      weak = SlopCop::MutationFacts::Fact.new(file: "x", method: "m", kill_rate: nil, gate_status: "missing")
      assert_equal 1.0, SlopCop::MutationFacts.risk_multiplier(strong, active: false, complexity: 9, history: 1, coverage_gap: 1)
      assert_equal 0.9, SlopCop::MutationFacts.risk_multiplier(strong, active: true, complexity: 9, history: 1, coverage_gap: 0)
      assert_equal 1.1, SlopCop::MutationFacts.risk_multiplier(moderate, active: true, complexity: 1, history: 0, coverage_gap: 0)
      assert_equal 1.9, SlopCop::MutationFacts.risk_multiplier(weak, active: true, complexity: 9, history: 1, coverage_gap: 1)
      assert_equal 1.7, SlopCop::MutationFacts.risk_multiplier(weak, active: true, complexity: 9, history: 1, coverage_gap: 0)
      assert_equal 1.45, SlopCop::MutationFacts.risk_multiplier(weak, active: true, complexity: 9, history: 0, coverage_gap: 0)
      assert_equal "hardened veteran", SlopCop::MutationFacts.profile(strong, active: true, complexity: 9, history: 0, coverage_gap: 0)
      assert_equal "partial verification", SlopCop::MutationFacts.profile(moderate, active: true, complexity: 1, history: 0, coverage_gap: 0)
      assert_equal "lurking disaster", SlopCop::MutationFacts.profile(weak, active: true, complexity: 9, history: 1, coverage_gap: 1)
      assert_nil SlopCop::MutationFacts.profile(weak, active: false, complexity: 9, history: 1, coverage_gap: 1)
    end
  end
end
