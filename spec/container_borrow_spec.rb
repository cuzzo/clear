require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/transpiler"

# Tests that container access (HashMap get, pool indexing) registers
# borrows in the OwnershipGraph, suppresses cleanup, and prevents
# returning borrowed values without lifetime annotations.

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
  # OR on container borrow is an error (mixes borrowed + owned)
  # =========================================================================
  it "raises error when using OR on container borrow" do
    expect_error(<<~CLEAR, /Cannot use OR.*borrowed/)
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
          val = map["key"] OR Value.Nil;
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
