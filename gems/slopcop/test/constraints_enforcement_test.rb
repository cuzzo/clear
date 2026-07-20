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
    "rust" => {
      filename: "test.rs",
      source: "fn test(cb: fn()) { cb(); }",
      line: 1,
      hazard_type: "rust_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-rust-callback-uncovered"
    },
    "zig" => {
      filename: "zig/runtime/test.zig",
      source: "fn test(cb: anytype) void { cb.store(1, .release); }",
      line: 1,
      hazard_type: "zig_loom_atomic",
      required_evidence: "loom",
      rule_id: "slopcop-zig-loom-uncovered"
    },
    "ruby" => {
      filename: "test.rb",
      source: "def test(cb) cb.call end",
      line: 1,
      hazard_type: "ruby_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-ruby-metaprogramming-uncovered"
    },
    "python" => {
      filename: "test.py",
      source: "def test(cb): cb()",
      line: 1,
      hazard_type: "python_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-python-metaprogramming-uncovered"
    },
    "javascript" => {
      filename: "test.js",
      source: "function test(cb) { cb(); }",
      line: 1,
      hazard_type: "javascript_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-javascript-metaprogramming-uncovered"
    },
    "typescript" => {
      filename: "test.ts",
      source: "function test(cb: () => void) { cb(); }",
      line: 1,
      hazard_type: "typescript_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-typescript-metaprogramming-uncovered"
    },
    "lua" => {
      filename: "test.lua",
      source: "function test(cb) cb() end",
      line: 1,
      hazard_type: "lua_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-lua-metaprogramming-uncovered"
    },
    "java" => {
      filename: "test.java",
      source: "class Demo { void test(Runnable cb) { cb.run(); } }",
      line: 1,
      hazard_type: "java_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-java-metaprogramming-uncovered"
    },
    "kotlin" => {
      filename: "test.kt",
      source: "fun test(cb: () -> Unit) { cb() }",
      line: 1,
      hazard_type: "kotlin_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-kotlin-metaprogramming-uncovered"
    },
    "swift" => {
      filename: "test.swift",
      source: "func test(cb: () -> Void) { cb() }",
      line: 1,
      hazard_type: "swift_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-swift-metaprogramming-uncovered"
    },
    "php" => {
      filename: "test.php",
      source: "<?php function test($cb) { $cb(); }",
      line: 1,
      hazard_type: "php_callback_invocation",
      required_evidence: "nil-kill",
      rule_id: "slopcop-php-metaprogramming-uncovered"
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

  def test_multiple_hazards_on_one_line_are_retained
    # 5. Multiple hazards on one line are retained
    with_file("test.rb", "class Foo; def perform; send(:a); send(:b); end; end") do |dir, path|
      provider = SlopCop::Constraints::RubyProvider
      no_evidence = SlopCop::Constraints::Evidence.from_specs([], repo: dir)
      findings = provider.findings(repo: dir, additions: { path => [1] }, evidence: no_evidence)
      assert_equal 2, findings.size
      assert_equal "ruby_metaprogramming", findings[0].hazard_type
      assert_equal "ruby_metaprogramming", findings[1].hazard_type
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
