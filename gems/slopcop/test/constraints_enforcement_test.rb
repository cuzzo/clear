# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/slopcop"

class ConstraintsEnforcementTest < Minitest::Test
  LANGUAGES = {
    "c" => {
      filename: "test.c",
      source: "void* p = malloc(10);",
      line: 1,
      hazard_type: "c_lsan_lifetime",
      required_evidence: "lsan",
      rule_id: "slopcop-c-lsan-uncovered"
    },
    "cpp" => {
      filename: "test.cpp",
      source: "void* p = malloc(10);",
      line: 1,
      hazard_type: "cpp_lsan_lifetime",
      required_evidence: "lsan",
      rule_id: "slopcop-cpp-lsan-uncovered"
    },
    "csharp" => {
      filename: "test.cs",
      source: "class Demo { void Test() { lock(this) {} } }",
      line: 1,
      hazard_type: "csharp_concurrency",
      required_evidence: "concurrency",
      rule_id: "slopcop-csharp-concurrency-uncovered"
    },
    "go" => {
      filename: "test.go",
      source: "package main\nfunc test() {\n  go func() {}()\n}",
      line: 3,
      hazard_type: "go_race_goroutine",
      required_evidence: "race",
      rule_id: "slopcop-go-race-uncovered"
    },
    "zig" => {
      filename: "zig/runtime/test.zig",
      source: "fn test(cb: anytype) void { cb.store(1, .release); }",
      line: 1,
      hazard_type: "zig_loom_atomic",
      required_evidence: "loom",
      rule_id: "slopcop-zig-loom-uncovered"
    },
    "rust" => {
      filename: "test.rs",
      source: "unsafe fn test() {}",
      line: 1,
      hazard_type: "rust_unsafe_fn",
      required_evidence: "miri",
      rule_id: "slopcop-rust-miri-uncovered"
    }
  }

  def test_enforcement_matrix_for_all_languages
    LANGUAGES.each do |lang, config|
      with_file(config[:filename], config[:source]) do |dir, path|
        provider = SlopCop::Constraints.providers.fetch(lang)
        
        # 1. Hazard fails audit without evidence
        no_evidence = SlopCop::Constraints::Evidence.from_specs([], repo: dir)
        findings = provider.findings(repo: dir, additions: { path => [config[:line]] }, evidence: no_evidence)
        assert_equal 1, findings.size, "Expected 1 finding for #{lang} without evidence"
        finding = findings.first
        assert_equal config[:rule_id], finding.rule_id
        assert_equal config[:line], finding.line
        assert_equal config[:hazard_type], finding.hazard_type
        assert_equal config[:required_evidence], finding.required_evidence

        # 2. Correct evidence suppresses hazard
        correct_cobertura = make_cobertura(dir, path, config[:line] => 1)
        correct_evidence = SlopCop::Constraints::Evidence.from_specs(["#{config[:required_evidence]}:#{correct_cobertura}"], repo: dir)
        correct_findings = provider.findings(repo: dir, additions: { path => [config[:line]] }, evidence: correct_evidence)
        assert_empty correct_findings, "Expected correct evidence to suppress #{lang} hazard"

        wrong_cobertura = make_cobertura(dir, path, config[:line] => 0)
        wrong_evidence = SlopCop::Constraints::Evidence.from_specs(["#{config[:required_evidence]}:#{wrong_cobertura}"], repo: dir)
        wrong_findings = provider.findings(repo: dir, additions: { path => [config[:line]] }, evidence: wrong_evidence)
        assert_equal 1, wrong_findings.size, "Expected wrong evidence count/hits to not suppress #{lang} hazard"
      end
    end
  end

  def test_failing_closed_behavior
    # 4. Execution failures fail the audit
    with_file("test.rb", "def test; end") do |dir, path|
      provider = SlopCop::Constraints::RubyProvider
      original_bin = ENV["FACT_MINE_RUST_BINARY"]
      ENV["FACT_MINE_RUST_BINARY"] = "/nonexistent/binary"
      begin
        assert_raises(StandardError) do
          provider.findings(repo: dir, additions: { path => [1] }, evidence: SlopCop::Constraints::Evidence.from_specs([], repo: dir))
        end
      ensure
        ENV["FACT_MINE_RUST_BINARY"] = original_bin
      end
    end
  end

  def test_multiple_hazards_are_retained
    # Multiple sanitizer hazards are retained. Review-only dynamic-boundary
    # sites are reported separately from coverage-satisfiable hazards.
    with_file("test.c", "void f(void) {\n  malloc(1);\n  memcpy(dst, src, n);\n}") do |dir, path|
      provider = SlopCop::Constraints::CProvider
      no_evidence = SlopCop::Constraints::Evidence.from_specs([], repo: dir)
      findings = provider.findings(repo: dir, additions: { path => [2, 3] }, evidence: no_evidence)
      assert_equal 2, findings.size
      assert_equal "c_lsan_lifetime", findings[0].hazard_type
      assert_equal "c_asan_raw_memory_api", findings[1].hazard_type
    end
  end

  private

  def with_file(name, contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      yield dir, name
    end
  end

  def make_cobertura(dir, path, hits)
    @cobertura_counter ||= 0
    @cobertura_counter += 1
    coverage = File.join(dir, "coverage_#{@cobertura_counter}.xml")
    lines = hits.map do |line, count|
      %(<line number="#{line}" hits="#{count}"/>)
    end.join("\n")
    File.write(coverage, <<~XML)
      <?xml version="1.0" ?>
      <coverage>
        <sources><source>#{dir}</source></sources>
        <packages><package name=""><classes>
          <class name="example" filename="#{path}">
            <lines>
              #{lines}
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML
    coverage
  end
end
