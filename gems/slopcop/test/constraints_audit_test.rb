# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/slopcop"

class ConstraintsAuditTest < Minitest::Test
  def test_audit_unsupported_language
    audit = SlopCop::Constraints::Audit.new(
      repo: Dir.tmpdir,
      base: "base",
      head: "head",
      languages: ["unsupported_lang"]
    )
    assert_raises(ArgumentError) do
      audit.findings
    end
  end

  def test_audit_findings_and_rules
    Dir.mktmpdir do |dir|
      audit = SlopCop::Constraints::Audit.new(
        repo: dir,
        base: "base",
        head: "head",
        languages: ["zig"]
      )
      
      # Mock Diff.added_lines and Evidence.from_specs
      SlopCop::Constraints::Diff.stub :added_lines, { "example.zig" => [1] } do
        SlopCop::Constraints::Evidence.stub :from_specs, nil do
          # Stub ZigProvider.findings to return a dummy finding
          finding = SlopCop::Constraints::Finding.new(
            path: "example.zig",
            line: 1,
            rule_id: "slopcop-zig-loom-uncovered",
            required_evidence: "loom",
            message: "Missing loom test coverage",
            hazard_type: "zig_loom_atomic",
            severity: "warning",
            source: :test
          )
          
          SlopCop::Constraints::ZigProvider.stub :findings, [finding] do
            findings = audit.findings
            assert_equal 1, findings.size
            assert_equal "example.zig", findings.first.path
            
            rules = audit.rules
            refute_empty rules
            
            # test serialization
            assert_includes audit.to_sarif, "SlopCop"
            assert_includes audit.to_json, "example.zig"
            
            md = audit.to_markdown
            assert_includes md, "SlopCop Constraint Audit"
            assert_includes md, "example.zig"
          end
        end
      end
    end
  end

  def test_audit_markdown_empty_findings
    audit = SlopCop::Constraints::Audit.new(
      repo: Dir.tmpdir,
      base: "base",
      head: "head",
      languages: ["zig"]
    )
    
    audit.stub :findings, [] do
      md = audit.to_markdown
      assert_includes md, "No constraint coverage warnings."
    end
  end

  def test_diff_added_lines_parsing
    diff_output = <<~DIFF
      diff --git a/example.zig b/example.zig
      index 123456..7890ab 100644
      --- a/example.zig
      +++ b/example.zig
      @@ -1,0 +2,4 @@
      +const foo = 1;
      +const bar = 2;
      -const old = 0;
      +const baz = 3;
      diff --git a/deleted.zig b/deleted.zig
      --- a/deleted.zig
      +++ /dev/null
      @@ -1 +0,0 @@
      -deleted
    DIFF
    
    SlopCop::Constraints::Diff.stub :diff, diff_output do
      adds = SlopCop::Constraints::Diff.added_lines(repo: "/repo", base: "base")
      assert_equal [2, 3, 4], adds["example.zig"]
      assert_nil adds["deleted.zig"]
    end
  end

  class DummyFileCoverage
    attr_reader :file, :source_path, :lines

    def initialize(file:, source_path:, lines:)
      @file = file
      @source_path = source_path
      @lines = lines
    end

    def line_hits(line)
      return nil if line < 1 || line > @lines.size
      @lines[line - 1]
    end

    def line_known?(line)
      return false if line < 1 || line > @lines.size
      !@lines[line - 1].nil?
    end
  end

  class DummyDataset
    attr_reader :files

    def initialize(files)
      @files = files
    end

    def empty?
      @files.empty?
    end

    def [](path)
      @files[path]
    end
  end

  def test_evidence_matching_and_lookups
    Dir.mktmpdir do |dir|
      evidence = SlopCop::Constraints::Evidence.new(repo: dir)
      
      abs_path = File.join(dir, "example.zig")
      cov_file = DummyFileCoverage.new(
        file: abs_path,
        source_path: "example.zig",
        lines: [1, 0, nil, 5]
      )
      
      dataset = DummyDataset.new(abs_path => cov_file)
      
      Boobytrap::CoverageData.stub :load, dataset do
        evidence.add("loom", "example.zig")
      end
      
      assert evidence.known_type?("loom")
      refute evidence.known_type?("vopr")
      
      assert_equal 1, evidence.line_hits("loom", "example.zig", 1)
      assert_equal 0, evidence.line_hits("loom", "example.zig", 2)
      assert_equal 0, evidence.line_hits("loom", "example.zig", 3)
      assert evidence.line_known?("loom", "example.zig", 1)
      refute evidence.line_known?("loom", "example.zig", 3)
      
      assert evidence.line_covered?("loom", "example.zig", 1)
      refute evidence.line_covered?("loom", "example.zig", 2)
      
      assert_equal 4, evidence.first_instrumented_line_at_or_after("loom", "example.zig", 3)
      
      hit_map = evidence.line_hit_map("loom", "example.zig")
      assert_equal 1, hit_map[1]
      assert_equal 0, hit_map[2]
      assert_nil hit_map[3]
    end
  end
end
