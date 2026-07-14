# frozen_string_literal: true

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "parser phase contracts" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  it "initializes the program language mode explicitly" do
    expect(AST::Program.new(nil, []).language_mode).to eq(:default)
    expect(parse("").language_mode).to eq(ClearParser.ownership_mode)
    expect(ClearParser.new(Lexer.new("").tokenize, "", gradual: true).parse.language_mode).to eq(:easy)
  end

  it "pairs struct fields with a non-optional token map" do
    bind = parse("point = Point{x: 1};").statements.fetch(0)
    literal = bind.value

    expect(literal).to be_a(AST::StructLit)
    expect(literal.field_tokens.fetch("x").text!).to eq("x")
    expect(AST::StructLit.new(nil, "Empty", {}, :stack).field_tokens).to eq({})
  end

  it "normalizes IF comptime state to booleans" do
    regular = parse("IF TRUE THEN PASS; END").statements.fetch(0)
    comptime = parse("COMPTIME IF TRUE THEN PASS; END").statements.fetch(0)

    expect(regular.comptime).to be(false)
    expect(comptime.comptime).to be(true)
  end

  it "normalizes WHILE tight state to booleans" do
    regular = parse("WHILE FALSE DO PASS; END").statements.fetch(0)
    tight = parse("TIGHT WHILE FALSE DO PASS; END").statements.fetch(0)

    expect(regular.tight).to be(false)
    expect(tight.tight).to be(true)
  end

  it "normalizes range and collection FOR tight state to booleans" do
    range = parse("FOR i IN (0 ..< 2) DO PASS; END").statements.fetch(0)
    tight_range = parse("TIGHT FOR i IN (0 ..< 2) DO PASS; END").statements.fetch(0)
    collection = parse("FOR item IN [1] DO PASS; END").statements.fetch(0)
    tight_collection = parse("TIGHT FOR item IN [1] DO PASS; END").statements.fetch(0)

    expect(range.tight).to be(false)
    expect(tight_range.tight).to be(true)
    expect(collection.tight).to be(false)
    expect(tight_collection.tight).to be(true)
  end
end
