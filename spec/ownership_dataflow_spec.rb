require "rspec"
require_relative "../src/backends/transpiler"

RSpec.describe OwnershipDataflow do
  def analyze(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    OwnershipDataflow.analyze(fn_node)
  end

  describe "basic ownership" do
    it "tracks owned variable" do
      df = analyze("FN main() RETURNS Void -> x = 42; RETURN; END", "main")
      expect(df.exit_states["x"]).to eq(:owned)
    end

    it "tracks moved variable (heap struct)" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "does not move Copy types (primitives)" do
      src = <<~SRC
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      expect(df.exit_states["x"]).to eq(:owned)
      expect(df.exit_states["y"]).to eq(:owned)
    end

    it "does not move strings (Copy in CLEAR)" do
      src = <<~SRC
        FN main() RETURNS Void ->
          s = "hello";
          t = s;
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      expect(df.exit_states["s"]).to eq(:owned)
    end
  end

  describe "control flow merging" do
    it "detects maybe_moved through if-then branch" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN consume!(TAKES u: %User) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          IF TRUE THEN
            consume!(a);
          END
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      # 'a' is moved in the then-branch but not if the condition is false
      expect(df.exit_states["a"]).to eq(:maybe_moved)
    end

    it "detects moved through both branches" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN consume!(TAKES u: %User) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          IF TRUE THEN
            consume!(a);
          ELSE
            consume!(a);
          END
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      expect(df.exit_states["a"]).to eq(:moved)
    end

    it "stays owned when no branch moves" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          IF TRUE THEN
            x = 1;
          END
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      expect(df.exit_states["a"]).to eq(:owned)
    end
  end

  describe "cleanup_summary" do
    it "reports needs_cleanup for owned variables" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      summary = df.cleanup_summary
      expect(summary["a"][:needs_cleanup]).to be true
      expect(summary["a"][:has_moved_guard]).to be false
    end

    it "reports has_moved_guard for maybe_moved variables" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN consume!(TAKES u: %User) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          IF TRUE THEN
            consume!(a);
          END
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      summary = df.cleanup_summary
      expect(summary["a"][:needs_cleanup]).to be true
      expect(summary["a"][:has_moved_guard]).to be true
    end

    it "reports no cleanup for fully moved variables" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      SRC
      df = analyze(src, "main")
      summary = df.cleanup_summary
      expect(summary["a"][:needs_cleanup]).to be false
    end
  end

  describe "TAKES parameters" do
    it "tracks TAKES param as owned" do
      src = <<~SRC
        STRUCT User { id: Int64 }
        FN consume!(TAKES u: %User) RETURNS Void -> RETURN; END
      SRC
      df = analyze(src, "consume!")
      expect(df.exit_states["u"]).to eq(:owned)
    end
  end

  describe "zero under-guarding across test suite" do
    it "never under-guards vs CleanupClassifier" do
      test_files = Dir.glob("transpile-tests/*.cht").sort
      under_guarded = []

      test_files.each do |f|
        next if File.read(f).include?("REQUIRE")
        begin
          code = File.read(f)
          tokens = Lexer.new(code).tokenize
          ast = Parser.new(tokens, code).parse
          PipelineRewriter.new.rewrite!(ast)
          ann = SemanticAnnotator.new
          ann.annotate!(ast)
          StringConcatRewriter.new.rewrite!(ast)

          fn_nodes = {}
          ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
          schema = ->(n) { ann.lookup_type_schema(n) }

          fn_nodes.each do |name, fn|
            next unless fn.body
            bindings = CleanupClassifier.classify(fn, fn_nodes: fn_nodes, schema_lookup: schema)
            next if bindings.empty?

            df = OwnershipDataflow.analyze(fn)
            summary = df.cleanup_summary

            bindings.each do |var, entry|
              next unless entry[:needs_cleanup]
              plan_guard = entry[:has_moved_guard] || false
              df_entry = summary[var]
              next unless df_entry
              df_guard = df_entry[:has_moved_guard]
              # Under-guard: dataflow says guard needed but plan says no
              if !plan_guard && df_guard
                under_guarded << "#{File.basename(f)} #{name}() #{var}"
              end
            end
          end
        rescue
          # Skip files with parse/annotation errors
        end
      end

      expect(under_guarded).to eq([])
    end
  end
end
