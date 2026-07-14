require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser non-replaying VAR_ID statements" do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse_statement(source)
    parser_for(source).send(:parse_statement)
  end

  it "parses expression, typed bind, field, index, compound, and destructuring forms" do
    expect(parse_statement("call();")).to be_a(AST::FuncCall)
    expect(parse_statement("value: Int64 = 1_i64;")).to be_a(AST::BindExpr)
    expect(parse_statement("record.field = 1_i64;")).to be_a(AST::Assignment)

    compound = parse_statement("items[0_i64] += 1_i64;")
    expect(compound).to be_a(AST::Assignment)
    expect(compound.compound_op).to eq(:ADD)

    identifier_compound = parse_statement("count += 1_i64;")
    expect(identifier_compound).to be_a(AST::BindExpr)
    expect(identifier_compound.compound_op).to eq(:ADD)

    destructuring = parse_statement("left: Pair<Int64, Float64>, right = pair;")
    expect(destructuring).to be_a(AST::DestructuringAssignment)
    expect(destructuring.targets.map(&:name)).to eq(%w[left right])

    mutable = parse_statement("MUTABLE left, right = pair;")
    expect(mutable.targets.map(&:mutable)).to eq([true, true])
  end

  it "rejects call results as assignment targets after parsing them once" do
    expect { parse_statement("call() = 1_i64;") }
      .to raise_error(ParserError, /Invalid assignment target/)
    expect { parse_statement("call() += 1_i64;") }
      .to raise_error(ParserError, /Invalid assignment target/)
  end

  it "shares the parsed-once path with value blocks and BG bodies" do
    value_source = "cb: FN() -> Int64 = %() -> { left, right = pair; call(); value: Int64 = 1_i64; value };"
    value_block = parser_for(value_source).parse.statements.first.value.body
    expect(value_block.body.map(&:class)).to eq([AST::DestructuringAssignment, AST::FuncCall, AST::BindExpr])
    expect(value_block.result).to be_a(AST::Identifier)

    bg = parse_statement("BG { left, right = pair; request() THEN finish(); value = 1_i64; }")
    expect(bg.body.map(&:class)).to eq([AST::DestructuringAssignment, AST::ThenChain, AST::BindExpr])
  end

  it "keeps recursive expression work linear instead of replaying nested value blocks" do
    expression = "call()"
    20.times { expression = "call({ #{expression}; 0 })" }
    source = "#{expression};"
    parser = parser_for(source)
    expression_calls = 0

    parser.define_singleton_method(:parse_expression) do
      expression_calls += 1
      super()
    end

    expect(parser.send(:parse_statement)).to be_a(AST::FuncCall)
    expect(expression_calls).to be <= 3 * 20 + 1
  end
end
