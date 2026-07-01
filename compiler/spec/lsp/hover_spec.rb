require "rspec"
require_relative "../../ruby/lsp/hover" unless defined?(LSP::Hover)
require_relative "../../ruby/lsp/document_store" unless defined?(LSP::DocumentStore)
require_relative "../../ruby/lsp/analyzer" unless defined?(LSP::Analyzer)
require_relative "../../ruby/ast/fixable_error" unless defined?(FixCollector)

RSpec.describe LSP::Hover do
  Token = Struct.new(:line, :column, :value, keyword_init: true)
  StubFinding = Struct.new(:level, :message, :token, :category, :fixes, keyword_init: true)

  def make_doc(text = "  x = 5;\n", findings: [], fatal: nil)
    store = LSP::DocumentStore.new
    store.open("file:///t.clear", text, 1)
    doc = store.get("file:///t.clear")
    doc.cached_findings = LSP::AnalysisResult.new(findings: findings, fatal_error: fatal)
    doc
  end

  describe ".render" do
    it "returns nil when document is nil" do
      expect(LSP::Hover.render(nil, { "line" => 0, "character" => 0 })).to be_nil
    end

    it "returns nil when cached_findings is nil" do
      store = LSP::DocumentStore.new
      store.open("file:///t.clear", "x = 5", 1)
      doc = store.get("file:///t.clear")
      expect(LSP::Hover.render(doc, { "line" => 0, "character" => 0 })).to be_nil
    end

    it "returns nil when no finding overlaps the cursor" do
      f = StubFinding.new(level: :error, message: "x", token: Token.new(line: 1, column: 1, value: "foo"), category: :type, fixes: [])
      doc = make_doc(findings: [f])
      # Cursor on line 5 — way past the finding.
      expect(LSP::Hover.render(doc, { "line" => 5, "character" => 0 })).to be_nil
    end

    it "renders a hover for an overlapping finding with a known registry code" do
      # ARITY_MISMATCH template: "Function '%{name}' expects %{expected} arguments, got %{got}."
      f = StubFinding.new(
        level:    :error,
        message:  "Function 'add' expects 2 arguments, got 3.",
        token:    Token.new(line: 1, column: 5, value: "add"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("    add(1, 2, 3);\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 5 })
      expect(hover).not_to be_nil
      expect(hover[:contents][:kind]).to eq("markdown")
      md = hover[:contents][:value]
      expect(md).to include("ARITY_MISMATCH")
      expect(md).to include("error")
    end

    it "falls back to the raw message when no registry code resolves" do
      f = StubFinding.new(
        level:    :error,
        message:  "totally bespoke message that no template prefix matches",
        token:    Token.new(line: 1, column: 1, value: "foo"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("foo;\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 1 })
      expect(hover).not_to be_nil
      md = hover[:contents][:value]
      expect(md).to include("totally bespoke message")
    end

    it "renders the cause and fix_hint when the registry entry has them" do
      # ATOMIC_ESCAPE_RETURN umbrella was given rich docs in T9 backfill.
      # Its template is "%{message}" so we provide a custom prefix
      # — but DiagnosticRegistry won't recover the code from the
      # rendered text. Instead, use a real registry entry whose template
      # has a literal prefix and rich docs:
      #   UNDEFINED_VAR has cause + fix_hint and a template starting
      #   with "Undefined variable '".
      f = StubFinding.new(
        level:    :error,
        message:  "Undefined variable 'foo'.",
        token:    Token.new(line: 1, column: 1, value: "foo"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("foo;\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 1 })
      md = hover[:contents][:value]
      expect(md).to include("UNDEFINED_VAR")
      expect(md).to include("**Cause:**")
      expect(md).to include("**Fix:**")
    end

    it "renders the spec-pulled bad/good example when DiagnosticExamples has one" do
      # ENUM_UNKNOWN_VARIANT has both rich docs AND a spec example.
      f = StubFinding.new(
        level:    :error,
        message:  "Type Error: Enum 'Color' has no variant 'Yellow'.",
        token:    Token.new(line: 1, column: 1, value: "Yellow"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("Color.Yellow;\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 1 })
      md = hover[:contents][:value]
      expect(md).to include("**Example (bad):**")
      expect(md).to include("**Example (good):**")
      expect(md).to include("```clear")
    end

    it "uses fatal_error finding when present" do
      fatal = StubFinding.new(
        level:    :error,
        message:  "boom",
        token:    Token.new(line: 1, column: 1, value: "x"),
        category: :syntax,
        fixes:    [],
      )
      doc = make_doc("x\n", findings: [], fatal: fatal)
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 0 })
      expect(hover).not_to be_nil
      expect(hover[:contents][:value]).to include("boom")
    end

    it "puts the diagnostic's range in the hover response" do
      f = StubFinding.new(
        level:    :error,
        message:  "Undefined variable 'foo'.",
        token:    Token.new(line: 2, column: 5, value: "foo"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("a\nb\n    foo;\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 1, "character" => 5 })
      expect(hover[:range][:start][:line]).to eq(1)
      expect(hover[:range][:start][:character]).to eq(4)
    end

    it "falls back to same-line finding when cursor isn't on the exact token" do
      # The diagnostic's token covers col 5..8 (`add`); cursor is at
      # col 30 on the same line. Strict overlap fails, but the
      # same-line fallback picks the finding anyway.
      f = StubFinding.new(
        level:    :error,
        message:  "Function 'add' expects 2 arguments, got 3.",
        token:    Token.new(line: 1, column: 5, value: "add"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("    add(1, 2, 3);                            comment\n", findings: [f])
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 30 })
      expect(hover).not_to be_nil
      expect(hover[:contents][:value]).to include("ARITY_MISMATCH")
    end

    it "still returns nil when the cursor is on a different line" do
      f = StubFinding.new(
        level:    :error,
        message:  "Function 'add' expects 2 arguments, got 3.",
        token:    Token.new(line: 1, column: 5, value: "add"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("    add(1, 2, 3);\n  comment;\n", findings: [f])
      expect(LSP::Hover.render(doc, { "line" => 1, "character" => 0 })).to be_nil
    end

    it "renders the code-only header when registry.lookup returns nil" do
      # Theoretical edge case: Diagnostics recovers a code from the
      # message text, but a concurrent registry mutation (or stub)
      # makes lookup return nil. Hover should still render — without
      # the category half of the header.
      f = StubFinding.new(
        level:    :error,
        message:  "Function 'add' expects 2 arguments, got 3.",
        token:    Token.new(line: 1, column: 1, value: "add"),
        category: :type,
        fixes:    [],
      )
      doc = make_doc("add(1,2,3);\n", findings: [f])
      allow(DiagnosticRegistry).to receive(:lookup).and_return(nil)
      hover = LSP::Hover.render(doc, { "line" => 0, "character" => 0 })
      expect(hover[:contents][:value]).to include("ARITY_MISMATCH")
      # No category italic when entry is nil.
      expect(hover[:contents][:value]).not_to include("_type_")
    end

    it "renders severity correctly for warning / hint / info levels" do
      [
        [:warning, "warning"],
        [:hint,    "hint"],
        [:info,    "info"],
      ].each do |level, label|
        f = StubFinding.new(level: level, message: "x", token: Token.new(line: 1, column: 1, value: "x"), category: :lint, fixes: [])
        doc = make_doc("x\n", findings: [f])
        hover = LSP::Hover.render(doc, { "line" => 0, "character" => 0 })
        expect(hover[:contents][:value]).to include("[#{label}]"), "expected level :#{level} → label '#{label}'"
      end
    end
  end
end
