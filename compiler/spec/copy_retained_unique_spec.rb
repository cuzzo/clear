require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# Carrier model: bare COPY is a memcpy and cannot copy a live @multiowned/
# @shared handle (that would duplicate an owner without touching the refcount).
# The sole retained-carrier detach is OWN COPY. This holds at every boundary,
# UNIQUE included. COPY of a plain value is unaffected.
RSpec.describe "COPY vs OWN COPY of a retained carrier" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  it "accepts OWN COPY of an @multiowned value at a UNIQUE parameter boundary (detach)" do
    src = <<~CLEAR
      STRUCT B { c: Int64 }
      FN fork(TAKES b: UNIQUE B) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        MUTABLE s = B{ c: 1 } @multiowned;
        fork(OWN COPY s);
        WITH s { ASSERT s.c == 1; }
        RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end

  it "rejects a bare COPY (memcpy) of an @multiowned value even at a UNIQUE boundary" do
    src = <<~CLEAR
      STRUCT B { c: Int64 }
      FN fork(TAKES b: UNIQUE B) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        MUTABLE s = B{ c: 1 } @multiowned;
        fork(COPY s);
        WITH s { ASSERT s.c == 1; }
        RETURN;
      END
    CLEAR
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("COPY_RETAINED_NEEDS_UNIQUE") }
  end

  it "rejects a bare COPY of an @multiowned value at a non-UNIQUE parameter boundary" do
    src = <<~CLEAR
      STRUCT B { c: Int64 }
      FN sink(TAKES b: B) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        MUTABLE s = B{ c: 1 } @multiowned;
        sink(COPY s);
        WITH s { ASSERT s.c == 1; }
        RETURN;
      END
    CLEAR
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("COPY_RETAINED_NEEDS_UNIQUE") }
  end

  it "leaves COPY of a plain value unaffected" do
    src = <<~CLEAR
      STRUCT B { c: Int64 }
      FN sink(TAKES b: B) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        p = B{ c: 1 };
        sink(COPY p);
        ASSERT p.c == 1;
        RETURN;
      END
    CLEAR
    expect { annotate(src) }.not_to raise_error
  end
end
