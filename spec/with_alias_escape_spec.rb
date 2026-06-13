require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "WITH alias escape rules" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "rejects RETURN of an EXCLUSIVE alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN leak() RETURNS Box ->
        c = Box{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y { RETURN y; }
      END
    CLEAR

    expect { annotate(src) }.to raise_error(CompilerError, /Cannot RETURN 'y'.*WITH aliases are borrows/m)
  end

  it "allows RETURN COPY of an EXCLUSIVE alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN copyOut() RETURNS !Box ->
        c = Box{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y { RETURN COPY y; }
      END
    CLEAR

    expect { annotate(src) }.not_to raise_error
  end

  it "rejects RETURN SHARE of an EXCLUSIVE alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN reshare() RETURNS SHARED !Box ->
        c = Box{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y { RETURN SHARE y; }
      END
    CLEAR

    expect { annotate(src) }.to raise_error(CompilerError, /Cannot SHARE WITH-scoped 'y'/)
  end

  it "rejects RETURN CLONE of an EXCLUSIVE alias even when the payload is cloneable" do
    src = <<~CLEAR
      FN reclone() RETURNS ~Int64@shared ->
        p: ~Int64@shared = BG { 1; };
        c = p @shared:locked;
        WITH EXCLUSIVE c AS y { RETURN CLONE y; }
      END
    CLEAR

    expect { annotate(src) }.to raise_error(CompilerError, /Cannot CLONE WITH-scoped 'y'/)
  end

  it "rejects RETURN of a POLYMORPHIC alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN leak(x: SHARED T) RETURNS T ->
        WITH POLYMORPHIC x AS y { RETURN y; }
      END
    CLEAR

    expect { annotate(src) }.to raise_error(CompilerError, /Cannot RETURN 'y'.*WITH aliases are borrows/m)
  end

  it "allows RETURN COPY of a POLYMORPHIC alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN copyOut(x: SHARED T) RETURNS !T ->
        WITH POLYMORPHIC x AS y { RETURN COPY y; }
      END
    CLEAR

    expect { annotate(src) }.not_to raise_error
  end

  it "rejects RETURN SHARE of a POLYMORPHIC alias" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN reshare(x: SHARED T) RETURNS SHARED !T ->
        WITH POLYMORPHIC x AS y { RETURN SHARE y; }
      END
    CLEAR

    expect { annotate(src) }.to raise_error(CompilerError, /Cannot SHARE WITH-scoped 'y'/)
  end
end
