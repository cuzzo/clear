require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser capability records" do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse_expr(source)
    parser_for(source).send(:parse_expression)
  end

  def parse_type(source)
    parser_for(source).send(:parse_type_annotation)
  end

  def parse_statement(source)
    parser_for(source).send(:parse_statement)
  end

  it "joins expression capability dimensions into a named result" do
    forward = parse_expr("value @shared:locked(rank: 7):boxed")
    reverse = parse_expr("value @locked(rank: -2):shared")

    expect(forward).to be_a(AST::CapabilityWrap)
    expect([forward.ownership, forward.sync, forward.layout, forward.lock_rank])
      .to eq([:shared, :locked, :indirect, 7])
    expect([reverse.ownership, reverse.sync, reverse.layout, reverse.lock_rank])
      .to eq([:shared, :locked, nil, -2])
  end

  it "combines shared and node ownership independent of order" do
    expect(parse_expr("value @shared:node").ownership).to eq(:shared_node)
    expect(parse_expr("value @node:shared").ownership).to eq(:shared_node)
  end

  it "rejects duplicate dimensions and malformed lock-rank arguments" do
    expect { parse_expr("value @shared:shared") }.to raise_error(ParserError, /Duplicate ownership/)
    expect { parse_expr("value @locked(level: 2)") }.to raise_error(ParserError, /rank/i)
  end

  it "ignores a dimension outside the parser's closed sigil table" do
    parser = parser_for("")
    token = Lexer::Token.new(:VAR_ID, "@future", 1, 1)
    attrs = ClearParser::SigilAttrs.new(dim: :future, val: :future)
    dimensions = ClearParser::CapJoin.new

    expect(parser.send(:apply_cap_dim!, token, attrs, dimensions)).to be_nil
    expect([dimensions.ownership, dimensions.sync, dimensions.layout]).to eq([nil, nil, nil])
  end

  it "records each supported element capability dimension from source" do
    expected = {
      "Counter@shared:locked[]" => [:shared, :locked, nil],
      "Counter@shared:node[]" => [:shared_node, nil, nil],
      "Counter@node:shared[]" => [:shared_node, nil, nil],
      "Counter@multiowned[]" => [:multiowned, nil, nil],
      "Counter@link[]" => [:link, nil, nil],
      "Counter@writeLocked[]" => [nil, :write_locked, nil],
      "Counter@alwaysMutable[]" => [nil, :always_mutable, nil],
      "Counter@boxed[]" => [nil, nil, :indirect],
    }

    expected.each do |source, dimensions|
      type = parse_type(source)
      expect([type.elem_ownership, type.elem_sync, type.elem_layout]).to eq(dimensions)
    end
  end

  it "maps DO branch sigils through typed attributes" do
    node = parse_statement("DO { @micro:pinned:parallel:canSmash -> work() }")
    branch = node.branches.first

    expect([branch.stack_size, branch.pinned, branch.parallel, branch.can_smash])
      .to eq([:micro, true, true, true])
  end

  it "reports unknown DO branch sigils" do
    expect { parse_statement("DO { @micor -> work() }") }.to raise_error(ParserError)
  end

  it "maps BG prefix sigils through typed attributes" do
    node = parse_statement("BG { @micro:arena:parallel:canSmash -> work(); }")

    expect([node.stack_size, node.pinned, node.parallel, node.arena_mode, node.can_smash])
      .to eq([:micro, true, true, true, true])
  end

  it "reports unknown BG prefix sigils" do
    expect { parse_statement("BG { @rean -> work(); }") }.to raise_error(ParserError)
  end
end
