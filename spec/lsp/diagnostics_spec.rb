require "rspec"
require_relative "../../src/lsp/diagnostics"
require_relative "../../src/lsp/analyzer"

RSpec.describe LSP::Diagnostics do
  Token = Struct.new(:line, :column, :value, keyword_init: true)
  StubFinding = Struct.new(:level, :message, :token, :category, :fixes, keyword_init: true)

  describe ".from_finding" do
    it "produces a complete LSP Diagnostic for an error-level finding" do
      finding = StubFinding.new(
        level:    :error,
        message:  "Undefined variable 'foo'.",
        token:    Token.new(line: 3, column: 7, value: "foo"),
        category: :type,
        fixes:    [],
      )
      d = LSP::Diagnostics.from_finding(finding)
      expect(d[:severity]).to eq(LSP::Diagnostics::SEVERITY_ERROR)
      expect(d[:message]).to eq("Undefined variable 'foo'.")
      expect(d[:source]).to eq("clear")
      expect(d[:range]).to eq(
        start: { line: 2, character: 6 },
        end:   { line: 2, character: 9 },
      )
    end

    it "maps level → LSP severity correctly" do
      [
        [:error,   LSP::Diagnostics::SEVERITY_ERROR],
        [:warning, LSP::Diagnostics::SEVERITY_WARNING],
        [:info,    LSP::Diagnostics::SEVERITY_INFO],
        [:hint,    LSP::Diagnostics::SEVERITY_HINT],
      ].each do |level, expected|
        f = StubFinding.new(level: level, message: "x", token: Token.new(line: 1, column: 1, value: "x"), category: :lint, fixes: [])
        d = LSP::Diagnostics.from_finding(f)
        expect(d[:severity]).to eq(expected), "level :#{level} should map to severity #{expected}, got #{d[:severity]}"
      end
    end

    it "defaults severity to ERROR for unknown levels" do
      f = StubFinding.new(level: :weird, message: "x", token: Token.new(line: 1, column: 1, value: "x"), category: :type, fixes: [])
      expect(LSP::Diagnostics.from_finding(f)[:severity]).to eq(LSP::Diagnostics::SEVERITY_ERROR)
    end

    it "recovers the registry code when the message starts with a known template prefix" do
      # ARITY_MISMATCH template: "Type Error: Function '%{name}' expects %{expected} arguments, got %{got}"
      f = StubFinding.new(
        level:    :error,
        message:  "Type Error: Function 'add' expects 2 arguments, got 3",
        token:    Token.new(line: 1, column: 1, value: "add"),
        category: :type,
        fixes:    [],
      )
      d = LSP::Diagnostics.from_finding(f)
      expect(d[:code]).to be_a(String)
      expect(d[:code]).to match(/^[A-Z][A-Z0-9_]+$/)
    end

    it "leaves code unset when no template prefix matches" do
      f = StubFinding.new(
        level:    :error,
        message:  "this exactly-this string is in no registry template",
        token:    Token.new(line: 1, column: 1, value: "x"),
        category: :type,
        fixes:    [],
      )
      d = LSP::Diagnostics.from_finding(f)
      expect(d).not_to have_key(:code)  # .compact strips nil values
    end

    it "computes a 1-character range for an empty-value token" do
      f = StubFinding.new(
        level:    :error,
        message:  "x",
        token:    Token.new(line: 1, column: 1, value: ""),
        category: :type,
        fixes:    [],
      )
      d = LSP::Diagnostics.from_finding(f)
      expect(d[:range][:start][:character]).to eq(0)
      expect(d[:range][:end][:character]).to eq(1)
    end

    it "uses the source string to compute UTF-16 columns when present" do
      # `é` is one UTF-16 code unit; the byte column for `foo` differs
      # from the character column.
      source = "  é foo\n"
      f = StubFinding.new(
        level:    :error,
        message:  "x",
        token:    Token.new(line: 1, column: 6, value: "foo"),  # 1-based byte col 6
        category: :type,
        fixes:    [],
      )
      d = LSP::Diagnostics.from_finding(f, source)
      expect(d[:range][:start][:character]).to eq(4)
      expect(d[:range][:end][:character]).to eq(7)
    end
  end

  describe ".from_result" do
    it "converts every finding plus the fatal error" do
      f1 = StubFinding.new(level: :warning, message: "w", token: Token.new(line: 1, column: 1, value: "x"), category: :lint, fixes: [])
      f2 = StubFinding.new(level: :error,   message: "e", token: Token.new(line: 2, column: 1, value: "y"), category: :type, fixes: [])
      fatal = StubFinding.new(level: :error, message: "boom", token: Token.new(line: 3, column: 1, value: "z"), category: :syntax, fixes: [])
      result = LSP::Analyzer::Result.new(findings: [f1, f2], fatal_error: fatal)
      diags = LSP::Diagnostics.from_result(result)
      expect(diags.size).to eq(3)
      expect(diags.last[:message]).to eq("boom")
    end

    it "produces an empty array for a clean Result" do
      result = LSP::Analyzer::Result.new(findings: [], fatal_error: nil)
      expect(LSP::Diagnostics.from_result(result)).to eq([])
    end
  end
end
