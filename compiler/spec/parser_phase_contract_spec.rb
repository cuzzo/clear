# frozen_string_literal: true

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "parser phase contracts" do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse(source)
    parser_for(source).parse
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

  it "uses the same named field result for generic struct literals" do
    bind = parse("pair = Pair<Int64>{left: 1, Right: 2};").statements.fetch(0)
    literal = bind.value

    expect(literal.fields.keys).to eq(%w[left Right])
    expect(literal.field_tokens.transform_values(&:text!)).to eq(
      "left" => "left",
      "Right" => "Right",
    )
    expect(literal.type_args).to eq(["Int64"])
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

  it "routes standalone test-support statements through the shared statement table" do
    program = parse(<<~CLEAR)
      STUB fetch RETURNS 1;
      SMASH work();
      PROFILE work();
    CLEAR

    expect(program.statements.map(&:class)).to eq([
      AST::StubDecl,
      AST::SmashStmt,
      AST::ProfileStmt,
    ])
  end

  it "keeps diagnostic-only grammar routes explicit" do
    expect { parse("COMPTIME PASS;") }.to raise_error(ParserError, /IF/)
    expect { parser_for("~?(Int64[])").send(:parse_type_annotation) }
      .to raise_error(ParserError, /grouped optional/)
    expect { parser_for("~FN() -> Int64").send(:parse_type_annotation) }
      .to raise_error(ParserError, /function type annotation/)
  end

  it "fails closed when a parser table contains an unsupported action" do
    parser = parser_for("(value")
    unknown = ClearParser::ParserRule.new(type: :VAR_ID, action: :unknown)
    value = AST::Identifier.new(nil, "value")

    expect { parser.send(:dispatch_stmt_rule, unknown) }
      .to raise_error(RuntimeError, /Unknown statement parser action/)
    expect { parser.send(:dispatch_primary_rule, unknown) }
      .to raise_error(RuntimeError, /Unknown primary parser action/)
    expect { parser.send(:dispatch_suffix_rule, unknown, value) }
      .to raise_error(RuntimeError, /Unknown suffix parser action/)

    # The delimiter index deliberately leaves malformed pairs unpaired. The
    # fallback scan must still make progress and terminate at EOF.
    expect(parser.send(:top_level_assignment_before_brace_delimiter?, 0)).to be(false)
  end

  it "keeps checked identifier payloads across uncommon grammar routes" do
    method = parse("METHOD update() -> RETURN; END").statements.fetch(0)
    require_node = parse('REQUIRE "helper.clear" AS helper;').statements.fetch(0)
    extern_method = parse('EXTERN FN Dir.makePath() RETURNS Void FROM "std.fs";').statements.fetch(0)
    is_a = parser_for("value IS_A Box AS matched").send(:parse_expression)
    override = parser_for("@thunk(4) work()").send(:parse_expression)
    string = parser_for('%"text"').send(:parse_expression)
    if_bind = parse("IF maybe EXISTS AS value THEN PASS; END").statements.fetch(0)
    short_while = parse("WHILE maybe EXISTS AS value -> PASS;").statements.fetch(0)
    block_while = parse("WHILE maybe EXISTS AS value DO PASS; END").statements.fetch(0)
    let = parser_for("LET counter = 1;").send(:parse_let_binding)
    tagged = parser_for('WHEN "ctx" TAGS [slow, fast] DO END').send(:parse_when_block)

    expect(method).to be_a(AST::FunctionDef)
    expect(require_node.namespace).to eq("helper")
    expect([extern_method.owner_type, extern_method.name]).to eq(%w[Dir makePath])
    expect(is_a.binding).to eq("matched")
    expect([override.kind, override.n]).to eq([:thunk, 4])
    expect(string.value).to eq("text")
    expect(if_bind.bindings.map(&:name)).to eq(["value"])
    expect(short_while.binding_name).to eq("value")
    expect(block_while.binding_name).to eq("value")
    expect(let.name).to eq("counter")
    expect(tagged.tags).to eq(%w[slow fast])

    expect { parser_for("@thunk(0) work()").send(:parse_expression) }
      .to raise_error(ParserError, /positive integer/)
    expect(parser_for("List[] @soa").send(:parse_expression).constructor_soa?).to be(true)
    expect { parser_for("List[]:locked").send(:parse_expression) }
      .to raise_error(ParserError, /unknown modifier/i)

    FixCollector.enable!
    begin
      legacy_if = parse("IF maybe AS value THEN PASS; END").statements.fetch(0)
      legacy_short_while = parse("WHILE maybe AS value -> PASS;").statements.fetch(0)
      legacy_block_while = parse("WHILE maybe AS value DO PASS; END").statements.fetch(0)

      expect(legacy_if.bindings.map(&:name)).to eq(["value"])
      expect(legacy_short_while.binding_name).to eq("value")
      expect(legacy_block_while.binding_name).to eq("value")
      expect(FixCollector.drain.length).to eq(3)
    ensure
      FixCollector.disable!
    end
  end
end
