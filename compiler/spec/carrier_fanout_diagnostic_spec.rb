require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# V5-2c: a carrier-polymorphic TAKES parameter consumed then used again must
# get the v5 fan-out diagnostic guiding to KEEP (design rule 3),
# not the generic use-after-move / capability-upgrade advice.
RSpec.describe "carrier-polymorphic fan-out diagnostic" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  SRC = <<~CLEAR
    STRUCT User { id: Int64 }
    FN sink(TAKES u: User) RETURNS Void -> RETURN; END
    FN cache(TAKES u: User) RETURNS Void -> sink(u); RETURN; END
    FN queue(TAKES u: User) RETURNS Void -> sink(u); RETURN; END
    FN foo(TAKES u: User) RETURNS Void ->
      cache(u);
      queue(u);
      RETURN;
    END
    FN main() RETURNS Void -> foo(User{ id: 1 }); RETURN; END
  CLEAR

  it "guides a carrier-polymorphic param fan-out to KEEP" do
    expect { annotate(SRC) }.to raise_error(SourceError) { |err|
      expect(err.message).to include("KEEP")
      expect(err.message).to include("UNIQUE")
    }
  end

  it "accepts the KEEP fix at the first fan-out" do
    fixed = SRC.sub("cache(u);", "cache(KEEP u);")
    expect { annotate(fixed) }.not_to raise_error
  end
end
