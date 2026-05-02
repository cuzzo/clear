require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # LIFETIMES
  describe "Lifetimes" do
    let(:func_def) { ast.statements.find { |n| n.is_a?(AST::FunctionDef) } }
    context "simple valid lifetime" do
      let(:code) {
        <<~FLUX
          -- Define function that returns a Float64
          FN identity(n: Float64) RETURNS n:Float64 ->
            RETURN n;
          END

          identity(1);
        FLUX
      }

      it "parses annotation properly" do
        expect(func_def.return_lifetime.first.name).to eq("n")
        expect(result).to eq(:Float64)
      end
    end

    context "simple invalid lifetime" do
      let(:code) {
        <<~FLUX
          -- Define function that returns a Float64
          FN identity(n: Float64) RETURNS x:Float64 ->
            RETURN n;
          END

          identity(1);
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "simple missing field lifetime" do
      let(:code) {
        <<~FLUX
          UNION Val { Nil, Name: String }
          STRUCT Foo { v: Val }

          FN identity(f: Foo) RETURNS Val ->
            RETURN f.v;
          END
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Cannot return/i)
      end
    end

    context "simple supplied field lifetime" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          identity(Foo{ b: Bar{ index: 1 }});
        FLUX
      }

      it "parses successfully" do
        expect(func_def.return_lifetime.first.name).to eq("f")
        expect(result).to eq(:Bar)
      end
    end

    context "simple missing index lifetime" do
      let(:code) {
        <<~FLUX
          UNION Val { Nil, Name: String }

          FN identity(l: Val[]) RETURNS Val ->
            RETURN l[1];
          END
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Cannot return/i)
      end
    end

    context "block non-restricted mutable borrows" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          identity(foo);
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "allow WITH RESTRICT mutable borrows" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            identity(foo);
          }
        FLUX
      }

      it "succeeds" do
        expect(func_def.return_lifetime.first.name).to eq("f")
        expect(result).to eq(:Void)
      end
    end

    context "allow WITH RESTRICT multiple mutable borrows WITHOUT assignment" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            identity(foo);
            identity(foo);
          }
        FLUX
      }

      it "succeeds" do
        expect(func_def.return_lifetime.first.name).to eq("f")
        expect(result).to eq(:Void)
      end
    end

    context "forbid WITH RESTRICT multiple mutable borrows WITH assignment" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            MUTABLE x = identity(foo);
            MUTABLE y = identity(foo);
          }
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "forbid WITH RESTRICT multiple borrows (one mutable) WITH assignment" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            MUTABLE x = identity(foo);
            MUTABLE y = identity(foo);
          }
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "forbid mutating RESTRICTed mutables" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            MUTABLE y = identity(foo);
            foo.b = Bar{index: 10};
          }
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "forbid mutating RESTRICTed mutables" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { b: Bar }

          FN changeBar!(MUTABLE f: Foo) ->
            f.b = Bar{index: 10};
          END

          -- Define function that returns a Float64
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          MUTABLE foo = Foo{ b: Bar{ index: 1 }};
          WITH RESTRICT foo {
            MUTABLE y = identity(foo);
            changeBar!(foo);
          }
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "forbid invalid sub-lifetimes" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Baz { name: String }
          STRUCT Foo { bar: Bar, baz: Baz }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Float64
          FN identity(r: Root) RETURNS f.baz:Bar ->
            RETURN r.bar;
          END
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    context "allow valid sub-lifetimes" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Baz { name: Byte[] }
          STRUCT Foo { bar: Bar, baz: Baz }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Float64
          FN identity(r: Root) RETURNS r.foo.bar:Bar ->
            RETURN r.foo.bar;
          END

          r = Root{ foo: Foo{ bar: Bar{ index: 1 }, baz: Baz{ name: "Test"}}};
          identity(r);
        FLUX
      }

      it "succeeds" do
        annotator = SemanticAnnotator.new
        expect(annotator.send(:get_lifetime_path, func_def)).to eq("r.foo.bar")
        expect(result).to eq(:Bar)
      end
    end

    context "allow valid sub-lifetimes" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Float64 }
          STRUCT Foo { bar1: Bar, bar2: Bar }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Float64
          FN identity(r: Root) RETURNS r.foo.bar2:Bar ->
            RETURN r.foo.bar1;
          END
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end

    # =========================================================================
    # BUG: indirect borrow escape -- elem = list[idx]; RETURN elem
    # The OG marks elem as :borrowed but verify_return only checked GetIndex/
    # GetField nodes directly; it bailed out early for Identifier nodes.
    # =========================================================================
    context "indirect indexed borrow escape (via variable, non-copyable element)" do
      let(:code) {
        <<~FLUX
          UNION Val { Nil, Name: String }

          FN first(items: Val[]) RETURNS Val ->
            elem = items[0];
            RETURN elem;
          END
        FLUX
      }

      it "errors: cannot return a borrowed element via variable without COPY or lifetime" do
        expect { result }.to raise_error(/Cannot return borrowed/i)
      end
    end

    context "indirect field borrow escape (via variable, non-copyable field)" do
      let(:code) {
        <<~FLUX
          UNION Val { Nil, Name: String }
          STRUCT Foo { v: Val }

          FN getVal(f: Foo) RETURNS Val ->
            v = f.v;
            RETURN v;
          END
        FLUX
      }

      it "errors: cannot return a borrowed field via variable without COPY or lifetime" do
        expect { result }.to raise_error(/Cannot return borrowed/i)
      end
    end

    context "COPY of indexed element is allowed" do
      let(:code) {
        <<~FLUX
          UNION Val { Nil, Name: String }

          FN first(items: Val[]) RETURNS Val ->
            elem = COPY items[0];
            RETURN elem;
          END
        FLUX
      }

      it "does not error" do
        expect { result }.not_to raise_error
      end
    end
  end
end
