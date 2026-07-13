require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "SHARE keyword" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "lexes SHARE as a keyword" do
    tokens = Lexer.new("x = SHARE y;").tokenize
    expect(tokens.map(&:value)).to include("SHARE")
    expect(tokens.find { |t| t.value == "SHARE" }.type).to eq(:KEYWORD)
  end

  it "lexes SHARED as a keyword for polymorphic shared type annotations" do
    tokens = Lexer.new("FN keep(x: SHARED T) RETURNS SHARED T -> RETURN x; END").tokenize
    expect(tokens.map(&:value)).to include("SHARED")
    expect(tokens.find { |t| t.value == "SHARED" }.type).to eq(:KEYWORD)
  end

  it "parses SHARED T as polymorphic shared while T @shared remains concrete Arc syntax" do
    ast = parse(<<~CLEAR)
      FN keep(x: SHARED T) RETURNS SHARED T -> RETURN x; END
      FN make() RETURNS Box @shared -> RETURN Box{ value: 1 } @shared; END
    CLEAR

    keep = ast.statements.first
    concrete = ast.statements.last

    expect(keep.params.first[:type]).to be_polymorphic_shared
    expect(keep.return_type).to be_polymorphic_shared
    expect(concrete.return_type).to be_shared
    expect(concrete.return_type).not_to be_polymorphic_shared
  end

  it "parses SHARED outside return lifetimes" do
    ast = parse(<<~CLEAR)
      FN spawn(counter: Int64) RETURNS SHARED counter:~T -> RETURN counter; END
    CLEAR

    fn = ast.statements.first
    expect(fn.return_lifetime.first.name).to eq("counter")
    expect(fn.return_type).to be_polymorphic_shared
    expect(fn.return_type.resolved).to eq(:"~T")
  end

  it "parses SHARE as an expression" do
    ast = parse("x = SHARE y;")
    bind = ast.statements.first

    expect(bind.value).to be_a(AST::ShareNode)
    expect(bind.value.value).to be_a(AST::Identifier)
    expect(bind.value.value.name).to eq("y")
  end

  it "infers SHARE as a shared value" do
    ast = annotate(<<~CLEAR)
      STRUCT Box { value: Int64 }
      FN main() RETURNS Void ->
        b = Box{ value: 1 };
        s = SHARE b;
        RETURN;
      END
    CLEAR

    share = ast.statements.last.body[1].value
    expect(share.full_type).to be_shared
  end

  it "rejects bare values passed to T@shared parameters and suggests SHARE" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(b);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /expects Box @shared.*got Box.*SHARE b/m)
  end

  it "rejects @multiowned values passed to T@shared parameters and suggests SHARE" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 } @multiowned;
          takes_shared(b);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /expects Box @shared.*SHARE b/m)
  end

  it "suggests SHARE expression syntax for non-identifier shared arguments" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          takes_shared(Box{ value: 1 });
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /expects Box @shared.*Use SHARE <expr>/m)
  end

  it "accepts shared values passed to T@shared parameters" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 } @shared;
          takes_shared(b);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts synchronized shared-family values passed to plain @shared parameters" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 } @shared:locked;
          takes_shared(b);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts SHARE values passed to T@shared parameters" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(SHARE b);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts explicit SHARE promotion from @multiowned to @shared" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 } @multiowned;
          takes_shared(SHARE b);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "accepts SHARE into a T@shared function that only clones the handle" do
    zig = transpile(<<~CLEAR)
      STRUCT Box { value: Int64 }

      FN clone_only(b: Box @shared) RETURNS Void ->
        retained = CLONE b;
        RETURN;
      END

      FN main() RETURNS Void ->
        b = Box{ value: 1 };
        clone_only(SHARE b);
        RETURN;
      END
    CLEAR

    expect(zig).to include("CheatLib.arcCreate(Box")
    expect(zig).to include("CheatLib.arcRetain(Box")
    expect(zig).to include("fn clone_only(rt: *Runtime")
  end

  it "accepts SHARE into a T@shared function that crosses a BG boundary" do
    expect {
      transpile(<<~CLEAR)
        STRUCT Box { value: Int64 }

        FN crosses_boundary(b: Box @shared) RETURNS !Void ->
          p: ~Int64 = BG { b.value; };
          value = NEXT p;
          RETURN;
        END

        FN main() RETURNS !Void ->
          b = Box{ value: 1 };
          crosses_boundary(SHARE b) OR_ELSE EXIT;
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects CLONE on a bare non-shared value" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          c = CLONE b;
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /CLONE is only supported/)
  end

  it "records GIVE as the move action for explicit GIVE expressions" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          moved = GIVE b;
          x = b.value;
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /USE AFTER MOVE.*`b`.*already GAVE.*line 4/m)
  end

  it "consumes a bare source passed through SHARE" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(SHARE b);
          x = b.value;
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /USE AFTER MOVE.*`b`.*already SHARED.*line 5/m)
  end

  it "reports the earlier SHARE site when sharing a consumed source again" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(SHARE b);
          takes_shared(SHARE b);
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /USE AFTER MOVE.*`b`.*already SHARED.*line 5/m)
  end

  it "does not consume the source when SHARE wraps COPY" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(SHARE COPY b);
          x = b.value;
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "does not consume an already shared handle" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 } @shared;
          takes_shared(SHARE b);
          takes_shared(b);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects returning a shared handle from a bare return type" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN unwrap_bad(b: Box @shared) RETURNS Box ->
          RETURN b;
        END
      CLEAR
    }.to raise_error(CompilerError, /expected to return 'Box'.*returned 'Box @shared'/m)
  end

  it "accepts returning a shared handle from a shared return type" do
    zig = transpile(<<~CLEAR)
      STRUCT Box { value: Int64 }
      FN retain_shared(b: Box @shared) RETURNS Box @shared ->
        RETURN b;
      END
    CLEAR

    expect(zig).to include("fn retain_shared")
    expect(zig).to include("CheatLib.Arc(Box)")
    expect(zig).to include("CheatLib.arcRetain(Box")
  end

  it "rejects returning a locked shared handle from a concrete unspecialized shared return type" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN retain_shared() RETURNS Box @shared ->
          b = Box{ value: 1 } @shared:locked;
          RETURN b;
        END
      CLEAR
    }.to raise_error(CompilerError, /expected to return 'Box @shared'.*returned 'Box @shared @locked'/m)
  end

  it "rejects returning a multiowned handle from a bare return type" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN unwrap_bad() RETURNS Box ->
          b = Box{ value: 1 } @multiowned;
          RETURN b;
        END
      CLEAR
      }.to raise_error(CompilerError, /expected to return 'Box'.*returned 'Box @multiowned'/m)
  end
end
