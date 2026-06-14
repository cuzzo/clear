require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/fixable_error" unless defined?(FixCollector)

# Atomics M2.8 -- the M2.6 lifetime errors that fire on `@shared:atomic`
# sources are now fixable findings. Under `FixCollector`, they record
# a FixableFinding with category `:escape` and an interactive Fix
# whose edit swaps `@shared:atomic` -> `@shared:locked` at the
# source's declaration line. The :interactive confidence is
# deliberate: `@shared:locked` typically requires a STRUCT wrap
# around the primitive, so the user reviews before applying.
#
# Without FixCollector, behaviour falls through to the existing
# `error!` path -- already covered by the lifetime audit specs;
# this file focuses on the collector-enabled flow.
RSpec.describe "Atomic-escape fixable finding (M2.8)" do
  def collect_findings(src)
    tokens = Lexer.new(src).tokenize
    ast    = ClearParser.new(tokens, src).parse
    ann    = SemanticAnnotator.new
    ann.source_code = src
    FixCollector.enable!
    begin
      ann.annotate!(ast)
    rescue StandardError
      # raise_in_collector: true on the M2.8 fixable means the
      # annotator raises after pushing into the collector. The
      # finding is what we want to inspect; the raised error is
      # expected.
    end
    findings = FixCollector.drain
    FixCollector.disable!
    findings
  ensure
    FixCollector.disable!
  end

  describe "RETURN of a BG handle capturing @shared:atomic" do
    let(:src) {
      <<~CLEAR
        FN spawn() RETURNS ~Void ->
          counter: Int64 = 0 @shared:atomic;
          bg = BG { v = counter; print(v.toString()); };
          RETURN bg;
        END
      CLEAR
    }

    it "emits a single :escape-category fixable finding" do
      fs = collect_findings(src)
      escape = fs.select { |f| f.category == :escape }
      expect(escape.size).to eq(1)
    end

    it "the finding is fatal (level :error) so `clear build` still rejects" do
      fs = collect_findings(src)
      escape = fs.find { |f| f.category == :escape }
      expect(escape.fatal?).to be true
    end

    it "the message matches the M2.6 RETURN lifetime error shape" do
      fs = collect_findings(src)
      escape = fs.find { |f| f.category == :escape }
      expect(escape.message).to match(/Lifetime Error.*RETURN.*lifetime is tied/i)
    end

    it "carries exactly one Fix with interactive confidence" do
      fs = collect_findings(src)
      escape = fs.find { |f| f.category == :escape }
      expect(escape.fixes.size).to eq(1)
      expect(escape.fixes.first.confidence).to eq(:interactive)
    end

    it "the fix description names the @shared:atomic -> @shared:locked migration" do
      fs = collect_findings(src)
      fix = fs.find { |f| f.category == :escape }.fixes.first
      expect(fix.description).to include("@shared:atomic")
      expect(fix.description).to include("@shared:locked")
    end

    it "the fix description mentions the v0.3 atomic-struct-fields wait option" do
      fs = collect_findings(src)
      fix = fs.find { |f| f.category == :escape }.fixes.first
      expect(fix.description).to match(/v0\.3.*atomic struct fields/i)
    end

    it "the fix's edit replaces the sigil text on the source's declaration line" do
      fs = collect_findings(src)
      fix = fs.find { |f| f.category == :escape }.fixes.first
      edit = fix.edits.first
      expect(edit.replacement).to eq('@shared:locked')
      # The source declared the atomic on line 2 (line 1 is `FN spawn()...`).
      expect(edit.span.line).to eq(2)
      decl_line = src.lines[1]
      expect(decl_line[edit.span.col - 1, edit.span.length]).to eq('@shared:atomic')
    end

    it "targets the ESCAPING binding's sigil when a prior @shared:atomic is on the same line" do
      multi_decl_src = <<~CLEAR
        FN spawn() RETURNS ~Void ->
          a: Int64 = 0_i64 @shared:atomic; counter: Int64 = 0_i64 @shared:atomic;
          bg = BG { v = counter; print(v.toString()); };
          RETURN bg;
        END
      CLEAR
      fs = collect_findings(multi_decl_src)
      fix = fs.find { |f| f.category == :escape }&.fixes&.first
      expect(fix).not_to be_nil
      decl_line = multi_decl_src.lines[1]
      # Fix must target counter's sigil (the second occurrence), not a's.
      expect(fix.edits.first.span.col).to eq(decl_line.rindex('@shared:atomic') + 1)
    end
  end

  describe "store-into-long-lived: assigning a BG handle into a struct field" do
    # Build a fn taking `MUTABLE outer: Holder` where `outer.handle = bg`
    # would store an atomic-tied BG handle into a destination outliving
    # the atomic. Today the test exercises the RETURN path because the
    # store-into-arg-field path is well-covered by the M2.6 audit; the
    # important contract here is "any escape on `@shared:atomic` produces
    # a fixable finding". The suggester spec carries the kind variants.
    it "non-atomic tied-lifetime escapes still take the plain error! path" do
      # Borrowed-field BG capture without atomic -- the source's sync is
      # not :atomic, so M2.8 falls back to plain error! (no fixable
      # finding).
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN spawn(MUTABLE c: C) RETURNS ~Void ->
          bg = BG { x = c.v; print(x.toString()); };
          RETURN bg;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast    = ClearParser.new(tokens, src).parse
      ann    = SemanticAnnotator.new
      ann.source_code = src
      FixCollector.enable!
      begin
        ann.annotate!(ast)
      rescue StandardError
      end
      escape = FixCollector.drain.select { |f| f.category == :escape }
      FixCollector.disable!
      # BG that captures only borrowed/non-atomic params produces a
      # tied-lifetime error too, but because the source isn't @shared:
      # atomic, M2.8's fixable path is skipped (no fix). The error
      # still fires via error!; FixCollector doesn't see it.
      expect(escape).to be_empty
    end
  end
end
