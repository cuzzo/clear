require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Assigning to a field of a MATCH arm binding is an immutability error. The
# auto-fix that offers `MUTABLE ` at the declaration reads the declaring node's
# token; a MATCH arm binding's declaring node is an AST::MatchCase, which has
# no token, so the fix builder must decline rather than raise NoMethodError.
RSpec.describe "MATCH arm binding immutability fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  let(:src) {
    <<~CLEAR
      STRUCT A { line: Int64 }
      STRUCT B { line: Int64 }
      UNION U { A: A, B: B }

      FN setLine(MUTABLE u: U, value: Int64) RETURNS Void ->
        PARTIAL MATCH u START
          U.A AS item -> item.line = value;,
          U.B AS item -> item.line = value;
        END
      END
    CLEAR
  }

  it "reports a CLEAR error instead of crashing in the fix builder" do
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    expect { SemanticAnnotator.new.annotate!(ast) }.not_to raise_error(NoMethodError)
  end
end
