require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# V5-2c static rules 4/5/6 (design "Static rules"). KEEP is only
# for carrier-polymorphic values; COPY is only for locals / UNIQUE params.
RSpec.describe "carrier correctness static rules" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  PRE = "STRUCT User { id: Int64 }\nFN sink(TAKES u: User) RETURNS Void -> RETURN; END\n"

  it "rule 4: KEEP on a plain local is an error (use COPY)" do
    src = PRE + "FN f() RETURNS Void -> u = User{ id: 1 }; sink(KEEP u); sink(u); RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("KEEP_ON_KNOWN_CARRIER") }
  end

  it "rule 5: KEEP on a UNIQUE param is an error (use COPY)" do
    src = PRE + "FN f(TAKES u: UNIQUE User) RETURNS Void -> sink(KEEP u); sink(u); RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("KEEP_ON_KNOWN_CARRIER") }
  end

  it "rule 6: COPY on a carrier-polymorphic param is an error (use KEEP/UNIQUE)" do
    src = PRE + "FN f(TAKES u: User) RETURNS Void -> sink(COPY u); sink(u); RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("COPY_ON_POLYMORPHIC_PARAM") }
  end

  it "allows COPY on a UNIQUE param (rule: UNIQUE enables COPY)" do
    src = PRE + "FN f(TAKES u: UNIQUE User) RETURNS Void -> sink(COPY u); sink(u); RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end
end

RSpec.describe "carrier-polymorphic provenance (alias)" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  PRE2 = "STRUCT User { id: Int64 }\nFN sink(TAKES u: User) RETURNS Void -> RETURN; END\n"

  it "rejects COPY on a local that directly aliases a carrier-polymorphic param" do
    src = PRE2 + "FN bad(TAKES value: User) RETURNS Void -> alias = value; sink(COPY alias); sink(alias); RETURN; END"
    expect { annotate(src) }.to raise_error(SourceError) { |e| expect(e.message).to include("COPY_ON_POLYMORPHIC_PARAM") }
  end

  it "still allows COPY on a genuinely local plain value" do
    src = PRE2 + "FN ok() RETURNS Void -> local = User{ id: 1 }; sink(COPY local); sink(local); RETURN; END"
    expect { annotate(src) }.not_to raise_error
  end
end
