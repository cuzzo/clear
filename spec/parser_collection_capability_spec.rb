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

  it "uses the same shard-count validation for types and constructors" do
    expect { parse_expr("List[]:sharded(1)") }.to raise_error(ParserError, /requires N >= 2/)
    expect { parse_type("Int64[]@list:sharded(1)") }.to raise_error(ParserError, /requires N >= 2/)
  end

  it "rejects unsupported constructor modifiers instead of silently ignoring them" do
    expect { parse_expr("List[]:locked") }.to raise_error(ParserError, /Expected 'sharded\(N\)' or 'soa'|unknown modifier/i)
  end
end
