require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)

# Full pipeline helper: source -> Zig string
def compile_symbol_src(src)
  ZigTranspiler.new.transpile(src, test_mode: true)
end

RSpec.describe "String@symbol" do

  # =========================================================================
  # Lexer
  # Symbol literals are parsed at the parser level (not the lexer level)
  # because ':' is also used as a separator in struct/hash/capability syntax.
  # The lexer emits ':' as CHAR and the identifier as VAR_ID separately.
  # =========================================================================
  describe "Lexer" do
    def tokens(src)
      Lexer.new(src).tokenize
    end

    it "lexes ':ok' as CHAR ':' then VAR_ID 'ok'" do
      toks = tokens(":ok")
      expect(toks[0].type).to eq(:CHAR)
      expect(toks[0].value).to eq(":")
      expect(toks[1].type).to eq(:VAR_ID)
      expect(toks[1].value).to eq("ok")
    end

    it "does not produce SYMBOL_LIT tokens" do
      toks = tokens(":ok :error :pending")
      expect(toks.none? { |t| t.type == :SYMBOL_LIT }).to be true
    end

    it "keeps '::' as DOUBLE_COLON and does not break" do
      toks = tokens("Foo::Bar")
      expect(toks[1].type).to eq(:DOUBLE_COLON)
    end

    it "':' followed by uppercase is CHAR + TYPE_ID (not a symbol)" do
      toks = tokens(":Foo")
      expect(toks[0].type).to eq(:CHAR)
      expect(toks[0].value).to eq(":")
      expect(toks[1].type).to eq(:TYPE_ID)
    end

    it "capability chain '@shared:locked' lexes without SYMBOL_LIT" do
      toks = tokens("@shared:locked")
      expect(toks.none? { |t| t.type == :SYMBOL_LIT }).to be true
      # ':' should be a plain CHAR between the two VAR_IDs
      colon = toks.find { |t| t.type == :CHAR && t.value == ":" }
      expect(colon).not_to be_nil
    end
  end

  # =========================================================================
  # ClearParser
  # =========================================================================
  describe "ClearParser" do
    def parse(src)
      tokens = Lexer.new(src).tokenize
      ClearParser.new(tokens, src).parse
    end

    def main_body(src)
      ast = parse(src)
      ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }.body
    end

    it "parses a symbol literal as AST::Literal with type :SYMBOL" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          x = :ok;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      decl = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(decl).not_to be_nil
      lit = decl.value
      expect(lit).to be_a(AST::Literal)
      expect(lit.type).to eq(:SYMBOL)
      expect(lit.value).to eq("ok")
    end

    it "parses a symbol in a comparison expression" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          ASSERT :ok == :ok, "msg";
          RETURN;
        END
      CLEAR
      # Should not raise a parse error
      expect(ast).not_to be_nil
    end

    it "parses uppercase symbol literals for enum-like tags" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void ->
          tok = :ELLIPSIS;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      decl = body.find { |s| s.respond_to?(:name) && s.name == "tok" }
      expect(decl.value).to be_a(AST::Literal)
      expect(decl.value.type).to eq(:SYMBOL)
      expect(decl.value.value).to eq("ELLIPSIS")
    end

    it "parses @symbol as a type capability annotation on a parameter" do
      ast = parse(<<~CLEAR)
        FN label(tag: String@symbol) RETURNS String ->
          RETURN "x";
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "label" }
      expect(fn).not_to be_nil
      # params are { name:, type: <Type object>, ... } — sync lives on the Type
      param_type = fn.params.first[:type]
      expect(param_type).to be_a(Type)
      expect(param_type.symbol?).to be true
    end
  end

  # =========================================================================
  # Type system
  # =========================================================================
  describe "Type" do
    it "symbol? is true for sync: :symbol" do
      t = Type.new(:String, sync: :symbol)
      expect(t.symbol?).to be true
    end

    it "parses String@symbol through the Type constructor" do
      t = Type.new("String@symbol")
      expect(t.resolved).to eq(:String)
      expect(t.symbol?).to be true
      expect(t.provenance).to eq(:rodata)
    end

    it "symbol? is false for plain String" do
      expect(Type.new(:String).symbol?).to be false
    end

    it "symbol? is false for String@raw" do
      expect(Type.new(:String, sync: :raw).symbol?).to be false
    end

    it "symbol type has :rodata provenance" do
      t = Type.new(:String, sync: :symbol)
      expect(t.provenance).to eq(:rodata)
    end

    it "symbol type is NOT forced to heap" do
      t = Type.new(:String, sync: :symbol)
      expect(t.heap?).to be false
      expect(t.rodata?).to be true
    end

    it "any_sync? excludes :symbol (like :raw)" do
      expect(Type.new(:String, sync: :symbol).any_sync?).to be false
    end

    it "dispatch_key is :string_symbol" do
      t = Type.new(:String, sync: :symbol)
      expect(t.dispatch_key).to eq(:string_symbol)
    end

    it "symbol type is implicitly copyable" do
      t = Type.new(:String, sync: :symbol)
      expect(t.implicitly_copyable?).to be true
    end

    it "symbol type is not caller-owned cleanup-bearing data" do
      t = Type.new(:String, sync: :symbol)
      expect(t.ownership_bearing?).to be false
    end

    it "zig_type is []const u8 (same wire type as String)" do
      t = Type.new(:String, sync: :symbol)
      expect(t.zig_type).to eq("[]const u8")
    end

    it "symbol type via constructor sets provenance to :rodata explicitly" do
      t = Type.new(:String, sync: :symbol, location: :rodata)
      expect(t.symbol?).to be true
      expect(t.provenance).to eq(:rodata)
      expect(t.any_sync?).to be false
    end

    it "preserves symbol capability on optional wrappers" do
      t = Type.optional_of(Type.new(:String, sync: :symbol))
      expect(t.optional?).to be true
      expect(t.symbol?).to be true
      expect(t.wrapped_type.symbol?).to be true
      expect(Type.coercion_surface_name(t)).to eq("?String@symbol")
    end

    it "does not accept a plain String where String@symbol is required" do
      expect(Type.new(:String, sync: :symbol).accepts?(Type.new(:String))).to be false
      expect(Type.new(:String, sync: :symbol).accepts?(Type.new(:String, sync: :symbol))).to be true
    end
  end

  # =========================================================================
  # Annotator
  # =========================================================================
  describe "Annotator" do
    def run(src)
      tokens = Lexer.new(src).tokenize
      ast    = ClearParser.new(tokens, src).parse
      SemanticAnnotator.new.annotate!(ast)
      ast
    end

    it "annotates a symbol literal with String@symbol type" do
      ast = run(<<~CLEAR)
        FN main() RETURNS Void ->
          x = :ok;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      decl = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      lit  = decl.value
      expect(lit.full_type).to be_a(Type)
      expect(lit.full_type.string?).to be true
      expect(lit.full_type.symbol?).to be true
      expect(lit.full_type.rodata?).to be true
    end

    it "infers variable type as String@symbol from a symbol literal" do
      ast = run(<<~CLEAR)
        FN main() RETURNS Void ->
          status = :ok;
          RETURN;
        END
      CLEAR
      body  = ast.statements.first.body
      decl  = body.find { |s| s.respond_to?(:name) && s.name == "status" }
      expect(decl.full_type.symbol?).to be true
    end

    it "accepts String@symbol parameter annotation" do
      expect {
        run(<<~CLEAR)
          FN check(tag: String@symbol) RETURNS Bool ->
            RETURN tag == :ok;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts symbol literal passed to String@symbol parameter" do
      expect {
        run(<<~CLEAR)
          FN check(tag: String@symbol) RETURNS Bool ->
            RETURN tag == :ok;
          END
          FN main() RETURNS Void ->
            check(:ok);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts symbol literal passed to optional String@symbol parameter" do
      expect {
        run(<<~CLEAR)
          FN check(tag: ?String@symbol) RETURNS Bool ->
            RETURN tag != NIL;
          END
          FN main() RETURNS Void ->
            check(:ok);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts symbol literal defaults for String@symbol parameters" do
      expect {
        run(<<~CLEAR)
          FN check(tag = :ok: String@symbol) RETURNS Bool ->
            RETURN tag == :ok;
          END
          FN main() RETURNS Void ->
            check();
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "preserves symbol capability on cast targets" do
      ast = run(<<~CLEAR)
        FN coerce(tag: String) RETURNS String@symbol ->
          RETURN CAST(tag AS String@symbol);
        END
      CLEAR

      ret = ast.statements.first.body.first
      expect(ret.value.full_type.symbol?).to be true
    end

    it "accepts runtime symbol interning through the symbol intrinsic" do
      expect {
        run(<<~CLEAR)
          FN coerce(tag: String) RETURNS String@symbol ->
            RETURN symbol(tag);
          END
        CLEAR
      }.not_to raise_error
    end

    it "does not classify runtime symbol hoists as cleanup-bearing" do
      importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
      ast = CompilerFrontend.compile(<<~CLEAR, importer: importer, source_dir: Dir.pwd).ast
        FN coerce(tag: String) RETURNS String@symbol ->
          RETURN symbol(tag);
        END
      CLEAR

      decl = ast.statements.first.body.find { |node| node.is_a?(AST::VarDecl) && node.name.to_s.start_with?("__hoist_") }
      expect(decl).not_to be_nil
      expect(decl.full_type.symbol?).to be true
      expect(decl.mir_binding_entry.needs_cleanup?).to be false
    end

    it "accepts symbol literals in String@symbol union payloads" do
      expect {
        run(<<~CLEAR)
          UNION MaybeSymbol { SymbolValue: String@symbol }
          FN main() RETURNS Void ->
            value: MaybeSymbol = MaybeSymbol{ SymbolValue: :ok };
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "distinguishes String and String@symbol runtime union payload checks" do
      expect {
        run(<<~CLEAR)
          UNION TemplateValue { StringValue: String, SymbolValue: String@symbol }
          FN is_plain(value: TemplateValue) RETURNS Bool ->
            RETURN value IS_A String;
          END
          FN is_symbol(value: TemplateValue) RETURNS Bool ->
            RETURN value IS_A String@symbol;
          END
        CLEAR
      }.not_to raise_error
    end

    it "coerces a unique union payload return into an optional union" do
      ast = run(<<~CLEAR)
        UNION TemplateValue { StringValue: String, SymbolValue: String@symbol }
        FN copy_symbol(value: TemplateValue) RETURNS ?TemplateValue ->
          IF value IS_A String@symbol AS symbol_value THEN
            RETURN symbol_value;
          END
          RETURN NIL;
        END
      CLEAR

      branch_return = ast.statements[1].body.first.then_branch.first
      coerced_type = Type.new(branch_return.value.coerced_type)
      expect(coerced_type.optional?).to be true
      expect(coerced_type.value_payload_type.resolved).to eq(:TemplateValue)
    end

    it "rejects a plain string literal passed to String@symbol parameter" do
      expect {
        run(<<~CLEAR)
          FN check(tag: String@symbol) RETURNS Bool ->
            RETURN tag == :ok;
          END
          FN main() RETURNS Void ->
            check("ok");
            RETURN;
          END
        CLEAR
      }.to raise_error(/String@symbol/)
    end

    it "rejects assigning a plain string literal to String@symbol" do
      expect {
        run(<<~CLEAR)
          FN main() RETURNS Void ->
            tag: String@symbol = "ok";
            RETURN;
          END
        CLEAR
      }.to raise_error(/String@symbol/)
    end
  end

  # =========================================================================
  # MIR lowering / Zig emission
  # =========================================================================
  describe "Zig code generation" do
    it "emits a symbol literal through the static symbol pool" do
      zig = compile_symbol_src(<<~CLEAR)
        FN main() RETURNS Void ->
          x = :ok;
          RETURN;
        END
      CLEAR
      expect(zig).to include('const __clear_symbol_0: []const u8 = "ok";')
      expect(zig).to include("const x: []const u8 = __clear_symbol_0;")
    end

    it "deduplicates repeated static symbol literals" do
      zig = compile_symbol_src(<<~CLEAR)
        FN main() RETURNS Void ->
          a = :foo;
          b = :foo;
          c = :bar;
          _ = a == b;
          _ = c == :bar;
          RETURN;
        END
      CLEAR
      expect(zig.scan(/const __clear_symbol_\d+: \[\]const u8 = "foo";/).size).to eq(1)
      expect(zig.scan(/const __clear_symbol_\d+: \[\]const u8 = "bar";/).size).to eq(1)
    end

    it "emits the static symbol pool for modules before exported items" do
      zig = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
        PUB FN label() RETURNS String@symbol ->
          RETURN :ok;
        END
      CLEAR
      expect(zig).to include('const __clear_symbol_0: []const u8 = "ok";')
      expect(zig.index("const __clear_symbol_0")).to be < zig.index("pub fn label")
    end

    it "emits symbol == symbol comparison as pointer+length check" do
      zig = compile_symbol_src(<<~CLEAR)
        FN main() RETURNS Void ->
          a = :foo;
          b = :foo;
          _ = a == b;
          RETURN;
        END
      CLEAR
      # symbolEql expands to pointer+length comparison, not CheatLib.eql
      expect(zig).to include(".ptr ==")
      expect(zig).to include(".len ==")
      expect(zig).to include("const a: []const u8 = __clear_symbol_0;")
      expect(zig).to include("const b: []const u8 = __clear_symbol_0;")
      expect(zig).not_to include("CheatLib.eql")
    end

    it "emits != between symbols as negated pointer check" do
      zig = compile_symbol_src(<<~CLEAR)
        FN main() RETURNS Void ->
          a = :foo;
          b = :bar;
          _ = !(a == b);
          RETURN;
        END
      CLEAR
      expect(zig).to include(".ptr ==")
    end

    it "emits ASSERT with symbol comparison" do
      expect {
        compile_symbol_src(<<~CLEAR)
          FN main() RETURNS Void ->
            ASSERT :ok == :ok, "must match";
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "symbol used as function argument emits correct Zig" do
      zig = compile_symbol_src(<<~CLEAR)
        FN tag_label(t: String@symbol) RETURNS String ->
          RETURN "x";
        END
        FN main() RETURNS Void ->
          tag_label(:debug);
          RETURN;
        END
      CLEAR
      expect(zig).to include('const __clear_symbol_0: []const u8 = "debug";')
      expect(zig).to include("tag_label(__clear_symbol_0)")
    end

    it "function returning String@symbol emits correct return type" do
      zig = compile_symbol_src(<<~CLEAR)
        FN mode() RETURNS String@symbol ->
          RETURN :release;
        END
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      expect(zig).to include('const __clear_symbol_0: []const u8 = "release";')
      # Return type is []const u8 (same wire type)
      expect(zig).to include("[]const u8")
    end

    it "lowers symbol intrinsic to runtime interning" do
      zig = compile_symbol_src(<<~CLEAR)
        FN mode(name: String) RETURNS String@symbol ->
          RETURN symbol(name);
        END
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR

      expect(zig).to include("try rt.internSymbol(name)")
    end

    it "wraps a returned symbol payload in the unique union variant" do
      zig = compile_symbol_src(<<~CLEAR)
        UNION TemplateValue { StringValue: String, SymbolValue: String@symbol }
        FN copy_symbol(value: TemplateValue) RETURNS ?TemplateValue ->
          IF value IS_A String@symbol AS symbol_value THEN
            RETURN symbol_value;
          END
          RETURN NIL;
        END
      CLEAR

      expect(zig).to include("return TemplateValue{ .SymbolValue = symbol_value };")
    end

    it "wraps a symbol payload assigned into an optional union map value" do
      zig = compile_symbol_src(<<~CLEAR)
        UNION TemplateValue { StringValue: String, SymbolValue: String@symbol }
        FN put_symbol!(MUTABLE out: HashMap<String, ?TemplateValue>, value: String@symbol) RETURNS Void ->
          out[:value] = value;
        END
      CLEAR

      expect(zig).to include("TemplateValue{ .SymbolValue = value }")
    end
  end

end
