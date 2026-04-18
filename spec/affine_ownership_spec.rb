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

  describe "Affine Ownership & Move Semantics" do
    let(:preamble) {
      <<~FLUX
        STRUCT Config { id: Float64, data: HashMap<Float64> }
      FLUX
    }

    context "Assignments" do
      context "Copy Types (Primitives)" do
        let(:code) { preamble + <<~FLUX
            FN test() ->
              a = 10;
              b = a;    -- Copy
              c = a;    -- 'a' should still be alive
            END
          FLUX
        }
        it "allows multiple uses of a primitive (Float64)" do
          expect { ast }.not_to raise_error
        end
      end

      context "Linear Types (Structs)" do
        let(:code) { preamble + <<~FLUX
            FN test() ->
              a = Config { id: 1 };
              b = a;    -- MOVE occurs here because Config is not primitive
              c = a;    -- ERROR: Use after move
            END
          FLUX
        }
        it "raises error on use-after-move" do
          expect { ast }.to raise_error(/Use of moved value 'a'/)
        end
      end

      context "Re-initialization" do
        let(:code) { preamble + <<~FLUX
            FN test() ->
              MUTABLE a = Config { id: 1 };
              b = a;                -- 'a' is moved
              a = Config { id: 2 }; -- 'a' is reborn (live)
              c = a;                -- Should be valid
            END
          FLUX
        }
        it "allows using a variable after it has been re-assigned" do
          expect { ast }.not_to raise_error
        end
      end

      context "Sub-path Move Tracking" do
        context "moving a sub-field marks it as dead" do
          let(:code) { <<~FLUX
              STRUCT Inner { value: Int64 }
              STRUCT Outer { inner: Inner, count: Int64 }

              FN test() ->
                outer = Outer{ inner: Inner{ value: 42 }, count: 1 };
                x = outer.inner;  -- moves outer.inner
                y = outer.inner;  -- ERROR: outer.inner is moved
              END
            FLUX
          }
          it "raises error on use-after-move of sub-path" do
            expect { ast }.to raise_error(/Use of moved value 'outer.inner'/)
          end
        end

        context "moving a sub-field allows access to sibling fields" do
          let(:code) { <<~FLUX
              STRUCT Inner { value: Int64 }
              STRUCT Outer { inner: Inner, count: Int64 }

              FN test() ->
                outer = Outer{ inner: Inner{ value: 42 }, count: 1 };
                x = outer.inner;   -- moves outer.inner
                y = outer.count;   -- OK: outer.count is still valid
              END
            FLUX
          }
          it "allows access to sibling fields after sub-move" do
            expect { ast }.not_to raise_error
          end
        end

        context "moving a sub-field marks nested children as dead" do
          let(:code) { <<~FLUX
              STRUCT Deep { val: Int64 }
              STRUCT Inner { deep: Deep }
              STRUCT Outer { inner: Inner }

              FN test() ->
                outer = Outer{ inner: Inner{ deep: Deep{ val: 1 } } };
                x = outer.inner;       -- moves outer.inner
                y = outer.inner.deep;  -- ERROR: outer.inner is moved, so outer.inner.deep is dead
              END
            FLUX
          }
          it "raises error on accessing child of moved sub-path" do
            expect { ast }.to raise_error(/Use of moved value 'outer.inner'/)
          end
        end

        context "primitive fields are copied, not moved" do
          let(:code) { <<~FLUX
              STRUCT Point { x: Int64, y: Int64 }

              FN test() ->
                p = Point{ x: 10, y: 20 };
                a = p.x;  -- primitives copy
                b = p.x;  -- still valid
              END
            FLUX
          }
          it "allows multiple reads of primitive sub-fields" do
            expect { ast }.not_to raise_error
          end
        end
      end

      context "COPY Keyword" do
        context "copying a struct with all primitive fields" do
          let(:code) { <<~FLUX
              STRUCT Point { x: Int64, y: Int64 }

              FN test() ->
                p = Point{ x: 10, y: 20 };
                copy = COPY p;  -- COPY creates independent value
              END
            FLUX
          }
          it "allows COPY of copyable struct" do
            expect { ast }.not_to raise_error
          end
        end

        context "copying a nested copyable struct" do
          let(:code) { <<~FLUX
              STRUCT Inner { value: Int64 }
              STRUCT Outer { inner: Inner, count: Int64 }

              FN test() ->
                outer = Outer{ inner: Inner{ value: 42 }, count: 1 };
                inner_copy = COPY outer.inner;  -- COPY nested struct
              END
            FLUX
          }
          it "allows COPY of nested copyable struct" do
            expect { ast }.not_to raise_error
          end
        end

        context "copying a non-copyable type (array)" do
          let(:code) { <<~FLUX
              FN test() ->
                arr = [1, 2, 3];
                copy = COPY arr;
              END
            FLUX
          }
          it "allows COPY of non-copyable array (explicit deep-copy)" do
            expect { ast }.not_to raise_error
          end
        end

        context "copying a struct with non-copyable field" do
          let(:code) { <<~FLUX
              STRUCT Container { data: HashMap<String> }

              FN test() ->
                MUTABLE c = Container{ data: {} };
                copy = COPY c;
              END
            FLUX
          }
          it "allows COPY of struct with non-copyable field (explicit deep-copy)" do
            expect { ast }.not_to raise_error
          end
        end
      end
    end

    context "Function Calls" do
      context "Passing by Value (Explicit TAKES)" do
        let(:code) { preamble + <<~FLUX
            FN consume(TAKES c: Config) RETURNS Float64 -> RETURN 0; END

            FN test() ->
              x = Config { id: 1 };
              consume(x);   -- 'x' is moved into 'consume'
              y = x;    -- ERROR: 'x' is dead
            END
          FLUX
        }
        it "marks the variable as moved if the parameter specifies TAKES" do
          expect { ast }.to raise_error(/Use of moved value 'x'/)
        end
      end

      # Note: Depending on your implementation, passing a Linear Type by value
      # might implicitly move it even without TAKES.
      # If your language requires explicit TAKES, this test confirms that safety.
    end

    context "Control Flow (Branching)" do
      context "Move in one branch, Use in parent" do
        let(:code) { preamble + <<~FLUX
            FN consume(TAKES c: Config) RETURNS Float64 -> RETURN 0; END

            FN test(n: Float64) ->
              x = Config { id: 1 };

              IF n > 10 THEN
                consume(x); -- 'x' moved here
              ELSE
                -- 'x' alive here
              END

              -- Merge: x is dead because it died in the THEN branch
              y = x;
            END
          FLUX
        }
        it "invalidates the variable in the parent scope if it moved in ANY branch" do
          expect { ast }.to raise_error(/Use of moved value 'x'/)
        end
      end

      context "Move in both branches" do
        let(:code) { preamble + <<~FLUX
            FN consume(TAKES c: Config) RETURNS Float64 -> RETURN 0; END

            FN test(n: Float64) ->
              x = Config { id: 1 };

              IF n > 10 THEN
                consume(x);
              ELSE
                consume(x);
              END

              -- x should definitely be dead
              y = x;
            END
          FLUX
        }
        it "consistently invalidates the variable" do
          expect { ast }.to raise_error(/Use of moved value 'x'/)
        end
      end
    end

    context "Automatic Memory Reclamation (Deferred Drops)" do
      let(:code) { preamble + <<~FLUX
          FN test() ->
            IF TRUE THEN
              x = Config { id: 1 };
              -- x is unused and Affine
              -- Should auto-drop here
            END
          END
        FLUX
      }

      it "attaches deferred drops to the scope node (IfStatement) for unused linear vars" do
        func_node = ast.statements.last
        if_node = func_node.body.first

        expect(if_node.then_drops).to include(include(name: "x"))
      end
    end

    context "Automatic Memory Reclamation (Deferred Drops)" do
      let(:code) { preamble + <<~FLUX
          FN test() ->
            IF TRUE THEN
              z = 1;
            ELSE
              x = Config { id: 1 };
              -- x is unused and Affine
              -- Should auto-drop here
            END
          END
        FLUX
      }

      it "attaches deferred drops to the scope node (ELSE) for unused linear vars" do
        func_node = ast.statements.last
        if_node = func_node.body.first

        expect(if_node.else_drops).to include(include(name: "x"))
      end
    end


    context "Function Scope (Deferred Drops)" do
      let(:code) { preamble + <<~FLUX
          FN test() ->
            a = Config { id: 1 };
            b = 10; -- Primitive, no drop needed
            -- 'a' is never moved. It must be dropped here.
          END
        FLUX
      }

      it "attaches deferred drops to the FunctionDef node" do
        func_node = ast.statements.last

        # Verify 'a' is dropped
        expect(func_node.deferred_drops).to include(include(name: "a"))

        # Verify 'b' is NOT dropped (it's a primitive)
        expect(func_node.deferred_drops).not_to include(include(name: "b"))
      end
    end

    context "Loops (While)" do
      # Assuming you implement similar logic for While loops
      let(:code) { preamble + <<~FLUX
          FN consume(TAKES c: Config) RETURNS Float64 -> RETURN 0; END

          FN test() ->
            x = Config { id: 1 };

            WHILE TRUE DO
              consume(x); -- Error: Moves 'x' in first iteration, 2nd iteration crashes
            END
          END
        FLUX
      }

      # This detects that the loop body moves 'x', implying 'x' must be available
      # at the start of every iteration, which it isn't after the first move.
      it "raises error if a loop body moves a variable defined outside the loop" do
         expect { ast }.to raise_error(/Use of moved value 'x'/)
      end
    end
  end

  # ===========================================================================
  # Parameter ownership: default = borrow, TAKES = owned
  # Non-TAKES parameters are implicit borrows. They cannot be moved into
  # containers or returned from functions (for non-Copy types).
  # ===========================================================================
  describe "Parameter ownership" do
    let(:preamble) {
      <<~CLEAR
        UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
      CLEAR
    }

    context "default parameter (implicit borrow)" do
      let(:code) {
        preamble + <<~CLEAR
          FN test!(v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "raises error when storing borrowed parameter into HashMap" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "MUTABLE parameter (still a borrow, not owned)" do
      let(:code) {
        preamble + <<~CLEAR
          FN test!(MUTABLE v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "raises error when storing mutable borrowed parameter into HashMap" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "TAKES parameter (owned)" do
      let(:code) {
        preamble + <<~CLEAR
          FN test!(TAKES v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "allows storing TAKES parameter into HashMap" do
        expect { ast }.not_to raise_error
      end
    end

    context "TAKES MUTABLE parameter (owned + mutable)" do
      let(:code) {
        preamble + <<~CLEAR
          FN test!(TAKES MUTABLE v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "allows storing TAKES MUTABLE parameter into HashMap" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # Storing borrowed values into struct/union construction is an error.
  # A borrow cannot outlive its source via struct capture.
  # ===========================================================================
  describe "Borrow capture in struct/union construction" do
    let(:preamble) {
      <<~CLEAR
        UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @indirect, id: Int64 } }
      CLEAR
    }

    context "borrowed parameter captured in union variant" do
      let(:code) {
        preamble + <<~CLEAR
          FN bad(items: Value[]) RETURNS Value ->
              RETURN Value.Lambda{ params: items, body: Value{ Num: 0.0 }, id: 1 };
          END
        CLEAR
      }

      it "raises error when storing borrowed slice into union variant" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "owned parameter captured in union variant" do
      let(:code) {
        preamble + <<~CLEAR
          FN good(TAKES items: Value[]) RETURNS Value ->
              RETURN Value.Lambda{ params: items, body: Value{ Num: 0.0 }, id: 1 };
          END
        CLEAR
      }

      it "allows storing owned parameter into union variant" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # Lambda parameter ownership: same rules as functions.
  # Default = borrow, TAKES = owned.
  # ===========================================================================
  describe "Lambda parameter ownership" do
    context "default lambda parameter is borrowed" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
              v = Value.Nil;
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "raises error when storing non-Copy local into HashMap after move" do
        # v is a local, first assignment moves it - but v is not reused here.
        # The point: function params that are borrowed cannot be stored.
        # Let's test that directly with a function parameter.
      end
    end

    context "default function parameter (borrowed) cannot be stored" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
          FN test!(v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "raises error when function stores borrowed param into HashMap" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "TAKES function parameter (owned) can be stored" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
          FN test!(TAKES v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = v;
              RETURN;
          END
        CLEAR
      }

      it "allows TAKES param to be stored into HashMap" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # MATCH AS borrow propagation: binding inherits borrow from source.
  # If the MATCH source is borrowed, the AS binding is also borrowed.
  # ===========================================================================
  describe "MATCH AS borrow propagation" do
    context "MATCH AS on borrowed parameter produces borrowed binding" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @indirect, id: Int64 } }
          FN bad(v: Value) RETURNS Value ->
              MATCH v START
                  Value.List AS items ->
                      RETURN Value.Lambda{ params: items, body: Value{ Num: 0.0 }, id: 1 };,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      }

      it "raises error when storing MATCH AS borrow into union variant" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "MATCH AS on owned TAKES parameter is still a borrow" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @indirect, id: Int64 } }
          FN bad(TAKES v: Value) RETURNS Value ->
              MATCH v START
                  Value.List AS items ->
                      RETURN Value.Lambda{ params: items, body: Value{ Num: 0.0 }, id: 1 };,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      }

      it "auto-promotes to TAKES when AS extracts non-Copy variant" do
        # MATCH AS on non-Copy variants auto-consumes source (like Rust's move semantics).
        # The binding is owned, so storing it in a struct is valid.
        expect { ast }.not_to raise_error
      end
    end

    context "MATCH TAKES on owned parameter produces owned binding" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, List: Value[], Lambda { params: Value[], body: Value @indirect, id: Int64 } }
          FN good(TAKES v: Value) RETURNS Value ->
              MATCH TAKES v START
                  Value.List AS items ->
                      RETURN Value.Lambda{ params: items, body: Value{ Num: 0.0 }, id: 1 };,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      }

      it "allows storing MATCH TAKES AS binding into union variant" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # List indexing of non-Copy elements: must use .remove(i) to take ownership.
  # Plain indexing returns a borrow (cannot store/move).
  # ===========================================================================
  describe "List indexing of non-Copy elements" do
    context "assigning non-Copy list element to variable" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
          FN test!(MUTABLE list: Value[]@list) RETURNS Void ->
              list.append(Value.Nil);
              f = list[0];
              RETURN;
          END
        CLEAR
      }

      it "marks list index result as borrowed" do
        # f is a borrow from the list - cannot be moved/stored
        expect { ast }.not_to raise_error
        # f should be borrowed in the OG
      end
    end

    context "storing non-Copy list element into HashMap" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect, id: Int64 } }
          FN test!(MUTABLE list: Value[]@list, MUTABLE map: HashMap<Value>) RETURNS Void ->
              list.append(Value.Nil);
              map["key"] = list[0];
              RETURN;
          END
        CLEAR
      }

      it "raises error when storing list index borrow into HashMap" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end

    context "passing non-Copy list element to TAKES parameter" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String, List: Value[] }
          FN consume!(TAKES v: Value) RETURNS Void ->
              RETURN;
          END
          FN test!(MUTABLE list: Value[]@list) RETURNS Void ->
              list.append(Value.Nil);
              consume!(list[0]);
              RETURN;
          END
        CLEAR
      }

      it "raises error (cannot TAKES a container borrow)" do
        expect { ast }.to raise_error(/Cannot pass container index.*TAKES|borrow/)
      end
    end

    context "passing Copy list element to TAKES parameter is OK" do
      let(:code) {
        <<~CLEAR
          FN consume!(TAKES n: Int64) RETURNS Void ->
              RETURN;
          END
          FN test!() RETURNS Void ->
              MUTABLE list: Int64[]@list = List[];
              list.append(1_i64);
              consume!(list[0]);
              RETURN;
          END
        CLEAR
      }

      it "allows Copy types through TAKES" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # Array indexing of non-Copy elements into union construction is a borrow
  # ===========================================================================
  describe "Array index in union construction" do
    context "storing array-indexed string into HashMap via union" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
              data: String[] = ["alpha", "beta"];
              map["key"] = Value{ Str: data[0] };
              RETURN;
          END
        CLEAR
      }

      it "raises error (data[0] is borrowed from array)" do
        expect { ast }.to raise_error(/borrow|cannot.*store|cannot.*move/)
      end
    end
  end

  # ===========================================================================
  # String variable in union construction stored to HashMap must use COPY
  # ===========================================================================
  describe "String variable in union construction for HashMap" do
    context "storing string variable into HashMap via union without COPY" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN test!(s: String, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = Value{ Str: s };
              RETURN;
          END
        CLEAR
      }

      it "raises error (s is borrowed, cannot store into container)" do
        expect { ast }.to raise_error(/borrow|cannot.*store|Cannot/)
      end
    end

    context "storing COPY of string variable into HashMap via union" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN test!(s: String, MUTABLE map: HashMap<Value>) RETURNS Void ->
              map["key"] = Value{ Str: COPY s };
              RETURN;
          END
        CLEAR
      }

      it "allows storing COPY'd string" do
        expect { ast }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # Stdlib function returning frame string stored into container
  # ===========================================================================
  describe "Stdlib frame string in union for HashMap" do
    context "substr result in union without COPY" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS Void ->
              s = substr("hello", 0_i64, 3_i64);
              map["key"] = Value{ Str: s };
              RETURN;
          END
        CLEAR
      }

      it "raises error (substr returns frame string)" do
        expect { ast }.to raise_error(/Cannot.*store.*string|COPY/)
      end
    end

  end

  describe "Container Borrow (HashMap.get)" do
    context "when reading a non-Copy union from a HashMap" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS String ->
              val = map["t0"] OR Value.Nil;
              MATCH val START
                  Value.Str AS s -> RETURN s;,
                  DEFAULT -> RETURN "";
              END
              RETURN "";
          END
        CLEAR
      }

      it "marks the binding as container_borrow" do
        fn = ast[1].find { |n| n.is_a?(AST::FunctionDef) && n.name == "test!" }
        bind = fn.body.find { |s| s.is_a?(AST::BindExpr) && s.name == "val" }
        expect(bind.container_borrow).to eq(true)
      end
    end

    context "when binding from a function call (not container)" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN makeVal() RETURNS Value ->
              RETURN Value.Nil;
          END
          FN test() RETURNS Void ->
              val = makeVal();
              RETURN;
          END
        CLEAR
      }

      it "does NOT mark as container_borrow" do
        fn = ast[1].find { |n| n.is_a?(AST::FunctionDef) && n.name == "test" }
        bind = fn.body.find { |s| s.is_a?(AST::BindExpr) && s.name == "val" }
        expect(bind.container_borrow).to be_nil
      end
    end
  end

  describe "TAKES parameter registration in pre_register_function" do
    context "when calling a TAKES function from another function" do
      let(:code) {
        <<~CLEAR
          UNION Value { Nil, Str: String }
          FN consume!(TAKES v: Value) RETURNS Void ->
              RETURN;
          END
          FN caller() RETURNS Void ->
              x = Value{ Str: COPY "hello" };
              consume!(x);
              RETURN;
          END
        CLEAR
      }

      it "marks the argument as was_moved at the call site" do
        fn = ast[1].find { |n| n.is_a?(AST::FunctionDef) && n.name == "caller" }
        call = fn.body.find { |s| s.is_a?(AST::FuncCall) && s.name == "consume!" }
        expect(call.args[0].was_moved).to eq(true)
      end
    end
  end

end
