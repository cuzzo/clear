require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"  # loads compiler, annotator, lexer, parser, ast
require_relative "../src/ast"

RSpec.describe SemanticAnnotator do
  # Helper to Lex -> Parse -> Annotate
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

  describe "Smooth Operator (s>)" do
    context "when piping to a Function Call: x s> f()" do
      let(:code) {
        <<~FLUX
          -- Define function that returns a Number
          FN identity(n: Number) RETURNS Number ->
            RETURN n;
          END

          -- Pipe 1 (Number) into identity()
          result = 1 s> identity();
        FLUX
      }

      it "resolves the return type correctly based on the function signature" do
        expect(result).to eq(:Number)
      end
   end

   context "when piping to a Function Call: x s> f()" do
     let(:code) {
        <<~FLUX
          FN add(a: Number, b: Number) RETURNS Number ->
            RETURN a + b;
          END

          -- 1 is 'a', 2 is 'b'
          result = 1 s> add(2);
        FLUX
     }

     it "validates arity correctly (1 implicit + 1 explicit)" do
       expect(result).to eq(:Number)
     end
   end

   context "when piping to a Function Call: x s> f()" do
     let(:code) {
        <<~FLUX
          FN require_string(s: String) RETURNS Bool ->
            RETURN TRUE;
          END

          -- Passing Number (1) into String expectation
          result = 1 s> require_string();
        FLUX
      }

      it "raises error if types do not match" do
        expect { ast }.to raise_error(/Type Error/i)
      end
    end

    context "when piping to an Identifier: x s> f" do
      let(:code) {
        <<~FLUX
          FN identity(n: Number) RETURNS Number ->
            RETURN n;
          END

          -- Pipe to identifier 'identity' without parens
          result = 1 s> identity;
        FLUX
      }

      it "resolves the return type correctly" do
        expect(result).to eq(:Number)
      end
    end


    context "when piping to an Identifier: x s> f" do
      let(:code) {
        <<~FLUX
          FN add(a: Number, b: Number) RETURNS Number ->
            RETURN a + b;
          END

          -- Pipe 1 to add. 'add' needs 2 args. We only provided 1 (via pipe).
          result = 1 s> add;
        FLUX
      }

      it "raises error on arity mismatch (missing required args)" do
        expect { ast }.to raise_error(/expects \d+ arguments/i)
      end
    end

    context "when piping to Native/Intrinsics" do
      let(:code) {
        <<~FLUX
          x = 10 s> print();
        FLUX
      }

      it "correctly handles print (returns Nil/Void)" do
        # Assuming print is defined as returning :Nil or :Void in builtins
        expect(result).to eq(:Void)
      end
    end

    context "Chained Pipelines" do
      let(:code) {
        <<~FLUX
          FN double(n: Number) RETURNS Number -> RETURN n * 2; END
          FN to_bool(n: Number) RETURNS Bool -> RETURN n > 10; END

          -- Number -> Number -> Bool
          result = 5
            s> double()
            s> to_bool();
        FLUX
      }

      it "propagates types through multiple steps" do
        expect(result).to eq(:Bool)
      end
    end

    context "Chained Pipelines with Identifiers" do
      let(:code) {
        <<~FLUX
          FN s1() -> RETURN 10; END
          FN s2(n: Number) -> RETURN n * 2; END
          FN s3(n: Number) -> RETURN n + 5; END

          result = s1() s> s2 s> s3;
        FLUX
      }

      it "resolves the entire chain correctly" do
        # This will fail if the middle step doesn't resolve/propagate its type
        expect(result).to eq(:Number)
      end
    end
  end

  describe "Function Return Types" do
    context "Exact Matches" do
      let(:code) {
        <<~FLUX
          FN get_num() RETURNS Number ->
            RETURN 10;
          END
          x = get_num();
        FLUX
      }
      it "passes when types match exactly" do
        expect { ast }.not_to raise_error
      end
    end

    context "Type Mismatches" do
      let(:code) {
        <<~FLUX
          FN get_string() RETURNS String ->
            RETURN 10;
          END
        FLUX
      }
      it "raises error when returning Number instead of String" do
        expect { ast }.to raise_error(/Function expected/i)
      end
    end

    context "Safe Autocasting" do
      context "Int64 to Number" do
        let(:code) {
          <<~FLUX
            FN get_number() RETURNS Number ->
              i : Int64 = 10;
              RETURN i;
            END
          FLUX
        }
        it "allows returning Int64 where Number is expected" do
          func_def = ast.statements.first
          return_node = func_def.body.last

          expect(return_node).to be_a(AST::ReturnNode) # Sanity check
          expect(return_node.value.coerced_type).to eq(:Number)
        end
      end

      context "Byte to Number" do
        let(:code) {
          <<~FLUX
            FN get_number() RETURNS Number ->
              b : Byte = 255;
              RETURN b;
            END
          FLUX
        }
        it "allows returning Byte where Number is expected" do
          expect { ast }.not_to raise_error
        end
      end

      context "Fixed Array to Dynamic Array (Slice/View)" do
        let(:code) {
          <<~FLUX
            FN get_list() RETURNS Number[] ->
              -- [1, 2, 3] is Number[3] (Fixed)
              RETURN [1, 2, 3];
            END
          FLUX
        }
        it "allows returning Fixed Array where Dynamic Array is expected" do
          func_def = ast.statements.first
          return_node = func_def.body.last

          expect(return_node.value.coerced_type).to eq(:"Number[]")
        end
      end
    end

    context "Implicit / Any Return" do
      let(:code) {
        <<~FLUX
          -- No return type specified -> :Any
          FN get_anything() ->
            RETURN "hello";
          END
          x = get_anything();
        FLUX
      }
      it "defaults to Any and allows returning anything" do
        expect { ast }.not_to raise_error
      end
    end

    # TODO: Allow this in the parser
    #context "Void / Empty Return" do
    #  # Depending on your parser, RETURN with no value might be nil or AST::Literal(:NIL)
    #  # This test assumes you handle 'RETURN' without value
    #  let(:code) {
    #    <<~FLUX
    #      FN do_nothing() RETURNS Void ->
    #         x = 1;
    #         RETURN;
    #      END
    #    FLUX
    #  }

    #  # NOTE: If your parser doesn't support empty RETURN, you can skip this.
    #  # But if it does, `visit_ReturnNode` needs to handle node.value being nil.
    #  it "handles empty returns for Void functions" do
    #     # Expectation depends on implementation details of empty return
    #     # If unhandled, this might raise NoMethodError on nil
    #     expect { run(code) }.not_to raise_error
    #  end
    #end

    context "Default Arguments" do
      context "Matching Types" do
        let(:code) {
          <<~FLUX
            FN increment(n: Number = 1) -> RETURN n + 1; END
          FLUX
        }
        it "allows correct default values" do
          expect { ast }.not_to raise_error
        end
      end

      context "Mismatching Types" do
        let(:code) {
          <<~FLUX
            -- n expects Number, default is String
            FN increment(n: Number = "1") -> RETURN n; END
          FLUX
        }
        it "raises error when default value type mismatch" do
          expect { ast }.to raise_error(/Type Error/i)
        end
      end
    end

    context "Return Type Consistency" do
      context "implicit Return" do
        let(:code) {
          <<~FLUX
            FN ambig(n: Number) ->
              IF n > 10 THEN
                RETURN 1;      -- Number
              ELSE
                RETURN "Low";  -- String
              END
            END
          FLUX
        }
        it "raises error when inferred returns are inconsistent" do
          expect { ast }.to raise_error(/Ambiguous Return/i)
        end
      end

      # TODO: Probably want to ban this...
      context "explicit Any Return" do
        let(:code) {
          <<~FLUX
            FN generic(n: Number) RETURNS Any ->
              IF n > 10 THEN RETURN 1; ELSE RETURN "Low"; END
            END
          FLUX
        }
        it "allows inconsistent returns if explicit return type is Any" do
          expect { ast }.not_to raise_error
        end
      end
    end

    context "Mutable Parameter Naming" do
      context "missing suffix" do
        let(:code) {
          <<~FLUX
            FN update(MUTABLE x: Number) ->
              x = x + 1;
              RETURN x;
            END
          FLUX
        }
        it "raises error if function takes MUTABLE param but name doesn't end in !" do
          expect { ast }.to raise_error(/Style Error/i)
        end
      end

      context "matching suffix" do
        let(:code) {
          <<~FLUX
            FN update!(MUTABLE x: Number) ->
              x = x + 1;
              RETURN x;
            END
          FLUX
        }
        it "allows MUTABLE param if name ends in !" do
          expect { ast }.not_to raise_error
        end
      end
    end
  end

  describe "Function Calls (FuncCall)" do
    context "Method Missing" do
       let(:code) {
        <<~FLUX
          add(1, 2);
        FLUX
      }
      it "errors when calling undefined function" do
        expect { ast }.to raise_error(/Undefined function/i)
      end
    end

    context "Missing Local Argument" do
       let(:code) {
        <<~FLUX
          FN add(a, b) -> RETURN a * b; END
          add(x, 2);
        FLUX
      }
      it "errors when calling defined function with undefined variable" do
        expect { ast }.to raise_error(/Undefined variable/i)
      end
    end

    context "Arity Checks" do
      let(:base_code) {
        <<~FLUX
          FN add(a: Number, b: Number) RETURNS Number ->
            RETURN a + b;
          END
        FLUX
      }

      it "errors when given not enough arguments" do
        code = base_code + "add(1);"
        expect { run(code) }.to raise_error(/expects \d+ arguments/i)
      end

      it "errors when given too many arguments" do
        code = base_code + "add(1, 2, 3);"
        expect { run(code) }.to raise_error(/expects \d+ arguments/i)
      end

      it "succeeds with the exact number of arguments" do
        code = base_code + "add(1, 2);"
        expect(get_last_type(code)).to eq(:Number)
      end
    end

    context "Default Arguments" do
      let(:base_code) {
        <<~FLUX
          FN increment(n: Number, by: Number = 1) RETURNS Number ->
            RETURN n + by;
          END
        FLUX
      }

      it "accepts call using the default value (arity lower bound)" do
        code = base_code + "increment(10);"
        expect { run(code) }.not_to raise_error
        expect(get_last_type(code)).to eq(:Number)
      end

      it "accepts call overriding the default value (arity upper bound)" do
        code = base_code + "increment(10, 5);"
        expect { run(code) }.not_to raise_error
        expect(get_last_type(code)).to eq(:Number)
      end
    end

    context "Auto-casting Arguments" do
      context "Number -> Int64" do
        let(:code) {
          <<~FLUX
            FN process_int(i: Int64) RETURNS Int64 -> RETURN i; END
            n : Number = 100;
            process_int(n);
          FLUX
        }

        it "accepts a Number passed into an Int64 parameter" do
          expect(result).to eq(:Int64)

          # TODO: Not yet supported
          #func_call = ast.statements.last
          #arg_expr = func_call.args.first

          #expect(arg_expr.coerced_type).to eq(:Int64)
        end
      end

      context "Byte -> Number" do
        let(:code) {
          <<~FLUX
            FN process_num(n: Number) RETURNS Number -> RETURN n; END
            b : Byte = 255;
            process_num(b);
          FLUX
        }

        it "accepts a Byte passed into a Number parameter" do
          expect { ast }.not_to raise_error
        end
      end

      context "Fixed Array -> Dynamic Array" do
        let(:code) {
          <<~FLUX
            FN sum_list(list: Number[]) RETURNS Number -> RETURN 0; END
            fixed : Number[3] = [1, 2, 3];
            sum_list(fixed);
          FLUX
        }
        it "accepts a Fixed Array passed into a Dynamic Array parameter (Slice Coercion)" do
          expect { ast }.not_to raise_error
        end
      end

      context "Incompat types: String -> Number" do
        let(:code) {
          <<~FLUX
            FN calc(n: Number) -> RETURN n; END
            calc("hello");
          FLUX
        }
        it "errors when types are incompatible (e.g. String -> Number)" do
          expect { ast }.to raise_error(/argument \d+ expects/)
        end
      end
    end

    context "String Handling (Heap vs Stack)" do
      let(:base_code) {
        <<~FLUX
          -- expects Number[]
          FN print_args(args: Number[]) RETURNS Number ->
             RETURN 1;
          END
        FLUX
      }

      it "accepts a HEAP string" do
        code = base_code + <<~FLUX
          local_args = %[1, 2, 3];
          print_args(local_args);
        FLUX
        expect { run(code) }.not_to raise_error
      end

      it "accepts a STACK string" do
        # This creates a String[2] on the stack
        code = base_code + <<~FLUX
          local_args = [1, 2, 3];
          print_args(local_args);
        FLUX
        expect { run(code) }.not_to raise_error
      end
    end

    context "Mutability Safety" do
      let(:mutable_func) {
        <<~FLUX
          FN modify!(MUTABLE x: Number) ->
            x = x + 1;
          END
        FLUX
      }

      it "errors when passing an immutable variable to a MUTABLE parameter" do
        code = mutable_func + <<~FLUX
          im = 10; -- Implicitly immutable
          modify!(im);
        FLUX
        expect { run(code) }.to raise_error(/but you passed immutable variable/i)
      end

      # TODO: Probably not a good idea.
      it "errors when passing a literal/expression to a MUTABLE parameter" do
        code = mutable_func + "modify!(10);"
        expect { run(code) }.to raise_error(/You cannot pass a value\/expression/i)
      end

      it "accepts a mutable variable passed to a MUTABLE parameter" do
        code = mutable_func + <<~FLUX
          MUTABLE m = 10;
          modify!(m);
        FLUX
        expect { run(code) }.not_to raise_error
      end
    end

    context "Alias Overlap" do
      let(:mutable_func) {
        <<~FLUX
          STRUCT User { id: Number }

          -- This doesn't actually work, but it's just for testing aliasing...
          FN swap!(MUTABLE u1: User, MUTABLE u2: User) ->
            u1 = u2;
            u2 = User{ id: 20 };
          END
        FLUX
      }

      it "errors" do
        code = mutable_func + <<~FLUX
          MUTABLE u = User{ id: 1 };
          swap!(u, u);
        FLUX
        expect { run(code) }.to raise_error(/Aliasing Error/i)
      end

      it "does not error" do
        code = mutable_func + <<~FLUX
          MUTABLE u1 = User{id: 1};
          MUTABLE u2 = User{id: 2};
          swap!(u1, u2);
        FLUX
        expect { run(code) }.not_to raise_error
      end
    end

    context "Resolved Type Correctness" do
      it "resolves to the explicit return type" do
        code = <<~FLUX
          FN get_str() RETURNS String -> RETURN %"hi"; END
          get_str();
        FLUX
        expect(get_last_type(code)).to eq(:"String")
      end

      it "resolves to the inferred return type" do
        code = <<~FLUX
          FN get_inferred() -> RETURN 10; END -- Infers Number
          get_inferred();
        FLUX
        expect(get_last_type(code)).to eq(:Int64)
      end

      it "resolves to Void for functions with no return" do
        code = <<~FLUX
          FN do_work() RETURNS Void -> x = 1; END
          do_work();
        FLUX
        expect(get_last_type(code)).to eq(:Void)
      end
    end
  end

  describe "Assignments (x = ...)" do
    # Common Struct Definition for field tests
    let(:struct_def) {
      <<~FLUX
        STRUCT Point {
          x: Number,
          y: Number
        }
      FLUX
    }

    context "Variable Assignment" do
      context "when assigning to a MUTABLE variable" do
        let(:code) {
          <<~FLUX
            MUTABLE x = 10;
            x = 20;
          FLUX
        }

        it "succeeds and resolves to the variable's type" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Int64)
        end
      end

      context "when assigning to an immutable variable" do
        let(:code) {
          <<~FLUX
            x = 10;
            x = 20;
          FLUX
        }

        it "raises an immutability error" do
          expect { ast }.to raise_error(/Variable 'x' is immutable/)
        end
      end

      context "when reassigning to an immutable variable" do
        let(:code) {
          <<~FLUX
            y = 20;
            y = 30;
          FLUX
        }

        it "raises an immutable variable error" do
          expect { ast }.to raise_error(/Variable 'y' is immutable/)
        end
      end

      context "when types mismatch (Number = String)" do
        let(:code) {
          <<~FLUX
            MUTABLE x = 10;
            x = "hello";
          FLUX
        }

        it "raises a type mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch/)
        end
      end

      context "when autocasting is safe (Number = Byte)" do
        let(:code) {
          <<~FLUX
            MUTABLE x : Number = 10;
            b : Byte = 255;
            x = b;
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Number)
        end
      end
    end

    context "Array Index Assignment" do
      context "when modifying a MUTABLE list index" do
        let(:code) {
          <<~FLUX
            MUTABLE list = [1, 2, 3];
            list[0] = 99;
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Int64)
        end
      end

      context "when modifying an immutable list index" do
        let(:code) {
          <<~FLUX
            list = [1, 2, 3];
            list[0] = 99;
          FLUX
        }

        it "raises an immutability error" do
          expect { ast }.to raise_error(/Cannot modify index of immutable list 'list'/)
        end
      end

      context "when assigning an incompatible type to an index" do
        let(:code) {
          <<~FLUX
            MUTABLE list = [1, 2, 3];
            list[0] = "string";
          FLUX
        }

        it "raises a type mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch/)
        end
      end
    end

    context "Struct Field Assignment" do
      context "when modifying a field of a MUTABLE struct" do
        let(:code) {
          struct_def + <<~FLUX
            MUTABLE p = Point{ x: 1, y: 2 };
            p.x = 100;
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Void) # Assignments are statements (void)
        end
      end

      context "when modifying a field of an immutable struct" do
        let(:code) {
          struct_def + <<~FLUX
            p = Point{ x: 1, y: 2 };
            p.x = 100;
          FLUX
        }

        it "raises an immutability error" do
          expect { ast }.to raise_error(/Cannot modify field of immutable struct 'p'/)
        end
      end

      context "when assigning an incompatible type to a field" do
        let(:code) {
          struct_def + <<~FLUX
            MUTABLE p = Point{ x: 1, y: 2 };
            p.x = "wrong";
          FLUX
        }

        it "raises a type mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch/)
        end
      end

      context "when assigning to a non-existent field" do
        let(:code) {
          struct_def + <<~FLUX
            MUTABLE p = Point{ x: 1, y: 2 };
            p.z = 100;
          FLUX
        }

        it "raises a missing field error (from GetField visitor)" do
          expect { ast }.to raise_error(/Cannot determine struct type/i)
        end
      end
    end

    context "Reference / Borrow Interactions" do
      context "when attempting to assign through an immutable slice" do
        let(:code) {
          <<~FLUX
            MUTABLE data = [1, 2, 3];
            slice = data[0..1];        -- Immutable borrow because VAR
            slice[0] = 99;
          FLUX
        }

        it "raises an immutability error on the slice" do
          expect { ast }.to raise_error(/Cannot modify index of immutable list 'slice'/)
        end
      end
    end

    context "Autocasting Assignments" do
      context "when assigning Byte to Number variable" do
        let(:code) {
          <<~FLUX
            MUTABLE n : Number = 0;
            b : Byte = 255;
            n = b;
          FLUX
        }

        it "tags the assignment value with the coerced type" do
          # AST: [VarDecl, VarDecl, Assignment]
          assignment = ast.statements.last

          # Assuming AssignmentNode has a .value accessor for the RHS
          expect(assignment.value.coerced_type).to eq(:Number)
        end
      end

      context "when assigning Fixed Array to Dynamic Array variable" do
         let(:code) {
           <<~FLUX
             MUTABLE list : Number[] = [];
             list = [1, 2, 3]; -- Literal is Number[3]
           FLUX
         }

         it "tags the array literal with the coerced slice type" do
           assignment = ast.statements.last
           expect(assignment.value.coerced_type).to eq(:"Number[]")
         end
      end
    end
  end

  describe "Variable Declarations (visit_VarDecl)" do
    context "Implicit Autocasting (Primitives)" do
      context "when assigning Int64 to Number" do
        let(:code) {
          <<~FLUX
            -- 100 is treated as Number or Int64 depending on context
            -- Here we test explicit Int64 literal if supported, or just flow
            x : Number = 100;
          FLUX
        }
        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Number)
        end
      end

      context "when assigning Byte to Number" do
        let(:code) {
          <<~FLUX
            b : Byte = 255;
            x : Number = b;
          FLUX
        }
        it "succeeds" do
          var_decl = ast.statements.last
          value_node = var_decl.value # This is the VarAccess('b')

          expect(value_node.coerced_type).to eq(:Number)
        end
      end

      context "when types are incompatible (String -> Number)" do
        let(:code) {
          <<~FLUX
            x : Number = "hello";
          FLUX
        }
        it "raises a Type Mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch: Cannot assign/)
        end
      end
    end

    context "Array Constraints & Autocasting" do
      context "Exact Size Match" do
        let(:code) {
          <<~FLUX
            -- [1, 2, 3] is inferred as Number[3]
            list : Number[3] = [1, 2, 3];
          FLUX
        }
        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:"Number[3]")
        end
      end

      context "Undersized Assignment (Capacity > Size)" do
        let(:code) {
          <<~FLUX
            -- Assigning size 2 to capacity 3
            list : Number[3] = [1, 2];
          FLUX
        }
        it "succeeds (fills remaining with default/garbage)" do
          expect { ast }.not_to raise_error
        end
      end

      context "Oversized Assignment (Size > Capacity)" do
        let(:code) {
          <<~FLUX
            list : Number[1] = [1.0, 2.0, 3.0];
          FLUX
        }
        it "raises a Fixed Array Size Mismatch error" do
          expect { ast }.to raise_error(/Cannot initialize array of size/i)
        end
      end

      context "Empty List to Fixed Array" do
        let(:code) {
          <<~FLUX
            -- Any[] -> Number[5]
            list : Number[5] = [];
          FLUX
        }
        it "succeeds (safe autocast from empty)" do
          expect { ast }.not_to raise_error
        end
      end

      context "Fixed Stack Array to Dynamic View (Slice)" do
        let(:code) {
          <<~FLUX
            -- Number[3] -> Number[]
            list : Number[] = [1, 2, 3];
          FLUX
        }
        it "succeeds (Slice Coercion)" do
          var_decl = ast.statements.last
          expect(var_decl.value.coerced_type).to eq(:"Number[]")
        end
      end

      context "Fixed Stack Array to Wildcard View" do
        let(:code) {
          <<~FLUX
            -- Number[3] -> Number[*]
            list : Number[*] = [1, 2, 3];
          FLUX
        }
        it "succeeds" do
          expect { ast }.not_to raise_error
        end
      end

      context "Heap Array to Dynamic View" do
        let(:code) {
          <<~FLUX
            -- %[...] creates Heap Array (Number[])
            list : Number[] = %[1, 2, 3];
          FLUX
        }
        it "succeeds" do
          expect { ast }.not_to raise_error
        end
      end

      context "Array Content Type Mismatch" do
        let(:code) {
          <<~FLUX
            -- String[3] -> Number[3]
            list : Number[3] = ["a", "b", "c"];
          FLUX
        }
        it "raises a Type Mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch/)
        end
      end

      context "Nested Array Mismatch" do
        let(:code) {
          <<~FLUX
            -- Trying to assign Number[][1] to Number[]
            list : Number[] = [[1]];
          FLUX
        }
        it "raises a Type Mismatch error" do
          expect { ast }.to raise_error(/Type Mismatch/)
        end
      end
    end
  end

  describe "Struct Initialization (visit_StructLit)" do
    let(:struct_def) {
      <<~FLUX
        STRUCT Point {
          x: Number,
          y: Number
        }

        STRUCT User {
          id: Int64,
          active: Bool
        }

        STRUCT Wrapper {
          inner: Point
        }
      FLUX
    }

    context "Valid Initialization" do
      context "Exact Type Match" do
        let(:code) {
          struct_def + <<~FLUX
            p = Point{ x: 1, y: 2 };
          FLUX
        }

        it "succeeds and resolves to the Struct type" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Point)
        end
      end

      context "Safe Autocasting" do
        context "Byte/Int64 -> Number Field" do
          let(:code) {
            struct_def + <<~FLUX
              b : Byte = 255;
              -- x takes literal Int64 (10), y takes Byte variable
              p = Point{ x: 10, y: b };
            FLUX
          }

          it "succeeds (implicitly casts fields)" do
            expect(result).to eq(:Point)
            var_decl = ast.statements.last
            struct_lit = var_decl.value    # Point{...}

            # TODO
            ## Fields order depends on parser, assuming x then y
            #x_field = struct_lit.fields["x"]
            #y_field = struct_lit.fields["y"]

            ## 10 (Int64) -> Number
            #expect(x_field.value.coerced_type).to eq(:Number)
            ## b (Byte) -> Number
            #expect(y_field.value.coerced_type).to eq(:Number)
          end
        end
      end

      context "Nested Structs" do
        let(:code) {
          struct_def + <<~FLUX
            w = Wrapper{
              inner: Point{ x: 10, y: 20 }
            };
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Wrapper)
        end
      end
    end

    context "Invalid Initialization" do
      # TODO: Implement REQUIRED fields.
      #context "Missing Required Field" do
      #  let(:code) {
      #    struct_def + <<~FLUX
      #      -- Missing 'y'
      #      p = Point{ x: 1 };
      #    FLUX
      #  }

      #  it "raises a Missing Field error" do
      #    expect { ast }.to raise_error(/Missing required field 'y'/)
      #  end
      #end

      context "Setting Unknown Field" do
        let(:code) {
          struct_def + <<~FLUX
            -- 'z' does not exist on Point
            p = Point{ x: 1, y: 2, z: 3 };
          FLUX
        }

        it "raises an Unknown Field error" do
          expect { ast }.to raise_error(/Struct 'Point' has no field 'z'/)
        end
      end

      context "Type Mismatch on Field" do
        let(:code) {
          struct_def + <<~FLUX
            -- 'x' expects Number, got String
            p = Point{ x: "bad", y: 2 };
          FLUX
        }

        it "raises a Type Mismatch error" do
          expect { ast }.to raise_error(/Field 'x' expected Number/i)
        end
      end

      context "Unknown Struct Name" do
        let(:code) {
          <<~FLUX
            g = Ghost{ boo: 1 };
          FLUX
        }

        it "raises an Unknown Struct error" do
          expect { ast }.to raise_error(/Unknown struct type: 'Ghost'/)
        end
      end
    end
  end

  describe "List Literals (visit_ListLit)" do
    context "Valid Homogeneous Lists" do
      context "Simple Primitive List" do
        let(:code) {
          <<~FLUX
            list = [1, 2, 3];
          FLUX
        }
        it "infers the type based on the first element (Number[3])" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:"Int64[3]")
        end
      end

      context "Nested Lists (Matrix)" do
        let(:code) {
          <<~FLUX
            -- [1, 2] is Number[2]
            -- So outer list is Number[2] of size 2 -> Number[2][2]
            matrix = [[1, 2], [3, 4]];
          FLUX
        }
        it "infers nested array types correctly" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:"Int64[2][2]")
        end
      end

      context "Empty List" do
        let(:code) {
          <<~FLUX
            list = [];
          FLUX
        }
        it "defaults to Any[]" do
          expect { ast }.not_to raise_error
          # Assuming logic maps [] to Any[]
          expect(result).to eq(:"Any[]")
        end
      end
    end

    context "Invalid Heterogeneous Lists" do
      context "Mixed Primitives" do
        let(:code) {
          <<~FLUX
            list = [1, "string"];
          FLUX
        }
        it "raises error when types differ" do
          expect { ast }.to raise_error(/List literal contains mixed types/)
        end
      end

      context "Mixed Nested Types" do
        let(:code) {
          <<~FLUX
            -- First item is Number[1], Second is String[1]
            list = [[1], ["A"]];
          FLUX
        }
        it "raises error when inner array types differ" do
          expect { ast }.to raise_error(/List literal contains mixed types/)
        end
      end

      context "Nested Array Size Mismatch (Ragged Arrays)" do
        let(:code) {
          <<~FLUX
            -- First item is Number[2], Second is Number[1]
            -- In CHEAT, arrays are rectangular. Types Number[2] and Number[1] are distinct.
            list = [[1, 2], [3]];
          FLUX
        }
        it "raises error because Number[2] != Number[1]" do
          expect { ast }.to raise_error(/List literal contains mixed types/)
        end
      end
    end
  end

  describe "Control Flow Validation" do
    context "While Loops (visit_WhileLoop)" do
      context "Valid Loops" do
        let(:code) {
          <<~FLUX
            MUTABLE i = 0;
            WHILE i < 10 DO
              i = i + 1;
            END
          FLUX
        }
        it "validates boolean conditions" do
          expect { ast }.not_to raise_error
        end
      end

      context "Invalid Condition Type" do
        let(:code) {
          <<~FLUX
            -- "string" is not a Bool
            WHILE "true" DO
              x = 1;
            END
          FLUX
        }
        it "raises error for non-boolean condition" do
          expect { ast }.to raise_error(/Condition must be a Boolean/)
        end
      end

      # TODO: Need to lift conditional variable
      #context "Scope Isolation" do
      #  let(:code) {
      #    <<~FLUX
      #      WHILE TRUE DO
      #        inner_var = 10;
      #      END
      #      -- Should fail: inner_var is out of scope
      #      y = inner_var;
      #    FLUX
      #  }
      #  it "prevents leaking variables from the loop scope" do
      #    expect { ast }.to raise_error(/Undefined variable 'inner_var'/)
      #  end
      #end
    end

    context "WhileLoop mark_per_iter" do
      it "marks loop as safe for per-iter frame marks when list is loop-local" do
        src = <<~CLEAR
          FN foo() RETURNS Void ->
            MUTABLE i = 0_i64;
            WHILE i < 10 DO
              MUTABLE vals: Number[]@list = [];
              append(vals, 1.0);
              i = i + 1_i64;
            END
            RETURN;
          END
        CLEAR
        annotated = run(src)
        fn = annotated.statements.first
        loop_node = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
        expect(loop_node.mark_per_iter).to be true
      end

      it "does NOT mark loop as safe when outer-scope list is appended" do
        src = <<~CLEAR
          FN foo() RETURNS Void ->
            MUTABLE all: Number[]@list = [];
            MUTABLE i = 0_i64;
            WHILE i < 10 DO
              append(all, 1.0);
              i = i + 1_i64;
            END
            RETURN;
          END
        CLEAR
        annotated = run(src)
        fn = annotated.statements.first
        loop_node = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
        expect(loop_node.mark_per_iter).to be false
      end

      it "does NOT mark loop as safe when outer var is assigned a frame-allocating call" do
        # BigS has 130 fields (>128 threshold) → frame allocation.
        # Assigning frame-allocated return value to an outer var escapes the iteration.
        fields = (1..130).map { |i| "f#{i}: Float64" }.join(", ")
        src = <<~CLEAR
          STRUCT BigS { #{fields} }
          FN makeBig() RETURNS BigS -> RETURN BigS{ #{(1..130).map { |i| "f#{i}: 0.0" }.join(", ")} }; END
          FN foo() RETURNS Void ->
            MUTABLE result = makeBig();
            MUTABLE i = 0_i64;
            WHILE i < 10 DO
              result = makeBig();
              i += 1_i64;
            END
            RETURN;
          END
        CLEAR
        annotated = run(src)
        fn = annotated.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "foo" }
        loop_node = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
        expect(loop_node.mark_per_iter).to be false
      end
    end

    context "ReturnNode collection_return flag" do
      it "sets collection_return=true when returning a @list from a frame-using function" do
        # BigS is 130 slots (>128 threshold) → local declaration → uses_frame = true.
        # Returning a @list from that function is dangerous: the frame mark rewinds on
        # exit, invalidating the arena buffer.
        src = <<~CLEAR
          STRUCT Chunk5 { a: Number, b: Number, c: Number, d: Number, e: Number }
          STRUCT BigS {
            c1: Chunk5, c2: Chunk5, c3: Chunk5, c4: Chunk5, c5: Chunk5,
            c6: Chunk5, c7: Chunk5, c8: Chunk5, c9: Chunk5, c10: Chunk5,
            c11: Chunk5, c12: Chunk5, c13: Chunk5, c14: Chunk5, c15: Chunk5,
            c16: Chunk5, c17: Chunk5, c18: Chunk5, c19: Chunk5, c20: Chunk5,
            c21: Chunk5, c22: Chunk5, c23: Chunk5, c24: Chunk5, c25: Chunk5,
            c26: Chunk5
          }
          FN buildList() RETURNS Number[]@list ->
            zero: Chunk5 = Chunk5{ a: 0.0, b: 0.0, c: 0.0, d: 0.0, e: 0.0 };
            big: BigS = BigS{
              c1: zero, c2: zero, c3: zero, c4: zero, c5: zero,
              c6: zero, c7: zero, c8: zero, c9: zero, c10: zero,
              c11: zero, c12: zero, c13: zero, c14: zero, c15: zero,
              c16: zero, c17: zero, c18: zero, c19: zero, c20: zero,
              c21: zero, c22: zero, c23: zero, c24: zero, c25: zero,
              c26: zero
            };
            MUTABLE vals: Number[]@list = [];
            append(vals, big.c1.a);
            RETURN vals;
          END
        CLEAR
        annotated = run(src)
        fn = annotated.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "buildList" }
        ret = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
        expect(fn.uses_frame).to be true
        expect(ret.collection_return).to be true
      end

      it "sets collection_return for list returns even without other frame usage" do
        src = <<~CLEAR
          FN buildList() RETURNS Number[]@list ->
            MUTABLE vals: Number[]@list = [];
            append(vals, 1.0);
            RETURN vals;
          END
        CLEAR
        annotated = run(src)
        fn = annotated.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "buildList" }
        ret = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
        # Lists use frameAlloc for append() — always need promotion on escape
        expect(ret.collection_return).to be true
      end
    end

    context "Break and Continue" do
      context "Inside Loop" do
        let(:code) {
          <<~FLUX
            WHILE TRUE DO
              BREAK;
              CONTINUE;
            END
          FLUX
        }
        it "allows BREAK and CONTINUE inside loops" do
          expect { ast }.not_to raise_error
        end
      end

      context "Orphaned Break (Outside Loop)" do
        let(:code) {
          <<~FLUX
            x = 1;
            BREAK;
          FLUX
        }
        it "raises error for BREAK outside loop" do
          expect { ast }.to raise_error(/BREAK must be used inside a loop/)
        end
      end

      context "Orphaned Continue (Outside Loop)" do
        let(:code) {
          <<~FLUX
            CONTINUE;
          FLUX
        }
        it "raises error for CONTINUE outside loop" do
          expect { ast }.to raise_error(/CONTINUE must be used inside a loop/)
        end
      end

      context "Inside Function (but not loop)" do
        let(:code) {
          <<~FLUX
            FN test() ->
               BREAK;
            END
          FLUX
        }
        it "raises error even inside a function if no loop is present" do
          expect { ast }.to raise_error(/BREAK must be used inside a loop/)
        end
      end
    end
  end

  describe "Method Calls / Unified Call Syntax (visit_MethodCall)" do
    # Define a Point struct and functions that operate on it
    let(:base_funcs) {
      <<~FLUX
        STRUCT Point {
          x: Number,
          y: Number
        }

        -- "Method" to add two points: add(p1, p2)
        FN add(a: Point, b: Point) RETURNS Point ->
          RETURN Point{ x: a.x + b.x, y: a.y + b.y };
        END

        -- "Method" to get X coordinate: get_x(p)
        FN get_x(p: Point) RETURNS Number ->
          RETURN p.x;
        END

        -- "Method" to convert Number to List: to_list(n)
        FN to_list(n: Number) RETURNS Number[] ->
          RETURN [n];
        END
      FLUX
    }

    context "Unified Call Syntax (UCS)" do
      context "Simple Transformation: p.add(p2) -> add(p, p2)" do
        let(:code) {
          base_funcs + <<~FLUX
            p1 = Point{ x: 1, y: 2 };
            p2 = Point{ x: 3, y: 4 };

            -- Should resolve to add(p1, p2)
            res = p1.add(p2);
          FLUX
        }

        it "resolves correctly using the global function signature" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Point)
        end
      end

      context "Chained Calls: p.add(p2).get_x().to_list()" do
        let(:code) {
          base_funcs + <<~FLUX
            p1 = Point{ x: 1, y: 2 };
            p2 = Point{ x: 3, y: 4 };

            -- 1. p1.add(p2)    -> Point
            -- 2. .get_x()      -> Number
            -- 3. .to_list()    -> Number[]
            res = p1.add(p2).get_x().to_list();
          FLUX
        }

        it "resolves chains by propagating types" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:"Number[]")  # to_list returns dynamic array, always of size 1
        end
      end
    end

    context "Validation & Errors" do
      context "Undefined Method" do
        let(:code) {
          base_funcs + <<~FLUX
            p = Point{ x: 1, y: 2 };
            p.unknown_method();
          FLUX
        }
        it "raises error if the function does not exist globally" do
          expect { ast }.to raise_error(/Undefined function 'unknown_method'/)
        end
      end

      context "Type Mismatch (UCS Argument)" do
        let(:code) {
          base_funcs + <<~FLUX
            p1 = Point{ x: 1, y: 2 };
            -- add expects (Point, Point). We pass (Point, Number)
            p1.add(5);
          FLUX
        }
        it "raises argument type error on the explicit argument" do
          expect { ast }.to raise_error(/Argument .* expects Point, got Int64/i)
        end
      end

      context "Arity Mismatch" do
        let(:code) {
          base_funcs + <<~FLUX
            p1 = Point{ x: 1, y: 2 };
            -- add expects 2 args (Point, Point). We provide only 1 (self) via dot syntax.
            p1.add();
          FLUX
        }
        it "raises arity mismatch considering the implicit first argument" do
          # Expects 2, got 1 (the object p1)
          expect { ast }.to raise_error(/Function 'add' expects 2 arguments, got 1/i)
        end
      end
    end

    # TDOO: Decide...
    #context "Intrinsics via Dot Syntax" do
    #  let(:code) {
    #    base_funcs + <<~FLUX
    #      -- print(x) -> Void/Nil
    #      p = Point{ x: 1, y: 2 };
    #      p.print();
    #    FLUX
    #  }
    #  it "works for built-in functions like print" do
    #    expect { ast }.not_to raise_error
    #    # Assuming print returns Nil/Void
    #    expect(result).to eq(:Nil)
    #  end
    #end
  end

  describe "The USE Keyword (Closure Captures)" do
    context "when capturing a single scalar variable" do
      let(:code) {
        <<~FLUX
          x = 100;

          -- Define a lambda that explicitly captures 'x'
          FN getter() USE(x) RETURNS Number ->
            RETURN x;
          END

          -- Call it to verify the type flows through the capture
          getter();
        FLUX
      }

      it "resolves the return type correctly via the captured variable" do
        expect(result).to eq(:Number)
      end
    end

    context "when capturing multiple variables" do
      let(:code) {
        <<~FLUX
          a = 10;
          b = 20;

          -- Capture both 'a' and 'b'
          FN adder() USE(a, b) RETURNS Number ->
            RETURN a + b;
          END

          adder();
        FLUX
      }

      it "successfully resolves types for all captured variables" do
        expect(result).to eq(:Number)
      end
    end

    context "when mixing Parameters and USE captures" do
      let(:code) {
        <<~FLUX
          scalar = 5;

          -- 'n' is a parameter, 'scalar' is an upvalue
          FN multiplier(n: Number) USE(scalar) RETURNS Number ->
            RETURN n * scalar;
          END

          multiplier(10);
        FLUX
      }

      it "resolves operations between parameters and upvalues" do
        expect(result).to eq(:Number)
      end
    end

    context "when attempting to capture an undefined variable" do
      let(:code) {
        <<~FLUX
          FN ghost() USE(ghost_var) ->
            RETURN 1;
          END
        FLUX
      }

      it "raises a semantic error for undefined capture" do
        expect { run(code) }.to raise_error(/Cannot capture undefined variable/i)
      end
    end

    # Assuming your Annotator adheres to the "Explicit Capture Only" rule implied by USE
    context "when accessing a variable NOT in the USE list" do
      let(:code) {
        <<~FLUX
          secret = 42;

          -- We forgot USE(secret)
          FN leak() RETURNS Number ->
            RETURN secret;
          END
        FLUX
      }

      it "raises a semantic error for accessing uncaptured variable" do
         # Note: Adjust error message to match your specific compiler error
        expect { run(code) }.to raise_error(/Undefined variable/i)
      end
    end
  end

  # ============================================================================
  # 1. Standard Library & Intrinsics
  # ============================================================================
  describe "Standard Library Intrinsics" do
    let(:result) { ast.statements.last.full_type }

    context "String Manipulation (split)" do
      let(:code) {
        <<~FLUX
          data = "a,b,c";
          -- split returns a List of Strings (String)
          parts = data.split(",");
        FLUX
      }
      it "resolves split to a List of Strings" do
        expect(result).to eq(:"String[]")
      end
    end

    context "String Manipulation (join)" do
      let(:code) {
        <<~FLUX
          parts = ["a", "b"];
          -- join takes a List of Strings and returns a Heap String
          s = parts.join("-");
        FLUX
      }
      it "resolves join to a Heap String" do
        expect(result).to eq(:"String")
      end
    end

    context "String Manipulation (trim & chaining)" do
      let(:code) {
        <<~FLUX
          -- trim returns a String slice (String)
          clean = "  abc  ".trim();
        FLUX
      }
      it "resolves trim to a String slice" do
        expect(result).to eq(:"String")
      end
    end

    context "Polymorphic Conversion (toInt)" do
      context "when parsing a String" do
        let(:code) { 'i = "123".toInt();' }
        it "resolves to Int64" do
          expect(result).to eq(:Int64)
        end
      end

      context "when casting a Float" do
        let(:code) { 'i = 12.5.toInt();' }
        it "resolves to Int64" do
          expect(result).to eq(:Int64)
        end
      end
    end

    context "Polymorphic Conversion (toFloat)" do
      let(:code) { 'f = "12.5".toFloat();' }
      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "Collection Utilities (length/len)" do
      let(:code) {
        <<~FLUX
          list = [1, 2, 3];
          l = length(list);
        FLUX
      }
      it "resolves length of a list to Int64" do
        expect(result).to eq(:Int64)
      end
    end

    context "Collection Utilities (append)" do
      let(:code) {
        <<~FLUX
          MUTABLE list = [1, 2];
          -- append returns Void, usually used as statement
          list.append(3);
        FLUX
      }
      it "resolves append to Void" do
        expect(result).to eq(:Void)
      end
    end
  end

  # Higher-Order specs moved to spec/higher_order_spec.rb

  describe "Escape Analysis (Heap Promotion)" do
    # Helper to check if a specific variable was promoted
    def expect_escape(var_name)
      # We verify that mark_escaped is called with the target variable.
      # We allow other calls (like for captured variables) to avoid strict arity/argument failures.
      expect_any_instance_of(Scope).to receive(:mark_escaped).with(var_name).and_call_original
      allow_any_instance_of(Scope).to receive(:mark_escaped).and_call_original
    end

    def expect_no_escape(var_name = nil)
      if var_name
        expect_any_instance_of(Scope).not_to receive(:mark_escaped).with(var_name)
      else
        expect_any_instance_of(Scope).not_to receive(:mark_escaped)
      end
      allow_any_instance_of(Scope).to receive(:mark_escaped).and_call_original
    end

    context "Return Statements" do
      it "promotes a variable when it is returned (Pass-by-Reference requirement)" do
        expect_escape("x")
        run(<<~FLUX)
          STRUCT Config { id: Number }
          FN create() RETURNS %Config ->
            x = Config { id: 1 };
            RETURN x; -- x must be on heap to survive return
          END
        FLUX
      end

      it "does NOT promote primitives (Number)" do
        # Primitives are copied, so mark_escaped guards against them,
        # or the annotator shouldn't even call it.
        # Your Scope code handles the guard, so we can expect the call OR check the logic.
        # But generally, we expect NO promotion to heap storage.
        expect_no_escape
        run(<<~FLUX)
          FN get_num() RETURNS Number ->
            x = 10;
            RETURN x;
          END
        FLUX
      end
    end

    context "Assignment to Persistent Storage" do
      it "promotes a variable assigned to a Global" do
        expect_escape("local")
        run(<<~FLUX)
          STRUCT Item { id: Number, name: Byte[100] }
          STRUCT Container { item: %Item }

          MUTABLE g: %Container = Container { item: Item{id:0, name: [0]} }; -- Global Heap

          FN update() USE(MUTABLE g) ->
            local = Item { id: 99, name: [1] };
            g.item = local; -- 'local' escapes to Global
          END
        FLUX
      end

      it "does NOT promote when assigning to a local stack variable" do
        expect_no_escape
        run(<<~FLUX)
          STRUCT Item { id: Number }
          FN test() ->
            MUTABLE a = Item { id: 1 };
            b = Item { id: 2 };
            a = b; -- 'b' moves to 'a', but both are stack. No escape.
          END
        FLUX
      end
    end

    context "Lambda/Function Captures (USE)" do
      it "promotes a variable when it is captured by USE" do
        expect_escape("x")
        run(<<~FLUX)
          STRUCT Node { id: Number }
          FN main() ->
            x = Node { id: 1 };
            -- x is captured by lambda, must be on heap
            f = %(n: Number) USE(x) -> x.id + n;
            RETURN;
          END
        FLUX
      end
    end

    context "Multi-dimensional Arrays" do
      it "resolves a 2D array literal correctly" do
        code = "MUTABLE matrix: Number[][] = [[1.0, 2.0], [3.0, 4.0]];"
        local_ast = run(code)
        expect(local_ast.statements.last.value.full_type.to_s).to eq("Number[2][2]")
      end

      it "resolves a 3D array literal correctly" do
        code = "MUTABLE cube: Number[][][] = [[[1.0]]];"
        local_ast = run(code)
        expect(local_ast.statements.last.value.full_type.to_s).to eq("Number[1][1][1]")
      end

      it "fails when nested array types are inconsistent" do
        expect {
          run(<<~FLUX)
            MUTABLE x: Number[][] = [[1, 2], ["a", "b"]];
          FLUX
        }.to raise_error(/List literal contains mixed types/i)
      end
    end
  end

  describe "Function Return Strategies (ABI)" do
    # Helper to get the strategy of the first function in the code
    def get_strategy(source)
      ast = run(source)
      func_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }

      # If this fails, it means the parser/annotator crashed or didn't produce a function
      raise "No FunctionDef found in AST" unless func_node

      signature = func_node.full_type
      signature[:return_strategy]
    end

    let(:preamble) { "STRUCT Config { id: Number }" }

    context "Register Return (Fast)" do
      it "uses :register for Primitives (Number)" do
        code = <<~FLUX
          FN get_num() RETURNS Number -> RETURN 1; END
        FLUX
        expect(get_strategy(code)).to eq(:register)
      end

      it "uses :register for Booleans" do
        code = <<~FLUX
          FN check() RETURNS Bool -> RETURN TRUE; END
        FLUX
        expect(get_strategy(code)).to eq(:register)
      end

      it "uses :register for Heap Objects (Pointers)" do
        # Even though Config is a struct, %Config is a pointer (8 bytes).
        # Pointers fit in registers.
        code = preamble + <<~FLUX
          FN make_heap() RETURNS %Config ->
            c = %Config{id:1};
            RETURN c;
          END
        FLUX
        expect(get_strategy(code)).to eq(:register)
      end
    end

    context "Destination Passing (Large Value Types)" do
      it "uses :destination_pass for Stack Structs" do
        # A Stack Struct is a "Value Type". It must be written to memory provided by the caller.
        code = preamble + <<~FLUX
          FN make_stack() RETURNS Config ->
            c = Config{id:1};
            RETURN c;
          END
        FLUX
        expect(get_strategy(code)).to eq(:destination_pass)
      end

      it "uses :destination_pass for Fixed Arrays" do
        code = <<~FLUX
          FN get_vec() RETURNS Number[3] -> RETURN [1, 2, 3]; END
        FLUX
        expect(get_strategy(code)).to eq(:destination_pass)
      end
    end

    context "Void" do
      it "uses :void for empty returns" do
        code = <<~FLUX
          FN do_thing() RETURNS Void -> RETURN; END
        FLUX
        expect(get_strategy(code)).to eq(:void)
      end

      it "uses :void for procedures with no return" do
        code = <<~FLUX
          FN do_thing() RETURNS Void -> x = 1; END
        FLUX
        expect(get_strategy(code)).to eq(:void)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Range Literals (..<  and  ..<=)
  # ---------------------------------------------------------------------------
  describe "Range literals" do
    context "exclusive range (1..<10)" do
      let(:code) { "r = (1..<10);" }

      it "resolves to :Range" do
        expect(result).to eq(:Range)
      end

      it "does not raise an error" do
        expect { ast }.not_to raise_error
      end
    end

    context "inclusive range (1..<=10)" do
      let(:code) { "r = (1..<=10);" }

      it "resolves to :Range" do
        expect(result).to eq(:Range)
      end

      it "does not raise an error" do
        expect { ast }.not_to raise_error
      end
    end

    context "field access on range (.start and .end)" do
      let(:code) {
        <<~FLUX
          r = (2..<8);
          s = r.start;
          e = r.end;
        FLUX
      }

      it "resolves .start to Number" do
        start_decl = ast.statements[-2]
        expect(start_decl.resolved_type).to eq(:Number)
      end

      it "resolves .end to Number" do
        end_decl = ast.statements.last
        expect(end_decl.resolved_type).to eq(:Number)
      end
    end

    context "range with Int64 bounds (auto-coerced to Number)" do
      let(:code) { "r = (0_i64..<5_i64);" }

      it "resolves to :Range without error" do
        expect { ast }.not_to raise_error
        expect(result).to eq(:Range)
      end

      it "coerces Int64 start to Number" do
        range_node = ast.statements.last.value
        expect(range_node.start.coerced_type).to eq(:Number)
      end
    end

    context "range with arithmetic bounds" do
      let(:code) { "r = ((1 + 2)..<(3 * 4));" }

      it "resolves to :Range without error" do
        expect { ast }.not_to raise_error
        expect(result).to eq(:Range)
      end
    end

    context "range with String start (type error)" do
      let(:code) { 'r = ("bad"..<10);' }

      it "raises a type error" do
        expect { ast }.to raise_error(/Range start must be a numeric type/)
      end
    end

    context "range with Bool end (type error)" do
      let(:code) { "r = (1..<TRUE);" }

      it "raises a type error" do
        expect { ast }.to raise_error(/Range end must be a numeric type/)
      end
    end
  end

  # ==========================================
  describe "Visibility modifiers" do
  # ==========================================

    def run_with_annotator(source)
      tokens = Lexer.new(source).tokenize
      ast = Parser.new(tokens, source).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      [ast, annotator]
    end

    context "PUB FN" do
      let(:code) { "PUB FN foo() RETURNS Number -> RETURN 1; END" }

      it "sets :pub visibility on the FunctionDef node" do
        expect(ast.statements.first.visibility).to eq(:pub)
      end

      it "stores :pub visibility in the scope signature" do
        _, annotator = run_with_annotator(code)
        sig = annotator.scope_stack.first.locals["foo"].type
        expect(sig[:visibility]).to eq(:pub)
      end
    end

    context "PRIVATE FN" do
      let(:code) { "PRIVATE FN foo() RETURNS Number -> RETURN 1; END" }

      it "sets :private visibility on the FunctionDef node" do
        expect(ast.statements.first.visibility).to eq(:private)
      end

      it "stores :private visibility in the scope signature" do
        _, annotator = run_with_annotator(code)
        sig = annotator.scope_stack.first.locals["foo"].type
        expect(sig[:visibility]).to eq(:private)
      end
    end

    context "FN (no modifier)" do
      let(:code) { "FN foo() RETURNS Number -> RETURN 1; END" }

      it "defaults to :package visibility on the FunctionDef node" do
        expect(ast.statements.first.visibility).to eq(:package)
      end

      it "stores :package visibility in the scope signature" do
        _, annotator = run_with_annotator(code)
        sig = annotator.scope_stack.first.locals["foo"].type
        expect(sig[:visibility]).to eq(:package)
      end
    end

    context "STRUCT visibility" do
      it "PUB STRUCT sets :pub visibility" do
        result = run("PUB STRUCT Point { x: Number, y: Number }")
        expect(result.statements.first.visibility).to eq(:pub)
      end

      it "PRIVATE STRUCT sets :private visibility" do
        result = run("PRIVATE STRUCT Point { x: Number, y: Number }")
        expect(result.statements.first.visibility).to eq(:private)
      end

      it "STRUCT (no modifier) defaults to :package visibility" do
        result = run("STRUCT Point { x: Number, y: Number }")
        expect(result.statements.first.visibility).to eq(:package)
      end
    end

    context "mixed visibility in same file" do
      let(:code) {
        <<~FLUX
          PUB FN exported() RETURNS Number -> RETURN 1; END
          FN internal() RETURNS Number -> RETURN 2; END
          PRIVATE FN hidden() RETURNS Number -> RETURN 3; END
        FLUX
      }

      it "annotates without errors" do
        expect { ast }.not_to raise_error
      end

      it "assigns correct visibility to each function" do
        stmts = ast.statements
        expect(stmts[0].visibility).to eq(:pub)
        expect(stmts[1].visibility).to eq(:package)
        expect(stmts[2].visibility).to eq(:private)
      end
    end
  end

  # ==========================================
  describe "REQUIRE (multi-file imports)" do
  # ==========================================

    # Helper: write helper files to a tmpdir, annotate the main code using
    # a ModuleImporter rooted in that tmpdir, and return the AST.
    def annotate_with_require(main_code, helpers: {})
      dir = Dir.mktmpdir
      helpers.each { |filename, code| File.write(File.join(dir, filename), code) }

      compiler  = ModuleImporter.new(base_dir: dir)
      tokens    = Lexer.new(main_code).tokenize
      ast       = Parser.new(tokens, main_code).parse
      annotator = SemanticAnnotator.new(importer: compiler, source_dir: dir)
      annotator.annotate!(ast)
      ast
    ensure
      FileUtils.rm_rf(dir)
    end

    context "importing a PUB function" do
      let(:helper) { "PUB FN add(a: Number, b: Number) RETURNS Number -> RETURN a + b; END" }
      let(:main) {
        <<~FLUX
          REQUIRE "helper.cht";
          FN caller() RETURNS Number ->
            RETURN add(1, 2);
          END
        FLUX
      }

      it "annotates without error" do
        expect { annotate_with_require(main, helpers: { "helper.cht" => helper }) }.not_to raise_error
      end

      it "resolves the call return type from the imported signature" do
        ast = annotate_with_require(main, helpers: { "helper.cht" => helper })
        fn_node = ast.statements.last
        return_node = fn_node.body.last
        expect(return_node.value.full_type).to eq(:Number)
      end

      it "tags the FuncCall node with the module namespace alias" do
        ast = annotate_with_require(main, helpers: { "helper.cht" => helper })
        fn_node   = ast.statements.last
        call_node = fn_node.body.last.value
        expect(call_node.module_alias).to eq("helper")
      end
    end

    context "importing a package-private function from the same directory" do
      let(:helper) { "FN multiply(x: Number, y: Number) RETURNS Number -> RETURN x * y; END" }
      let(:main) {
        <<~FLUX
          REQUIRE "helper.cht";
          FN caller() RETURNS Number ->
            RETURN multiply(3, 4);
          END
        FLUX
      }

      it "annotates without error (same-dir package access is allowed)" do
        expect { annotate_with_require(main, helpers: { "helper.cht" => helper }) }.not_to raise_error
      end
    end

    context "attempting to call a PRIVATE function from a required file" do
      let(:helper) { "PRIVATE FN secret(x: Number) RETURNS Number -> RETURN x; END" }
      let(:main) {
        <<~FLUX
          REQUIRE "helper.cht";
          FN caller() RETURNS Number ->
            RETURN secret(1);
          END
        FLUX
      }

      it "raises an Undefined function error" do
        expect {
          annotate_with_require(main, helpers: { "helper.cht" => helper })
        }.to raise_error(/Undefined function 'secret'/)
      end
    end

    context "REQUIRE with AS alias" do
      let(:helper) { "PUB FN greet() RETURNS Number -> RETURN 42; END" }
      let(:main) {
        <<~FLUX
          REQUIRE "helper.cht" AS myLib;
          FN caller() RETURNS Number ->
            RETURN greet();
          END
        FLUX
      }

      it "uses the alias as the namespace on the parsed RequireNode" do
        ast = annotate_with_require(main, helpers: { "helper.cht" => helper })
        require_node = ast.statements.first
        expect(require_node.namespace).to eq("myLib")
      end

      it "tags the FuncCall with the alias" do
        ast = annotate_with_require(main, helpers: { "helper.cht" => helper })
        fn_node   = ast.statements.last
        call_node = fn_node.body.last.value
        expect(call_node.module_alias).to eq("myLib")
      end
    end

    context "circular dependency detection" do
      it "raises a circular dependency error" do
        dir = Dir.mktmpdir
        # a.cht REQUIREs b.cht, b.cht REQUIREs a.cht
        File.write(File.join(dir, "a.cht"), 'REQUIRE "b.cht";')
        File.write(File.join(dir, "b.cht"), 'REQUIRE "a.cht";')

        compiler  = ModuleImporter.new(base_dir: dir)
        main_code = 'REQUIRE "a.cht";'
        tokens    = Lexer.new(main_code).tokenize
        ast       = Parser.new(tokens, main_code).parse
        annotator = SemanticAnnotator.new(importer: compiler, source_dir: dir)

        expect { annotator.annotate!(ast) }.to raise_error(/Circular dependency/)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    context "missing required file" do
      it "raises a file-not-found error" do
        expect {
          annotate_with_require('REQUIRE "nonexistent.cht";', helpers: {})
        }.to raise_error(/file not found/)
      end
    end

    context "importing struct types from a required file" do
      let(:helper) {
        <<~FLUX
          PUB STRUCT Point { x: Number, y: Number }
          PUB FN makePoint(x: Number, y: Number) RETURNS Point ->
            RETURN %Point{ x: x, y: y };
          END
        FLUX
      }
      let(:main) {
        <<~FLUX
          REQUIRE "helper.cht";
          FN caller() RETURNS Number ->
            p = makePoint(1, 2);
            RETURN p.x;
          END
        FLUX
      }

      it "makes the imported struct type available" do
        expect { annotate_with_require(main, helpers: { "helper.cht" => helper }) }.not_to raise_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "EXTERN (FFI declarations)" do
    def annotate_extern(source)
      tokens = Lexer.new(source).tokenize
      ast    = Parser.new(tokens, source).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      ast
    end

    context "EXTERN FN declaration" do
      let(:code) {
        <<~CLEAR
          EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";
          FN caller() RETURNS Number ->
            RETURN native_add(1, 2);
          END
        CLEAR
      }

      it "parses without error" do
        expect { annotate_extern(code) }.not_to raise_error
      end

      it "registers the extern function in scope" do
        ast = annotate_extern(code)
        decl = ast.statements.first
        expect(decl).to be_a(AST::ExternFnDecl)
        expect(decl.name).to eq("native_add")
        expect(decl.from_module).to eq("native_math")
      end

      it "resolves calls to the extern function with the correct return type" do
        ast = annotate_extern(code)
        caller_fn = ast.statements.last
        ret_node  = caller_fn.body.last
        expect(ret_node.value.resolved_type).to eq(:Number)
      end

      it "marks the FuncCall node as an extern call" do
        ast = annotate_extern(code)
        caller_fn = ast.statements.last
        ret_node  = caller_fn.body.last
        call = ret_node.value
        expect(call).to be_a(AST::FuncCall)
        expect(call.extern_call).to be true
      end

      it "sets module_alias on the FuncCall to the from_module name" do
        ast = annotate_extern(code)
        caller_fn = ast.statements.last
        ret_node  = caller_fn.body.last
        call = ret_node.value
        expect(call.module_alias).to eq("native_math")
      end
    end

    context "multiple EXTERN FN declarations from the same module" do
      let(:code) {
        <<~CLEAR
          EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";
          EXTERN FN native_multiply(a: Number, b: Number) RETURNS Number FROM "native_math";
          FN caller() RETURNS Number ->
            RETURN native_add(native_multiply(2, 3), 1);
          END
        CLEAR
      }

      it "annotates without error" do
        expect { annotate_extern(code) }.not_to raise_error
      end

      it "both calls are marked as extern" do
        ast = annotate_extern(code)
        caller_fn = ast.statements.last
        ret_node  = caller_fn.body.last
        outer_call = ret_node.value
        inner_call = outer_call.args.first
        expect(outer_call.extern_call).to be true
        expect(inner_call.extern_call).to be true
      end
    end

    context "EXTERN FN with no return type" do
      let(:code) {
        <<~CLEAR
          EXTERN FN native_log(val: Number) FROM "native_io";
          FN caller() RETURNS Void ->
            native_log(42);
          END
        CLEAR
      }

      it "annotates without error" do
        expect { annotate_extern(code) }.not_to raise_error
      end
    end

    context "EXTERN STRUCT declaration" do
      let(:code) {
        <<~CLEAR
          EXTERN STRUCT Vec2 { x: Number, y: Number } FROM "native_math";
          FN use_vec() RETURNS Number ->
            v = Vec2{ x: 1, y: 2 };
            RETURN v.x;
          END
        CLEAR
      }

      it "registers the extern struct type" do
        expect { annotate_extern(code) }.not_to raise_error
      end

      it "makes fields accessible via dot access" do
        ast = annotate_extern(code)
        fn  = ast.statements.last
        ret = fn.body.last
        expect(ret.value.resolved_type).to eq(:Number)
      end
    end

    context "calling an undefined extern function" do
      it "raises an Undefined function error" do
        code = <<~CLEAR
          FN bad() RETURNS Number ->
            RETURN nonexistent_native(1, 2);
          END
        CLEAR
        expect { annotate_extern(code) }.to raise_error(/Undefined function/)
      end
    end

    context "EXTERN FN transpilation" do
      it "emits @import once per native module (deduplication)" do
        code = <<~CLEAR
          EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";
          EXTERN FN native_multiply(a: Number, b: Number) RETURNS Number FROM "native_math";
          FN main() RETURNS Void ->
            x = native_add(1, 2);
          END
        CLEAR
        tokens = Lexer.new(code).tokenize
        ast    = Parser.new(tokens, code).parse
        annotator = SemanticAnnotator.new
        annotator.annotate!(ast)
        transpiler = ZigTranspiler.new
        output = transpiler.transpile_as_module(code)
        imports = output.scan(/@import\("native_math"\)/)
        expect(imports.length).to eq(1)
      end

      it "emits the native call trampolined via onRootStack (no rt, no try)" do
        code = <<~CLEAR
          EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";
          FN main() RETURNS Void ->
            x = native_add(3.0, 4.0);
          END
        CLEAR
        output = ZigTranspiler.new.transpile_as_module(code)
        expect(output).to include("native_math.native_add(")
        expect(output).to include("onRootStack")
        expect(output).not_to match(/try native_math\.native_add/)
        expect(output).not_to match(/native_math\.native_add\(rt,/)
      end

      it "emits a type alias for EXTERN STRUCT" do
        code = <<~CLEAR
          EXTERN STRUCT Vec2 { x: Number, y: Number } FROM "native_math";
          FN main() RETURNS Void ->
          END
        CLEAR
        output = ZigTranspiler.new.transpile_as_module(code)
        expect(output).to include("const Vec2 = native_math.Vec2;")
      end
    end
  end

  # ==========================================
  # ENUM
  # ==========================================
  describe "ENUM" do
    # --------------------------------------------------
    # Declaration
    # --------------------------------------------------
    describe "declaration" do
      it "registers the enum type in scope without error" do
        expect { run("ENUM Direction { North, South, East, West }") }.not_to raise_error
      end

      it "resolves the EnumDef node as Void (like StructDef)" do
        ast = run("ENUM Direction { North, South, East, West }")
        expect(ast.statements.first.resolved_type).to eq(:Void)
      end

      it "accepts PUB ENUM without error" do
        expect { run("PUB ENUM Color { Red, Green, Blue }") }.not_to raise_error
      end

      it "accepts PRIVATE ENUM without error" do
        expect { run("PRIVATE ENUM Size { Small, Medium, Large }") }.not_to raise_error
      end

      it "allows multiple independent enum types in the same file" do
        expect {
          run(<<~CLEAR)
            ENUM Direction { North, South }
            ENUM Status { Active, Inactive }
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # Variant access (EnumType.Variant)
    # --------------------------------------------------
    describe "variant access" do
      let(:code) {
        <<~CLEAR
          ENUM Color { Red, Green, Blue }
          x: Color = Color.Red;
        CLEAR
      }

      it "resolves variant access to the enum's own type" do
        rhs = ast.statements.last.value
        expect(rhs.resolved_type).to eq(:Color)
      end

      it "resolves the declared variable to the enum type" do
        expect(ast.statements.last.resolved_type).to eq(:Color)
      end

      it "resolves all variants to the same enum type" do
        ast = run(<<~CLEAR)
          ENUM Dir { North, South, East, West }
          a: Dir = Dir.North;
          b: Dir = Dir.South;
          c: Dir = Dir.East;
          d: Dir = Dir.West;
        CLEAR
        ast.statements.drop(1).each do |stmt|
          expect(stmt.resolved_type).to eq(:Dir)
        end
      end
    end

    # --------------------------------------------------
    # Functions with enum params / return types
    # --------------------------------------------------
    describe "enum in function signatures" do
      let(:code) {
        <<~CLEAR
          ENUM Dir { North, South }
          FN mirror(d: Dir) RETURNS Dir ->
            RETURN d;
          END
          FN main() RETURNS Void ->
            result = mirror(Dir.North);
          END
        CLEAR
      }

      it "accepts enum as a parameter type without error" do
        expect { ast }.not_to raise_error
      end

      it "resolves the call result to the enum type" do
        fn        = ast.statements.last
        call_stmt = fn.body.last
        expect(call_stmt.resolved_type).to eq(:Dir)
      end

      it "raises Type Error when wrong type is passed to enum param" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            FN use(d: Dir) RETURNS Void ->
            END
            FN main() RETURNS Void ->
              use(42);
            END
          CLEAR
        }.to raise_error(/Type Error/i)
      end
    end

    # --------------------------------------------------
    # Equality and comparison
    # --------------------------------------------------
    describe "equality" do
      it "resolves == comparison between enum values to Bool" do
        result = get_last_type(<<~CLEAR)
          ENUM Status { Active, Inactive }
          a: Status = Status.Active;
          b: Status = Status.Inactive;
          a == b;
        CLEAR
        expect(result).to eq(:Bool)
      end

      it "resolves != comparison between enum values to Bool" do
        result = get_last_type(<<~CLEAR)
          ENUM Status { Active, Inactive }
          a: Status = Status.Active;
          b: Status = Status.Inactive;
          a != b;
        CLEAR
        expect(result).to eq(:Bool)
      end
    end

    # --------------------------------------------------
    # MATCH on enum values
    # --------------------------------------------------
    describe "MATCH" do
      it "type-checks MATCH cases against the enum type without error" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when a MATCH case is a different enum type" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            ENUM Color { Red, Blue }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH d START
                Color.Red -> n = 1_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH case type Color does not match expression type Dir/)
      end
    end

    # --------------------------------------------------
    # Error messages
    # --------------------------------------------------
    describe "error messages" do
      it "raises 'Type Error: Enum ... has no variant' for an unknown variant" do
        expect {
          run(<<~CLEAR)
            ENUM Season { Spring, Summer, Autumn }
            x: Season = Season.Winter;
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Enum 'Season' has no variant 'Winter'/)
      end

      it "raises 'Type Error: ... is an enum type' when accessing a field on an enum value" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            FN main() RETURNS Void ->
              d: Dir = Dir.North;
              bad = d.name;
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: 'Dir' is an enum type/)
      end

      it "raises 'Type Error: Enum ... has no variant' for a variant typo" do
        expect {
          run(<<~CLEAR)
            ENUM Color { Red, Green, Blue }
            x: Color = Color.Purple;
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Enum 'Color' has no variant 'Purple'/)
      end
    end

    # --------------------------------------------------
    # Zig code generation
    # --------------------------------------------------
    describe "Zig code generation" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      it "emits a Zig enum type declaration with all variants" do
        out = transpile(<<~CLEAR)
          ENUM Planet { Mercury, Venus, Earth }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Planet = enum {")
        expect(out).to include("    Mercury,")
        expect(out).to include("    Venus,")
        expect(out).to include("    Earth,")
      end

      it "emits enum variant access as TypeName.Variant" do
        out = transpile(<<~CLEAR)
          ENUM Color { Red, Green }
          FN main() RETURNS Void ->
            c: Color = Color.Red;
          END
        CLEAR
        expect(out).to include("Color.Red")
      end

      it "emits the enum type annotation on a const declaration" do
        out = transpile(<<~CLEAR)
          ENUM Dir { North, South }
          FN main() RETURNS Void ->
            d: Dir = Dir.North;
          END
        CLEAR
        expect(out).to include("Dir")
        expect(out).to include("Dir.North")
      end

      it "emits enum as a function parameter type" do
        out = transpile(<<~CLEAR)
          ENUM Dir { North, South }
          FN turn(d: Dir) RETURNS Dir ->
            RETURN d;
          END
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("d: Dir")
        expect(out).to match(/fn turn.*Dir/)
      end

      it "includes PUB ENUM in transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PUB ENUM Status { Active, Inactive }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Status = enum {")
      end

      it "excludes PRIVATE ENUM from transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PRIVATE ENUM Internal { A, B }
          FN main() RETURNS Void ->
          END
        CLEAR
        expect(out).not_to include("const Internal = enum {")
      end
    end
  end

  # ===========================================================================
  # HashMap Methods (delete, contains, count, keys, values)
  # ===========================================================================
  describe "HashMap Methods" do
    def transpile_map(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    describe "HashMap#count" do
      it "resolves count() return type as Int64" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            n = m.count();
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr)) && n.name == "n" }
        expect(bind.full_type.resolved).to eq(:Int64)
      end

      it "emits CheatLib.mapCount in Zig" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            n = m.count();
            RETURN;
          END
        CLEAR
        expect(out).to include("m.count()")
      end

      it "raises when count receives arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.count(42);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.count takes no arguments/)
      end
    end

    describe "HashMap#contains" do
      it "resolves contains?() return type as Bool" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            found = m.contains?("x");
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "found" }
        expect(bind.full_type.resolved).to eq(:Bool)
      end

      it "emits CheatLib.mapContains in Zig" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            found = m.contains?("x");
            RETURN;
          END
        CLEAR
        expect(out).to include('m.contains("x")')  # ? stripped in Zig output
      end

      it "raises when contains receives no arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.contains?();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.contains\? requires exactly 1 argument/)
      end

      it "raises when contains key is not a String" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.contains?(42);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.contains\?: key must be a String/)
      end
    end

    describe "HashMap#delete" do
      it "resolves delete() return type as Void" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m.delete("x");
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        call = fn_node.body.find { |n| n.is_a?(AST::MethodCall) && n.name == "delete" }
        expect(call.full_type.to_sym).to eq(:Void)
      end

      it "emits CheatLib.mapDelete in Zig" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m.delete("x");
            RETURN;
          END
        CLEAR
        expect(out).to include('m.remove(rt.heapAlloc(), "x")')
      end

      it "raises when delete receives no arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.delete();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.delete requires exactly 1 argument/)
      end
    end

    describe "HashMap#keys" do
      it "resolves keys() return type as String[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            ks = m.keys();
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "ks" }
        expect(bind.full_type.resolved).to eq(:"String[]")
      end

      it "emits CheatLib.mapKeys in Zig" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            ks = m.keys();
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.mapKeys(i64, rt.frameAlloc(), m.inner)")
      end

      it "raises when keys receives arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.keys("x");
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.keys takes no arguments/)
      end
    end

    describe "HashMap#values" do
      it "resolves values() return type as V[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            vs = m.values();
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "vs" }
        expect(bind.full_type.resolved).to eq(:"Int64[]")
      end

      it "emits CheatLib.mapValues in Zig" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            vs = m.values();
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.mapValues(i64, rt.frameAlloc(), m.inner)")
      end

      it "raises when values receives arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.values(1);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.values takes no arguments/)
      end
    end

    describe "HashMap literal with initial values" do
      it "emits a Zig block with mapPut calls for populated literals" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m = {"a": 1_i64, "b": 2_i64};
            RETURN;
          END
        CLEAR
        expect(out).to include("__hl0_map.put(rt.frameAlloc(), rt.frameAlloc()")
        expect(out).to include('"a"')
        expect(out).to include('"b"')
      end

      it "emits zero-init for empty string-keyed map literals" do
        out = transpile_map(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.StringMap(i64){ .alloc = rt.frameAlloc() }")
        expect(out).not_to include("mapPut")
      end
    end

    describe "HashMap#unknown_method error" do
      it "raises a helpful error for unknown map methods" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.frobnicate();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Unknown method 'frobnicate' on HashMap/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Frame Allocation & SROA Optimization
  # ---------------------------------------------------------------------------
  describe "frame allocation — large structs (> 128 slots)" do
    # Chunk5 = 5 Number fields = 5 slots.
    # BigS   = 26 × Chunk5   = 130 slots → should be classified :frame.
    let(:large_struct_preamble) do
      chunk_fields = "a: Number, b: Number, c: Number, d: Number, e: Number"
      big_fields   = (1..26).map { |i| "c#{i}: Chunk5" }.join(", ")
      <<~CLEAR
        STRUCT Chunk5 { #{chunk_fields} }
        STRUCT BigS   { #{big_fields}   }
      CLEAR
    end

    let(:large_struct_fn) do
      chunk_init = "Chunk5{ a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 }"
      big_fields = (1..26).map { |i| "c#{i}: #{chunk_init}" }.join(", ")
      <<~CLEAR
        FN make_big() RETURNS Void ->
          s: BigS = BigS{ #{big_fields} };
          _ = s.c1.a;
        END
      CLEAR
    end

    let(:code)  { large_struct_preamble + large_struct_fn }
    let(:zig)   { ZigTranspiler.new.transpile(code) }

    it "classifies large struct (130 slots) as :frame storage" do
      ast = run(code)
      fn  = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "make_big" }
      # keywordless `s: BigS = ...` is a BindExpr in decl mode
      decl = fn.body.find { |s| s.is_a?(AST::BindExpr) && s.name == "s" }
      expect(decl.storage).to eq(:frame)
    end

    it "sets frame? on the full_type of the declaration" do
      ast = run(code)
      fn  = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "make_big" }
      decl = fn.body.find { |s| s.is_a?(AST::BindExpr) && s.name == "s" }
      expect(decl.type_info.frame?).to be true
    end

    it "emits *BigS as the Zig type for the frame-allocated variable" do
      expect(zig).to match(/const s = blk:/)
      expect(zig).to include("rt.frameAlloc().create(BigS)")
    end

    it "emits ptr.* initialiser inside the allocation block" do
      expect(zig).to include("ptr.* = BigS{")
    end

    it "does NOT use heapAlloc for the BigS struct" do
      expect(zig).not_to include("heapAlloc().create(BigS)")
    end

    it "does NOT emit a _moved flag or defer destroy for frame variables" do
      expect(zig).not_to include("s_moved")
      expect(zig).not_to include("CheatLib.free(rt, s)")
    end

    it "keeps small structs on the stack (≤ 128 slots) — no frameAlloc.create" do
      small_code = <<~CLEAR
        STRUCT Tiny { x: Number, y: Number }
        FN use_tiny() RETURNS Void ->
          t: Tiny = Tiny{ x: 1.0, y: 2.0 };
          _ = t.x;
        END
      CLEAR
      small_zig = ZigTranspiler.new.transpile(small_code)
      expect(small_zig).not_to include("frameAlloc().create(Tiny)")
      expect(small_zig).to     include("Tiny{ .x = 1.0, .y = 2.0 }")
    end
  end

  describe "loop-local SROA — large struct literals inside a loop body" do
    # BigS (130 slots) declared inside a WHILE loop should be :stack, not :frame.
    # The OS stack reclaims it each iteration; no frame-arena growth.
    let(:preamble) do
      chunk_fields = "a: Number, b: Number, c: Number, d: Number, e: Number"
      big_fields   = (1..26).map { |i| "c#{i}: Chunk5" }.join(", ")
      <<~CLEAR
        STRUCT Chunk5 { #{chunk_fields} }
        STRUCT BigS   { #{big_fields}   }
        FN first_a(s: BigS) RETURNS Number @reentrant ->
          RETURN s.c1.a;
        END
      CLEAR
    end

    let(:loop_code) do
      chunk_init = "Chunk5{ a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 }"
      big_fields = (1..26).map { |i| "c#{i}: #{chunk_init}" }.join(", ")
      preamble + <<~CLEAR
        FN bench() RETURNS Void ->
          MUTABLE i = 0_i64;
          MUTABLE acc: Number = 0.0;
          WHILE i < 100 DO
            s = BigS{ #{big_fields} };
            acc = acc + first_a(s);
            i = i + 1_i64;
          END
          ASSERT acc > 0.0, "ok";
        END
      CLEAR
    end

    it "classifies loop-local large struct as :stack (not :frame)" do
      ast = run(loop_code)
      fn  = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "bench" }
      while_node = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
      decl = while_node.do_branch.find { |s| s.is_a?(AST::BindExpr) && s.name == "s" }
      expect(decl.storage).to eq(:stack)
    end

    it "does not emit frameAlloc for a loop-local large struct" do
      zig = ZigTranspiler.new.transpile(loop_code)
      expect(zig).not_to include("frameAlloc().create(BigS)")
    end

    it "emits the struct literal directly (no blk: wrapper)" do
      zig = ZigTranspiler.new.transpile(loop_code)
      expect(zig).to include("const s = BigS{")
    end

    it "still uses frameAlloc for the same large struct declared OUTSIDE a loop" do
      chunk_init = "Chunk5{ a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 }"
      big_fields = (1..26).map { |i| "c#{i}: #{chunk_init}" }.join(", ")
      outside_code = preamble + <<~CLEAR
        FN outside() RETURNS Void ->
          s = BigS{ #{big_fields} };
          _ = first_a(s);
        END
      CLEAR
      zig = ZigTranspiler.new.transpile(outside_code)
      expect(zig).to include("frameAlloc().create(BigS)")
    end
  end

  describe "frame allocation — passing frame variables to functions" do
    let(:code) do
      chunk_fields = "a: Number, b: Number, c: Number, d: Number, e: Number"
      big_fields   = (1..26).map { |i| "c#{i}: Chunk5" }.join(", ")
      chunk_init   = "Chunk5{ a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 }"
      big_init     = "BigS{ #{(1..26).map { |i| "c#{i}: #{chunk_init}" }.join(", ")} }"
      <<~CLEAR
        STRUCT Chunk5 { #{chunk_fields} }
        STRUCT BigS   { #{big_fields}   }
        FN consume(s: BigS) RETURNS Number ->
          RETURN s.c1.a;
        END
        FN caller() RETURNS Number ->
          s: BigS = #{big_init};
          RETURN consume(s);
        END
      CLEAR
    end

    let(:zig) { ZigTranspiler.new.transpile(code) }

    it "passes frame pointer directly — anytype monomorphization handles T and *T" do
      # With anytype params, no explicit .* deref needed — Zig auto-derefs at comptime.
      # The call site emits consume(s) and the function's anytype param handles both.
      expect(zig).to include("consume(s)")
    end
  end

  describe "frame allocation — returning frame variables" do
    let(:code) do
      chunk_fields = "a: Number, b: Number, c: Number, d: Number, e: Number"
      big_fields   = (1..26).map { |i| "c#{i}: Chunk5" }.join(", ")
      chunk_init   = "Chunk5{ a: 0.0, b: 0.0, c: 0.0, d: 0.0, e: 0.0 }"
      big_init     = "BigS{ #{(1..26).map { |i| "c#{i}: #{chunk_init}" }.join(", ")} }"
      <<~CLEAR
        STRUCT Chunk5 { #{chunk_fields} }
        STRUCT BigS   { #{big_fields}   }
        FN make() RETURNS BigS ->
          s: BigS = #{big_init};
          RETURN s;
        END
      CLEAR
    end

    let(:zig) { ZigTranspiler.new.transpile(code) }

    it "auto-derefs the frame pointer when returning a value type" do
      expect(zig).to include("return s.*;")
    end
  end

  # ---------------------------------------------------------------------------
  # SROA — stack-allocated fixed array literals
  # ---------------------------------------------------------------------------
  describe "SROA — fixed array literals with explicit T[N] annotation" do
    let(:code) do
      <<~CLEAR
        FN use_fixed_array() RETURNS Void ->
          vals: Number[3] = [1.0, 2.0, 3.0];
          _ = vals;
        END
      CLEAR
    end

    let(:zig) { ZigTranspiler.new.transpile(code) }

    it "emits a raw Zig array literal [N]T{...} instead of makeList" do
      expect(zig).to include("[3]f64{ 1.0, 2.0, 3.0 }")
    end

    it "does NOT emit makeList for a stack-fixed array" do
      expect(zig).not_to include("CheatLib.makeList")
    end

    it "does NOT emit frameAlloc for a stack-fixed array" do
      expect(zig).not_to include("frameAlloc")
    end

    it "works for a two-element Number array" do
      two_code = <<~CLEAR
        FN use_two_array() RETURNS Void ->
          ns: Number[2] = [10.0, 20.0];
          _ = ns;
        END
      CLEAR
      two_zig = ZigTranspiler.new.transpile(two_code)
      expect(two_zig).to include("[2]f64{")
      expect(two_zig).not_to include("makeList")
    end

    it "still emits makeList for dynamic arrays without fixed annotation" do
      dyn_code = <<~CLEAR
        FN use_dyn() RETURNS Void ->
          vals: Number[] = [1.0, 2.0, 3.0];
          _ = vals;
        END
      CLEAR
      dyn_zig = ZigTranspiler.new.transpile(dyn_code)
      expect(dyn_zig).to include("CheatLib.makeList")
    end
  end

  # ===================================================================

  # ===================================================================
  # FOR range loop
  # ===================================================================
  describe "FOR range loop" do
    it "transpiles inclusive FOR loop (..=)" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Int64 ->
          MUTABLE sum: Int64 = 0;
          FOR i IN (1_i64..=5_i64) DO
            sum += i;
          END
          RETURN sum;
        END
      CLEAR
      expect(zig).to match(/__for_\d+ <= 5/)
      expect(zig).to match(/const i: i64 = __for_\d+/)
    end

    it "transpiles exclusive FOR loop (..<)" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Int64 ->
          MUTABLE sum: Int64 = 0;
          FOR i IN (0_i64..<5_i64) DO
            sum += i;
          END
          RETURN sum;
        END
      CLEAR
      expect(zig).to match(/__for_\d+ < 5/)
    end

    it "rejects non-Int64 range bounds" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            FOR i IN (1.0..=10.0) DO
              RETURN;
            END
            RETURN;
          END
        CLEAR
      }.to raise_error(/FOR range start must be Int64/)
    end

    it "loop variable is immutable" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            FOR i IN (0_i64..<10_i64) DO
              i = 5_i64;
            END
            RETURN;
          END
        CLEAR
      }.to raise_error(/immutable|cannot reassign/i)
    end

    it "loop variable is visible in body" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Int64 ->
          MUTABLE sum: Int64 = 0;
          FOR i IN (0_i64..<3_i64) DO
            sum += i;
          END
          RETURN sum;
        END
      CLEAR
      expect(zig).to include("sum = (sum + i)")
    end

    it "iterates over a fixed array" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Int64 ->
          items: Int64[3] = [1_i64, 2_i64, 3_i64];
          MUTABLE sum: Int64 = 0;
          FOR x IN items DO
            sum += x;
          END
          RETURN sum;
        END
      CLEAR
      expect(zig).to include("for (&items) |x|")
    end

    it "iterates over a list" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Void ->
          MUTABLE nums: Int64[]@list = [];
          nums.append(1_i64);
          MUTABLE sum: Int64 = 0;
          FOR n IN nums DO
            sum += n;
          END
          RETURN;
        END
      CLEAR
      expect(zig).to include("for (nums.items) |n|")
    end

    it "rejects non-collection FOR IN" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            x: Int64 = 5_i64;
            FOR i IN x DO
              RETURN;
            END
            RETURN;
          END
        CLEAR
      }.to raise_error(/requires an array, list, or map/)
    end

    it "supports ..<=  (legacy inclusive syntax)" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS Int64 ->
          MUTABLE sum: Int64 = 0;
          FOR i IN (1_i64..<=5_i64) DO
            sum += i;
          END
          RETURN sum;
        END
      CLEAR
      expect(zig).to match(/__for_\d+ <= 5/)
    end
  end

  # ===================================================================

  describe "WHILE loop in MATCH branch with struct bindings" do
    it "allows WHILE loops when struct MATCH binding is not used inside the loop" do
      src = <<~CLEAR
        UNION Data {
            Pair { x: Int64, y: Int64 }
        }
        FN main() RETURNS Void ->
            d = Data.Pair{ x: 1, y: 2 };
            MATCH d START
                Data.Pair AS p ->
                    px = p.x;
                    py = p.y;
                    MUTABLE sum: Int64 = 0;
                    MUTABLE i: Int64 = 0;
                    WHILE i < px DO
                        sum += py;
                        i += 1;
                    END,
                DEFAULT -> PASS;
            END
        END
      CLEAR
      expect { run(src) }.not_to raise_error
    end
  end

  describe "String interpolation" do
    it "annotates interpolated string without error and produces String type" do
      src = 'FN f() RETURNS Void -> name = "World"; greeting: String = "Hello, ${name}!"; RETURN; END'
      expect { run(src) }.not_to raise_error
    end

    it "annotates without error when interpolating expressions" do
      src = <<~CLEAR
        FN f(x: Int64) RETURNS String ->
          RETURN "value: \${x.toString()}";
        END
      CLEAR
      expect { run(src) }.not_to raise_error
    end

    it "emits Zig concat for interpolated string" do
      src = <<~CLEAR
        FN f(name: String) RETURNS String ->
          result = "Hello, \${name}!";
          RETURN result;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(src)
      expect(zig).to include("CheatLib.concat")
      expect(zig).to include("Hello, ")
    end
  end
end

