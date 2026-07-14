require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser typed rule routes" do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse_statement(source)
    parser_for(source).send(:parse_statement)
  end

  def parse_expression(source)
    parser_for(source).send(:parse_expression)
  end

  it "parses statement routes without positional capture arrays" do
    plain = parse_statement("ASSERT ready;")
    messaged = parse_statement('ASSERT ready, "not ready";')

    expect([plain.class, plain.message]).to eq([AST::Assert, :Any])
    expect([messaged.class, messaged.message]).to eq([AST::Assert, "not ready"])
    expect(parse_statement("BREAK;")).to be_a(AST::BreakNode)
    expect(parse_statement("CONTINUE;")).to be_a(AST::ContinueNode)
  end

  it "parses CAST through named local values" do
    node = parse_expression("CAST(value AS Int64)")

    expect(node).to be_a(AST::Cast)
    expect(node.value.name).to eq("value")
    expect(node.target.base_type).to eq(:Int64)
  end

  it "parses every value-wrapper route directly" do
    expected = {
      "MOVE value" => AST::MoveNode,
      "GIVE value" => AST::MoveNode,
      "COPY value" => AST::CopyNode,
      "CLONE value" => AST::CloneNode,
      "SHARE value" => AST::ShareNode,
      "LINK value" => AST::LinkNode,
      "RESOLVE value" => AST::ResolveNode,
      "FREEZE value" => AST::FreezeNode,
    }

    expected.each do |source, node_class|
      node = parse_expression(source)
      expect(node).to be_a(node_class)
      expect(node.value.name).to eq("value")
    end
  end

  it "parses expression REQUIRE without a generic token capture" do
    node = parse_expression('REQUIRE "module.clear"')

    expect(node).to be_a(AST::Require)
    expect(node.path).to eq("module.clear")
  end

  it "parses every single-expression pipeline route directly" do
    expected = {
      "SELECT predicate" => AST::SelectOp,
      "WHERE predicate" => AST::WhereOp,
      "INDEX key" => AST::IndexOp,
      "ORDER_BY key" => AST::OrderByOp,
      "LIMIT count" => AST::LimitOp,
      "SKIP count" => AST::SkipOp,
      "UNNEST values" => AST::UnnestOp,
      "DISTINCT key" => AST::DistinctOp,
      "FIND predicate" => AST::FindOp,
      "ANY predicate" => AST::AnyOp,
      "ALL predicate" => AST::AllOp,
      "COUNT predicate" => AST::CountOp,
      "SUM value" => AST::SumOp,
      "AVERAGE value" => AST::AverageOp,
      "MIN value" => AST::MinOp,
      "MAX value" => AST::MaxOp,
      "TAKE_WHILE predicate" => AST::TakeWhileOp,
      "COLLECT" => AST::CollectOp,
    }

    expected.each do |source, node_class|
      expect(parse_expression(source)).to be_a(node_class)
    end
  end
end
