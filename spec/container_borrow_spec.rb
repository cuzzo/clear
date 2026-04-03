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
  # HashMap indexing registers borrow in OwnershipGraph
  # =========================================================================
  it "registers HashMap get result as borrowed in OG" do
    src = <<~CLEAR
      STRUCT Env { x: Int64 }
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(MUTABLE pool: Env[10]@pool, MUTABLE map: HashMap<Value>) RETURNS Void ->
          pool.insert(Env{ x: 1 });
          val = map["key"] OR Value.Nil;
          RETURN;
      END
    CLEAR
    _ast, ann = annotate(src)
    og = ann.instance_variable_get(:@og)
    expect(og.borrowed?("val")).to be true
    expect(og.borrow_source("val")).to eq("map")
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
  # Returning a container borrow without lifetime annotation is an error
  # =========================================================================
  it "raises error when returning container_borrow without lifetime" do
    expect_error(<<~CLEAR, /Cannot return.*borrowed/)
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN getVal!(MUTABLE map: HashMap<Value>) RETURNS Value ->
          val = map["key"] OR Value.Nil;
          RETURN val;
      END
    CLEAR
  end
end
