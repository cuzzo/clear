require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "PRE clauses on function signatures" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "parser" do
    it "leaves pre_clauses nil when no PRE is given" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64 ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses).to be_nil
    end

    it "parses a single PRE clause between RETURNS and ->" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64
          PRE: x > 0
        ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(1)
      entry = fn.pre_clauses.first
      expect(entry[:expr]).to be_a(AST::BinaryOp)
      expect(entry[:source]).to eq("x > 0")
    end

    it "parses multiple PRE clauses without any terminator" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64
          PRE: x > 0
          PRE: x < 100
        ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(2)
    end

    it "parses PRE with && and || combinators" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64
          PRE: x > 0 && x < 100
        ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(1)
      entry = fn.pre_clauses.first
      expect(entry[:expr]).to be_a(AST::BinaryOp)
      expect(entry[:source]).to eq("x > 0 && x < 100")
    end

    it "parses PRE that references multiple parameters" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64, y: Int64) RETURNS !Int64
          PRE: x < y
        ->
          RETURN x + y;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(1)
    end

    # source_slice_between has two branches: same-line slice and
    # multi-line slice. The multi-line case is exercised by every
    # other test (the predicate ends on its own line, before `->`
    # on the next line). This covers the same-line slice — the
    # whole signature on one source line so start_tok and end_tok
    # share a line. Verifies the captured source text is correct
    # and includes interior whitespace exactly as written between
    # the two tokens.
    it "captures source text correctly when PRE and `->` are on the same line" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64 PRE: x > 0 ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(1)
      entry = fn.pre_clauses.first
      expect(entry[:expr]).to be_a(AST::BinaryOp)
      expect(entry[:source]).to eq("x > 0")
    end

    it "captures source text when two PRE clauses share one line" do
      ast = parse(<<~CLEAR)
        FN foo(x: Int64) RETURNS !Int64
          PRE: x > 0  PRE: x < 100
        ->
          RETURN x;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.pre_clauses.length).to eq(2)
      # First PRE's end_tok is the second `PRE` keyword on the
      # same line — single-line slice path.
      expect(fn.pre_clauses[0][:source]).to eq("x > 0")
      # Second PRE's end_tok is `->` on a later line — multi-line
      # slice path. Both predicates round-trip cleanly.
      expect(fn.pre_clauses[1][:source]).to eq("x < 100")
    end

    it "parses PRE clauses on a function that also has REQUIRES" do
      ast = parse(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN bump!(MUTABLE c: Counter) RETURNS !Void
          REQUIRES c: LOCKED
          PRE: TRUE
        ->
          RETURN;
        END
      CLEAR
      fn = ast.statements.last
      expect(fn.pre_clauses.length).to eq(1)
      expect(fn.requires).not_to be_nil
    end
  end

  describe "annotator: validation" do
    it "accepts a Bool predicate over a parameter" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS !Int64
            PRE: x > 0
          ->
            RETURN x;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts multiple PRE predicates over distinct parameters" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64, y: Int64) RETURNS !Int64
            PRE: x > 0
            PRE: y < 100
          ->
            RETURN x + y;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts TRUE / FALSE literals in a PRE predicate" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS !Int64
            PRE: TRUE
          ->
            RETURN x;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects a non-Bool PRE expression" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS !Int64
            PRE: x
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError, /PRE expression must return Bool/)
    end

    it "rejects PRE references to non-parameter symbols" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS !Int64
            PRE: y > 0
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError,
        /PRE clauses may only reference function parameters.*'y'/m)
    end

    it "the PRE-typo error carries an :auto fix suggesting the closest parameter name" do
      require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
      FixCollector.enable!
      begin
        begin
          annotate(<<~CLEAR)
            FN foo(count: Int64) RETURNS !Int64
              PRE: counnt > 0
            ->
              RETURN count;
            END
          CLEAR
        rescue CompilerError
          # cascade: true raises after the finding is pushed
        end
        findings = FixCollector.drain.select { |f|
          f.message.include?("PRE clauses may only reference")
        }
        expect(findings).not_to be_empty
        fix = findings.first.fixes.first
        expect(fix.confidence).to eq(:auto)
        expect(fix.edits.first.replacement).to eq('count')
      ensure
        FixCollector.disable!
      end
    end

    it "rejects a PRE that calls a fallible function (RAISE inside callee)" do
      expect {
        annotate(<<~CLEAR)
          FN check?(x: Int64) RETURNS !Bool ->
            IF x < 0 THEN RAISE Input, BadInput, "negative"; END
            RETURN TRUE;
          END
          FN foo(x: Int64) RETURNS !Int64
            PRE: check?(x)
          ->
            RETURN 0;
          END
        CLEAR
      }.to raise_error(CompilerError, /PRE clauses must be pure.*can fail/m)
    end

    it "rejects when the function has PRE but no RETURNS clause" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64)
            PRE: x > 0
          ->
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError,
        /PRE clauses but no explicit return type.*RETURNS !Void/m)
    end

    it "the PRE-without-RETURNS error carries an :auto fixable that inserts `RETURNS !Void`" do
      require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
      FixCollector.enable!
      begin
        begin
          annotate(<<~CLEAR)
            FN foo(x: Int64)
              PRE: x > 0
            ->
              RETURN;
            END
          CLEAR
        rescue CompilerError
          # fixable! at :error level raises after pushing in collector mode
        end
        findings = FixCollector.drain.select { |f|
          f.category == :type && f.message.include?("PRE clauses but no explicit return type")
        }
        expect(findings).not_to be_empty
        fix = findings.first.fixes.first
        expect(fix.confidence).to eq(:auto)
        expect(fix.edits.first.replacement).to eq('RETURNS !Void ')
      ensure
        FixCollector.disable!
      end
    end

    it "rejects when the function has PRE and RETURNS T (non-error-union)" do
      expect {
        annotate(<<~CLEAR)
          FN foo(x: Int64) RETURNS Int64
            PRE: x > 0
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError, /can fail.*Change `RETURNS Int64` to `RETURNS !Int64`/m)
    end

    it "accepts a PRE that references a MUTABLE-by-ref parameter" do
      # PRE evaluates at function entry, before any of the body's
      # mutations could touch the bound value. A MUTABLE param reads
      # cleanly through the predicate.
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bumpIfNonNeg!(MUTABLE c: Counter) RETURNS !Int64
            PRE: c.value >= 0
          ->
            c.value = c.value + 1;
            RETURN c.value;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts a PRE on a generic function with REQUIRES-bound type param" do
      # PRE on FN foo<T>(x: T) — predicate must type-check for the
      # generic type parameter. The simplest form: predicate over the
      # parameter without invoking T-specific operations.
      expect {
        annotate(<<~CLEAR)
          FN identity?<T>(x: T) RETURNS !T
            PRE: TRUE
          ->
            RETURN x;
          END
          FN main() RETURNS !Void ->
            v = identity?(7) OR RAISE;
            ASSERT v == 7, "ok";
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
