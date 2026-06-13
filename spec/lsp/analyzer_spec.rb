require "rspec"
require_relative "../../src/lsp/analyzer" unless defined?(LSP::Analyzer)

# Drives the LSP analyzer with real CLEAR snippets and asserts that
# findings come back as expected. The analyzer is the bridge between
# the protocol layer and the CLEAR compiler — its contract is:
#   * always returns a Result (never raises)
#   * fatal errors become a `fatal_error` field, not an exception
#   * FixCollector is left disabled afterwards (no leak)
RSpec.describe LSP::Analyzer do
  describe ".run" do
    it "returns an empty Result for clean source" do
      result = LSP::Analyzer.run("FN main() RETURNS Void -> END\n")
      expect(result.findings).to be_empty
      expect(result.fatal?).to be false
    end

    it "captures FixableFindings without raising" do
      # WITH RESTRICT on an immutable binding — Tier 1 fix.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x = 5;
          WITH RESTRICT x { _ = x; }
        END
      CLEAR
      result = LSP::Analyzer.run(src)
      expect(result.fatal?).to be false
      expect(result.findings.size).to be >= 1
      # The RESTRICT finding has a fix.
      restrict = result.findings.find { |f| f.message =~ /RESTRICT/ }
      expect(restrict).not_to be_nil
      expect(restrict.fixes.size).to eq(1)
    end

    it "surfaces a CompilerError as a fatal_error finding" do
      # Undeclared variable — annotator raises CompilerError mid-pass.
      result = LSP::Analyzer.run(<<~CLEAR)
        FN main() RETURNS Void ->
          _ = doesNotExist;
        END
      CLEAR
      expect(result.fatal?).to be true
      expect(result.fatal_error.message).to match(/Undefined variable/i)
      expect(result.fatal_error.token).not_to be_nil
      expect(result.fatal_error.token.line).to eq(2)
    end

    it "surfaces a ParserError as a fatal_error finding" do
      # Missing closing brace — parser raises.
      result = LSP::Analyzer.run("FN main() RETURNS Void -> ")
      expect(result.fatal?).to be true
      expect(result.fatal_error.category).to eq(:syntax)
    end

    it "leaves FixCollector disabled after running" do
      LSP::Analyzer.run("FN main() RETURNS Void -> END\n")
      expect(FixCollector.enabled?).to be false
    end

    it "leaves FixCollector disabled even when the analyzer raises" do
      # Force the lexer to blow up by passing an object that doesn't
      # respond to the methods Lexer uses.
      allow(Lexer).to receive(:new).and_raise(RuntimeError, "synthetic")
      result = LSP::Analyzer.run("anything")
      expect(result.fatal?).to be true
      expect(result.fatal_error.message).to include("synthetic")
      expect(FixCollector.enabled?).to be false
    end
  end
end
