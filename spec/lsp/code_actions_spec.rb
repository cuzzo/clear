require "rspec"
require_relative "../../src/lsp/code_actions" unless defined?(LSP::CodeActions)
require_relative "../../src/lsp/document_store" unless defined?(LSP::DocumentStore)
require_relative "../../src/lsp/analyzer" unless defined?(LSP::Analyzer)
require_relative "../../src/ast/fixable_error" unless defined?(FixCollector)

# CodeActions converts FixableFindings to LSP CodeActions. The unit
# tests below feed canned findings; the server-level integration tests
# (server_spec.rb) drive the full request → response path.
RSpec.describe LSP::CodeActions do
  Token = Struct.new(:line, :column, :value, keyword_init: true)
  StubFinding = Struct.new(:level, :message, :token, :category, :fixes, keyword_init: true)

  def make_doc(text = "FN main() RETURNS Void -> END\n", findings: [])
    store = LSP::DocumentStore.new
    store.open("file:///t.cht", text, 1)
    doc = store.get("file:///t.cht")
    doc.cached_findings = LSP::AnalysisResult.new(findings: findings, fatal_error: nil)
    doc
  end

  def auto_fix(line: 1, col: 1, length: 0, replacement: "MUTABLE ", desc: "Add MUTABLE")
    Fix.new(
      description: desc,
      confidence:  :auto,
      edits:       [Edit.new(span: Span.new(file: nil, line: line, col: col, length: length),
                             replacement: replacement)],
    )
  end

  def interactive_fix(line: 1, col: 1, length: 5, replacement: "CAST(x AS Int64)", desc: "Wrap with CAST")
    Fix.new(
      description: desc,
      confidence:  :interactive,
      edits:       [Edit.new(span: Span.new(file: nil, line: line, col: col, length: length),
                             replacement: replacement)],
    )
  end

  def finding_with(*fixes, line: 1, col: 1, value: "x", message: "an error")
    StubFinding.new(
      level:    :error,
      message:  message,
      token:    Token.new(line: line, column: col, value: value),
      category: :type,
      fixes:    fixes,
    )
  end

  def request_range(start_line: 0, start_char: 0, end_line: 0, end_char: 100)
    {
      "start" => { "line" => start_line, "character" => start_char },
      "end"   => { "line" => end_line,   "character" => end_char },
    }
  end

  describe ".for_range" do
    it "returns an empty array when the document is nil" do
      expect(LSP::CodeActions.for_range(nil, request_range)).to eq([])
    end

    it "returns an empty array when there are no cached findings" do
      doc = LSP::DocumentStore.new.open("file:///t.cht", "x", 1)
      doc = LSP::DocumentStore.new.tap { |s| s.open("file:///t.cht", "x", 1) }.get("file:///t.cht")
      doc.cached_findings = nil
      expect(LSP::CodeActions.for_range(doc, request_range)).to eq([])
    end

    it "returns an empty array when no findings have fixes" do
      f = finding_with  # no fixes
      doc = make_doc(findings: [f])
      expect(LSP::CodeActions.for_range(doc, request_range)).to eq([])
    end

    it "skips no-fix findings without computing diagnostics and continues to later findings" do
      no_fix = StubFinding.new(
        level: :error,
        message: "bad finding",
        token: nil,
        category: :type,
        fixes: [],
      )
      with_fix = finding_with(auto_fix, line: 1, col: 1, value: "x")
      doc = make_doc(findings: [no_fix, with_fix])

      out = LSP::CodeActions.for_range(doc, request_range)

      expect(out.size).to eq(1)
      expect(out.first[:title]).to eq("Add MUTABLE")
    end

    it "skips findings whose range doesn't overlap the request" do
      # Finding on line 5, request on line 1 → no overlap.
      f = finding_with(auto_fix, line: 5, col: 1, value: "x")
      doc = make_doc(findings: [f])
      out = LSP::CodeActions.for_range(doc, request_range(start_line: 0, end_line: 0))
      expect(out).to eq([])
    end

    it "continues after an out-of-range finding" do
      out_of_range = finding_with(auto_fix(desc: "ignore"), line: 5, col: 1, value: "x")
      in_range = finding_with(auto_fix(desc: "apply"), line: 1, col: 1, value: "x")
      doc = make_doc(findings: [out_of_range, in_range])

      out = LSP::CodeActions.for_range(doc, request_range(start_line: 0, end_line: 0))

      expect(out.map { |action| action[:title] }).to eq(["apply"])
    end

    it "uses document text for UTF-16 diagnostic and edit ranges" do
      text = "ééabc\n"
      fix = auto_fix(line: 1, col: 5, length: 1, replacement: "A")
      f = finding_with(fix, line: 1, col: 5, value: "a")
      doc = make_doc(text, findings: [f])

      out = LSP::CodeActions.for_range(
        doc,
        request_range(start_line: 0, start_char: 2, end_line: 0, end_char: 3),
      )

      edit = out.first[:edit][:documentChanges].first[:edits].first
      expect(edit[:range]).to eq(
        start: { line: 0, character: 2 },
        end: { line: 0, character: 3 },
      )
    end

    it "produces one CodeAction per Fix on overlapping findings" do
      f = finding_with(auto_fix, interactive_fix, line: 1, col: 1, value: "x")
      doc = make_doc(findings: [f])
      out = LSP::CodeActions.for_range(doc, request_range)
      expect(out.size).to eq(2)
    end

    it "marks :auto fixes as 'quickfix' kind and isPreferred=true" do
      f = finding_with(auto_fix, line: 1, col: 1, value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      expect(action[:kind]).to eq("quickfix")
      expect(action[:isPreferred]).to be true
    end

    it "marks :interactive fixes as 'refactor' kind without isPreferred" do
      f = finding_with(interactive_fix, line: 1, col: 1, value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      expect(action[:kind]).to eq("refactor")
      expect(action.key?(:isPreferred)).to be false
    end

    it "carries the fix's description as the action title" do
      f = finding_with(auto_fix(desc: "Declare 'x' as MUTABLE"), value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      expect(action[:title]).to eq("Declare 'x' as MUTABLE")
    end

    it "attaches the originating Diagnostic so the client can group actions" do
      f = finding_with(auto_fix, message: "Variable 'x' is immutable", value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      expect(action[:diagnostics].size).to eq(1)
      expect(action[:diagnostics].first[:message]).to eq("Variable 'x' is immutable")
    end

    it "produces a WorkspaceEdit with the fix's edits as TextEdits" do
      f = finding_with(auto_fix(line: 2, col: 5, replacement: "MUTABLE "), value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      changes = action[:edit][:documentChanges]
      expect(changes.size).to eq(1)
      td_edit = changes.first
      expect(td_edit[:textDocument][:uri]).to eq("file:///t.cht")
      expect(td_edit[:textDocument][:version]).to eq(1)
      edit = td_edit[:edits].first
      expect(edit[:newText]).to eq("MUTABLE ")
      expect(edit[:range][:start][:line]).to eq(1)        # 2 → 0-based 1
      expect(edit[:range][:start][:character]).to eq(4)   # col 5 → 0-based 4
    end

    it "expands every Edit in a multi-edit Fix" do
      multi_fix = Fix.new(
        description: "Wrap with CAST",
        confidence:  :interactive,
        edits: [
          Edit.new(span: Span.new(file: nil, line: 1, col: 1, length: 0),
                   replacement: "CAST("),
          Edit.new(span: Span.new(file: nil, line: 1, col: 5, length: 0),
                   replacement: " AS Int64)"),
        ],
      )
      f = finding_with(multi_fix, value: "x")
      doc = make_doc(findings: [f])
      action = LSP::CodeActions.for_range(doc, request_range).first
      edits = action[:edit][:documentChanges].first[:edits]
      expect(edits.size).to eq(2)
      expect(edits[0][:newText]).to eq("CAST(")
      expect(edits[1][:newText]).to eq(" AS Int64)")
    end
  end

  describe "range overlap" do
    def lsp_range(start_line, start_char, end_line, end_char, string_keys: false)
      range = {
        start: { line: start_line, character: start_char },
        end: { line: end_line, character: end_char },
      }
      return range unless string_keys

      {
        "start" => { "line" => start_line, "character" => start_char },
        "end" => { "line" => end_line, "character" => end_char },
      }
    end

    it "considers ranges overlapping when one end matches the other start" do
      # Action range: line 0 char 0..1; request: line 0 char 1..5.
      # Touching boundaries count as overlapping.
      f = finding_with(auto_fix, line: 1, col: 1, value: "x")  # range 0:0..0:1
      doc = make_doc(findings: [f])
      out = LSP::CodeActions.for_range(doc, request_range(start_line: 0, start_char: 1, end_line: 0, end_char: 5))
      expect(out.size).to eq(1)

      expect(
        LSP::CodeActions.send(
          :ranges_overlap?,
          lsp_range(0, 0, 0, 1),
          lsp_range(0, 1, 0, 5, string_keys: true),
        ),
      ).to be(true)
      expect(
        LSP::CodeActions.send(
          :ranges_overlap?,
          lsp_range(0, 1, 0, 5),
          lsp_range(0, 0, 0, 1, string_keys: true),
        ),
      ).to be(true)
    end

    it "considers ranges non-overlapping when one ends strictly before the other starts" do
      # Action range: line 0 char 0..1; request: line 0 char 5..10.
      f = finding_with(auto_fix, line: 1, col: 1, value: "x")
      doc = make_doc(findings: [f])
      out = LSP::CodeActions.for_range(doc, request_range(start_line: 0, start_char: 5, end_line: 0, end_char: 10))
      expect(out).to eq([])

      expect(
        LSP::CodeActions.send(
          :ranges_overlap?,
          lsp_range(0, 0, 0, 1),
          lsp_range(0, 2, 0, 5, string_keys: true),
        ),
      ).to be(false)
      expect(
        LSP::CodeActions.send(
          :ranges_overlap?,
          lsp_range(0, 5, 0, 10),
          lsp_range(0, 0, 0, 4, string_keys: true),
        ),
      ).to be(false)
    end
  end
end
