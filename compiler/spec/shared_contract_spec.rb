require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# V5-3c: the SHARED parameter contract (design "Shared identity"). SHARED
# means copying the payload would be semantically wrong: it rejects a plain
# value in DEFAULT/STRICT, accepts a retained (@shared/Arc) family, auto-
# retains multiple consuming uses, and does NOT silently make @multiowned
# thread-safe (the conservative implementation requires an explicit @shared,
# so a single-thread Rc is never silently promoted to a cross-thread Arc).
RSpec.describe "SHARED parameter contract" do
  def annotate(source, mode: :default)
    ClearParser.ownership_mode = mode
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  ensure
    ClearParser.ownership_mode = :default
  end

  REG = "STRUCT Sess { id: Int64 }\nFN reg(TAKES s: SHARED Sess) RETURNS Void -> RETURN; END\n"

  it "rejects a plain value in DEFAULT" do
    src = REG + "FN main() RETURNS Void -> x = Sess{ id: 1 }; reg(x); RETURN; END"
    expect { annotate(src, mode: :default) }.to raise_error(SourceError) { |e| expect(e.message).to include("ARG_NEEDS_SHARED") }
  end

  it "rejects a plain value in STRICT" do
    src = REG + "FN main() RETURNS Void -> x = Sess{ id: 1 }; reg(x); RETURN; END"
    expect { annotate(src, mode: :strict) }.to raise_error(SourceError) { |e| expect(e.message).to include("ARG_NEEDS_SHARED") }
  end

  it "accepts an @shared (Arc) source" do
    src = REG + "FN main() RETURNS Void -> x = Sess{ id: 1 } @shared; reg(x); RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end

  it "auto-retains multiple consuming uses of a SHARED param with no per-use KEEP" do
    src = "STRUCT Sess { id: Int64 }\n" \
          "FN sink(TAKES s: SHARED Sess) RETURNS Void -> RETURN; END\n" \
          "FN reg(TAKES s: SHARED Sess) RETURNS Void -> sink(s); sink(s); RETURN; END\n" \
          "FN main() RETURNS Void -> x = Sess{ id: 1 } @shared; reg(x); RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end

  it "does not silently accept a bare @multiowned as thread-safe into SHARED (requires explicit @shared)" do
    src = REG + "FN main() RETURNS Void -> x = Sess{ id: 1 } @multiowned; reg(x); RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("ARG_NEEDS_SHARED") }
  end
end
