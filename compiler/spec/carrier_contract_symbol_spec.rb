require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# V5-2a: the parsed parameter carrier contract reaches the resolved
# SymbolEntry as the single authoritative fact downstream reads.
RSpec.describe "parameter carrier contract on SymbolEntry" do
  def param_symbols(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    fn.params.map(&:symbol)
  end

  it "stamps :polymorphic on an unconstrained TAKES param" do
    sym = param_symbols("FN f(TAKES u: User) RETURNS Void -> RETURN; END").first
    expect(sym.carrier_contract).to eq(:polymorphic)
  end

  it "stamps :unique on a UNIQUE param" do
    sym = param_symbols("FN f(TAKES u: UNIQUE User) RETURNS Void -> RETURN; END").first
    expect(sym.carrier_contract).to eq(:unique)
  end

  it "stamps :monomorphic on a MONOMORPHIC param" do
    sym = param_symbols("FN f(TAKES u: MONOMORPHIC User) RETURNS Void -> RETURN; END").first
    expect(sym.carrier_contract).to eq(:monomorphic)
  end
end
