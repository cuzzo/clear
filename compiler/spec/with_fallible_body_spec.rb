require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "fallible work inside WITH bodies" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "rejects fallible work inside WITH SNAPSHOT transaction bodies" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN update() RETURNS !Void ->
        c = Box{ value: 0 } @versioned;
        WITH SNAPSHOT c AS MUTABLE y {
          y.value = toInt("1") OR_ELSE RAISE;
        } ON MvccConflict RAISE
        RETURN;
      END
    CLEAR

    expect { annotate(src) }.to raise_error(
      CompilerError,
      /WITH SNAPSHOT .* body must be non-fallible for atomicity.*toInt.*Move fallible work outside/m
    )
  end

  it "rejects fallible work inside universal WITH POLYMORPHIC bodies with the same retryable-body diagnostic" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN update(x: SHARED T) RETURNS !Void ->
        WITH POLYMORPHIC x AS y {
          _ = toInt("1") OR_ELSE RAISE;
        }
        RETURN;
      END
      FN main() RETURNS !Void ->
        b = Box{ value: 0 } @shared:locked;
        update(b) OR_ELSE RAISE;
        RETURN;
      END
    CLEAR

    expect { annotate(src) }.to raise_error(
      CompilerError,
      /WITH POLYMORPHIC body must be non-fallible for atomicity.*toInt.*Move fallible work outside/m
    )
  end

  it "allows fallible work inside inline lock WITH bodies" do
    src = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN update() RETURNS !Void ->
        c = Box{ value: 0 } @shared:locked;
        WITH EXCLUSIVE c AS y {
          y.value = toInt("1") OR_ELSE RAISE;
        }
        RETURN;
      END
    CLEAR

    expect { annotate(src) }.not_to raise_error
  end
end
