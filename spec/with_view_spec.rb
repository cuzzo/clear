require "rspec"
require "stringio"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Phase 2.3 — `WITH VIEW v AS s { ... }`:
#   - parser recognizes the form (also `WITH MATERIALIZED VIEW`)
#   - annotator rejects WITH VIEW on non-`@observable` sources
#   - alias is bound as `?T` (NIL until first item)
#   - alias is non_escaping for VIEW (borrow), escapable for MATERIALIZED_VIEW
RSpec.describe "WITH VIEW (Phase 2.3)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
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
                ASSERT s != NIL, "started";
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
                ASSERT s != NIL, "started";
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
                ASSERT s != NIL, "started";
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
                ASSERT s != NIL, "started";
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
                ASSERT s != NIL, "started";
            }
            RETURN GIVE running;
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
    # Phase-2 LOCKABLE compatibility shim must NOT fire on them.
    it "does NOT auto-infer 'REQUIRES p: LOCKABLE' on WITH VIEW" do
      src = <<~F
        FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
            WITH VIEW running AS s {
                ASSERT s != NIL, "started";
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
      expect(stderr_capture.string).not_to match(/Auto-inferring.*LOCKABLE/)
    end

    it "does NOT auto-infer 'REQUIRES p: LOCKABLE' on WITH MATERIALIZED VIEW" do
      src = <<~F
        FN viewer(running: ~Float64) RETURNS ~Float64 ->
            WITH MATERIALIZED VIEW running AS s {
                ASSERT s != NIL, "ok";
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
      expect(stderr_capture.string).not_to match(/Auto-inferring.*LOCKABLE/)
    end
  end
end
