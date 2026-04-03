require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"
require_relative "../src/ast"

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
          it "raises error for non-copyable array" do
            expect { ast }.to raise_error(/Cannot COPY non-copyable type/)
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
          it "raises error for struct containing non-copyable field" do
            expect { ast }.to raise_error(/Cannot COPY non-copyable type/)
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

end
