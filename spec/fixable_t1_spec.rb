require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Tier 1 fixable findings — five error codes that previously raised a
# plain CompilerError now emit a FixableFinding with a deterministic
# auto-fix. Each spec captures the finding via FixCollector and
# verifies both halves: the error fires AND the fix's edit is exactly
# what the user would paste back into their source.
RSpec.describe "Tier 1 fixable findings" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "WITH_RESTRICT_NEEDS_MUTABLE" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          x = 5;
          WITH RESTRICT x { _ = x; }
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src)
      findings = FixCollector.drain.select { |f| f.message.include?("RESTRICT") }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts `MUTABLE ` at the binding's column" do
      annotate(src)
      finding = FixCollector.drain.first
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("MUTABLE ")
      expect(edit.span.line).to eq(2)            # `  x = 5;` line
      expect(edit.span.length).to eq(0)          # insert, not replace
    end

    it "applying the fix produces compilable CLEAR" do
      lines = src.lines
      lines[1] = "  MUTABLE #{lines[1].lstrip}"
      fixed = lines.join
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "STYLE_MUTABLE_PARAM_NEEDS_BANG" do
    let(:src) {
      <<~CLEAR
        FN inc(MUTABLE x: Int64) -> x += 1; END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src)
      findings = FixCollector.drain.select { |f| f.message.include?("MUTABLE parameters") }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that appends `!` immediately after the function name" do
      annotate(src)
      edit = FixCollector.drain.first.fixes.first.edits.first
      expect(edit.replacement).to eq("!")
      expect(edit.span.line).to eq(1)
      expect(edit.span.length).to eq(0)
      # `FN inc` — name 'inc' starts at column 4, ends after column 6.
      # The bang insertion goes at column 7 (1-indexed, 0-length insert).
      expect(edit.span.col).to eq(7)
    end

    it "applying the fix produces compilable CLEAR" do
      fixed = src.sub("FN inc(", "FN inc!(")
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "CAN_SMASH_NOT_SUPPORTED" do
    # `@canSmash` lives inside the BG body's prefix block, between `{`
    # and the body's `->`. Consume the future with NEXT so the
    # PROMISE_NOT_CONSUMED check doesn't fire alongside.
    let(:src) {
      <<~CLEAR
        FN doSomething() RETURNS Int64 -> RETURN 42; END
        FN main() RETURNS Int64 ->
          fut = BG { @canSmash -> _ = doSomething(); };
          RETURN NEXT fut;
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message.include?("@canSmash") }
      expect(findings.size).to be >= 1
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that replaces `@canSmash` with `@service`" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message.include?("@canSmash") }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("@service")
      # length matches @canSmash = 9 chars
      expect(edit.span.length).to eq("@canSmash".length)
    end
  end

  describe "TYPE_MISMATCH_ASSIGN" do
    # Reassignment (not declaration) goes through validate_assignment_type;
    # initial declaration with a wrong-typed RHS hits Type#coerce! and
    # the TYPE_COERCION_FAILED umbrella code instead.
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x: Int64 = 5;
          x = "hello";
        END
      CLEAR
    }

    it "captures a fixable finding with one :interactive CAST fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.category == :type && f.message =~ /Type [Mm]ismatch/ }
      expect(findings.size).to be >= 1
      fix = findings.first.fixes.first
      expect(fix.confidence).to eq(:interactive)
      expect(fix.description).to include("CAST")
      expect(fix.description).to include("Int64")
    end

    it "produces a paired edit that brackets the value with `CAST(... AS Int64)`" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.category == :type && f.message =~ /Type [Mm]ismatch/ }
      edits = finding.fixes.first.edits
      expect(edits.size).to eq(2)
      expect(edits.first.replacement).to eq("CAST(")
      expect(edits.last.replacement).to eq(" AS Int64)")
    end

    it "offers a CAST fix when the value is a bare Identifier" do
      ident_src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x: Int64 = 5;
          y: String = "hello";
          x = y;
        END
      CLEAR
      annotate(ident_src) rescue nil
      finding = FixCollector.drain.find { |f| f.category == :type && f.message =~ /Type [Mm]ismatch/ }
      expect(finding).not_to be_nil
      edits = finding.fixes.first.edits
      # CAST wrap: insert "CAST(" before `y` and " AS Int64)" right after.
      expect(edits.size).to eq(2)
      expect(edits.first.replacement).to eq("CAST(")
      expect(edits.last.replacement).to eq(" AS Int64)")
    end

    it "skips the fix when the value isn't a Literal/Identifier (build_cast_wrap_fix returns nil)" do
      # BinaryOp / FuncCall etc. fall through to the else branch and
      # return nil; emit_type_mismatch_assign_error! then falls back
      # to plain error! (no finding captured).
      complex_src = <<~CLEAR
        FN concat(a: String, b: String) RETURNS String -> RETURN a + b; END
        FN main() RETURNS Void ->
          MUTABLE x: Int64 = 5;
          x = concat("a", "b");
        END
      CLEAR
      annotate(complex_src) rescue nil
      finding = FixCollector.drain.find { |f| f.category == :type && f.message =~ /Type [Mm]ismatch/ }
      if finding
        expect(finding.fixes).to be_empty
      end
    end
  end

  describe "fallback paths (no fix locatable)" do
    it "WITH_RESTRICT_NEEDS_MUTABLE — falls back to plain error! when scope info is missing" do
      # When the binding's symbol scope can't locate the declaration's
      # token (e.g. the binding came from a sub-tree without a reg.token),
      # build_declare_mutable_fix returns nil and the helper raises.
      # Synthesize this by stubbing.
      tokens = Lexer.new("FN main() RETURNS Void -> x = 5; WITH RESTRICT x { _ = x; } END").tokenize
      ast = Parser.new(tokens, "FN main() RETURNS Void -> x = 5; WITH RESTRICT x { _ = x; } END").parse
      ann = SemanticAnnotator.new
      allow(ann).to receive(:build_declare_mutable_fix).and_return(nil)
      FixCollector.disable!  # raise instead of collect
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /RESTRICT.*[Mm]utable/)
    end
  end
end
