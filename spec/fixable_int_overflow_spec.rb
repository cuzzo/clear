require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/fixable_error" unless defined?(FixCollector)
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Unit-level coverage for emit_int_overflow_error!'s widen-annotation
# fix path. The CLI-level integration is exercised in clear_fix_spec
# (tagged :integration); these specs poke the Fix output directly.
RSpec.describe "INT_LITERAL_OVERFLOW widen-annotation fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  it "rewrites the OVERFLOWING decl's annotation, not an earlier same-typed one on the same line" do
    # Two `: Byte` annotations on one physical line. The literal in y's
    # decl fits; x's literal overflows. The fix must target x's `Byte`,
    # not y's (which appears first).
    src = <<~CLEAR
      FN main() RETURNS Void ->
        y: Byte = 5; x: Byte = 1000;
        _ = x;
        _ = y;
      END
    CLEAR
    annotate(src) rescue nil
    finding = FixCollector.drain.find { |f| f.message =~ /overflows Byte/ }
    expect(finding).not_to be_nil
    fix = finding.fixes.find { |fx| fx.description =~ /Widen annotation/ }
    expect(fix).not_to be_nil
    decl_line = "  y: Byte = 5; x: Byte = 1000;"
    expect(fix.edits.first.span.col).to eq(decl_line.rindex("Byte") + 1)
  end
end
