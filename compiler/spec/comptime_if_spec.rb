require "rspec"

require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "COMPTIME IF type predicates" do
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

  it "lowers generic IS_A type predicates to Zig comptime type equality" do
    zig = transpile(<<~CLEAR)
      STRUCT Box {}

      FN handle<T>(x: T) RETURNS Void ->
        COMPTIME IF T IS_A Box THEN
          PASS
        END
      END

      FN main() RETURNS Void -> PASS END
    CLEAR

    expect(zig).to include("fn handle(comptime T: type, x: T)")
    expect(zig).to include("if (comptime (T == Box))")
  end

  it "parses capability-qualified type annotations on the right side" do
    ast = parse(<<~CLEAR)
      FN handle<T>(x: T) RETURNS Void ->
        COMPTIME IF T IS_A String@symbol THEN
          PASS
        END
      END
    CLEAR

    fn = ast.statements.first
    condition = fn.body.first.condition
    expect(condition.right).to be_a(Type)
    expect(condition.right.symbol?).to be true
  end

  it "lowers capability-qualified IS_A type predicates" do
    zig = transpile(<<~CLEAR)
      FN handle<T>(x: T) RETURNS Void ->
        COMPTIME IF T IS_A String@symbol THEN
          PASS
        END
      END

      FN main() RETURNS Void -> PASS END
    CLEAR

    expect(zig).to include("fn handle(comptime T: type, x: T)")
    expect(zig).to include("if (comptime (T == []const u8))")
  end

  it "allows a then-branch type binding" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box {}

        FN handle<T>(x: T) RETURNS Void ->
          COMPTIME IF T IS_A Box AS matched THEN
            PASS
          END
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects a non-type left operand" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box {}

        FN main() RETURNS Void ->
          x = 1;
          COMPTIME IF x IS_A Box THEN
            PASS
          END
        END
      CLEAR
    }.to raise_error(CompilerError, /Left side of IS_A must be a type, got Int64/)
  end

  it "rejects a non-type right operand" do
    expect {
      annotate(<<~CLEAR)
        FN handle<T>(x: T) RETURNS Void ->
          y = 1;
          COMPTIME IF T IS_A y THEN
            PASS
          END
        END
      CLEAR
    }.to raise_error(CompilerError, /Right side of IS_A must be a type, got Int64/)
  end

  it "emits an autofix when IS_A is used without COMPTIME" do
    FixCollector.enable!
    begin
      annotate(<<~CLEAR) rescue nil
        STRUCT Box {}

        FN handle<T>(x: T) RETURNS Void ->
          IF T IS_A Box THEN
            PASS
          END
        END
      CLEAR

      finding = FixCollector.drain.find { |f| f.message.include?("COMPTIME IF") }
      expect(finding).not_to be_nil
      fix = finding.fixes.first
      expect(fix.confidence).to eq(:auto)
      expect(fix.edits.first.replacement).to eq("COMPTIME ")
      expect(fix.edits.first.span.line).to eq(4)
      expect(fix.edits.first.span.col).to eq(3)
    ensure
      FixCollector.disable!
    end
  end
end
