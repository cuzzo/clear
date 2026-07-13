require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser collection capability chains" do
  def parse_expr(source)
    ClearParser.new(Lexer.new(source).tokenize, source).send(:parse_expression)
  end

  def parse_type(source)
    ClearParser.new(Lexer.new(source).tokenize, source).send(:parse_type_annotation)
  end

  it "parses constructor collection modifiers through the unified capability parser" do
    list = parse_expr("List[]:sharded(3)")
    pool = parse_expr("Pool[]:soa")
    set = parse_expr("Set[]")

    expect(list.constructor_collection).to eq(:list)
    expect(list.constructor_shard_count).to eq(3)
    expect(list.constructor_soa?).to be false

    expect(pool.constructor_collection).to eq(:pool)
    expect(pool.constructor_shard_count).to be_nil
    expect(pool.constructor_soa?).to be true

    expect(set.constructor_collection).to eq(:set)
    expect(set.constructor_shard_count).to be_nil
    expect(set.constructor_soa?).to be false
  end

  it "validates constructor shard counts while type annotations defer to semantic validation" do
    expect { parse_expr("List[]:sharded(1)") }.to raise_error(ParserError, /requires N >= 2/)
    expect(parse_type("Int64[]@list:sharded(1)").shard_count).to eq(1)
  end

  it "distinguishes optional elements from an optional collection" do
    optional_elements = parse_type("?Counter[]@list")
    optional_collection = parse_type("?(Counter[]@list)")

    expect(optional_elements.optional?).to be false
    expect(T.must(optional_elements.element_type).optional?).to be true
    expect(optional_collection.optional?).to be true
    expect(T.must(optional_collection.wrapped_type).list_collection?).to be true
    expect(T.must(T.must(optional_collection.wrapped_type).element_type).optional?).to be false
    expect(Type.surface_name_type(optional_collection)).to eq("?(Counter[])")

    parser = ClearParser.new(Lexer.new("").tokenize, "")
    expect(parser.send(:type_annotation_source, optional_collection)).to eq("?(Counter[]@list)")
  end

  it "parses direct constructor modifier tokens before colon chains" do
    list = parse_expr("List[] @sharded(3)")
    pool = parse_expr("Pool[] @soa")

    expect(list.constructor_shard_count).to eq(3)
    expect(list.constructor_soa?).to be false
    expect(pool.constructor_shard_count).to be_nil
    expect(pool.constructor_soa?).to be true
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

  it "round-trips polymorphic SHARED annotations without keeping the marker on the inner type" do
    parser = ClearParser.new(Lexer.new("").tokenize, "")
    type = Type.new(:Counter)
    type.apply_reference_ownership!(:shared)
    type.mark_polymorphic_shared!

    expect(parser.send(:type_annotation_source, type)).to eq("SHARED Counter")
  end
end
