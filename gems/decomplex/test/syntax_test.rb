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

  def test_default_tree_sitter_adapter_extracts_decision_and_write_facts
    grammar = ENV["DECOMPLEX_TS_RUBY_PATH"]
    skip "set DECOMPLEX_TS_RUBY_PATH to run default Tree-sitter adapter smoke test" unless grammar && File.file?(grammar)

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
      doc = Decomplex::Syntax.parse(path, language: :ruby)

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
    adapter_class = Decomplex::Syntax::TreeSitterAdapter
    original = adapter_class.instance_method(:grammar_candidates)
    adapter_class.define_method(:grammar_candidates) { |_language| [] }

    with_file("def a; end\n") do |path|
      error = nil
      with_env("DECOMPLEX_TS_RUBY_PATH", nil) do
        error = assert_raises(LoadError) do
          Decomplex::Syntax.parse(path, parser: "tree_sitter")
        end
      end
      assert_match(/missing Tree-sitter grammar/, error.message)
    end
  ensure
    adapter_class&.define_method(:grammar_candidates, original) if original
  end

  def test_tree_sitter_grammar_candidates_keep_only_current_platform_prebuilds
    adapter = Decomplex::Syntax::TreeSitterAdapter.new
    os = adapter.send(:host_os)
    arch = adapter.send(:host_arch)
    skip "unknown host platform" unless os && arch

    current = "/tmp/pkg/prebuilds/#{os}-#{arch}/tree-sitter-ruby.node"
    other = "/tmp/pkg/prebuilds/darwin-arm64/tree-sitter-ruby.node"
    other = "/tmp/pkg/prebuilds/linux-x64/tree-sitter-ruby.node" if other == current

    assert_equal [current], adapter.send(:platform_prebuilds, [other, current])
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
        refute_empty doc.branch_arms, language
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

  def test_tree_sitter_python_adapter_extracts_hidden_assignment_and_call_facts
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      class Worker:
          def __init__(self, items):
              self.items = items

          def call(self):
              self.items.append("x")
    PY
      doc = Decomplex::Syntax.parse(path, parser: "tree_sitter", language: :python)

      assert_includes doc.state_writes.map { |write| [write.receiver, write.field] }, ["self", "items"]
      assert_includes doc.state_param_origins.map { |origin| [origin.owner, origin.function, origin.receiver, origin.field, origin.param] },
        ["Worker", "__init__", "self", "items", "items"]
      assert_includes doc.call_sites.map { |call| [call.owner, call.function, call.receiver, call.message] },
        ["Worker", "call", "self.items", "append"]
    end
  end

  def test_tree_sitter_zig_adapter_extracts_structural_facts_when_grammar_is_available
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~ZIG, ".zig") do |path|
      pub fn Box(comptime T: type) type {
          return struct {
              value: T,
              count: usize = 0,
              const Self = @This();
              pub fn init(value: T) Self {
                  return .{ .value = value, .count = 1 };
              }
              pub fn get(self: *Self) T {
                  self.count = self.count + 1;
                  self.bump();
                  return self.value;
              }
              fn bump(self: *Self) void {
                  self.count = self.count + 1;
              }
          };
      }
    ZIG
      doc = Decomplex::Syntax.parse(path, parser: "tree_sitter", language: :zig)

      assert_includes doc.owner_defs.map(&:name), "Box"
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Box", "get"]
      assert_includes doc.state_declarations.map { |state| [state.owner, state.field, state.type] }, ["Box", "value", "T"]
      assert_includes doc.state_param_origins.map { |origin| [origin.owner, origin.field, origin.param] }, ["Box", "value", "value"]
      assert_includes doc.call_sites.map { |call| [call.owner, call.function, call.receiver, call.message] }, ["Box", "get", "self", "bump"]
    end
  end
end
