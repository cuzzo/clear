# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/fact_mine/syntax"

class SyntaxTest < Minitest::Test
  def self.populate_tree_sitter_env_defaults
    adapter = FactMine::Syntax::TreeSitterAdapter.new
    FactMine::Syntax::LANGUAGE_PROFILES.each_key do |language|
      env = "DECOMPLEX_TS_#{language.to_s.upcase}_PATH"
      next if ENV[env] && File.file?(ENV[env])

      candidate = adapter.send(:grammar_candidates, language).find { |path| File.file?(path) }
      ENV[env] = candidate if candidate
    end
  end

  populate_tree_sitter_env_defaults

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
      doc = FactMine::Syntax.parse(path, language: :ruby)

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
        FactMine::Syntax.parse(path, parser: "wat")
      end
      assert_match(/unknown decomplex parser/, error.message)
    end
  end

  def test_tree_sitter_parser_path_requires_a_grammar
    adapter_class = FactMine::Syntax::TreeSitterAdapter
    original = adapter_class.instance_method(:grammar_candidates)
    adapter_class.define_method(:grammar_candidates) { |_language| [] }

    with_file("def a; end\n") do |path|
      error = nil
      with_env("DECOMPLEX_TS_RUBY_PATH", nil) do
        error = assert_raises(LoadError) do
          FactMine::Syntax.parse_raw(path, parser: "tree_sitter")
        end
      end
      assert_match(/missing Tree-sitter grammar/, error.message)
    end
  ensure
    adapter_class&.define_method(:grammar_candidates, original) if original
  end

  def test_tree_sitter_grammar_candidates_keep_only_current_platform_prebuilds
    adapter = FactMine::Syntax::TreeSitterAdapter.new
    os = adapter.send(:host_os)
    arch = adapter.send(:host_arch)
    skip "unknown host platform" unless os && arch

    current = "/tmp/pkg/prebuilds/#{os}-#{arch}/tree-sitter-ruby.node"
    other = "/tmp/pkg/prebuilds/darwin-arm64/tree-sitter-ruby.node"
    other = "/tmp/pkg/prebuilds/linux-x64/tree-sitter-ruby.node" if other == current

    assert_equal [current], adapter.send(:platform_prebuilds, [other, current])
  end

  def test_language_profiles_have_language_specific_lexicons
    examples = {
      lua: ["script.lua", "value == nil", "error('bad')"],
      c: ["src/main.c", "ptr == NULL", "abort()"],
      cpp: ["src/main.cpp", "value == nullptr", "throw Error{}"],
      csharp: ["src/Program.cs", "value is string", "throw new Exception()"],
      java: ["src/Main.java", "value instanceof String", "throw new RuntimeException()"],
      swift: ["Sources/App.swift", "if let value = maybe", "fatalError()"],
      kotlin: ["src/Main.kt", "value as? String", "require(value != null)"]
    }

    examples.each do |language, (path, type_guard, diagnostic)|
      lexicon = FactMine::Syntax.language_lexicon(language)

      assert_equal language, FactMine::Syntax.language_for(path)
      assert_instance_of FactMine::Syntax::LanguageLexicon, lexicon, language
      assert lexicon.type_guard?(type_guard), language
      assert lexicon.diagnostic?(diagnostic), language
    end
  end

  def test_tree_sitter_language_profile_owns_parser_metadata
    c = FactMine::Syntax.language_profile(:c)
    assert_equal %w[.c .h], c.extensions
    assert_equal "tree-sitter-c", c.package
    assert_equal %w[c], c.grammar_names
    assert c.first_argument_receiver?

    csharp = FactMine::Syntax.language_profile(:csharp)
    assert_equal "tree-sitter-c-sharp", csharp.package
    assert_equal %w[c-sharp csharp], csharp.grammar_names
    assert_equal "c_sharp", csharp.tree_sitter_language_name
    refute csharp.first_argument_receiver?
  end

  def test_language_profile_fails_loudly_without_supported_language
    refute FactMine::Syntax.const_defined?(:GENERIC_LANGUAGE_PROFILE, false)

    missing = assert_raises(ArgumentError) do
      FactMine::Syntax.language_profile(nil)
    end
    assert_match(/missing Syntax language profile/, missing.message)

    unsupported = assert_raises(ArgumentError) do
      FactMine::Syntax.language_profile(:wat)
    end
    assert_match(/unsupported Syntax language profile/, unsupported.message)
  end

  def test_tree_sitter_adapter_requires_language_profile_context
    adapter = FactMine::Syntax::TreeSitterAdapter.new

    error = assert_raises(ArgumentError) do
      adapter.send(:syntax_profile, nil)
    end
    assert_match(/missing Syntax language profile context/, error.message)
  end

  def test_tree_sitter_language_adapter_normalizes_non_breaking_space
    profile = FactMine::Syntax.language_profile(:python)

    assert_equal "alpha beta", profile.send(:normalize_text, "alpha\u00A0beta")
  end

  def test_tree_sitter_adapter_delegates_language_normalization_to_profiles
    adapter_class = FactMine::Syntax::TreeSitterAdapter
    profile_class = FactMine::Syntax::TreeSitterLanguageAdapter
    ruby_profile_class = FactMine::Syntax::RubySyntaxAdapter

    refute adapter_class.const_defined?(:BRANCH_KINDS, false)
    refute adapter_class.const_defined?(:NOISE_MESSAGES, false)
    refute adapter_class.private_method_defined?(:record_state_write)
    assert profile_class.private_method_defined?(:record_state_write)
    assert ruby_profile_class.private_method_defined?(:skip_state_write_node?)
    assert ruby_profile_class.private_method_defined?(:skip_state_write_target?)
    assert ruby_profile_class.private_method_defined?(:hidden_case?)
    assert ruby_profile_class.private_method_defined?(:case_pattern_texts)
    assert ruby_profile_class.private_method_defined?(:direct_state_ref)
  end

  def test_tree_sitter_document_walks_seed_language_context
    adapter = FactMine::Syntax::TreeSitterAdapter.new
    document = Struct.new(:root, :file, :language, :lines)
                     .new(Object.new, "/tmp/demo.py", :python, [])
    captured = []

    adapter.define_singleton_method(:walk) do |doc, profile, &_block|
      captured << profile.initial_stack(doc)
    end

    adapter.decision_sites(document)
    adapter.branch_decisions(document, immutable_readers: {}, immutable_reader_types: {}, type_aliases: {})
    adapter.branch_arms(document)
    adapter.structural_facts(document)

    expected = [{ file_owner: "demo", language: :python }]
    assert_equal [expected, expected, expected, expected], captured
  end

  def test_force_language_override_handles_ambiguous_headers
    assert_equal :c, FactMine::Syntax.language_for("include/demo.h")

    with_env("DECOMPLEX_FORCE_LANGUAGE", "cpp") do
      assert_equal :cpp, FactMine::Syntax.language_for("include/demo.h")
      assert_equal :cpp, FactMine::Syntax.language_for("src/demo.c")
    end
  end

  def test_tree_sitter_lua_adapter_ignores_generated_teal_compat_prelude
    grammar = ENV["DECOMPLEX_TS_LUA_PATH"]
    skip "set DECOMPLEX_TS_LUA_PATH to run Lua structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~LUA, ".lua") do |path|
      local _tl_compat; if (tonumber((_VERSION or ""):match("[%d.]*$")) or 0) < 5.3 then local pcall, require = pcall, require; local ok, compat53 = pcall(require, "compat53.module"); if ok then compat53.module(_ENV) end end
      function real(a, b)
        if a and b then
          return true
        end
      end
    LUA
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :lua)

      assert_empty doc.decision_sites.select { |decision| decision.line == 1 }
      assert_empty doc.branch_arms.select { |arm| arm.line == 1 }
      assert_includes doc.decision_sites.map { |decision| [decision.line, decision.kind, decision.members] },
        [3, :conjunction, %w[a b]]
    end
  end

  def test_tree_sitter_go_adapter_extracts_name_type_struct_fields
    grammar = ENV["DECOMPLEX_TS_GO_PATH"]
    skip "set DECOMPLEX_TS_GO_PATH to run Go structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~GO, ".go") do |path|
      package util

      type Slab struct {
        I16 []int16
        Count int
      }
    GO
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :go)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Slab", :owner]
      assert_includes doc.state_declarations.map { |state| [state.owner, state.field, state.type] },
        ["Slab", "I16", "[]int16"]
      assert_includes doc.state_declarations.map { |state| [state.owner, state.field, state.type] },
        ["Slab", "Count", "int"]
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
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :ruby)

      assert_equal :ruby, doc.language
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
      assert_includes doc.decision_sites.map(&:kind), :conjunction
      assert_equal %w[AST::FuncCall AST::MethodCall], doc.decision_sites.find { |s| s.kind == :case_dispatch }.members
      assert_equal "storage", doc.state_writes.first.field
    end
  end

  def test_tree_sitter_ruby_adapter_applies_method_visibility
    grammar = ENV["DECOMPLEX_TS_RUBY_PATH"]
    skip "set DECOMPLEX_TS_RUBY_PATH to run Tree-sitter adapter smoke test" unless grammar && File.file?(grammar)

    with_file(<<~RB) do |path|
      class Worker
        def run; end

        private
        def prepare; end
        def validate; end

        public :validate
        protected
        def guarded; end

        private def inline_helper; end
        def self.build; end
        def Worker.explicit; end
      end
    RB
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :ruby)
      functions = doc.function_defs.to_h { |fn| [fn.name, fn] }

      assert_equal :public, functions.fetch("run").visibility
      assert_equal :private, functions.fetch("prepare").visibility
      assert_equal :public, functions.fetch("validate").visibility
      assert_equal :protected, functions.fetch("guarded").visibility
      assert_equal :private, functions.fetch("inline_helper").visibility
      assert_equal :public, functions.fetch("self.build").visibility
      assert_equal :public, functions.fetch("Worker.explicit").visibility
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
        doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: language)

        assert_includes doc.decision_sites.map(&:kind), :case_dispatch, language
        assert_includes doc.decision_sites.map(&:kind), :conjunction, language
        assert_includes doc.state_writes.map(&:field), "storage", language
        refute_empty doc.branch_arms, language
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

      def run(items):
          prepare(items)
    PY
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)

      assert_includes doc.state_writes.map { |write| [write.receiver, write.field] }, ["self", "items"]
      assert_includes doc.state_param_origins.map { |origin| [origin.owner, origin.function, origin.receiver, origin.field, origin.param] },
        ["Worker", "__init__", "self", "items", "items"]
      assert_includes doc.call_sites.map { |call| [call.function, call.receiver, call.message] },
        ["call", "self.items", "append"]
      assert_includes doc.call_sites.map { |call| [call.function, call.receiver, call.message, call.arguments] },
        ["run", "self", "prepare", ["items"]]
    end
  end

  def test_tree_sitter_python_adapter_extracts_typed_attribute_assignments
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      class Worker:
          def __init__(self, items):
              self.items = items
              self.cache: dict[str, int] = items
    PY
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)

      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.span] },
        ["self", "items", [3, 8, 3, 26]]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.span] },
        ["self", "cache", [4, 8, 4, 42]]
      assert_includes doc.state_param_origins.map { |origin| [origin.receiver, origin.field, origin.param, origin.span] },
        ["self", "items", "items", [3, 8, 3, 26]]
      assert_includes doc.state_param_origins.map { |origin| [origin.receiver, origin.field, origin.param, origin.span] },
        ["self", "cache", "items", [4, 8, 4, 42]]
      assert_empty doc.state_reads
    end
  end

  def test_tree_sitter_python_adapter_extracts_typed_splat_parameters
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def reconfigure(*args: Any, **kwargs: Any) -> None:
          new_console = Console(*args, **kwargs)
    PY
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)

      assert_equal %w[args kwargs], doc.function_defs.first.params
      statement = doc.local_methods.first.statements.first
      assert_equal %w[args kwargs], statement.reads.to_a.sort
      assert_equal [["new_console", "args"], ["new_console", "kwargs"]], statement.dependencies
    end
  end

  def test_tree_sitter_python_adapter_treats_annotation_only_locals_as_writes
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def parse_version():
          version_integers: tuple[int, ...]
    PY
      statement = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                     .local_methods
                                     .first
                                     .statements
                                     .first

      assert_empty statement.reads
      assert_equal ["version_integers"], statement.writes.to_a
    end
  end

  def test_tree_sitter_python_adapter_treats_typed_local_assignment_as_write
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def process(value):
          try:
              return_value: PromptType = convert(value)
          except ValueError:
              raise
          return return_value
    PY
      statements = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                      .local_methods
                                      .first
                                      .statements

      assert_includes statements[0].writes, "return_value"
      assert_includes statements[0].reads, "value"
      refute_includes statements[0].reads, "return_value"
      assert_equal ["return_value"], statements[1].reads.to_a
    end
  end

  def test_tree_sitter_python_adapter_mines_loop_and_with_locals_without_keyword_writes
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def download(urls, dest_dir):
          with ThreadPoolExecutor(max_workers=4) as pool:
              for url in urls:
                  filename = url.split("/")[-1]
                  dest_path = os.path.join(dest_dir, filename)
                  task_id = progress.add_task("download", filename=filename, start=False)
                  pool.submit(copy_url, task_id, url, dest_path)
    PY
      statement = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                     .local_methods
                                     .first
                                     .statements
                                     .first

      assert_includes statement.reads, "urls"
      assert_includes statement.reads, "url"
      assert_includes statement.reads, "pool"
      assert_includes statement.writes, "url"
      assert_includes statement.writes, "pool"
      refute_includes statement.writes, "urls"
      refute_includes statement.writes, "max_workers"
      refute_includes statement.writes, "start"
    end
  end

  def test_tree_sitter_python_adapter_counts_callable_locals_as_reads
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def invoke(callback, value):
          runner = callback
          return runner(value)
    PY
      statements = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                      .local_methods
                                      .first
                                      .statements

      assert_equal ["callback"], statements[0].reads.to_a
      assert_equal %w[runner value], statements[1].reads.to_a.sort
    end
  end

  def test_tree_sitter_python_adapter_mines_named_expression_writes
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def scan(text, index):
          if (character := text[index]):
              return character
    PY
      statement = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                     .local_methods
                                     .first
                                     .statements
                                     .first

      assert_includes statement.writes, "character"
      assert_includes statement.reads, "text"
      assert_includes statement.reads, "index"
      assert_includes statement.dependencies, ["character", "text"]
      assert_includes statement.dependencies, ["character", "index"]
    end
  end

  def test_tree_sitter_python_adapter_groups_try_except_as_one_statement
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def foo():
          try:
              raise RuntimeError("Hello")
          except Exception as e:
              raise e from e
    PY
      statements = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                      .local_methods
                                      .first
                                      .statements

      assert_equal 1, statements.length
      assert_includes statements.first.writes, "e"
      assert_includes statements.first.reads, "e"
    end
  end

  def test_tree_sitter_python_adapter_groups_if_elif_chain_as_one_statement
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def align(value):
          if value == "left":
              return 1
          elif value == "right":
              return 2
    PY
      statements = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                      .local_methods
                                      .first
                                      .statements

      assert_equal 1, statements.length
      assert_equal ["value"], statements.first.reads.to_a
    end
  end

  def test_tree_sitter_python_adapter_ignores_import_paths_that_match_locals
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def inspect():
          from rich._inspect import Inspect
          _inspect = Inspect()
          return _inspect
    PY
      statements = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                      .local_methods
                                      .first
                                      .statements

      assert_empty statements[0].reads
      assert_equal ["_inspect"], statements[1].writes.to_a
      assert_equal ["_inspect"], statements[2].reads.to_a
    end
  end

  def test_tree_sitter_python_adapter_reads_bare_with_context_local
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~PY, ".py") do |path|
      def use_status(status):
          with status:
              sleep(0.2)
    PY
      statement = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :python)
                                     .local_methods
                                     .first
                                     .statements
                                     .first

      assert_equal ["status"], statement.reads.to_a
    end
  end

  def test_tree_sitter_c_adapter_extracts_functions_branches_and_pointer_state
    grammar = ENV["DECOMPLEX_TS_C_PATH"]
    skip "set DECOMPLEX_TS_C_PATH to run C structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~C, ".c") do |path|
      typedef struct Node { int storage; int ready; int enabled; int kind; } Node;
      static int classify(Node* node) {
        node->storage = 1;
        if (node->ready && node->enabled) return 1;
        switch (node->kind) { case 1: return 1; case 2: return 2; default: return 0; }
      }
    C
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :c)

      assert_includes doc.function_defs.map(&:name), "classify"
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["self", "storage", "classify"]
      assert_includes doc.decision_sites.map(&:kind), :conjunction
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
    end
  end

  def test_tree_sitter_cpp_adapter_extracts_class_methods_and_pointer_state
    grammar = ENV["DECOMPLEX_TS_CPP_PATH"]
    skip "set DECOMPLEX_TS_CPP_PATH to run C++ structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~CPP, ".cpp") do |path|
      class Parser {
       public:
        int parse(Node* node) {
          node->storage = 1;
          if (node == nullptr || node->ready) return 1;
          switch (node->kind) { case 1: return 1; case 2: return 2; default: return 0; }
        }
      };
    CPP
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :cpp)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Parser", :class]
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Parser", "parse"]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["node", "storage", "parse"]
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
    end
  end

  def test_tree_sitter_csharp_adapter_extracts_class_methods_and_member_state
    grammar = ENV["DECOMPLEX_TS_CSHARP_PATH"]
    skip "set DECOMPLEX_TS_CSHARP_PATH to run C# structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~CS, ".cs") do |path|
      public sealed class Parser {
        private int _storage;
        public int Parse(Node node) {
          this._storage = 1;
          if (node == null || node.Ready) return 1;
          switch (node.Kind) { case 1: return 1; case 2: return 2; default: return 0; }
        }
      }
    CS
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :csharp)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Parser", :class]
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Parser", "Parse"]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["self", "_storage", "Parse"]
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
    end
  end

  def test_tree_sitter_java_adapter_extracts_class_methods_and_member_state
    grammar = ENV["DECOMPLEX_TS_JAVA_PATH"]
    skip "set DECOMPLEX_TS_JAVA_PATH to run Java structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~JAVA, ".java") do |path|
      public final class Parser {
        private int storage;
        public int parse(Node node) {
          this.storage = 1;
          if (node == null || node.ready()) return 1;
          switch (node.kind()) { case 1: return 1; case 2: return 2; default: return 0; }
        }
      }
    JAVA
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :java)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Parser", :class]
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Parser", "parse"]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["self", "storage", "parse"]
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
    end
  end

  def test_tree_sitter_swift_adapter_extracts_class_methods_and_member_state
    grammar = ENV["DECOMPLEX_TS_SWIFT_PATH"]
    skip "set DECOMPLEX_TS_SWIFT_PATH to run Swift structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~SWIFT, ".swift") do |path|
      final class Parser {
        private var storage: Int = 0
        func parse(_ node: Node) -> Int {
          self.storage = 1
          if node == nil || node.ready { return 1 }
          switch node.kind {
          case .one: return 1
          case .two: return 2
          default: return 0
          }
        }
      }
    SWIFT
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :swift)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Parser", :class]
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Parser", "parse"]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["self", "storage", "parse"]
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
    end
  end

  def test_tree_sitter_kotlin_adapter_extracts_class_methods_and_member_state
    grammar = ENV["DECOMPLEX_TS_KOTLIN_PATH"]
    skip "set DECOMPLEX_TS_KOTLIN_PATH to run Kotlin structural facts test" unless grammar && File.file?(grammar)

    with_file(<<~KOTLIN, ".kt") do |path|
      class Parser {
        var storage: Int = 0
        fun parse(node: Node): Int {
          this.storage = 1
          if (node == null || node.ready) return 1
          return when (node.kind) {
            Kind.ONE -> 1
            Kind.TWO -> 2
            else -> 0
          }
        }
      }
    KOTLIN
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :kotlin)

      assert_includes doc.owner_defs.map { |owner| [owner.name, owner.kind] }, ["Parser", :class]
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Parser", "parse"]
      assert_includes doc.state_writes.map { |write| [write.receiver, write.field, write.function] },
        ["self", "storage", "parse"]
      assert_includes doc.decision_sites.map(&:kind), :case_dispatch
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
      doc = FactMine::Syntax.parse(path, parser: "tree_sitter", language: :zig)

      assert_includes doc.owner_defs.map(&:name), "Box"
      assert_includes doc.function_defs.map { |fn| [fn.owner, fn.name] }, ["Box", "get"]
      assert_includes doc.state_declarations.map { |state| [state.owner, state.field, state.type] }, ["Box", "value", "T"]
      assert_includes doc.state_param_origins.map { |origin| [origin.owner, origin.field, origin.param] }, ["Box", "value", "value"]
      assert_includes doc.call_sites.map { |call| [call.owner, call.function, call.receiver, call.message] }, ["Box", "get", "self", "bump"]
    end
  end
end
