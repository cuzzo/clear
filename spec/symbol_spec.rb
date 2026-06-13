require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/type" unless defined?(Type)
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

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
  end

  # =========================================================================
  # MIR lowering / Zig emission
  # =========================================================================
  describe "Zig code generation" do
    it "emits a symbol literal as a Zig string literal" do
      zig = compile_symbol_src(<<~CLEAR)
        FN main() RETURNS Void ->
          x = :ok;
          RETURN;
        END
      CLEAR
      expect(zig).to include('"ok"')
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
      expect(zig).to include('"debug"')
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
      expect(zig).to include('"release"')
      # Return type is []const u8 (same wire type)
      expect(zig).to include("[]const u8")
    end
  end

end
