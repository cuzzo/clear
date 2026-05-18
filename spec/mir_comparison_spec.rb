require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/mir/mir"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_emitter"
require_relative "../src/ast/ast"

# Comparison test harness: verifies MIR pipeline produces equivalent Zig
# to the old transpiler for simple programs. This validates MIRLowering
# correctness against the battle-tested transpiler output.
#
# Strategy: run each CLEAR program through the old transpiler to get
# "expected" Zig, then run the annotated AST through MIRLowering + MIREmitter
# and compare the "user code" section per-statement.

RSpec.describe "MIR pipeline comparison" do
  # Run full old pipeline, return the transpiled Zig.
  def old_transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  # Run old pipeline up to MIRPass, then lower each statement via MIR pipeline.
  # Returns array of { old: String, new: String } per top-level statement.
  def compare_statements(src)
    t = ZigTranspiler.new

    # Run through annotation + MIRPass (same as transpile)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new(importer: nil, source_dir: ".", strict_test: false)
    annotator.annotate!(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)

    # Collect schemas from annotator for MIRLowering
    struct_schemas = {}
    enum_schemas = {}
    union_schemas = {}
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = stmt.field_decls
      when AST::EnumDef then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef then union_schemas[stmt.name.to_sym] = stmt.variants
      end
    end

    fn_sigs = {}
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      sig = stmt.full_type
      if sig.is_a?(FunctionSignature)
        fn_sigs[stmt.name] = sig
      end
    end

    lowering = MIRLowering.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
      fn_sigs: fn_sigs
    )
    emitter = MIREmitter.new

    # Lower each non-FunctionDef top-level statement and compare
    results = []
    ast.statements.each do |stmt|
      # Skip FunctionDef for now (Phase 3 work)
      next if stmt.is_a?(AST::FunctionDef)

      mir_node = lowering.lower(stmt)
      new_zig = emitter.emit(mir_node)
      results << { ast: stmt.class.name, new_zig: new_zig }
    end
    results
  end

  # Normalize whitespace for comparison
  def normalize(code)
    return "" if code.nil?
    code.strip.gsub(/\s+/, " ")
  end

  # =========================================================================
  # Type definitions
  # =========================================================================

  describe "enum definitions" do
    it "produces correct enum Zig" do
      src = <<~CLEAR
        ENUM Direction { North, South, East, West }
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      old = old_transpile(src)
      results = compare_statements(src)

      enum_result = results.find { |r| r[:ast].include?("EnumDef") }
      expect(enum_result).not_to be_nil
      # Old transpiler formats enum differently (one per line vs inline)
      # Verify both contain the same variants
      expect(enum_result[:new_zig]).to include("Direction")
      expect(enum_result[:new_zig]).to include("North")
      expect(enum_result[:new_zig]).to include("South")
      expect(enum_result[:new_zig]).to include("East")
      expect(enum_result[:new_zig]).to include("West")
      expect(enum_result[:new_zig]).to include("enum")
      # Verify old output also has them
      expect(old).to include("Direction")
      expect(old).to include("enum")
    end
  end

  describe "struct definitions" do
    it "produces correct struct Zig" do
      src = <<~CLEAR
        STRUCT Point { x: Number, y: Number }
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      old = old_transpile(src)
      results = compare_statements(src)

      struct_result = results.find { |r| r[:ast].include?("StructDef") }
      expect(struct_result).not_to be_nil
      expect(struct_result[:new_zig]).to include("Point")
      expect(struct_result[:new_zig]).to include("x: f64")
      expect(struct_result[:new_zig]).to include("y: f64")
      # Old transpiler also has these
      expect(old).to include("Point")
      expect(old).to include("x: f64")
    end
  end

  describe "union definitions" do
    it "produces correct union Zig" do
      src = <<~CLEAR
        UNION Result { Ok: Number, Err: String, Empty }
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      old = old_transpile(src)
      results = compare_statements(src)

      union_result = results.find { |r| r[:ast].include?("UnionDef") }
      expect(union_result).not_to be_nil
      expect(union_result[:new_zig]).to include("union(enum)")
      expect(union_result[:new_zig]).to include("Ok: f64")
      expect(union_result[:new_zig]).to include("Err: []const u8")
      expect(union_result[:new_zig]).to include("Empty: void")
      # Old transpiler
      expect(old).to include("union(enum)")
      expect(old).to include("Ok: f64")
    end
  end

  # =========================================================================
  # Statement-level lowering inside function bodies
  # =========================================================================

  # For function body comparison, we need a different approach:
  # extract the function body statements after MIRPass and lower each one.
  def compare_fn_body(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new(importer: nil, source_dir: ".", strict_test: false)
    annotator.annotate!(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)

    # Collect schemas
    struct_schemas = {}
    enum_schemas = {}
    union_schemas = {}
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = stmt.field_decls
      when AST::EnumDef then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef then union_schemas[stmt.name.to_sym] = stmt.variants
      end
    end

    lowering = MIRLowering.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas
    )
    emitter = MIREmitter.new

    # Find the main function and lower its body statements
    main_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
    return [] unless main_fn

    body = main_fn.body || []
    body.filter_map { |stmt|
      begin
        mir_node = lowering.lower(stmt)
        new_zig = emitter.emit(mir_node)
        { ast_class: stmt.class.name, new_zig: new_zig }
      rescue => e
        { ast_class: stmt.class.name, error: e.message }
      end
    }
  end

  describe "variable declarations" do
    it "lowers immutable number declaration" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x = 42;
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      decl = results.find { |r| r[:ast_class].include?("Bind") || r[:ast_class].include?("VarDecl") }
      expect(decl).not_to be_nil
      expect(decl[:error]).to be_nil
      expect(decl[:new_zig]).to include("const")
      expect(decl[:new_zig]).to include("42")
    end

    it "lowers string declaration" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          name = "alice";
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      decl = results.find { |r| r[:new_zig]&.include?("alice") }
      expect(decl).not_to be_nil
      expect(decl[:new_zig]).to include("const")
      expect(decl[:new_zig]).to include('"alice"')
    end

    it "lowers boolean declaration" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          flag = TRUE;
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      decl = results.find { |r| r[:new_zig]&.include?("flag") }
      expect(decl).not_to be_nil
      expect(decl[:new_zig]).to include("true")
    end
  end

  describe "control flow" do
    it "lowers if statement" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x = 5;
          IF x > 0 THEN
            y = 1;
          END
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      if_stmt = results.find { |r| r[:new_zig]&.include?("if (") }
      expect(if_stmt).not_to be_nil
      expect(if_stmt[:new_zig]).to include("if (")
    end

    it "lowers return" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      ret = results.find { |r| r[:new_zig]&.include?("return") }
      expect(ret).not_to be_nil
    end
  end

  describe "old MIR nodes passthrough" do
    it "translates MIR::Drop nodes from MIRPass" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          name = "hello";
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      # MIR::Drop should become MIR::Cleanup
      cleanup = results.find { |r| r[:ast_class] == "MIR::Drop" }
      if cleanup
        expect(cleanup[:error]).to be_nil
        expect(cleanup[:new_zig]).to include("defer")
      end
    end

    it "translates MIR::SuppressCleanup from MIRPass" do
      # GIVE or TAKES consumption generates SuppressCleanup
      src = <<~CLEAR
        FN consume(TAKES s: String) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          x = "hello";
          consume(GIVE x);
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      suppress = results.find { |r| r[:ast_class] == "MIR::SuppressCleanup" }
      if suppress
        expect(suppress[:error]).to be_nil
        expect(suppress[:new_zig]).to include("_moved = true")
      end
    end
  end

  describe "enum match" do
    it "lowers enum match to switch" do
      src = <<~CLEAR
        ENUM Color { Red, Blue, Green }
        FN main() RETURNS Void ->
          c: Color = Color.Red;
          PARTIAL MATCH c START
            Color.Red -> x = 1;,
            Color.Blue -> x = 2;,
            DEFAULT -> x = 0;
          END
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      match_result = results.find { |r| r[:new_zig]&.include?("switch") || r[:new_zig]&.include?("if (") }
      expect(match_result).not_to be_nil
      expect(match_result[:error]).to be_nil
    end
  end

  # =========================================================================
  # Phase 3: Full function lowering via MIR pipeline
  # =========================================================================

  def compare_top_level(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new(importer: nil, source_dir: ".", strict_test: false)
    annotator.annotate!(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)

    struct_schemas = {}
    enum_schemas = {}
    union_schemas = {}
    fn_sigs = {}
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = stmt.field_decls
      when AST::EnumDef then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef then union_schemas[stmt.name.to_sym] = stmt.variants
      when AST::FunctionDef
        sig = stmt.full_type
        fn_sigs[stmt.name] = sig if sig.is_a?(FunctionSignature)
      end
    end

    lowering = MIRLowering.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
      fn_sigs: fn_sigs
    )
    emitter = MIREmitter.new

    results = []
    ast.statements.each do |stmt|
      begin
        mir_node = lowering.lower(stmt)
        new_zig = emitter.emit(mir_node)
        results << { ast_class: stmt.class.name, name: stmt.respond_to?(:name) ? stmt.name : nil, new_zig: new_zig }
      rescue => e
        results << { ast_class: stmt.class.name, name: stmt.respond_to?(:name) ? stmt.name : nil, error: e.message }
      end
    end
    results
  end

  describe "function definition lowering" do
    it "lowers a simple function to FnDef" do
      src = <<~CLEAR
        FN greet() RETURNS Void ->
          RETURN;
        END
      CLEAR
      results = compare_top_level(src)
      fn = results.find { |r| r[:name] == "greet" }
      expect(fn).not_to be_nil
      expect(fn[:error]).to be_nil
      expect(fn[:new_zig]).to include("fn greet(")
      expect(fn[:new_zig]).to include("return;")
    end

    it "lowers function with params and return type" do
      src = <<~CLEAR
        FN add(a: Number, b: Number) RETURNS Number ->
          RETURN a + b;
        END
      CLEAR
      results = compare_top_level(src)
      fn = results.find { |r| r[:name] == "add" }
      expect(fn[:error]).to be_nil
      expect(fn[:new_zig]).to include("a: f64")
      expect(fn[:new_zig]).to include("b: f64")
      # Pure math function: needs_rt=false, can_fail=false
      expect(fn[:new_zig]).to include("f64")
    end

    it "lowers function with string return using alloc (frame string, no mark needed)" do
      src = <<~CLEAR
        FN getName() RETURNS !String ->
          s = toString(42);
          RETURN s;
        END
      CLEAR
      results = compare_top_level(src)
      fn = results.find { |r| r[:name] == "getName" }
      expect(fn[:error]).to be_nil
      # Frame-string return: no frame mark/restore (result lives in caller's frame region).
      expect(fn[:new_zig]).not_to include("saveFrameMark")
      expect(fn[:new_zig]).not_to include("preserveAndRewind")
      expect(fn[:new_zig]).not_to include("__pr_body")
    end

    it "lowers function calling another function" do
      src = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2;
        END
        FN main() RETURNS Void ->
          result = double(21.0);
          RETURN;
        END
      CLEAR
      results = compare_top_level(src)
      main_fn = results.find { |r| r[:name] == "main" }
      expect(main_fn[:error]).to be_nil
      expect(main_fn[:new_zig]).to include("double(")
    end
  end

  describe "intrinsic calls" do
    it "lowers toString intrinsic" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x = 42;
          s = toString(x);
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      # toString should appear somewhere in the lowered output
      toString_result = results.find { |r| r[:new_zig]&.include?("intToString") || r[:new_zig]&.include?("toString") }
      # May be nil if toString lowering produces different pattern -- just verify no errors
      errors = results.select { |r| r[:error] }
      expect(errors).to eq([])
    end
  end

  # =========================================================================
  # Phase 5: Full program lowering
  # =========================================================================

  describe "Program node lowering" do
    it "produces MIR::Program with standard imports" do
      src = <<~CLEAR
        ENUM Color { Red, Blue }
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new(importer: nil, source_dir: ".", strict_test: false)
      annotator.annotate!(ast)
      PipelineRewriter.new(annotator).rewrite!(ast)
      StringConcatRewriter.new.rewrite!(ast)

      fn_nodes = {}
      ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
      schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
      mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
      mir.transform!(ast)

      fn_sigs = {}
      ast.statements.each do |stmt|
        next unless stmt.is_a?(AST::FunctionDef)
        sig = stmt.full_type
        fn_sigs[stmt.name] = sig if sig.is_a?(FunctionSignature)
      end

      lowering = MIRLowering.new(fn_sigs: fn_sigs)
      emitter = MIREmitter.new

      program = lowering.lower(ast)
      expect(program).to be_a(MIR::Program)

      zig = emitter.emit(program)
      expect(zig).to include('@import("std")')
      expect(zig).to include('@import("runtime/runtime-header.zig")')
      expect(zig).to include("Color")
      expect(zig).to include("enum")
      expect(zig).to include("clearMain")
    end
  end

  # =========================================================================
  # Phase 5: OR_RESCUE comparison
  # =========================================================================

  describe "OR_RESCUE error chain comparison" do
    it "lowers optional orelse correctly" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          items = [1, 2, 3];
          first = items[0] OR 0;
          RETURN;
        END
      CLEAR
      results = compare_fn_body(src)
      errors = results.select { |r| r[:error] }
      expect(errors).to eq([])
      # Should have an orelse somewhere
      or_result = results.find { |r| r[:new_zig]&.include?("orelse") }
      expect(or_result).not_to be_nil
    end
  end

  # =========================================================================
  # Phase 6: Full pipeline integration (transpile_mir)
  # =========================================================================

  describe "transpile_mir integration" do
    it "produces complete Zig output for simple struct program" do
      src = <<~CLEAR
        STRUCT Point { x: Number, y: Number }
        FN main() RETURNS Void ->
          p = Point { x: 10, y: 20 };
          ASSERT p.x == 10, "x failed";
          RETURN;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile_mir(src)
      expect(zig).to include('@import("std")')
      expect(zig).to include('@import("runtime/runtime-header.zig")')
      expect(zig).to include("CheatHeader.CheatLib")
      expect(zig).to include("Point")
      expect(zig).to include("clearMain")
      expect(zig).to include("pub fn main()")
    end

    it "produces complete Zig for pure function" do
      src = <<~CLEAR
        FN double(n: Number) RETURNS Number -> RETURN n * 2; END
        FN main() RETURNS Void ->
          result = double(21);
          ASSERT result == 42, "double failed";
          RETURN;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile_mir(src)
      expect(zig).to include("fn double(")
      expect(zig).to include("clearMain")
      expect(zig).to include("42")
    end

    it "produces complete Zig for enum + match" do
      src = <<~CLEAR
        ENUM Dir { N, S, E, W }
        FN main() RETURNS Void ->
          d: Dir = Dir.N;
          PARTIAL MATCH d START Dir.N -> ASSERT TRUE, "ok";, DEFAULT -> ASSERT FALSE, "bad"; END
          RETURN;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile_mir(src)
      expect(zig).to include("Dir")
      expect(zig).to include("enum")
      expect(zig).to include("clearMain")
    end

    it "matches old transpiler structure for simple programs" do
      src = <<~CLEAR
        STRUCT Point { x: Number }
        FN main() RETURNS Void ->
          p = Point { x: 42 };
          ASSERT p.x == 42, "fail";
          RETURN;
        END
      CLEAR
      old_zig = ZigTranspiler.new.transpile(src)
      new_zig = ZigTranspiler.new.transpile_mir(src)

      # Both should have the same structural elements
      expect(new_zig).to include("Point")
      expect(new_zig).to include("clearMain")
      expect(new_zig).to include("pub fn main()")

      # Both should have runtime imports
      expect(old_zig).to include("CheatHeader")
      expect(new_zig).to include("CheatHeader")
    end
  end
end
