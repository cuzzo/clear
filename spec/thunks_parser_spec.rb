require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"

# Thunk Phase 1.1 — parser support for `EFFECTS REENTRANT[:VARIANT]`
# on regular FN definitions. The legacy `@reentrant` annotation
# continues to work; the annotator bridges them in Phase 1.3.
#
# This spec covers ONLY the parser surface; semantic effects (stack
# tier, propagation, NON_REENTRANT constraint solving) are out of
# scope here.

RSpec.describe "Parser: EFFECTS REENTRANT clause" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  def fn(ast, name = "main")
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  it "leaves effects_decl nil when no clause is present" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    expect(fn(ast).effects_decl).to be_nil
  end

  it "parses `EFFECTS REENTRANT` as :reentrant" do
    ast = parse(<<~CLEAR)
      FN walk(n: Int64) RETURNS Void
        EFFECTS REENTRANT ->
        RETURN;
      END
    CLEAR
    expect(fn(ast, "walk").effects_decl).to eq(:reentrant)
  end

  it "parses `EFFECTS REENTRANT:THUNK` as :reentrant_thunk" do
    ast = parse(<<~CLEAR)
      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        RETURN n;
      END
    CLEAR
    expect(fn(ast, "factorial").effects_decl).to eq(:reentrant_thunk)
  end

  it "parses `EFFECTS REENTRANT:TAIL_CALL` as :reentrant_tail_call" do
    ast = parse(<<~CLEAR)
      FN sum(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT:TAIL_CALL ->
        RETURN acc;
      END
    CLEAR
    expect(fn(ast, "sum").effects_decl).to eq(:reentrant_tail_call)
  end

  it "rejects an unknown REENTRANT variant" do
    expect {
      parse(<<~CLEAR)
        FN x() RETURNS Void
          EFFECTS REENTRANT:WAFFLES ->
          RETURN;
        END
      CLEAR
    }.to raise_error(/Unknown REENTRANT variant ':WAFFLES'/)
  end

  it "rejects a non-REENTRANT effect at function level" do
    expect {
      parse(<<~CLEAR)
        FN x() RETURNS Void
          EFFECTS HEAP ->
          RETURN;
        END
      CLEAR
    }.to raise_error(/Function-level EFFECTS only accepts REENTRANT/)
  end

  it "rejects mixing legacy @reentrant with EFFECTS REENTRANT" do
    expect {
      parse(<<~CLEAR)
        FN x() RETURNS Void @reentrant
          EFFECTS REENTRANT ->
          RETURN;
        END
      CLEAR
    }.to raise_error(/has both legacy '@reentrant' annotation and new 'EFFECTS REENTRANT' clause/)
  end

  it "leaves the legacy reentrant attr nil when only EFFECTS is used" do
    ast = parse(<<~CLEAR)
      FN walk() RETURNS Void
        EFFECTS REENTRANT ->
        RETURN;
      END
    CLEAR
    expect(fn(ast, "walk").reentrant).to be_nil
    expect(fn(ast, "walk").tail_call).to be_falsey
  end

  it "still accepts the legacy @reentrant annotation on its own" do
    ast = parse(<<~CLEAR)
      FN walk() RETURNS Void @reentrant ->
        RETURN;
      END
    CLEAR
    f = fn(ast, "walk")
    expect(f.reentrant).to eq(:reentrant)
    expect(f.effects_decl).to be_nil
  end

  it "still accepts the legacy @reentrant:tailCall annotation" do
    ast = parse(<<~CLEAR)
      FN sum(n: Int64) RETURNS Int64 @reentrant:tailCall ->
        RETURN n;
      END
    CLEAR
    f = fn(ast, "sum")
    expect(f.reentrant).to eq(:reentrant)
    expect(f.tail_call).to be(true)
    expect(f.effects_decl).to be_nil
  end
end

# Thunk Phase 1.2 — parser support for `REQUIRES <name>: NON_REENTRANT`
# constraint clauses on function definitions. Multiple clauses are
# allowed (one per parameter); each clause is independently parseable
# so that future constraint kinds can be added without disrupting the
# grammar of existing ones.
#
# Validation that `<name>` actually refers to a function parameter
# happens in the annotator (Phase 1.3); the parser is purely syntactic
# here.

RSpec.describe "Parser: REQUIRES NON_REENTRANT clause" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  def fn(ast, name = "main")
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  it "leaves requires_clauses nil when none are declared" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    expect(fn(ast).requires_clauses).to be_nil
  end

  it "parses a single `REQUIRES f: NON_REENTRANT` clause" do
    ast = parse(<<~CLEAR)
      FN map(items: Int64[], f: FN(Int64) -> Int64) RETURNS !Int64[]
        REQUIRES f: NON_REENTRANT ->
        RETURN items;
      END
    CLEAR
    expect(fn(ast, "map").requires_clauses).to eq("f" => :non_reentrant)
  end

  it "parses multiple REQUIRES clauses on independent parameters" do
    ast = parse(<<~CLEAR)
      FN apply2(f: FN(Int64) -> Int64, g: FN(Int64) -> Int64, x: Int64) RETURNS Int64
        REQUIRES f: NON_REENTRANT
        REQUIRES g: NON_REENTRANT ->
        RETURN x;
      END
    CLEAR
    expect(fn(ast, "apply2").requires_clauses).to eq(
      "f" => :non_reentrant,
      "g" => :non_reentrant,
    )
  end

  it "stacks REQUIRES with EFFECTS REENTRANT" do
    ast = parse(<<~CLEAR)
      FN reduce(items: Int64[], step: FN(Int64, Int64) -> Int64) RETURNS Int64
        EFFECTS REENTRANT
        REQUIRES step: NON_REENTRANT ->
        RETURN 0;
      END
    CLEAR
    f = fn(ast, "reduce")
    expect(f.effects_decl).to eq(:reentrant)
    expect(f.requires_clauses).to eq("step" => :non_reentrant)
  end

  it "rejects an unknown REQUIRES kind" do
    expect {
      parse(<<~CLEAR)
        FN x(f: FN() -> Void) RETURNS Void
          REQUIRES f: WAFFLES ->
          RETURN;
        END
      CLEAR
    }.to raise_error(/Unknown REQUIRES (family or kind|kind) 'WAFFLES'/)
  end

  it "rejects duplicate REQUIRES clauses for the same name" do
    expect {
      parse(<<~CLEAR)
        FN x(f: FN() -> Void) RETURNS Void
          REQUIRES f: NON_REENTRANT
          REQUIRES f: NON_REENTRANT ->
          RETURN;
        END
      CLEAR
    }.to raise_error(/duplicate REQUIRES clause for 'f'/)
  end
end
