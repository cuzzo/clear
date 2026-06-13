require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/annotator" unless defined?(SemanticAnnotator)

RSpec.describe "Wildcard Borrows" do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast.full_type.resolved
  end

  let(:base_code) {
    <<~FLUX
      STRUCT Bar { val: Float64 }
      STRUCT Foo { b1: Bar, b2: Bar }
    FLUX
  }

  it "restricts all fields with wildcard borrow" do
    code = base_code + <<~FLUX
      MUTABLE foo = Foo{ b1: Bar{ val: 1 }, b2: Bar{ val: 2 } };
      WITH RESTRICT foo.* {
        foo.b1.val = 10; # Should error
      }
    FLUX
    expect { run(code) }.to raise_error(/Lifetime Error: Cannot assign to 'foo' because it is currently borrowed/)
  end

  it "allows immutable usage of structure while wildcard restricted" do
    code = base_code + <<~FLUX
      FN takeFoo(f: Foo) -> PASS END
      MUTABLE foo = Foo{ b1: Bar{ val: 1 }, b2: Bar{ val: 2 } };
      WITH RESTRICT foo.* {
        takeFoo(foo); # Should be fine
      }
    FLUX
    expect { run(code) }.not_to raise_error
  end

  it "restricts field b2 specifically when wildcard restricted" do
    code = base_code + <<~FLUX
      MUTABLE foo = Foo{ b1: Bar{ val: 1 }, b2: Bar{ val: 2 } };
      WITH RESTRICT foo.* {
        foo.b2.val = 20; # Should error
      }
    FLUX
    expect { run(code) }.to raise_error(/Lifetime Error: Cannot assign to 'foo' because it is currently borrowed/)
  end
end
