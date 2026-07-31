require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

# V5-1b: parameter carrier contracts (retained-identity v5). A TAKES
# parameter may be constrained UNIQUE (exclusively owned, enables COPY) or
# SHARED (requires a retained-identity family). Unconstrained TAKES is
# carrier-polymorphic.
RSpec.describe ClearParser do
  def params_of(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    fn.params
  end

  it "defaults an unconstrained TAKES parameter to :polymorphic" do
    p = params_of("FN f(TAKES u: User) RETURNS Void -> RETURN; END").first
    expect(p.carrier_contract).to eq(:polymorphic)
  end

  it "parses UNIQUE as a :unique carrier contract" do
    p = params_of("FN f(TAKES u: UNIQUE User) RETURNS Void -> RETURN; END").first
    expect(p.carrier_contract).to eq(:unique)
    expect(p.type.resolved).to eq(:User)
  end

  it "parses SHARED as a :shared carrier contract" do
    p = params_of("FN f(TAKES s: SHARED Session) RETURNS Void -> RETURN; END").first
    expect(p.carrier_contract).to eq(:shared)
    expect(p.type.resolved).to eq(:Session)
  end

  it "leaves a non-TAKES (borrow) parameter :polymorphic with no contract keyword" do
    p = params_of("FN f(u: User) RETURNS Void -> RETURN; END").first
    expect(p.carrier_contract).to eq(:polymorphic)
  end
end

RSpec.describe "KEEP expression (v5)" do
  def first_call_arg(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    call = nil
    AST.each_locatable(fn.body) { |n| call ||= n if n.is_a?(AST::FuncCall) }
    call.args.first
  end

  it "parses KEEP as a KeepNode wrapping the operand" do
    arg = first_call_arg("FN f(TAKES u: User) -> cache(KEEP u); END")
    expect(arg).to be_a(AST::KeepNode)
    expect(arg.value).to be_a(AST::Identifier)
    expect(arg.value.name).to eq("u")
  end

  it "keeps COPY and KEEP as distinct nodes" do
    copy = first_call_arg("FN f(TAKES u: User) -> cache(COPY u); END")
    coc  = first_call_arg("FN f(TAKES u: User) -> cache(KEEP u); END")
    expect(copy).to be_a(AST::CopyNode)
    expect(coc).to be_a(AST::KeepNode)
  end
end

RSpec.describe "MONOMORPHIC carrier contract (C-3a)" do
  def mono_params(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    fn.params
  end

  it "parses MONOMORPHIC as a :monomorphic carrier contract" do
    p = mono_params("FN f(TAKES u: MONOMORPHIC User) RETURNS Void -> RETURN; END").first
    expect(p.carrier_contract).to eq(:monomorphic)
    expect(p.type.resolved).to eq(:User)
  end

  it "lexes MONOMORPHIC as a keyword" do
    tokens = Lexer.new("MONOMORPHIC").tokenize
    expect(tokens.first.type).to eq(:KEYWORD)
    expect(tokens.first.value).to eq("MONOMORPHIC")
  end
end

RSpec.describe "OWN COPY parse (foundation for the carrier downgrade)" do
  def own_parse(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    fn.body.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::Assignment) }
  end

  it "parses OWN COPY x as a CopyNode with own set" do
    tokens = Lexer.new("OWN COPY x;").tokenize
    ast = ClearParser.new(tokens, "OWN COPY x;").parse
    node = ast.statements.first
    expect(node).to be_a(AST::CopyNode)
    expect(node.own).to eq(true)
  end

  it "parses a bare COPY x as a CopyNode without own" do
    ast = ClearParser.new(Lexer.new("COPY x;").tokenize, "COPY x;").parse
    node = ast.statements.first
    expect(node).to be_a(AST::CopyNode)
    expect(node.own).to be_falsey
  end

  it "rejects bare OWN x with OWN_ALONE_UNSUPPORTED" do
    expect {
      ClearParser.new(Lexer.new("OWN x").tokenize, "OWN x").parse
    }.to raise_error(/OWN must be followed by COPY/)
  end
end
