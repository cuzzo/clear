require "rspec"

require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "runtime IS_A union sugar" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    ClearParser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  it "lowers explicit union variant checks to active tag comparisons" do
    zig = transpile(<<~CLEAR)
      UNION Shape { Circle: Float64, Point }

      FN main() RETURNS Void ->
        s: Shape = Shape.Point;
        IF s IS_A Shape.Point THEN
          PASS
        END
      END
    CLEAR

    expect(zig).to include("std.meta.activeTag(s)")
    expect(zig).to include(".Point")
  end

  it "binds payloads in the then branch" do
    expect {
      annotate(<<~CLEAR)
        UNION Shape { Circle: Float64, Point }

        FN main() RETURNS Void ->
          s: Shape = Shape{ Circle: 5.0 };
          IF s IS_A Shape.Circle AS radius THEN
            x = radius + 1.0;
          END
        END
      CLEAR
    }.not_to raise_error
  end

  it "allows variant-name shorthand for AST-style node unions" do
    expect {
      annotate(<<~CLEAR)
        STRUCT BinaryOp { value: Int64 }
        STRUCT Identifier { name: String }
        UNION Node { BinaryOp: BinaryOp, Identifier: Identifier }

        FN main() RETURNS Void ->
          node: Node = Node{ BinaryOp: BinaryOp{ value: 1 } };
          IF node IS_A BinaryOp AS bin_op THEN
            value = bin_op.value;
          END
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects ambiguous payload-type shorthand" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Payload { value: Int64 }
        UNION Node { A: Payload, B: Payload }

        FN main() RETURNS Void ->
          node: Node = Node{ A: Payload{ value: 1 } };
          IF node IS_A Payload AS payload THEN
            value = payload.value;
          END
        END
      CLEAR
    }.to raise_error(CompilerError, /matches multiple variants of union Node: A, B/)
  end

  it "rejects runtime IS_A on non-union values" do
    expect {
      annotate(<<~CLEAR)
        STRUCT BinaryOp { value: Int64 }

        FN main() RETURNS Void ->
          node = BinaryOp{ value: 1 };
          IF node IS_A BinaryOp THEN
            PASS
          END
        END
      CLEAR
    }.to raise_error(CompilerError, /requires a union-typed value/)
  end

  it "keeps COMPTIME autofix for type-parameter predicates" do
    FixCollector.enable!
    begin
      annotate(<<~CLEAR) rescue nil
        STRUCT BinaryOp { value: Int64 }

        FN handle<T>(node: T) RETURNS Void ->
          IF T IS_A BinaryOp THEN
            PASS
          END
        END
      CLEAR

      finding = FixCollector.drain.find { |f| f.message.include?("COMPTIME IF") }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("COMPTIME ")
    ensure
      FixCollector.disable!
    end
  end
end
