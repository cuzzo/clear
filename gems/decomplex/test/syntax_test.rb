# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class SyntaxTest < Minitest::Test
  def with_file(source, ext = ".rb")
    file = Tempfile.new(["syntax", ext])
    file.write(source)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def test_rubyvm_adapter_extracts_decision_and_write_facts
    with_file(<<~RB) do |path|
      def classify(node)
        node.storage = :heap
        case node
        when AST::FuncCall then 1
        when AST::MethodCall then 2
        end
        return true if node.ready? && @enabled
      end
    RB
      doc = Decomplex::Syntax.parse(path)

      assert_equal :ruby, doc.language
      assert_equal [:case_dispatch, :conjunction], doc.decision_sites.map(&:kind)
      assert_equal %w[AST::FuncCall AST::MethodCall], doc.decision_sites.first.members

      write = doc.state_writes.first
      assert_equal "storage", write.field
      assert_equal "node", write.receiver
      assert_equal "classify", write.function
    end
  end

  def test_unknown_parser_fails_loudly
    with_file("def a; end\n") do |path|
      error = assert_raises(ArgumentError) do
        Decomplex::Syntax.parse(path, parser: "wat")
      end
      assert_match(/unknown decomplex parser/, error.message)
    end
  end

  def test_tree_sitter_parser_path_requires_a_grammar
    with_file("def a; end\n") do |path|
      error = nil
      with_env("DECOMPLEX_TS_RUBY_PATH", nil) do
        error = assert_raises(LoadError) do
          Decomplex::Syntax.parse(path, parser: "tree_sitter")
        end
      end
      assert_match(/missing Tree-sitter grammar/, error.message)
    end
  end

  def test_tree_sitter_ruby_adapter_extracts_portable_facts_when_grammar_is_available
    grammar = ENV["DECOMPLEX_TS_RUBY_PATH"]
    skip "set DECOMPLEX_TS_RUBY_PATH to run Tree-sitter adapter smoke test" unless grammar && File.file?(grammar)

    with_file(<<~RB) do |path|
      def classify(node)
        node.storage = :heap
        case node
        when AST::FuncCall then 1
        when AST::MethodCall then 2
        end
        return true if node.ready? && @enabled
      end
    RB
      doc = Decomplex::Syntax.parse(path, parser: "tree_sitter", language: :ruby)

      assert_equal :ruby, doc.language
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
      assert_includes doc.decision_sites.map(&:kind), :conjunction
      assert_equal %w[AST::FuncCall AST::MethodCall], doc.decision_sites.find { |s| s.kind == :case_dispatch }.members
      assert_equal "storage", doc.state_writes.first.field
    end
  end

  def test_tree_sitter_language_profiles_extract_portable_facts_when_grammars_are_available
    profiles = {
      python: [
        "DECOMPLEX_TS_PYTHON_PATH",
        ".py",
        <<~PY
          def classify(node):
              node.storage = 'heap'
              if node.ready and node.enabled:
                  return True
              match node.kind:
                  case 'a': return 1
                  case 'b': return 2
        PY
      ],
      javascript: [
        "DECOMPLEX_TS_JAVASCRIPT_PATH",
        ".js",
        <<~JS
          function classify(node) {
            node.storage = 'heap';
            if (node.ready && node.enabled) return true;
            switch (node.kind) { case 'a': return 1; case 'b': return 2; }
          }
        JS
      ],
      typescript: [
        "DECOMPLEX_TS_TYPESCRIPT_PATH",
        ".ts",
        <<~TS
          function classify(node: Node): boolean {
            node.storage = "heap";
            if (node.ready && node.enabled) return true;
            switch (node.kind) { case "a": return true; case "b": return false; }
            return false;
          }
        TS
      ],
      go: [
        "DECOMPLEX_TS_GO_PATH",
        ".go",
        <<~GO
          package p
          func classify(node Node) bool {
            node.storage = "heap"
            if node.ready && node.enabled { return true }
            switch node.kind { case "a": return true; case "b": return false }
            return false
          }
        GO
      ],
      rust: [
        "DECOMPLEX_TS_RUST_PATH",
        ".rs",
        <<~RS
          fn classify(node: Node) -> bool {
            node.storage = "heap";
            if node.ready && node.enabled { return true; }
            match node.kind { "a" => 1, "b" => 2, _ => 0 };
            false
          }
        RS
      ],
      zig: [
        "DECOMPLEX_TS_ZIG_PATH",
        ".zig",
        <<~ZIG
          pub fn classify(node: Node) bool {
              node.storage = .heap;
              if (node.ready and node.enabled) return true;
              switch (node.kind) {
                  .a => return true,
                  .b => return false,
                  else => return false,
              }
          }
        ZIG
      ]
    }
    available = profiles.select { |_lang, (env, _ext, _source)| ENV[env] && File.file?(ENV[env]) }
    skip "set Tree-sitter grammar paths to run non-Ruby profile smoke tests" if available.empty?

    available.each do |language, (_env, ext, source)|
      with_file(source, ext) do |path|
        doc = Decomplex::Syntax.parse(path, parser: "tree_sitter", language: language)

        assert_includes doc.decision_sites.map(&:kind), :case_dispatch, language
        assert_includes doc.decision_sites.map(&:kind), :conjunction, language
        assert_includes doc.state_writes.map(&:field), "storage", language
      end
    end
  end

  def test_tree_sitter_report_runs_full_detector_set_for_non_ruby_when_grammar_is_available
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Tree-sitter report smoke test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def classify_one(node):
          node.storage = 'heap'
          if node.ready and node.enabled:
              return True
          match node.kind:
              case 'a': return 1
              case 'b': return 2

      def classify_two(node):
          node.storage = 'stack'
          if node.ready and node.enabled:
              return True
          match node.kind:
              case 'a': return 1
              case 'b': return 2
    PY
      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        report = Decomplex::Report.new([path])
        sections = report.sections_data.to_h { |title, _tier, rows| [title, rows] }

        refute_empty sections.fetch("Missing Abstractions")
        refute_empty sections.fetch("State-Based Branch Density")
      end
    end
  end
end
