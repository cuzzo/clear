require "rspec"
require_relative "../ruby/ast/syntax_typo_scanner" unless defined?(SyntaxTypoScanner)

# Unit-level coverage of SyntaxTypoScanner. The integration-tagged
# clear_fix_spec exercises the same code via `./clear fix` subprocesses,
# but those are excluded from the default suite, so the scanner ships
# without per-rule line coverage. These tests call scan! directly and
# inspect the FixCollector drain.

RSpec.describe SyntaxTypoScanner do
  before { FixCollector.enable! }
  after { FixCollector.disable! }

  def scan(source)
    SyntaxTypoScanner.scan!(source)
    FixCollector.drain
  end

  describe ".scan! pipeline-operator typo (`s>` -> `|>`)" do
    it "flags a bare `s>` and proposes `|>`" do
      findings = scan("FN main() ->\n  v = [1] s> SUM _;\nEND\n")
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.message).to match(/Unknown operator `s>`.*did you mean `\|>`/)
      edit = f.fixes.first.edits.first
      expect(edit.replacement).to eq("|>")
      # Anchor at the typo position — the scanner records line/col of
      # the first char of the matched pattern.
      expect(edit.span.line).to eq(2)
      expect(edit.span.col).to eq(11)
      expect(edit.span.length).to eq(2)
    end

    it "does NOT flag identifiers that happen to end in `s>` (e.g. `users>`)" do
      # The word-boundary safeguard rejects matches preceded by an
      # identifier char — `users>0` (no space) literally has the byte
      # sequence `s>` mid-identifier; without the safeguard the scanner
      # would emit a typo finding here.
      findings = scan("FN main() ->\n  x = users>0;\nEND\n")
      expect(findings).to be_empty
    end

    it "ignores `s>` inside line comments" do
      findings = scan("FN main() ->\n  # used to write s> here\n  RETURN;\nEND\n")
      expect(findings).to be_empty
    end

    it "ignores `s>` inside double-quoted strings" do
      findings = scan(%(FN main() ->\n  msg = "old s> form";\n  RETURN;\nEND\n))
      expect(findings).to be_empty
    end

    it "ignores `s>` inside triple-quoted strings spanning lines" do
      findings = scan(%(FN main() ->\n  msg = """\n  doc says s> is bad\n  """;\nEND\n))
      expect(findings).to be_empty
    end

    it "respects backslash escape inside single-quoted strings" do
      # An escaped quote (\\") must not close the string; the `s>`
      # past the escape must stay inside the string and not be flagged.
      findings = scan(%(FN main() ->\n  msg = "a\\" s> b";\nEND\n))
      expect(findings).to be_empty
    end
  end

  describe ".scan! arrow typo (`=>` -> `->`)" do
    it "flags `=>` and proposes `->`" do
      findings = scan("FN main() ->\n  IF 1 > 0 => 1 ELSE 0 END;\nEND\n")
      expect(findings.length).to eq(1)
      f = findings.first
      expect(f.message).to match(/Unknown operator `=>`.*did you mean `->`/)
      expect(f.fixes.first.edits.first.replacement).to eq("->")
    end
  end

  describe ".scan! retired mutation-name suffix" do
    it "removes bang suffixes from declarations and calls" do
      findings = scan("FN update!(MUTABLE x: Int64) -> update!(x); END")
      expect(findings.length).to eq(2)
      expect(findings.map { |finding| finding.fixes.first.edits.first.replacement }).to eq(["", ""])
      expect(findings.map { |finding| finding.fixes.first.edits.first.span.col }).to eq([10, 39])
    end

    it "does not confuse fallible types, negation, or !=" do
      findings = scan("FN f(x: !Int64) RETURNS !Bool -> ok = !false; x != 1; END")
      expect(findings).to be_empty
    end

    it "ignores bang-shaped text in strings and comments" do
      findings = scan("FN f() -> text = \"call!()\"; # mutate!()\nEND")
      expect(findings).to be_empty
    end
  end

  it "is a no-op when FixCollector is disabled" do
    FixCollector.disable!
    expect {
      SyntaxTypoScanner.scan!("FN main() -> v = [1] s> _; END")
    }.not_to raise_error
    # Re-enable for the after-hook
    FixCollector.enable!
    expect(FixCollector.drain).to be_empty
  end

  it "is a no-op on empty source" do
    findings = scan("")
    expect(findings).to be_empty
  end

  it "advances line/column tracking through newlines" do
    src = "FN main() ->\n\n\n  v = [1] s> _;\nEND\n"
    findings = scan(src)
    expect(findings.first.fixes.first.edits.first.span.line).to eq(4)
  end
end
