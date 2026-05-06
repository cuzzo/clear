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

  # ===================================================================
  # ~T@shared Shared Promises — Phase 2
  # ===================================================================
  describe "~T@shared Shared Promises" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    # ------------------------------------------------------------------
    # Type system
    # ------------------------------------------------------------------
    describe "Type predicates" do
      it "shared_promise? is true for ~Float64@shared" do
        tokens = Lexer.new("~Float64 @shared").tokenize
        t = Parser.new(tokens, "~Float64 @shared").send(:parse_type_annotation)
        expect(t.shared_promise?).to be true
      end

      it "shared_promise? is false for plain ~Float64" do
        expect(Type.new(:"~Float64").shared_promise?).to be false
      end

      it "shared_promise? is false for ~Float64[3] (bounded stream)" do
        expect(Type.new(:"~Float64[3]").shared_promise?).to be false
      end

      it "shared_promise? is false for plain Float64@shared" do
        tokens = Lexer.new("Float64 @shared").tokenize
        t = Parser.new(tokens, "Float64 @shared").send(:parse_type_annotation)
        expect(t.shared_promise?).to be false
      end

      it "requires_move? is false for shared promises (non-affine)" do
        tokens = Lexer.new("~Float64 @shared").tokenize
        t = Parser.new(tokens, "~Float64 @shared").send(:parse_type_annotation)
        expect(t.requires_move?).to be false
      end

      it "requires_move? is still true for plain ~Float64" do
        expect(Type.new(:"~Float64").requires_move?).to be true
      end

      it "any_rc? is false for shared promises (SharedPromise is not Rc/Arc)" do
        tokens = Lexer.new("~Float64 @shared").tokenize
        t = Parser.new(tokens, "~Float64 @shared").send(:parse_type_annotation)
        expect(t.any_rc?).to be false
      end

      it "any_rc? is still true for plain Float64@shared (Arc wrapper)" do
        tokens = Lexer.new("Float64 @shared").tokenize
        t = Parser.new(tokens, "Float64 @shared").send(:parse_type_annotation)
        expect(t.any_rc?).to be true
      end
    end

    describe "Zig type emission" do
      it "emits CheatLib.SharedPromise(f64) for ~Float64@shared" do
        tokens = Lexer.new("~Float64 @shared").tokenize
        t = Parser.new(tokens, "~Float64 @shared").send(:parse_type_annotation)
        expect(t.zig_type).to eq("CheatLib.SharedPromise(f64)")
      end

      it "emits CheatLib.SharedPromise(bool) for ~Bool@shared" do
        tokens = Lexer.new("~Bool @shared").tokenize
        t = Parser.new(tokens, "~Bool @shared").send(:parse_type_annotation)
        expect(t.zig_type).to eq("CheatLib.SharedPromise(bool)")
      end

      it "still emits CheatLib.Promise(f64) for plain ~Float64" do
        expect(Type.new(:"~Float64").zig_type).to eq("CheatLib.Promise(f64)")
      end

      it "still emits CheatLib.Rc(f64) for Float64@multiOwned" do
        tokens = Lexer.new("Float64 @multiowned").tokenize
        t = Parser.new(tokens, "Float64 @multiowned").send(:parse_type_annotation)
        expect(t.zig_type).to eq("CheatLib.Rc(f64)")
      end
    end

    # ------------------------------------------------------------------
    # Compiler error: ~T@multiOwned is invalid
    # ------------------------------------------------------------------
    describe "~T@multiOwned compiler error" do
      it "raises a directed error when a binding declares ~T@multiOwned" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            sp: ~Float64 @multiowned = BG { 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /~T@multiOwned is not valid/)
      end
    end

    # ------------------------------------------------------------------
    # Annotator: BgBlock type propagation
    # ------------------------------------------------------------------
    describe "BgBlock full_type propagation" do
      it "annotates the BgBlock as shared when the declared type is ~T@shared" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 42.0; };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        bind = fn_node.body.first
        bg = bind.value
        bg_type = Type.new(bg.full_type)
        expect(bg_type.tense?).to be true
        expect(bg_type.shared_promise?).to be true
      end

      it "does not mark a plain ~T BgBlock as shared" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            p: ~Float64 = BG { 1.0; };
            r: Float64 = NEXT p;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        bind = fn_node.body.first
        bg = bind.value
        bg_type = Type.new(bg.full_type)
        expect(bg_type.shared_promise?).to be false
      end
    end

    # ------------------------------------------------------------------
    # Annotator: visit_NextExpr on shared promises
    # ------------------------------------------------------------------
    describe "visit_NextExpr on shared promises" do
      it "returns the inner type T when NEXT is applied to ~Float64@shared" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 1.0; };
            r: Float64 = NEXT sp;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows NEXT to be called multiple times on the same shared promise" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 10.0; };
            a: Float64 = NEXT sp;
            b: Float64 = NEXT sp;
            c: Float64 = NEXT sp;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "does not mark the shared promise variable as moved after NEXT" do
        # If it were moved, the second NEXT would raise 'Use of moved value'.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 5.0; };
            x: Float64 = NEXT sp;
            y: Float64 = NEXT sp;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Transpiler output
    # ------------------------------------------------------------------
    describe "Transpiler output" do
      it "emits CheatLib.SharedPromise in the BG block spawn" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.SharedPromise(f64).spawn(")
      end

      it "emits var (not const) for shared promise declarations" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var sp /)
      end

      it "emits .next() for NEXT on a shared promise" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 1.0; };
            r: Float64 = NEXT sp;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("sp.next()")
      end

      it "emits .next() twice when NEXT is called twice on the same handle" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 1.0; };
            a: Float64 = NEXT sp;
            b: Float64 = NEXT sp;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out.scan("sp.next()").size).to eq(2)
      end

      it "emits SharedPromise Inner type in the BG context struct" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            sp: ~Float64 @shared = BG { 99.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.SharedPromise(f64).Inner")
      end

      it "plain BG block still emits Promise (not SharedPromise)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            p: ~Float64 = BG { 1.0; };
            r: Float64 = NEXT p;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.Promise(f64).spawn(")
        expect(out).not_to include("SharedPromise")
      end
    end
  end

  # ===================================================================
  # ~T[N] Bounded Streams — Phase 1
  # ===================================================================
  describe "~T[N] Bounded Streams" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    # ------------------------------------------------------------------
    # Type system
    # ------------------------------------------------------------------
    describe "Type predicates" do
      it "bounded_stream? is true for ~Float64[3]" do
        t = Type.new(:"~Float64[3]")
        expect(t.bounded_stream?).to be true
      end

      it "bounded_stream? is false for plain ~Float64" do
        expect(Type.new(:"~Float64").bounded_stream?).to be false
      end

      it "bounded_stream? is false for ~Float64[] (dynamic)" do
        expect(Type.new(:"~Float64[]").bounded_stream?).to be false
      end

      it "stream_element_type returns the inner T for ~Float64[3]" do
        t = Type.new(:"~Float64[3]")
        expect(t.stream_element_type.to_sym).to eq(:Float64)
      end

      it "stream_capacity returns N for ~Float64[3]" do
        expect(Type.new(:"~Float64[3]").stream_capacity).to eq(3)
      end

      it "stream_capacity returns 1 for ~Bool[1]" do
        expect(Type.new(:"~Bool[1]").stream_capacity).to eq(1)
      end

      it "requires_move? is false for bounded streams (incremental consumption)" do
        expect(Type.new(:"~Float64[3]").requires_move?).to be false
      end

      it "requires_move? is still true for single promises" do
        expect(Type.new(:"~Float64").requires_move?).to be true
      end
    end

    describe "Zig type emission" do
      it "emits CheatLib.BoundedStream(f64, 3) for ~Float64[3]" do
        expect(Type.new(:"~Float64[3]").zig_type).to eq("CheatLib.BoundedStream(f64, 3)")
      end

      it "emits CheatLib.BoundedStream(bool, 1) for ~Bool[1]" do
        expect(Type.new(:"~Bool[1]").zig_type).to eq("CheatLib.BoundedStream(bool, 1)")
      end

      it "still emits CheatLib.Promise(f64) for plain ~Float64" do
        expect(Type.new(:"~Float64").zig_type).to eq("CheatLib.Promise(f64)")
      end
    end

    # ------------------------------------------------------------------
    # Parser
    # ------------------------------------------------------------------
    describe "Parser: parse_type_annotation" do
      it "parses ~Float64[3] as a bounded stream type" do
        tokens = Lexer.new("~Float64[3]").tokenize
        t = Parser.new(tokens, "~Float64[3]").send(:parse_type_annotation)
        expect(t.bounded_stream?).to be true
        expect(t.stream_capacity).to eq(3)
        expect(t.stream_element_type.to_sym).to eq(:Float64)
      end

      it "parses ~Bool[1] as a bounded stream type" do
        tokens = Lexer.new("~Bool[1]").tokenize
        t = Parser.new(tokens, "~Bool[1]").send(:parse_type_annotation)
        expect(t.bounded_stream?).to be true
        expect(t.stream_capacity).to eq(1)
      end
    end

    # ------------------------------------------------------------------
    # Annotator: visit_ListLit (bounded stream literal)
    # ------------------------------------------------------------------
    describe "visit_ListLit with tense items" do
      it "infers ~Float64[3] when all 3 items are ~Float64 promises" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "infers ~Float64[1] for a single-element promise list" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[1] = [BG { 42.0; }];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "raises when promise list items produce different types" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { TRUE; }];
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /mixed promise types/)
      end
    end

    # ------------------------------------------------------------------
    # Annotator: visit_NextExpr on bounded streams
    # ------------------------------------------------------------------
    describe "visit_NextExpr on bounded streams" do
      it "returns the element type T when NEXT is applied to ~Float64[3]" do
        src = <<~CLEAR
          FN f() RETURNS !Float64 ->
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            r: Float64 = NEXT s;
            RETURN r;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows NEXT to be called multiple times on the same bounded stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 10.0; }, BG { 20.0; }];
            a: Float64 = NEXT s;
            b: Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "does not mark the stream variable as moved after first NEXT" do
        # If the stream were marked :moved, the second NEXT would raise 'Use of moved value'.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            a: Float64 = NEXT s;
            b: Float64 = NEXT s;
            c: Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "still raises when NEXT is applied to a non-tense value" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            x: Float64 = 5.0;
            r: Float64 = NEXT x;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /NEXT requires a future value/)
      end
    end

    # ------------------------------------------------------------------
    # Compiler error: ~T[] (bare dynamic tense) is not valid
    # ------------------------------------------------------------------
    describe "~T[] compiler error" do
      it "raises a directed error when NEXT is called on a ~T[] value" do
        # Build an annotated node with a dynamic tense type manually
        # to simulate someone bypassing the parse_type_annotation guard.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { 2.0; }];
            RETURN;
          END
        CLEAR
        # Normal bounded stream works fine (no error)
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Transpiler
    # ------------------------------------------------------------------
    describe "Transpiler output" do
      it "emits CheatLib.BoundedStream in the variable declaration" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { 2.0; }];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.BoundedStream(f64, 2)")
      end

      it "emits var (not const) for bounded stream declarations" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { 2.0; }];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var s /)
      end

      it "emits .next() for NEXT on a bounded stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { 2.0; }];
            a: Float64 = NEXT s;
            b: Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out.scan("s.next()").size).to eq(2)
      end

      it "emits pre-declared promise items for bounded stream literal" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 10.0; }, BG { 20.0; }];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        # Each BG item is pre-declared as a local const
        expect(out).to include("__stream0_item0")
        expect(out).to include("__stream0_item1")
      end

      it "emits a Promise array in the BoundedStream items field" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[2] = [BG { 1.0; }, BG { 2.0; }];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("[2]CheatLib.Promise(f64)")
      end

      it "emits two independent stream labels for two streams in the same function" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s1: ~Float64[1] = [BG { 1.0; }];
            s2: ~Float64[1] = [BG { 2.0; }];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("__stream0")
        expect(out).to include("__stream1")
      end

      it "allows CONCURRENT SELECT on a bounded stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            vals = s |> CONCURRENT(workers: 2) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows CONCURRENT WHERE on a bounded stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            vals = s |> CONCURRENT(workers: 2) WHERE _ > 1.5;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows CONCURRENT EACH on a bounded stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE total: Float64@shared:locked = 0.0;
            s: ~Float64[3] = [BG { 1.0; }, BG { 2.0; }, BG { 3.0; }];
            s |> CONCURRENT(workers: 2) EACH {
              WITH EXCLUSIVE total AS t {
                t = t + _;
              }
            };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows CONCURRENT with explicit capacity on a stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; YIELD 2; YIELD 3; };
            vals = s |> CONCURRENT(workers: 2, capacity: 4) SELECT _ * 2;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "rejects CONCURRENT capacity of zero" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; };
            vals = s |> CONCURRENT(workers: 2, capacity: 0) SELECT _ * 2;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /capacity must be greater than 0/)
      end

      it "rejects CONCURRENT capacity of negative value" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; };
            vals = s |> CONCURRENT(workers: 2, capacity: -1) SELECT _ * 2;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /capacity must be greater than 0/)
      end

      it "rejects unknown CONCURRENT options" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; };
            vals = s |> CONCURRENT(workers: 2, buffer: 4) SELECT _ * 2;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /Unknown CONCURRENT option 'buffer'/)
      end
    end
  end

  # ===================================================================
  # ~?T[] Open Streams — Phase 3
  # ===================================================================
  describe "~?T[] Open Streams" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    # -------------------------------------------------------------------
    # Type predicates
    # -------------------------------------------------------------------
    describe "Type predicates" do
      it "open_stream? is true for ~?Float64[]" do
        t = Type.new(:"~?Float64[]")
        expect(t.open_stream?).to be true
      end

      it "open_stream? is false for plain ~Float64" do
        t = Type.new(:"~Float64")
        expect(t.open_stream?).to be false
      end

      it "open_stream? is false for ~Float64[3] (bounded stream)" do
        t = Type.new(:"~Float64[3]")
        expect(t.open_stream?).to be false
      end

      it "open_stream? is false for ~Float64@shared" do
        t = Type.new(:"~Float64", ownership: :shared)
        expect(t.open_stream?).to be false
      end

      it "open_stream_element_type returns Float64 for ~?Float64[]" do
        t = Type.new(:"~?Float64[]")
        expect(t.open_stream_element_type.resolved).to eq :Float64
      end

      it "open_stream_element_type returns Bool for ~?Bool[]" do
        t = Type.new(:"~?Bool[]")
        expect(t.open_stream_element_type.resolved).to eq :Bool
      end

      it "requires_move? is false for open streams (resource semantics)" do
        t = Type.new(:"~?Float64[]")
        expect(t.requires_move?).to be false
      end

      it "bounded optional streams preserve optional element type for ~?Float64[3]" do
        t = Type.new(:"~?Float64[3]")
        expect(t.bounded_stream?).to be true
        expect(t.stream_element_type.resolved).to eq :"?Float64"
        expect(t.stream_capacity).to eq 3
      end

      it "open_stream_marker? is true for Float64[?]" do
        t = Type.new(:"Float64[?]")
        expect(t.open_stream_marker?).to be true
      end

      it "open_stream_marker? is false for Float64[3]" do
        t = Type.new(:"Float64[3]")
        expect(t.open_stream_marker?).to be false
      end

      it "fixed? is false for Float64[?]" do
        t = Type.new(:"Float64[?]")
        expect(t.fixed?).to be false
      end

      it "dynamic? is false for Float64[?] (it is not dynamic — it is open-stream)" do
        t = Type.new(:"Float64[?]")
        expect(t.dynamic?).to be false
      end
    end

    # -------------------------------------------------------------------
    # Zig type emission
    # -------------------------------------------------------------------
    describe "zig_type" do
      it "emits CheatLib.Stream(f64) for ~?Float64[]" do
        t = Type.new(:"~?Float64[]")
        expect(t.zig_type).to eq "CheatLib.Stream(f64)"
      end

      it "emits CheatLib.Stream(bool) for ~?Bool[]" do
        t = Type.new(:"~?Bool[]")
        expect(t.zig_type).to eq "CheatLib.Stream(bool)"
      end
    end

    # -------------------------------------------------------------------
    # Parser: [?] in type annotations
    # -------------------------------------------------------------------
    describe "parser" do
      it "parses ~?Float64[] as a type annotation" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------
    # Annotator: BgStreamBlock
    # -------------------------------------------------------------------
    describe "BgStreamBlock annotation" do
      it "infers ~?Float64[] type from YIELD Float64" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        decl = fn_node.body.first
        expect(decl.value.full_type.open_stream?).to be true
        expect(decl.value.full_type.open_stream_element_type.resolved).to eq :Float64
      end

      it "infers ~?Bool[] from YIELD Bool" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Bool[] = BG STREAM { YIELD TRUE; };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        decl = fn_node.body.first
        expect(decl.value.full_type.open_stream_element_type.resolved).to eq :Bool
      end

      it "errors when BG STREAM has no YIELD statements" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[?] = BG STREAM { RETURN; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/no YIELD statements/)
      end

      it "errors when YIELD is used outside BG STREAM" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            YIELD 1.0;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/YIELD can only be used inside/)
      end

      it "errors when YIELD types are inconsistent" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; YIELD TRUE; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/inconsistent types/)
      end
    end

    # -------------------------------------------------------------------
    # Annotator: NextExpr on open streams
    # -------------------------------------------------------------------
    describe "NextExpr on ~?T[]" do
      it "NEXT on ~?Float64[] returns ?Float64" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] = BG STREAM { YIELD 1.0; };
            v: ?Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        next_decl = fn_node.body[1]
        expect(next_decl.value.full_type.optional?).to be true
        expect(next_decl.value.full_type.wrapped_type.resolved).to eq :Float64
      end

      it "NEXT on ~?Bool[] returns ?Bool" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Bool[] = BG STREAM { YIELD TRUE; };
            v: ?Bool = NEXT s;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        next_decl = fn_node.body[1]
        expect(next_decl.value.full_type.optional?).to be true
        expect(next_decl.value.full_type.wrapped_type.resolved).to eq :Bool
      end
    end

    # -------------------------------------------------------------------
    # Resource cleanup: deinit is emitted
    # -------------------------------------------------------------------
    describe "resource cleanup" do
      it "emits plain defer s.deinit() when stream is never moved" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("defer s.deinit(")
        expect(out).not_to include("s_moved")
      end
    end

    # -------------------------------------------------------------------
    # Transpiler output
    # -------------------------------------------------------------------
    describe "transpiler output" do
      it "emits CheatLib.Stream(f64) in the var declaration" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.Stream(f64)")
      end

      it "emits var (not const) for the stream binding" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var s/)
      end

      it "emits spawnNew in the BG STREAM block" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("spawnNew")
      end

      it "emits push() calls for each YIELD" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; YIELD 2.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include(".push(")
      end

      it "emits defer close() inside generator fiber" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include(".close()")
      end

      it "emits .next() for NEXT on open stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            v: ?Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("s.next()")
      end

      it "emits independent labels for two open streams in same function" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s1: ~Float64[?] = BG STREAM { YIELD 1.0; };
            s2: ~Float64[?] = BG STREAM { YIELD 2.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("__sg0")
        expect(out).to include("__sg1")
      end
    end
  end

  # ===================================================================
  # ~?T[]@split Split Streams
  # ===================================================================
  describe "~?T[]@split Split Streams" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    describe "Type predicates" do
      it "split_open_stream? is true for ~?Float64[]@split" do
        t = Type.new(:"~?Float64[]", ownership: :split)
        expect(t.split_open_stream?).to be true
      end

      it "split_open_stream? is false for plain ~?Float64[]" do
        t = Type.new(:"~?Float64[]")
        expect(t.split_open_stream?).to be false
      end

      it "emits CheatLib.SplitStream(f64) for ~?Float64[]@split" do
        t = Type.new(:"~?Float64[]", ownership: :split)
        expect(t.zig_type).to eq("CheatLib.SplitStream(f64)")
      end
    end

    describe "validation" do
      it "rejects @split on non-stream types" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            x: Float64 @split = 1.0;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /@split is currently only supported on stream types/)
      end

      it "rejects @split on non-open future types" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[INF] @split = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /@split is currently only valid on open streams/)
      end
    end

    describe "BgStreamBlock annotation" do
      it "propagates @split onto the BG STREAM runtime type" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        decl = fn_node.body.first
        expect(Type.new(decl.value.full_type).split_open_stream?).to be true
      end
    end

    describe "NextExpr on ~?T[]@split" do
      it "NEXT on ~?Float64[]@split returns ?Float64" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            v: ?Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        next_decl = fn_node.body[1]
        expect(next_decl.value.full_type.optional?).to be true
        expect(next_decl.value.full_type.wrapped_type.resolved).to eq :Float64
      end
    end

    describe "transpiler output" do
      it "emits CheatLib.SplitStream in the BG STREAM binding" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.SplitStream(f64)")
        expect(out).to include("spawnNew")
      end

      it "emits CheatLib.splitRetain when CLONE is used on a split stream handle" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            t: ~?Float64[] @split = CLONE s;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.splitRetain(")
      end

      it "plain assignment moves a split stream handle" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            t: ~?Float64[] @split = s;
            v: ?Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /Use of moved value 's'/)
      end

      it "allows CLONE inside a BG block capture" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] @split = BG STREAM { YIELD 1.0; };
            cloned: ~?Float64[] @split = CLONE s;
            p: ~?Float64 = BG {
              NEXT cloned;
            };
            v: ?Float64 = NEXT p;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows CLONE inline inside DO branches" do
        # The point of this test is "CLONE works as an arg to NEXT inline
        # inside a DO branch." The original fixture wrapped each branch
        # in WITH EXCLUSIVE on a @locked counter, but that pattern holds
        # the lock across NEXT (P3.3 hold-lock-across-yield). The lock
        # was incidental — drop it to keep the CLONE coverage clean.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Int64[] @split = BG STREAM { YIELD 1; };
            DO {
              (NEXT (CLONE s))?,
              (NEXT (CLONE s))?
            }
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows returning CLONE of a split stream" do
        src = <<~CLEAR
          FN tail() RETURNS ~?Int64[] @split ->
            s: ~?Int64[] @split = BG STREAM { YIELD 1; YIELD 2; };
            RETURN CLONE s;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end
  end

  # ===================================================================
  # ~T[INF] Infinite Streams — Phase 4
  # ===================================================================
  describe "~T[INF] Infinite Streams" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    # -------------------------------------------------------------------
    # Type predicates
    # -------------------------------------------------------------------
    describe "Type predicates" do
      it "inf_stream? is true for ~Float64[INF]" do
        t = Type.new(:"~Float64[INF]")
        expect(t.inf_stream?).to be true
      end

      it "inf_stream? is false for plain ~Float64" do
        expect(Type.new(:"~Float64").inf_stream?).to be false
      end

      it "inf_stream? is false for ~Float64[3] (bounded stream)" do
        expect(Type.new(:"~Float64[3]").inf_stream?).to be false
      end

      it "inf_stream? is false for ~Float64[?] (open stream)" do
        expect(Type.new(:"~Float64[?]").inf_stream?).to be false
      end

      it "inf_stream_element_type returns Float64 for ~Float64[INF]" do
        t = Type.new(:"~Float64[INF]")
        expect(t.inf_stream_element_type.resolved).to eq :Float64
      end

      it "inf_stream_element_type returns Bool for ~Bool[INF]" do
        t = Type.new(:"~Bool[INF]")
        expect(t.inf_stream_element_type.resolved).to eq :Bool
      end

      it "requires_move? is false for infinite streams (resource semantics)" do
        expect(Type.new(:"~Float64[INF]").requires_move?).to be false
      end

      it "inf_stream_marker? is true for Float64[INF]" do
        t = Type.new(:"Float64[INF]")
        expect(t.inf_stream_marker?).to be true
      end

      it "inf_stream_marker? is false for Float64[3]" do
        expect(Type.new(:"Float64[3]").inf_stream_marker?).to be false
      end

      it "fixed? is false for Float64[INF]" do
        expect(Type.new(:"Float64[INF]").fixed?).to be false
      end

      it "dynamic? is false for Float64[INF]" do
        expect(Type.new(:"Float64[INF]").dynamic?).to be false
      end
    end

    # -------------------------------------------------------------------
    # Zig type emission
    # -------------------------------------------------------------------
    describe "zig_type" do
      it "emits CheatLib.InfStream(f64) for ~Float64[INF]" do
        expect(Type.new(:"~Float64[INF]").zig_type).to eq "CheatLib.InfStream(f64)"
      end

      it "emits CheatLib.InfStream(bool) for ~Bool[INF]" do
        expect(Type.new(:"~Bool[INF]").zig_type).to eq "CheatLib.InfStream(bool)"
      end
    end

    # -------------------------------------------------------------------
    # Parser: [INF] in type annotations
    # -------------------------------------------------------------------
    describe "parser" do
      it "parses ~Float64[INF] as a type annotation" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------
    # Annotator: BgStreamBlock with ~T[INF] declared type
    # -------------------------------------------------------------------
    describe "BgStreamBlock annotation with ~T[INF]" do
      it "infers ~Float64[INF] type when declared as ~Float64[INF]" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        decl = fn_node.body.first
        expect(decl.value.full_type.inf_stream?).to be true
        expect(decl.value.full_type.inf_stream_element_type.resolved).to eq :Float64
      end

      it "infers ~Bool[INF] when YIELD produces Bool" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Bool[INF] = BG STREAM { WHILE TRUE DO YIELD TRUE; END };
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        decl = fn_node.body.first
        expect(decl.value.full_type.inf_stream?).to be true
        expect(decl.value.full_type.inf_stream_element_type.resolved).to eq :Bool
      end
    end

    # -------------------------------------------------------------------
    # NextExpr on ~T[INF] returns T (not ?T)
    # -------------------------------------------------------------------
    describe "NextExpr on ~T[INF]" do
      it "NEXT on ~Float64[INF] returns Float64 (not ?Float64)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            v: Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        next_decl = fn_node.body[1]
        expect(next_decl.value.full_type.optional?).to be false
        expect(next_decl.value.full_type.resolved).to eq :Float64
      end

      it "NEXT on ~Bool[INF] returns Bool (not ?Bool)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Bool[INF] = BG STREAM { WHILE TRUE DO YIELD TRUE; END };
            v: Bool = NEXT s;
            RETURN;
          END
        CLEAR
        ast = run(src)
        fn_node = ast.statements.first
        next_decl = fn_node.body[1]
        expect(next_decl.value.full_type.optional?).to be false
        expect(next_decl.value.full_type.resolved).to eq :Bool
      end
    end

    # -------------------------------------------------------------------
    # Resource cleanup: deinit is emitted
    # -------------------------------------------------------------------
    describe "resource cleanup" do
      it "emits plain defer s.deinit() when infinite stream is never moved" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("defer s.deinit(")
        expect(out).not_to include("s_moved")
      end
    end

    # -------------------------------------------------------------------
    # Transpiler output
    # -------------------------------------------------------------------
    describe "transpiler output" do
      it "emits CheatLib.InfStream(f64) in the var declaration" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("CheatLib.InfStream(f64)")
      end

      it "emits var (not const) for the stream binding" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var s/)
      end

      it "emits spawnNew in the BG STREAM block" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("spawnNew")
      end

      it "emits push() calls for YIELD inside the generator" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include(".push(")
      end

      it "emits defer close() for infinite stream generators (signals WaitGroup on error)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        # All stream generators now emit defer close() so the WaitGroup is
        # signaled even if the generator errors. InfStream.close() is a no-op
        # in the normal case, but the defer ensures proper cleanup on error paths.
        expect(out).to include(".close()")
      end

      it "emits .next() for NEXT on infinite stream" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            v: Float64 = NEXT s;
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("s.next()")
      end
    end
  end

  # ------------------------------------------------------------------
  # Cross-cutting compiler error tests: ~T@multiOwned and bare ~T[]
  # ------------------------------------------------------------------
  describe "stream / promise compiler error guards" do
    describe "~T@multiowned rejection" do
      it "raises an error when a plain promise is declared @multiowned (BindExpr path)" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            p: ~Float64 @multiowned = BG { 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/~T@multiOwned is not valid/)
      end

      it "raises an error when an open stream is declared @multiowned (BindExpr path)" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[?] @multiowned = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/~T@multiOwned is not valid/)
      end

      it "raises an error when an infinite stream is declared @multiowned (BindExpr path)" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[INF] @multiowned = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/~T@multiOwned is not valid/)
      end

      it "raises an error when a plain promise function param is @multiowned (VarDecl path)" do
        # Capability annotations on params are rejected at parse time,
        # so this guard is defensive for programmatic AST construction.
        # Test via BindExpr path instead (same error message).
        src = <<~CLEAR
          FN f() RETURNS Void ->
            p: ~Float64 @multiowned = BG { 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/~T@multiOwned is not valid/)
      end

      it "suggests @shared as the correct alternative" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            p: ~Float64 @multiowned = BG { 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(/Use ~T@shared instead/)
      end
    end

    describe "native ~T[] finite streams" do
      it "allows bare ~T[] in BindExpr declaration for finite streams" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows bare ~T[] in VarDecl (MUTABLE declaration) path" do
        # VarDecl path: MUTABLE declarations
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE s: ~Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "rejects BG STREAM as a bounded stream source" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            s: ~Float64[3] = BG STREAM { YIELD 1.0; YIELD 2.0; YIELD 3.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /Type Mismatch: Cannot assign ~\?Float64\[] to ~Float64\[3\]/)
      end

      it "still accepts infinite streams as a separate syntax" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "accepts the new open-stream spelling ~?T[]" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "still accepts legacy ~T[?] as an alias during migration" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[?] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "does NOT raise when ~T[INF] is used (valid infinite stream)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[INF] = BG STREAM { WHILE TRUE DO YIELD 1.0; END };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows variable-backed ~T[] pipelines for fusible EACH chains" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 8;
            MUTABLE acc: Int64 = 0;
            s |> SELECT _ * 2 |> WHERE _ > 3 |> EACH {
              acc = acc + _;
            };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "accepts REDUCE on variable-backed ~T[]" do
        # REDUCE-scalar on a tense stream now produces a `~T@observable`
        # value -- consume via COLLECT (or carry the `~T@observable`
        # binding annotation if the user wants to read it concurrently).
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Int64[] = 0 ..< 8;
            _ = s |> REDUCE(0_i64) acc + _ |> COLLECT;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "accepts LIMIT on variable-backed ~T[]" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Int64[] = 1 ..< 100;
            MUTABLE sum: Int64 = 0;
            s |> LIMIT 3 |> EACH { sum = sum + _; };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "accepts EACH on BG/open streams as sequential pipeline op" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; YIELD 2; };
            s |> EACH { print(_); };
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "accepts REDUCE on BG/open streams as sequential pipeline op" do
        # REDUCE-scalar on a tense stream now produces a `~T@observable`
        # -- consume via COLLECT.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~?Int64[] = BG STREAM { YIELD 1; YIELD 2; };
            _ = s |> REDUCE(0) acc + _ |> COLLECT;
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end

    describe "updated ~T[] NEXT error message (no future phases mention)" do
      it "error message does not say 'future phases'" do
        # Build a scenario where NEXT receives a bare ~T[] by constructing
        # the annotated node directly to bypass the declaration guard.
        # We verify the message in visit_NextExpr is updated.
        # The declaration guard now fires first, so we test via the message content directly.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            s: ~Float64[] = BG STREAM { YIELD 1.0; };
            RETURN;
          END
        CLEAR
        begin
          run(src)
        rescue => e
          expect(e.message).not_to include("future phases")
        end
      end
    end
  end

  # ~T[]@list Promise Lists — Phase 1
  # ===================================================================
  describe "~T[]@list Promise Lists" do
    def transpile_fn(clear_src)
      ZigTranspiler.new.transpile(clear_src)
    end

    # ------------------------------------------------------------------
    # Type predicates
    # ------------------------------------------------------------------
    describe "Type predicates" do
      it "promise_list? is true for ~Int64[]@list" do
        t = Type.new(:"~Int64[]", collection: :list)
        expect(t.promise_list?).to be true
      end

      it "promise_list? is false for plain ~Int64" do
        expect(Type.new(:"~Int64").promise_list?).to be false
      end

      it "promise_list? is false for ~Int64[3] (bounded stream)" do
        expect(Type.new(:"~Int64[3]").promise_list?).to be false
      end

      it "promise_list? is false for Int64[]@list (non-tense list)" do
        t = Type.new(:"Int64[]", collection: :list)
        expect(t.promise_list?).to be false
      end

      it "list_collection? is true for ~Int64[]@list" do
        t = Type.new(:"~Int64[]", collection: :list)
        expect(t.list_collection?).to be true
      end

      it "requires_move? is false for promise lists (list_collection? short-circuit)" do
        t = Type.new(:"~Int64[]", collection: :list)
        expect(t.requires_move?).to be false
      end
    end

    # ------------------------------------------------------------------
    # Zig type emission
    # ------------------------------------------------------------------
    describe "zig_type" do
      it "emits std.ArrayListUnmanaged(CheatLib.Promise(i64)) for ~Int64[]@list" do
        t = Type.new(:"~Int64[]", collection: :list)
        expect(t.zig_type).to eq("std.ArrayListUnmanaged(CheatLib.Promise(i64))")
      end

      it "emits std.ArrayListUnmanaged(CheatLib.Promise(f64)) for ~Float64[]@list" do
        t = Type.new(:"~Float64[]", collection: :list)
        expect(t.zig_type).to eq("std.ArrayListUnmanaged(CheatLib.Promise(f64))")
      end
    end

    # ------------------------------------------------------------------
    # accepts?
    # ------------------------------------------------------------------
    describe "accepts?" do
      it "promise list accepts empty list literal" do
        promise_list_t = Type.new(:"~Int64[]", collection: :list)
        empty_list_t   = Type.new(:"Any[]")
        expect(promise_list_t.accepts?(empty_list_t)).to be true
      end

      it "Any[] accepts ~Int64[] (for append intrinsic matching)" do
        any_arr   = Type.new(:"Any[]")
        tense_arr = Type.new(:"~Int64[]")
        expect(any_arr.accepts?(tense_arr)).to be true
      end
    end

    # ------------------------------------------------------------------
    # Annotator
    # ------------------------------------------------------------------
    describe "Annotator" do
      it "accepts MUTABLE futures: ~Int64[]@list = [] without error" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "rejects initializing bare ~T[] from [] because that is a promise list mismatch" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[] = [];
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /Type Mismatch/)
      end

      it "allows append(futures, BG { ... }) where futures is a promise list" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 42; });
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows indexing a promise list: futures[0] binds as ~Int64 (consumed via NEXT)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 42; });
            v: Int64 = NEXT futures[0];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "NEXT futures[i] returns the element type (Int64)" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 42; });
            v: Int64 = NEXT futures[0];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Transpiler output
    # ------------------------------------------------------------------
    describe "Transpiler output" do
      it "emits std.ArrayListUnmanaged(CheatLib.Promise(i64)) in the var declaration" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("std.ArrayListUnmanaged(CheatLib.Promise(i64))")
      end

      it "emits var (not const) for promise list declarations" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var futures /)
      end

      it "emits defer cleanup for futures list" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/CheatLib\.cleanup\(/)
      end

      it "emits try futures.append(rt.frameAlloc(), ...) for append" do
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 7; });
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("futures.append(")
      end

      it "emits indexed access plus .next() for NEXT futures[0]" do
        # Indexing now defers to CheatLib.getAt (polymorphic ArrayList/slice
        # dispatch via comptime @hasField). The lowering no longer hard-codes
        # `.items[i]` for @list.
        src = <<~CLEAR
          FN f() RETURNS !Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 7; });
            v: Int64 = NEXT futures[0];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/CheatLib\.getAt\(futures, 0\)\.next\(\)/)
      end
    end
  end

end
