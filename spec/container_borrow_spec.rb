require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/transpiler"

RSpec.describe "Container borrow semantics" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def expect_error(src, pattern)
    expect { annotate(src) }.to raise_error(CompilerError, pattern)
  end

  def expect_no_error(src)
    expect { annotate(src) }.not_to raise_error
  end

  # =========================================================================
  # Pool indexing registers borrow in OwnershipGraph
  # =========================================================================
  it "registers pool indexing result as borrowed in OG" do
    src = <<~CLEAR
      STRUCT Env { vars: HashMap<Float64> }
      FN test!(MUTABLE pool: Env[10]@pool) RETURNS Void ->
          env = pool[0_u64];
          RETURN;
      END
    CLEAR
    _ast, ann = annotate(src)
    og = ann.instance_variable_get(:@og)
    expect(og.borrowed?("env")).to be true
    expect(og.borrow_source("env")).to eq("pool")
  end

  # =========================================================================
  # OR on container borrow with Copy fallback is allowed
  # =========================================================================
  it "allows OR with Copy fallback on container borrow" do
    expect_no_error(<<~CLEAR)
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
          val = map["key"] OR Value.Nil;
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # OR on container borrow with non-Copy fallback is an error
  # =========================================================================
  it "raises error when OR fallback is non-Copy on container borrow" do
    expect_error(<<~CLEAR, /Cannot use OR with non-Copy fallback/)
      UNION Value { Nil, Num: Float64, List: Value[], Lambda { body: Value @indirect, id: Int64 } }
      FN makeList!() RETURNS Value ->
          MUTABLE items: Value[]@list = List[];
          items.append(Value{ Num: 1.0 });
          RETURN Value{ List: items };
      END
      FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
          val = map["key"] OR makeList!();
          RETURN;
      END
    CLEAR
  end

  # =========================================================================
  # Returning a container borrow without lifetime annotation is an error
  # =========================================================================
  it "raises error when returning container_borrow without lifetime" do
    expect_error(<<~CLEAR, /Cannot return.*borrowed/)
      STRUCT Env { vars: HashMap<Float64> }
      FN getEnv!(MUTABLE pool: Env[10]@pool) RETURNS ?Env ->
          env = pool[0_u64];
          RETURN env;
      END
    CLEAR
  end
end
