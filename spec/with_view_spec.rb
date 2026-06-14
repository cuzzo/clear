require "rspec"
require "stringio"

require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# Phase 2.3 — `WITH VIEW v AS s { ... }`:
#   - parser recognizes the form (also `WITH MATERIALIZED VIEW`)
#   - annotator rejects WITH VIEW on non-`@observable` sources
#   - alias is bound as the tense payload type returned by view/materialize
#   - alias is non_escaping for VIEW (borrow), escapable for MATERIALIZED_VIEW
RSpec.describe "WITH VIEW (Phase 2.3)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def find_with_block(ast)
    found = nil
    walk = lambda do |n|
      return unless n
      found = n if n.is_a?(AST::WithBlock) && (n.view_kind == :view || n.view_kind == :materialized_view)
      n.each { |v| walk.call(v) if v.is_a?(Struct) || v.is_a?(Array) } if n.is_a?(Struct)
      n.each { |v| walk.call(v) } if n.is_a?(Array)
    end
    ast.statements.each { |s| walk.call(s) }
    found
  end

  describe "parser" do
    it "parses `WITH VIEW v AS s { body }`" do
      src = <<~F
        FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
            WITH VIEW running AS s {
                ASSERT s >= 0.0, "started";
            }
            RETURN GIVE running;
        END
      F
      ast = parse(src)
      with_block = find_with_block(ast)
      expect(with_block).not_to be_nil
      expect(with_block.view_kind).to eq(:view)
      expect(with_block.capabilities.first[:capability]).to eq(:VIEW)
      expect(with_block.capabilities.first[:alias]).to eq("s")
    end

    it "parses `WITH MATERIALIZED VIEW v AS s { body }`" do
      src = <<~F
        FN viewer(running: ~Float64) RETURNS ~Float64 ->
            WITH MATERIALIZED VIEW running AS s {
                ASSERT s >= 0.0, "started";
            }
            RETURN GIVE running;
        END
      F
      ast = parse(src)
      with_block = find_with_block(ast)
      expect(with_block).not_to be_nil
      expect(with_block.view_kind).to eq(:materialized_view)
      expect(with_block.capabilities.first[:capability]).to eq(:MATERIALIZED_VIEW)
    end

    it "parses arrow form `WITH VIEW v AS s -> body END`" do
      src = <<~F
        FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
            WITH VIEW running AS s ->
                ASSERT s >= 0.0, "started";
            END
            RETURN GIVE running;
        END
      F
      ast = parse(src)
      with_block = find_with_block(ast)
      expect(with_block).not_to be_nil
      expect(with_block.view_kind).to eq(:view)
    end
  end

  describe "annotator" do
    it "errors when WITH VIEW targets a non-@observable type" do
      src = <<~F
        FN viewer(running: ~Float64) RETURNS ~Float64 ->
            WITH VIEW running AS s {
                ASSERT s >= 0.0, "started";
            }
            RETURN GIVE running;
        END
      F
      expect { annotate(src) }.to raise_error(/WITH VIEW requires an `@observable` source/)
    end

    it "accepts WITH VIEW on a `~T@observable` source" do
      src = <<~F
        FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
            WITH VIEW running AS s {
                ASSERT s >= 0.0, "started";
            }
            RETURN GIVE running;
        END
      F
      expect { annotate(src) }.not_to raise_error
    end

    it "keeps FIND view aliases optional" do
      src = <<~F
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                YIELD 6_i64;
            };
            found: ~?Int64@observable = gen |> FIND _ == 6_i64;
            WITH VIEW found AS s {
                IF s != NIL THEN
                    ASSERT s == 6_i64, "found";
                END
            }
            _ = NEXT found;
        END
      F
      expect { annotate(src) }.not_to raise_error
    end

    it "errors when WITH MATERIALIZED VIEW targets a non-tense source" do
      src = <<~F
        FN main() RETURNS Void ->
            xs = [1, 2, 3];
            WITH MATERIALIZED VIEW xs AS s {
                ASSERT s != NIL, "ok";
            }
        END
      F
      expect { annotate(src) }.to raise_error(/WITH MATERIALIZED VIEW requires a/)
    end

    # Phase 2 cleanup: WITH VIEW / WITH MATERIALIZED VIEW are reads
    # on an `@observable` source, NOT lock acquisitions. The pre-
    # Phase-2 LOCKED compatibility shim must NOT fire on them.
    it "does NOT auto-infer 'REQUIRES p: LOCKED' on WITH VIEW" do
      src = <<~F
        FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
            WITH VIEW running AS s {
                ASSERT s >= 0.0, "started";
            }
            RETURN GIVE running;
        END
      F
      stderr_capture = StringIO.new
      orig_stderr = $stderr
      $stderr = stderr_capture
      begin
        annotate(src)
      ensure
        $stderr = orig_stderr
      end
      expect(stderr_capture.string).not_to match(/Auto-inferring.*LOCKED/)
    end

    it "does NOT auto-infer 'REQUIRES p: LOCKED' on WITH MATERIALIZED VIEW" do
      src = <<~F
        FN viewer(running: ~Float64) RETURNS ~Float64 ->
            WITH MATERIALIZED VIEW running AS s {
                ASSERT s >= 0.0, "ok";
            }
            RETURN GIVE running;
        END
      F
      stderr_capture = StringIO.new
      orig_stderr = $stderr
      $stderr = stderr_capture
      begin
        annotate(src)
      ensure
        $stderr = orig_stderr
      end
      expect(stderr_capture.string).not_to match(/Auto-inferring.*LOCKED/)
    end
  end

  # @example_for: WITH_MATERIALIZED_NEEDS_TENSE
  # @fix: WITH MATERIALIZED VIEW snapshots a *tense* (`~T`) aggregate.
  # @fix: Prefix the declared type with `~` so the binding becomes a
  # @fix: tense source the WITH can sample at the boundary.
  describe ":WITH_MATERIALIZED_NEEDS_TENSE — non-tense source for MATERIALIZED VIEW" do
    it "raises when the source isn't `~T`" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
              xs: Int64[3] = [1, 2, 3];
              WITH MATERIALIZED VIEW xs AS s {
                  ASSERT s != NIL, "ok";
              }
          END
        CLEAR
      }.to raise_error(/WITH MATERIALIZED VIEW requires a/)
    end

    it "compiles when the source is `~T`" do
      annotate(<<~CLEAR)
        FN viewer(xs: ~Float64) RETURNS ~Float64 ->
            WITH MATERIALIZED VIEW xs AS s {
                ASSERT s >= 0.0, "ok";
            }
            RETURN GIVE xs;
        END
      CLEAR
    end

    it "tense-prefix fix targets the binding under WITH MATERIALIZED VIEW, not a same-typed prior decl on the same line" do
      require_relative "../src/ast/fixable_error" unless defined?(FixCollector)
      FixCollector.enable!
      begin
        src = <<~CLEAR
          FN main() RETURNS Void ->
              y: Int64[] = [1_i64, 2_i64]; xs: Int64[] = [3_i64, 4_i64];
              WITH MATERIALIZED VIEW xs AS s {
                  ASSERT s != NIL, "ok";
              }
          END
        CLEAR
        tokens = Lexer.new(src).tokenize
        ast = ClearParser.new(tokens, src).parse
        SemanticAnnotator.new(source_code: src).annotate!(ast) rescue nil
        finding = FixCollector.drain.find { |f| f.message =~ /MATERIALIZED VIEW requires/ }
        expect(finding).not_to be_nil
        edit = finding.fixes.first.edits.first
        decl_line = "    y: Int64[] = [1_i64, 2_i64]; xs: Int64[] = [3_i64, 4_i64];"
        expect(edit.span.col).to eq(decl_line.rindex("Int64") + 1)
      ensure
        FixCollector.disable!
      end
    end
  end
end
