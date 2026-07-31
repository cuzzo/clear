require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# C-1: UNIQUE means exactly one owner. A retained (@multiowned/@shared) value
# handed to a UNIQUE parameter without COPY is a live multi-owned handle and
# must be rejected; COPY detaches an independent payload and is accepted;
# a plain owned value moves in fine.
RSpec.describe "UNIQUE requires exclusive ownership" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  UNIQ_PRE = "STRUCT B { c: Int64 }\nFN fork(TAKES b: UNIQUE B) RETURNS Void -> RETURN; END\n"

  it "rejects a bare @multiowned handed to a UNIQUE parameter" do
    src = UNIQ_PRE + "FN main() RETURNS Void -> MUTABLE s = B{ c: 1 } @multiowned; fork(s); WITH s { ASSERT s.c == 1; } RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("UNIQUE_NEEDS_EXCLUSIVE") }
  end

  it "rejects a bare @shared handed to a UNIQUE parameter" do
    src = UNIQ_PRE + "FN main() RETURNS Void -> MUTABLE s = B{ c: 1 } @shared; fork(s); WITH s { ASSERT s.c == 1; } RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("UNIQUE_NEEDS_EXCLUSIVE") }
  end

  it "accepts OWN COPY of a retained value into a UNIQUE parameter (detached payload)" do
    src = UNIQ_PRE + "FN main() RETURNS Void -> MUTABLE s = B{ c: 1 } @multiowned; fork(OWN COPY s); WITH s { ASSERT s.c == 1; } RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end

  it "accepts a plain owned value moved into a UNIQUE parameter" do
    src = UNIQ_PRE + "FN main() RETURNS Void -> s = B{ c: 1 }; fork(s); RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end
end
