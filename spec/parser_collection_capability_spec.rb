require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"

RSpec.describe "Parser collection capability chains" do
  def parse_expr(source)
    Parser.new(Lexer.new(source).tokenize, source).send(:parse_expression)
  end

  def parse_type(source)
    Parser.new(Lexer.new(source).tokenize, source).send(:parse_type_annotation)
  end

  it "parses constructor collection modifiers through the unified capability parser" do
    list = parse_expr("List[]:sharded(3)")
    pool = parse_expr("Pool[]:soa")
    set = parse_expr("Set[]")

    expect(list.instance_variable_get(:@constructor_collection)).to eq(:list)
    expect(list.instance_variable_get(:@constructor_shard_count)).to eq(3)
    expect(list.instance_variable_get(:@constructor_soa)).to be false

    expect(pool.instance_variable_get(:@constructor_collection)).to eq(:pool)
    expect(pool.instance_variable_get(:@constructor_shard_count)).to be_nil
    expect(pool.instance_variable_get(:@constructor_soa)).to be true

    expect(set.instance_variable_get(:@constructor_collection)).to eq(:set)
    expect(set.instance_variable_get(:@constructor_shard_count)).to be_nil
    expect(set.instance_variable_get(:@constructor_soa)).to be false
  end

  it "validates constructor shard counts while type annotations defer to semantic validation" do
    expect { parse_expr("List[]:sharded(1)") }.to raise_error(ParserError, /requires N >= 2/)
    expect(parse_type("Int64[]@list:sharded(1)").shard_count).to eq(1)
  end

  it "parses direct constructor modifier tokens before colon chains" do
    list = parse_expr("List[] @sharded(3)")
    pool = parse_expr("Pool[] @soa")

    expect(list.instance_variable_get(:@constructor_shard_count)).to eq(3)
    expect(list.instance_variable_get(:@constructor_soa)).to be false
    expect(pool.instance_variable_get(:@constructor_shard_count)).to be_nil
    expect(pool.instance_variable_get(:@constructor_soa)).to be true
  end

  it "rejects duplicate local sync capability in type chains" do
    expect { parse_type("Int64 @locked:local") }.to raise_error(ParserError, /Duplicate sync/)
  end

  it "parses local sync capability and rejects direct bad constructor modifiers" do
    expect(parse_type("Int64 @local").sync).to eq(:local)
    expect { parse_expr("List[] @locked") }.to raise_error(ParserError, /Expected 'sharded\(N\)' or 'soa'|unknown modifier/i)
  end

  it "rejects unsupported constructor modifiers instead of silently ignoring them" do
    expect { parse_expr("List[]:locked") }.to raise_error(ParserError, /Expected 'sharded\(N\)' or 'soa'|unknown modifier/i)
  end
end
