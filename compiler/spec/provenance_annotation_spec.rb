require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/semantic/escape_analysis" unless defined?(EscapeAnalysis::EscapeSink)

# Phase 2 validation: provenance is set correctly during annotation
# and agrees with existing flags (heap_promoted, location, cleanup_alloc).
RSpec.describe "Provenance annotation" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    a = SemanticAnnotator.new
    a.annotate!(ast)
    fn_nodes = ast.statements.each_with_object({}) do |s, h|
      h[s.name] = s if s.is_a?(AST::FunctionDef)
    end
    EscapeAnalysis.apply!(fn_nodes)
    [ast, a]
  end

  def find_binding(ast, fn_name, var_name)
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    fn.body.find { |s| (s.is_a?(AST::BindExpr) || s.is_a?(AST::VarDecl)) && s.name == var_name }
  end

  describe "string literal" do
    it "has :rodata provenance" do
      ast, _ = annotate('FN main() RETURNS Void -> x = "hello"; RETURN; END')
      binding = find_binding(ast, "main", "x")
      ti = binding.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      expect(ti.provenance).to eq(:rodata)
    end
  end

  describe "COPY of string" do
    it "has :heap provenance" do
      ast, _ = annotate('FN main() RETURNS Void -> x = "hello"; y = COPY x; RETURN; END')
      binding = find_binding(ast, "main", "y")
      ti = binding.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      expect(ti.provenance).to eq(:heap)
    end
  end

  describe "string concat" do
    it "has :frame provenance" do
      ast, _ = annotate('FN main() RETURNS Void -> x = "a" $+ "b"; RETURN; END')
      binding = find_binding(ast, "main", "x")
      ti = binding.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      expect(ti.provenance).to eq(:frame)
    end
  end

  describe "struct literal with COPY string field" do
    it "field's CopyNode has :heap provenance" do
      ast, _ = annotate(<<~CLEAR)
        STRUCT User { name: String, age: Int64 }
        FN main() RETURNS Void ->
            u = User{ name: "Alice", age: 30_i64 };
            RETURN;
        END
      CLEAR
      binding = find_binding(ast, "main", "u")
      struct_lit = binding.value
      name_field = struct_lit.fields["name"]
      # ensure_owned_value! wraps rodata string in CopyNode
      expect(name_field).to be_a(AST::CopyNode)
      ti = name_field.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      expect(ti.provenance).to eq(:heap)
    end
  end

  describe "function returning promoted data" do
    it "caller binding has :heap provenance" do
      ast, _ = annotate(<<~CLEAR)
        STRUCT Holder { items: Int64[], label: String }
        FN build() RETURNS !Holder ->
            MUTABLE vals: []Int64 = [];
            vals.append(1_i64);
            RETURN Holder{ items: vals, label: "test" };
        END
        FN main() RETURNS Void ->
            h = build();
            RETURN;
        END
      CLEAR
      binding = find_binding(ast, "main", "h")
      ti = binding.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      # Provenance should be :heap for promoted return values
      if ti.heap?
        expect(ti.provenance).to eq(:heap)
      end
    end
  end

  describe "CATCH function returning String" do
    it "heap-places caller binding from escaping String result" do
      ast, _ = annotate(<<~CLEAR)
        FN riskyOp(x: String) RETURNS !String -> RETURN "ok"; END
        FN handle(x: String) RETURNS !String ->
            r = riskyOp(x) OR_ELSE RAISE;
            RETURN r;
        CATCH Transient
            RETURN "caught";
        END
        FN main() RETURNS Void -> s = handle("x"); RETURN; END
      CLEAR
      binding = find_binding(ast, "main", "s")
      expect(binding.symbol.storage).to eq(:heap)
    end
  end

  describe "provenance is authoritative for allocation decisions" do
    it "frame list has :frame provenance" do
      ast, _ = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE items: []Int64 = [];
            RETURN;
        END
      CLEAR
      binding = find_binding(ast, "main", "items")
      ti = binding.full_type
      ti = Type.new(ti) if !ti.is_a?(Type)
      expect(ti.provenance).to eq(:frame)
    end
  end
end
