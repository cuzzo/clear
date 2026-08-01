require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# Carrier fix: a retained @multiowned/@shared handle cannot silently fill a
# plain (RawT) TAKES parameter. The caller must OWN COPY (detach) or the param
# must opt into keeping the handle. This closes the silent payload-detach hole.
RSpec.describe "retained handle into a plain parameter" do
  RPS_PRE = "STRUCT User { id: Int64 }\nFN consume(TAKES u: User) RETURNS Int64 -> RETURN u.id; END\n"

  def annotate(src)
    ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  it "rejects a bare @multiowned handle passed to a plain parameter" do
    src = RPS_PRE + "FN main() RETURNS Void ->\n  m = User{ id: 1 } @multiowned;\n  x = consume(m);\n  RETURN;\nEND\n"
    expect { annotate(src) }.to raise_error(/RETAINED_NEEDS_OWN_COPY|cannot fill the plain parameter/)
  end

  it "rejects GIVE of a handle into a plain parameter" do
    src = RPS_PRE + "FN main() RETURNS Void ->\n  m = User{ id: 1 } @multiowned;\n  x = consume(GIVE m);\n  RETURN;\nEND\n"
    expect { annotate(src) }.to raise_error(/RETAINED_NEEDS_OWN_COPY|cannot fill the plain parameter/)
  end

  it "accepts OWN COPY of a handle into a plain parameter" do
    src = RPS_PRE + "FN main() RETURNS Void ->\n  m = User{ id: 1 } @multiowned;\n  x = consume(OWN COPY m);\n  RETURN;\nEND\n"
    expect { annotate(src) }.not_to raise_error
  end

  it "accepts a plain owned value moved into a plain parameter" do
    src = RPS_PRE + "FN main() RETURNS Void ->\n  p = User{ id: 1 };\n  x = consume(p);\n  RETURN;\nEND\n"
    expect { annotate(src) }.not_to raise_error
  end
end
