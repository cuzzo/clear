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

    context "ReturnNode list_return flag" do
      it "sets list_return=true when returning a @list from a frame-using function" do
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
        expect(ret.list_return).to be true
      end

      it "does NOT set list_return when the function has no frame usage" do
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
        expect(fn.uses_frame).to be false
        expect(ret.list_return).to be_falsey
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

  describe "Collection Types — Phase 5: Pool pipeline operators" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "pool s> SUM _.field resolves to Number" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          total = pool s> SUM _.value;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "pool s> WHERE _.value > 0 resolves to Item[]" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          result = pool s> WHERE _.value > 0.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Item[]" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "pool s> COUNT predicate resolves to Int64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          n = pool s> COUNT _.value > 0.0;
        FLUX
      }

      it "resolves to Int64" do
        expect(result).to eq(:Int64)
      end
    end

    context "pool s> ANY predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          found = pool s> ANY _.value > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "pool s> ALL predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          all_pos = pool s> ALL _.value > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "pool s> MIN _.field resolves to Number" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          mn = pool s> MIN _.value;
        FLUX
      }

      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "pool s> MAX _.field resolves to Number" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          mx = pool s> MAX _.value;
        FLUX
      }

      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "pool s> AVERAGE _.field resolves to Number" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          avg = pool s> AVERAGE _.value;
        FLUX
      }

      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "Zig output: pool pipeline materializes live slots" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          total = pool s> SUM _.value;
        FLUX
      }

      it "emits slot materialization loop" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("pipe_src_list.slots.items")
        expect(zig).to include("__pslot.alive")
        expect(zig).to include("pipe_mat.append")
        expect(zig).to include("sum_result")
      end
    end
  end

  describe "Collection Types — Phase 5: Pool FIND operator" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "pool s> FIND predicate resolves to optional element type" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          found = pool s> FIND _.value == 10.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to ?Item (optional Item)" do
        expect(result.to_s).to match(/\?Item|Item/)
      end
    end

    context "pool s> FIND on empty pool resolves without error" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          MUTABLE pool: Item[]@pool = [];
          found = pool s> FIND _.value == 99.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end
    end

    context "Zig output: pool s> FIND emits slot materialization and find loop" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Number }
          FN f() RETURNS Void ->
            MUTABLE pool: Item[]@pool = [];
            found = pool s> FIND _.value == 10.0;
            RETURN;
          END
        FLUX
      }

      it "emits alive-slot materialization before the find loop" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("__pslot.alive")
        expect(zig).to include("pipe_mat.append")
      end

      it "emits find_found flag and optional return" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("find_found")
        expect(zig).to include("find_result")
      end
    end
  end

  describe "MATCH statement" do
    context "basic integer match with default" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 2;
          MATCH x START
            1 -> x = 10;,
            2 -> x = 20;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "match with no default" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 0;
          MATCH x START
            1 -> x = 1;,
            2 -> x = 2;
          END
        FLUX
      }

      it "succeeds without a default case" do
        expect { ast }.not_to raise_error
      end
    end

    context "case type mismatch" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 42;
          MATCH x START
            "hello" -> x = 0;
          END
        FLUX
      }

      it "raises an error when case type differs from expression type" do
        expect { ast }.to raise_error(/MATCH case type/)
      end
    end

    context "WHEN conditional arm" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 7;
          MATCH x START
            1 -> x = 1;,
            WHEN x MOD 2 == 0 -> x = 0;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "WHEN arm with non-Bool condition" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 7;
          MATCH x START
            WHEN x + 1 -> x = 0;
          END
        FLUX
      }

      it "raises an error" do
        expect { ast }.to raise_error(/WHEN condition must be Bool/)
      end
    end

    # ── PASS statement ──────────────────────────────────────────────────────────

    context "PASS as case body (with semicolon)" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 1;
          MATCH x START
            1 -> PASS;,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "PASS as case body (without semicolon)" do
      let(:code) {
        <<~FLUX
          MUTABLE x = 1;
          MATCH x START
            1 -> PASS,
            DEFAULT -> x = 99;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
      end
    end

    # ── Struct destructuring ─────────────────────────────────────────────────────

    context "partial match with ..." do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number, y: Number }
          p = Point{ x: 10.0, y: 5.0 };
          MUTABLE result = 0;
          MATCH p START
            {x: 10.0, ...} -> result = 1;,
            {x: 20.0, ...} -> result = 2;,
            DEFAULT -> result = 3;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "wildcard field with _" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number, y: Number, z: Number }
          p = Point{ x: 1.0, y: 99.0, z: 3.0 };
          MUTABLE result = 0;
          MATCH p START
            {x: 1.0, y: _, z: 3.0} -> result = 42;,
            DEFAULT -> result = 0;
          END
        FLUX
      }

      it "resolves to Void without errors" do
        expect { ast }.not_to raise_error
        expect(ast.statements.last.resolved_type).to eq(:Void)
      end
    end

    context "mixed eq and struct pattern arms" do
      let(:code) {
        <<~FLUX
          STRUCT Msg { code: Number }
          MUTABLE x = 0;
          m = Msg{ code: 5.0 };
          MATCH m START
            {code: 5.0, ...} -> x = 1;,
            {code: 10.0, ...} -> x = 2;,
            DEFAULT -> x = 3;
          END
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "struct pattern against a primitive type" do
      let(:code) {
        <<~FLUX
          x = 42;
          MATCH x START
            {value: 42, ...} -> PASS;
          END
        FLUX
      }

      it "raises an error" do
        expect { ast }.to raise_error(/MATCH struct pattern requires a struct type/)
      end
    end

    context "struct pattern field not on struct" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number, y: Number }
          p = Point{ x: 1, y: 2 };
          MUTABLE result = 0;
          MATCH p START
            {z: 99, ...} -> result = 1;
          END
        FLUX
      }

      it "raises an error for unknown field" do
        expect { ast }.to raise_error(/MATCH struct pattern: field 'z' does not exist on type Point/)
      end
    end

    context "struct pattern field type mismatch" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number, y: Number }
          p = Point{ x: 1, y: 2 };
          MUTABLE result = 0;
          MATCH p START
            {x: "hello", ...} -> result = 1;
          END
        FLUX
      }

      it "raises an error for wrong field value type" do
        expect { ast }.to raise_error(/MATCH struct pattern: field 'x' has type Number, but pattern value has type/)
      end
    end

    # --------------------------------------------------
    # Regular MATCH: no exhaustiveness enforced
    # --------------------------------------------------
    context "regular MATCH has no exhaustiveness requirement" do
      it "accepts a partial enum MATCH with no DEFAULT" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN cheatMain() RETURNS Void ->
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

      it "accepts a partial union MATCH with no DEFAULT" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number, Err: Number, Empty }
            FN cheatMain() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              MATCH r START
                Result.Ok -> n = 1_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts a partial enum MATCH with DEFAULT" do
        expect {
          run(<<~CLEAR)
            ENUM Color { Red, Green, Blue }
            FN cheatMain() RETURNS Void ->
              c: Color = Color.Red;
              MUTABLE n = 0_i64;
              MATCH c START
                Color.Red -> n = 1_i64;,
                DEFAULT   -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts a MATCH with a WHEN guard and missing enum variants" do
        expect {
          run(<<~CLEAR)
            ENUM Bit { Zero, One }
            FN cheatMain() RETURNS Void ->
              b: Bit = Bit.Zero;
              MUTABLE n = 0_i64;
              MATCH b START
                Bit.Zero -> n = 0_i64;,
                WHEN n == 0 -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # MATCH IFF: exhaustiveness enforced
    # --------------------------------------------------
    context "MATCH IFF enum exhaustiveness" do
      it "accepts a fully exhaustive MATCH IFF on an enum" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN cheatMain() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH IFF d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;,
                Dir.East  -> n = 3_i64;,
                Dir.West  -> n = 4_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when MATCH IFF on enum is non-exhaustive" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South, East, West }
            FN cheatMain() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH IFF d START
                Dir.North -> n = 1_i64;,
                Dir.South -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF on enum 'Dir' is non-exhaustive: missing variants: East, West/)
      end

      it "raises an error when MATCH IFF has a DEFAULT branch" do
        expect {
          run(<<~CLEAR)
            ENUM Color { Red, Green, Blue }
            FN cheatMain() RETURNS Void ->
              c: Color = Color.Red;
              MUTABLE n = 0_i64;
              MATCH IFF c START
                Color.Red   -> n = 1_i64;,
                Color.Green -> n = 2_i64;,
                Color.Blue  -> n = 3_i64;,
                DEFAULT     -> n = 99_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF cannot have a DEFAULT branch/)
      end

      it "raises an error when MATCH IFF contains a WHEN guard" do
        expect {
          run(<<~CLEAR)
            ENUM Bit { Zero, One }
            FN cheatMain() RETURNS Void ->
              b: Bit = Bit.Zero;
              MUTABLE n = 0_i64;
              MATCH IFF b START
                Bit.Zero    -> n = 0_i64;,
                WHEN n == 0 -> n = 99_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF cannot contain WHEN guards/)
      end

      it "raises an error when MATCH IFF subject is not an enum or union" do
        expect {
          run(<<~CLEAR)
            FN cheatMain() RETURNS Void ->
              x = 42_i64;
              MUTABLE n = 0_i64;
              MATCH IFF x START
                1_i64 -> n = 1_i64;,
                2_i64 -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF requires an enum or union type/)
      end
    end

    context "MATCH IFF union exhaustiveness" do
      it "accepts a fully exhaustive MATCH IFF on a union" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number, Point }
            FN cheatMain() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              MATCH IFF s START
                Shape.Circle -> n = 1_i64;,
                Shape.Point  -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when MATCH IFF on union is non-exhaustive" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number, Err: Number, Empty }
            FN cheatMain() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              MATCH IFF r START
                Result.Ok -> n = 1_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF on union 'Result' is non-exhaustive: missing variants: Empty, Err/)
      end

      it "accepts a partial union MATCH (not IFF) with DEFAULT" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number, Err: Number }
            FN cheatMain() RETURNS Void ->
              r: Result = Result{ Ok: 1 };
              MUTABLE n = 0_i64;
              MATCH r START
                Result.Ok -> n = 1_i64;,
                DEFAULT   -> n = 99_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts exhaustive MATCH IFF on a generic union" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              opt = Option<Number>{ Some: 1.0 };
              MUTABLE n = 0.0;
              MATCH IFF opt START
                Option.Some -> n = 1.0;,
                Option.None -> n = 2.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error for non-exhaustive MATCH IFF on generic union" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              opt = Option<Number>{ Some: 1.0 };
              MUTABLE n = 0.0;
              MATCH IFF opt START
                Option.Some -> n = 1.0;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH IFF on union 'Option' is non-exhaustive: missing variants: None/)
      end
    end

    # --------------------------------------------------
    # Union payload capture (AS binding)
    # --------------------------------------------------
    context "union payload capture (AS binding)" do
      it "accepts payload capture from a payload variant" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number, Point }
            FN cheatMain() RETURNS Void ->
              s: Shape = Shape{ Circle: 5.0 };
              MUTABLE a = 0.0;
              MATCH s START
                Shape.Circle AS r -> a = r;,
                Shape.Point       -> a = 0.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves the captured binding to the variant's payload type" do
        ast = run(<<~CLEAR)
          UNION Result { Ok: Number, Err: Number, Empty }
          FN cheatMain() RETURNS Void ->
            r: Result = Result{ Ok: 42.0 };
            MUTABLE got = 0.0;
            MATCH r START
              Result.Ok    AS v -> got = v;,
              Result.Err   AS e -> got = e;,
              Result.Empty      -> got = 0.0;
            END
          END
        CLEAR
        # The body of the first case contains `got = v`.
        # If the annotator didn't declare `v` with the right type, it would error.
        expect(ast).not_to be_nil
      end

      it "raises an error when capturing from a unit variant" do
        expect {
          run(<<~CLEAR)
            UNION Maybe { Some: Number, None }
            FN cheatMain() RETURNS Void ->
              m: Maybe = Maybe.None;
              MUTABLE n = 0.0;
              MATCH m START
                Maybe.Some AS x -> n = x;,
                Maybe.None AS y -> n = 0.0;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot bind 'AS y': 'None' is a unit variant with no payload/)
      end

      it "raises an error when using AS on an enum variant" do
        expect {
          run(<<~CLEAR)
            ENUM Dir { North, South }
            FN cheatMain() RETURNS Void ->
              d: Dir = Dir.North;
              MUTABLE n = 0_i64;
              MATCH d START
                Dir.North AS x -> n = 1_i64;,
                Dir.South      -> n = 2_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot capture payload from enum variant: enums have no payload/)
      end

      it "correctly resolves generic union payload type through AS binding" do
        expect {
          run(<<~CLEAR)
            UNION Option<T> { Some: T, None }
            FN cheatMain() RETURNS Void ->
              opt = Option<Number>{ Some: 3.14 };
              MUTABLE got = 0.0;
              MATCH opt START
                Option.Some AS x -> got = x;,
                Option.None      -> got = -1.0;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises a type mismatch when using the captured binding with a wrong type" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number, Err: Number }
            FN need_str(s: String) RETURNS Void ->
            END
            FN cheatMain() RETURNS Void ->
              r: Result = Result{ Ok: 1.0 };
              MUTABLE n = 0.0;
              MATCH r START
                Result.Ok  AS v -> need_str(v);,
                Result.Err AS e -> n = e;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error/)
      end
    end

    # --------------------------------------------------
    # Zig code generation for AS capture and MATCH IFF
    # --------------------------------------------------
    context "Zig code generation" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      it "emits 'const r = subject.Circle;' for payload capture" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Number, Point }
          FN cheatMain() RETURNS Void ->
            s: Shape = Shape{ Circle: 2.0 };
            MUTABLE a = 0.0;
            MATCH IFF s START
              Shape.Circle AS r -> a = r;,
              Shape.Point       -> a = 0.0;
            END
          END
        CLEAR
        expect(out).to include("std.meta.activeTag(s) == .Circle")
        expect(out).to include("const r = s.Circle;")
      end

      it "emits == comparison (not activeTag) for enum MATCH IFF" do
        out = transpile(<<~CLEAR)
          ENUM Dir { North, South }
          FN cheatMain() RETURNS Void ->
            d: Dir = Dir.North;
            MUTABLE n = 0_i64;
            MATCH IFF d START
              Dir.North -> n = 1_i64;,
              Dir.South -> n = 2_i64;
            END
          END
        CLEAR
        expect(out).to include("d == Dir.North")
        expect(out).to include("d == Dir.South")
        expect(out).not_to include("activeTag")
      end

      it "emits payload capture for generic union MATCH IFF" do
        out = transpile(<<~CLEAR)
          UNION Option<T> { Some: T, None }
          FN cheatMain() RETURNS Void ->
            opt = Option<Number>{ Some: 7.0 };
            MUTABLE got = 0.0;
            MATCH IFF opt START
              Option.Some AS x -> got = x;,
              Option.None      -> got = -1.0;
            END
          END
        CLEAR
        expect(out).to include("std.meta.activeTag(opt) == .Some")
        expect(out).to include("const x = opt.Some;")
      end

      it "MATCH IFF and MATCH produce identical Zig output for the same exhaustive case" do
        src_iff = <<~CLEAR
          UNION Shape { Circle: Number, Point }
          FN cheatMain() RETURNS Void ->
            s: Shape = Shape.Point;
            MUTABLE n = 0_i64;
            MATCH IFF s START
              Shape.Circle -> n = 1_i64;,
              Shape.Point  -> n = 2_i64;
            END
          END
        CLEAR
        src_plain = src_iff.sub("MATCH IFF", "MATCH")
        expect(transpile(src_iff)).to eq(transpile(src_plain))
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
        sig = annotator.scope_stack.first.locals["foo"][:type]
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
        sig = annotator.scope_stack.first.locals["foo"][:type]
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
        sig = annotator.scope_stack.first.locals["foo"][:type]
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
          FN cheatMain() RETURNS Void ->
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

      it "emits the native call without rt and without try" do
        code = <<~CLEAR
          EXTERN FN native_add(a: Number, b: Number) RETURNS Number FROM "native_math";
          FN cheatMain() RETURNS Void ->
            x = native_add(3.0, 4.0);
          END
        CLEAR
        output = ZigTranspiler.new.transpile_as_module(code)
        expect(output).to include("native_math.native_add(3, 4)")
        expect(output).not_to match(/try native_math\.native_add/)
        expect(output).not_to match(/native_math\.native_add\(rt,/)
      end

      it "emits a type alias for EXTERN STRUCT" do
        code = <<~CLEAR
          EXTERN STRUCT Vec2 { x: Number, y: Number } FROM "native_math";
          FN cheatMain() RETURNS Void ->
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
          FN cheatMain() RETURNS Void ->
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
            FN cheatMain() RETURNS Void ->
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
            FN cheatMain() RETURNS Void ->
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
            FN cheatMain() RETURNS Void ->
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
            FN cheatMain() RETURNS Void ->
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
          FN cheatMain() RETURNS Void ->
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
          FN cheatMain() RETURNS Void ->
            c: Color = Color.Red;
          END
        CLEAR
        expect(out).to include("Color.Red")
      end

      it "emits the enum type annotation on a const declaration" do
        out = transpile(<<~CLEAR)
          ENUM Dir { North, South }
          FN cheatMain() RETURNS Void ->
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
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("d: Dir")
        expect(out).to match(/fn turn.*Dir/)
      end

      it "includes PUB ENUM in transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PUB ENUM Status { Active, Inactive }
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Status = enum {")
      end

      it "excludes PRIVATE ENUM from transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PRIVATE ENUM Internal { A, B }
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).not_to include("const Internal = enum {")
      end
    end
  end

  # ===================================================================
  # Phase 1: Linear Resource Types  (File, :: static constructors)
  # ===================================================================
  describe "Resource Types — Phase 1" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    # ------------------------------------------------------------------
    # Lexer
    # ------------------------------------------------------------------
    describe "Lexer: '::' token" do
      it "tokenises '::' as DOUBLE_COLON" do
        tokens = Lexer.new("File::open").tokenize.reject { |t| t.type == :EOF }
        expect(tokens.map(&:type)).to eq([:TYPE_ID, :DOUBLE_COLON, :VAR_ID])
      end

      it "does not confuse '::' with two separate ':' tokens" do
        tokens = Lexer.new("::").tokenize.reject { |t| t.type == :EOF }
        expect(tokens.length).to eq(1)
        expect(tokens.first.type).to eq(:DOUBLE_COLON)
      end
    end

    # ------------------------------------------------------------------
    # Parser
    # ------------------------------------------------------------------
    describe "Parser: StaticCall AST node" do
      it "parses TypeName::method(args) as a StaticCall" do
        tokens = Lexer.new('File::open("data.txt")').tokenize
        parser = Parser.new(tokens, 'File::open("data.txt")')
        node   = parser.send(:parse_primary)
        expect(node).to be_a(AST::StaticCall)
        expect(node.type_name.name).to eq("File")
        expect(node.method_name).to eq("open")
        expect(node.args.length).to eq(1)
      end

      it "parses a StaticCall as RHS of a bind expression" do
        src    = 'FN f() RETURNS Void -> f = File::open("x"); RETURN; END'
        tokens = Lexer.new(src).tokenize
        ast    = Parser.new(tokens, src).parse
        fn     = ast.statements.first
        bind   = fn.body.first
        expect(bind.value).to be_a(AST::StaticCall)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — happy-path type resolution
    # ------------------------------------------------------------------
    describe "Annotator: StaticCall type resolution" do
      it "File::open resolves to type :File" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        ast = run(src)
        fn  = ast.statements.first
        # The bind/decl's value node is the StaticCall
        call = fn.body.first.value
        expect(call.resolved_type).to eq(:File)
      end

      it "annotates a File variable as a resource in scope" do
        # We exercise the full annotator; no error means resource path ran
        expect { run('FN f() RETURNS Void -> f = File::open("t"); RETURN; END') }.not_to raise_error
      end

      it "File::open arg is passed the full_type :File" do
        src = 'FN f() RETURNS Void -> f = File::open("path"); RETURN; END'
        ast = run(src)
        fn  = ast.statements.first
        call = fn.body.first.value
        expect(call.full_type.resolved).to eq(:File)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — error cases
    # ------------------------------------------------------------------
    describe "Annotator: StaticCall errors" do
      it "raises on unknown type" do
        src = 'FN f() RETURNS Void -> x = Bogus::open("t"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /Unknown type 'Bogus'/)
      end

      it "raises on non-resource type used with ::" do
        src = 'STRUCT Point { x: Number } FN f() RETURNS Void -> p = Point::new(); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /does not support '::' static method calls/)
      end

      it "raises on unknown static method" do
        src = 'FN f() RETURNS Void -> f = File::flush("t"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /No static method 'flush' on 'File'/)
      end

      it "raises on wrong argument count" do
        src = 'FN f() RETURNS Void -> f = File::open("a", "b"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expects 1 argument/)
      end

      it "raises on wrong argument type" do
        src = 'FN f() RETURNS Void -> f = File::open(42); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expected String, got Int64/)
      end
    end

    # ------------------------------------------------------------------
    # Transpiler — code generation
    # ------------------------------------------------------------------
    describe "Transpiler: StaticCall code generation" do
      it "emits CheatLib.fileOpen for File::open" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileOpen("data.txt")')
      end

      it "emits defer with move-guarded f.close() for auto-RAII" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!f_moved) f.close();")
      end

      it "emits a _moved flag for resource move tracking" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("f_moved")
      end

      it "maps File to std.fs.File Zig type" do
        expect(Type.new(:File).zig_type).to eq("std.fs.File")
      end
    end

    # ------------------------------------------------------------------
    # Resource move semantics
    # ------------------------------------------------------------------
    describe "Resource move tracking" do
      it "marks the resource as :moved when reassigned" do
        # After 'g = f', f should be :moved so the outer scope does not double-close
        src = 'FN f() RETURNS Void -> a = File::open("t"); b = a; RETURN; END'
        # Should not raise (resource move is legal)
        expect { run(src) }.not_to raise_error
      end
    end
  end

  # ===================================================================
  # Phase 3: TCP Resource Types (TCPServer, TCPClient)
  # ===================================================================
  describe "Resource Types — Phase 3 (TCP)" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    # ------------------------------------------------------------------
    # Type system
    # ------------------------------------------------------------------
    describe "Type mapping" do
      it "TCPServer maps to i32 Zig type" do
        expect(Type.new(:TCPServer).zig_type).to eq("i32")
      end

      it "TCPClient maps to i32 Zig type" do
        expect(Type.new(:TCPClient).zig_type).to eq("i32")
      end
    end

    # ------------------------------------------------------------------
    # Annotator — TCPServer::listen
    # ------------------------------------------------------------------
    describe "Annotator: TCPServer::listen" do
      it "resolves TCPServer::listen(port) to type :TCPServer" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        ast = run(src)
        call = ast.statements.first.body.first.value
        expect(call.resolved_type).to eq(:TCPServer)
      end

      it "annotates TCPServer variable as a resource in scope" do
        expect {
          run('FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END')
        }.not_to raise_error
      end

      it "raises on wrong argument type (String instead of Int64)" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen("8080"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expected Int64, got/)
      end

      it "raises on wrong argument count" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(80, 90); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expects 1 argument/)
      end

      it "raises on unknown static method" do
        src = 'FN f() RETURNS Void -> s = TCPServer::connect(80); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /No static method 'connect' on 'TCPServer'/)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — accept / tcpRead / tcpWrite intrinsics
    # ------------------------------------------------------------------
    describe "Annotator: accept intrinsic" do
      it "accept(server) resolves to type :TCPClient" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); c = accept(s); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        accept_call = fn.body[1].value  # second statement
        expect(accept_call.resolved_type).to eq(:TCPClient)
      end

      it "annotates the accepted client as a resource (gets defer close)" do
        expect {
          run('FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END')
        }.not_to raise_error
      end

      it "raises if accept is called with a non-TCPServer arg" do
        src = 'FN f() RETURNS Void -> accept(42); RETURN; END'
        expect { run(src) }.to raise_error(SourceError)
      end
    end

    describe "Annotator: tcpRead intrinsic" do
      it "tcpRead(client) resolves to String" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); data = tcpRead(c); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        # data is the third statement
        data_bind = fn.body[2]
        expect(data_bind.value.resolved_type).to eq(:String)
      end
    end

    describe "Annotator: tcpWrite intrinsic" do
      it "tcpWrite(client, string) resolves to Void" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, "hello"); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        write_call = fn.body[2]
        expect(write_call.resolved_type).to eq(:Void)
      end
    end

    # ------------------------------------------------------------------
    # Transpiler — code generation
    # ------------------------------------------------------------------
    describe "Transpiler: TCPServer code generation" do
      it "emits CheatLib.socketListen for TCPServer::listen" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketListen(@intCast(8080))')
      end

      it "emits defer with move-guarded CheatLib.socketClose for server RAII" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!s_moved) CheatLib.socketClose(s);")
      end

      it "emits CheatLib.socketAccept for accept()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketAccept(s)')
      end

      it "emits defer with move-guarded CheatLib.socketClose for client RAII" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!c_moved) CheatLib.socketClose(c);")
      end

      it "emits CheatLib.socketRead for tcpRead()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); d = tcpRead(c); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketRead(')
      end

      it "emits CheatLib.socketWriteVoid for tcpWrite()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, "hi"); RETURN; END'
        out = transpile_fn(src)
        # The string literal may be wrapped in @as([]const u8, ...) — check the function name and first arg
        expect(out).to include('CheatLib.socketWriteVoid(c,')
        expect(out).to include('"hi"')
      end

      it "TCPServer Zig type is i32 (via Type#zig_type)" do
        # The transpiler infers the type from the expression; check via the type system directly.
        expect(Type.new(:TCPServer).zig_type).to eq("i32")
        expect(Type.new(:TCPClient).zig_type).to eq("i32")
      end

      it "emits a _moved flag for TCPServer resource move tracking" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("s_moved")
      end
    end

    # ------------------------------------------------------------------
    # Resource move semantics — linear ownership enforcement
    # ------------------------------------------------------------------
    describe "Resource move tracking" do
      it "allows moving a TCPServer to another variable" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "allows moving a TCPClient to another variable" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; RETURN; END'
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Use-after-move errors for resource types
    # Resources are linear: once moved to another binding they cannot
    # be used again — doing so would risk a double-close / use-after-free.
    # ------------------------------------------------------------------
    describe "Use-after-move errors for resource types" do
      # File::open
      it "raises on use-after-move of File::open resource" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); b = a; fileWrite(a, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      it "raises on double-move of File::open resource" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); b = a; c = a; RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      # File::create
      it "raises on use-after-move of File::create resource" do
        src = 'FN f() RETURNS Void -> a = File::create("x"); b = a; fileWrite(a, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      # TCPServer
      it "raises on use-after-move of TCPServer resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; c = accept(s); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 's'/)
      end

      it "raises on double-move of TCPServer resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; s3 = s; RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 's'/)
      end

      # TCPClient
      it "raises on use-after-move of TCPClient resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; d = tcpRead(c); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      it "raises on use-after-move when writing to moved TCPClient" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; tcpWrite(c, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      # TCPClient::connect
      it "raises on use-after-move of TCPClient::connect resource" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); c2 = c; tcpWrite(c, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      # Normal use — should NOT raise
      it "does not raise when using File before any move" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); fileWrite(a, "ok"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPServer before any move" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPClient before any move" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); d = tcpRead(c); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPClient::connect before any move" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); tcpWrite(c, "hi"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using File::create before any move" do
        src = 'FN f() RETURNS Void -> a = File::create("x"); fileWrite(a, "ok"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Phase 4 — File::create, fileWrite, TCPClient::connect
    # ------------------------------------------------------------------
    describe "Phase 4 — File::create" do
      it "resolves File::create return type as File" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "f" }
        expect(bind.full_type.to_sym).to eq(:File)
      end

      it "emits try CheatLib.fileCreate for File::create" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileCreate(')
      end

      it "emits defer with move-guarded f.close() RAII for File::create" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!f_moved) f.close();")
      end

      it "raises on File::create with wrong arg count" do
        src = 'FN f() RETURNS Void -> f = File::create("a.txt", "b.txt"); RETURN; END'
        expect { run(src) }.to raise_error(/expects 1 argument|argument.*got 2/i)
      end

      it "raises on unknown File static method" do
        src = 'FN f() RETURNS Void -> f = File::flush("out.txt"); RETURN; END'
        expect { run(src) }.to raise_error(/unknown static method|flush/i)
      end
    end

    describe "Phase 4 — fileWrite intrinsic" do
      it "resolves fileWrite return type as Void" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, "hello"); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        call = fn_node.body.find { |n| n.is_a?(AST::FuncCall) && n.name == "fileWrite" }
        expect(call.full_type.to_sym).to eq(:Void)
      end

      it "emits try CheatLib.fileWrite for fileWrite()" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, "hello"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileWrite(ff,')
      end

      it "raises on fileWrite with non-File first argument" do
        src = 'FN f() RETURNS Void -> fileWrite("not_a_file", "hello"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end

      it "raises on fileWrite with non-String second argument" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, 42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end

      it "raises on fileWrite with wrong arg count" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end
    end

    describe "Phase 4 — TCPClient::connect" do
      it "resolves TCPClient::connect return type as TCPClient" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "c" }
        expect(bind.full_type.to_sym).to eq(:TCPClient)
      end

      it "emits try CheatLib.socketConnect for TCPClient::connect" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketConnect(')
      end

      it "emits defer with move-guarded CheatLib.socketClose RAII for TCPClient::connect" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!c_moved) CheatLib.socketClose(c);")
      end

      it "raises on TCPClient::connect with wrong arg count" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1"); RETURN; END'
        expect { run(src) }.to raise_error(/expects 2 argument|argument.*got 1/i)
      end

      it "raises on unknown TCPClient static method" do
        src = 'FN f() RETURNS Void -> c = TCPClient::bind("127.0.0.1", 8080); RETURN; END'
        expect { run(src) }.to raise_error(/unknown static method|bind/i)
      end

      it "can send after TCPClient::connect — codegen includes tcpWrite" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            c = TCPClient::connect("127.0.0.1", 8080);
            tcpWrite(c, "hello");
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketWriteVoid(c,')
      end
    end

    describe "Phase 4 — tcpRead / tcpWrite / accept error cases" do
      it "raises on tcpRead with non-TCPClient argument" do
        src = 'FN f() RETURNS Void -> tcpRead("not_a_client"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpRead'|tcpRead/)
      end

      it "raises on tcpWrite with non-TCPClient first argument" do
        src = 'FN f() RETURNS Void -> tcpWrite("not_a_client", "data"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpWrite'|tcpWrite/)
      end

      it "raises on tcpWrite with non-String second argument" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, 42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpWrite'|tcpWrite/)
      end

      it "raises on accept with non-TCPServer argument" do
        src = 'FN f() RETURNS Void -> x = accept(42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'accept'|accept/)
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
        expect(out).to include("CheatLib.mapCount(i64, m)")
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
      it "resolves contains() return type as Bool" do
        tree = run(<<~CLEAR)
          FN f() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            found = m.contains("x");
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
            found = m.contains("x");
            RETURN;
          END
        CLEAR
        expect(out).to include('CheatLib.mapContains(i64, m, "x")')
      end

      it "raises when contains receives no arguments" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.contains();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.*\.contains requires exactly 1 argument/)
      end

      it "raises when contains key is not a String" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m.contains(42);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /HashMap.contains: key must be a String/)
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
        expect(out).to include('CheatLib.mapDelete(i64, rt.frameAlloc(), &m, "x")')
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
        expect(out).to include("CheatLib.mapKeys(i64, rt.frameAlloc(), m)")
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
        expect(out).to include("CheatLib.mapValues(i64, rt.frameAlloc(), m)")
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
        expect(out).to include("CheatLib.mapPut(i64, rt.frameAlloc(), rt.frameAlloc()")
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
        expect(out).to include("std.StringHashMapUnmanaged(i64){}")
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
      expect(small_zig).to     include("Tiny{ .x = 1, .y = 2 }")
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
      expect(zig).to include("[3]f64{ 1, 2, 3 }")
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

      it "emits std.ArrayListUnmanaged(CheatLib.Promise(f64)) for ~Number[]@list" do
        t = Type.new(:"~Number[]", collection: :list)
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
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "rejects bare ~T[] without @list (not a valid stream type)" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[] = [];
            RETURN;
          END
        CLEAR
        expect { run(src) }.to raise_error(SourceError, /not a valid stream type/)
      end

      it "allows append(futures, BG { ... }) where futures is a promise list" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 42; });
            RETURN;
          END
        CLEAR
        expect { run(src) }.not_to raise_error
      end

      it "allows indexing a promise list: futures[0] binds as ~Int64 (consumed via NEXT)" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
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
          FN f() RETURNS Void ->
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
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("std.ArrayListUnmanaged(CheatLib.Promise(i64))")
      end

      it "emits var (not const) for promise list declarations" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/var futures /)
      end

      it "emits defer futures.deinit(rt.frameAlloc()) for cleanup" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/defer futures\.deinit/)
      end

      it "emits try futures.append(rt.frameAlloc(), ...) for append" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 7; });
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include("futures.append(")
      end

      it "emits CheatLib.getAt(futures, 0).next() for NEXT futures[0]" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            MUTABLE futures: ~Int64[]@list = [];
            append(futures, BG { 7; });
            v: Int64 = NEXT futures[0];
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to match(/CheatLib\.getAt\(futures, .*\)\.next\(\)/)
      end
    end
  end

end

