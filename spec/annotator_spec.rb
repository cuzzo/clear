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

    context "String[] Handling (Heap vs Stack)" do
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
          FN get_str() RETURNS String[] -> RETURN %"hi"; END
          get_str();
        FLUX
        expect(get_last_type(code)).to eq(:"String[]")
      end

      it "resolves to the inferred return type" do
        code = <<~FLUX
          FN get_inferred() -> RETURN 10; END -- Infers Number
          get_inferred();
        FLUX
        expect(get_last_type(code)).to eq(:Number)
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
          expect(result).to eq(:Number)
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
          expect(result).to eq(:Number)
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
          expect(result).to eq(:Number)
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
            list : Number[1] = [1, 2, 3];
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
          expect(result).to eq(:"Number[3]")
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
          expect(result).to eq(:"Number[2][2]")
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
          expect { ast }.to raise_error(/Argument .* expects Point, got Number/i)
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
          -- split returns a List of Strings (String[][])
          parts = data.split(",");
        FLUX
      }
      it "resolves split to a List of Strings" do
        expect(result).to eq(:"String[][]")
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
        expect(result).to eq(:"String[]")
      end
    end

    context "String Manipulation (trim & chaining)" do
      let(:code) {
        <<~FLUX
          -- trim returns a String slice (String[])
          clean = "  abc  ".trim();
        FLUX
      }
      it "resolves trim to a String slice" do
        expect(result).to eq(:"String[]")
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

  # ============================================================================
  # 2. Higher-Order Functions & SELECT
  # ============================================================================
  describe "Higher-Order Syntax (SELECT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic Projection: list s> SELECT _.method()" do
      let(:code) {
        <<~FLUX
          words: String[][] = ["a", "bb", "ccc"];
          -- Project List<String> -> List<Int64> using .length()
          lengths = words s> SELECT _.length();
        FLUX
      }

      it "infers the resulting list type based on the projection body" do
        # _.length() returns Int64, so result is Int64[]
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Chained Pipe: string s> split s> SELECT" do
      let(:code) {
        <<~FLUX
          raw = "apple,banana";
          -- 1. split returns String[][]
          -- 2. SELECT iterates Strings
          -- 3. _.length() returns Int64
          lengths = raw s> split(",") s> SELECT _.length();
        FLUX
      }

      it "correctly resolves types through the chain" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Struct/Hash Projection: list s> SELECT %{...}" do
      let(:code) {
        <<~FLUX
          nums = [10, 20];

          -- Create a List of HashMaps
          complex = nums s> SELECT %{
            "original": _,
            "doubled": _ * 2
          };
        FLUX
      }

      it "infers a List of HashMaps" do
        # The Hash contains Int64s (since _ is Int and 2 is Int inferred)
        # So it is HashMap<Int64>[]
        expect(result).to eq(:"HashMap<Number>[]")
      end
    end

    context "Array Projection: list s> SELECT [_]" do
      let(:code) {
        <<~FLUX
          nums = [1_i64, 2_i64];
          -- Wrap each item in a list -> [[1], [2]]
          nested = nums s> SELECT [_];
        FLUX
      }

      it "infers a List of Lists (2D Array)" do
        # Inner is Int64[1] (Stack array), wrapped in Heap Array
        # The annotator usually generalizes stack arrays to [] in higher types
        expect(result.to_s).to include("Int64")
        expect(result.to_s).to end_with("][]") # Int64[][] roughly
      end
    end

    context "Error Handling: Selecting on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> SELECT _ + 1;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2b. Higher-Order Functions: INDEX (Group By)
  # ============================================================================
  describe "Higher-Order Syntax (INDEX)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic INDEX: list s> INDEX _.field" do
      let(:code) {
        <<~FLUX
          STRUCT User { name: String[], age: Int64 }
          users = [
            User{ name: %"Alice", age: 30_i64 },
            User{ name: %"Bob", age: 30_i64 },
            User{ name: %"Charlie", age: 25_i64 }
          ];
          grouped = users s> INDEX _.age;
        FLUX
      }

      it "infers HashMap with array values" do
        # INDEX _.age returns HashMap<User[]> (grouped by age)
        expect(result).to eq(:"HashMap<User[]>")
      end
    end

    context "INDEX with string keys: list s> INDEX _.name" do
      let(:code) {
        <<~FLUX
          STRUCT Item { category: String[], price: Number }
          items = [
            Item{ category: %"food", price: 10 },
            Item{ category: %"electronics", price: 100 },
            Item{ category: %"food", price: 20 }
          ];
          byCategory = items s> INDEX _.category;
        FLUX
      }

      it "infers HashMap with string keys and array values" do
        expect(result).to eq(:"HashMap<Item[]>")
      end
    end

    context "Error Handling: INDEX on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> INDEX _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2c. Higher-Order Functions: REDUCE (Fold)
  # ============================================================================
  describe "Higher-Order Syntax (REDUCE)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic REDUCE: sum of numbers" do
      let(:code) {
        <<~FLUX
          nums = [1, 2, 3, 4, 5];
          sum = nums s> REDUCE(0) acc + _;
        FLUX
      }

      it "infers the accumulator type from initial value" do
        expect(result).to eq(:Number)
      end
    end

    context "REDUCE with struct field access" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [
            Item{ value: 10_i64 },
            Item{ value: 20_i64 },
            Item{ value: 30_i64 }
          ];
          total = items s> REDUCE(0_i64) acc + _.value;
        FLUX
      }

      it "infers Int64 from initial value" do
        expect(result).to eq(:Int64)
      end
    end

    context "Error Handling: REDUCE on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> REDUCE(0) acc + _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot REDUCE non-list type/)
      end
    end
  end

  # ============================================================================
  # 2d. Higher-Order Functions: ORDER_BY (Sort)
  # ============================================================================
  describe "Higher-Order Syntax (ORDER_BY)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic ORDER_BY: sort by field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { name: String[], value: Int64 }
          items = [
            Item{ name: %"c", value: 30_i64 },
            Item{ name: %"a", value: 10_i64 },
            Item{ name: %"b", value: 20_i64 }
          ];
          sorted = items s> ORDER_BY _.value;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "ORDER_BY with simple values" do
      let(:code) {
        <<~FLUX
          nums = [3_i64, 1_i64, 2_i64];
          sorted = nums s> ORDER_BY _;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Error Handling: ORDER_BY on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> ORDER_BY _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2e. Higher-Order Functions: LIMIT
  # ============================================================================
  describe "Higher-Order Syntax (LIMIT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic LIMIT: take first n items" do
      let(:code) {
        <<~FLUX
          nums = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64];
          first_three = nums s> LIMIT 3;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "LIMIT with structs" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [
            Item{ value: 10_i64 },
            Item{ value: 20_i64 },
            Item{ value: 30_i64 }
          ];
          limited = items s> LIMIT 2;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "Error Handling: LIMIT on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> LIMIT 5;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot LIMIT non-list type/)
      end
    end
  end

  # ============================================================================
  # 2f. Higher-Order Functions: UNNEST (Flatmap)
  # ============================================================================
  describe "Higher-Order Syntax (UNNEST)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic UNNEST: flatten nested arrays" do
      let(:code) {
        <<~FLUX
          STRUCT Container { values: Int64[] }
          containers = [
            Container{ values: [1_i64, 2_i64] },
            Container{ values: [3_i64, 4_i64] }
          ];
          flattened = containers s> UNNEST _.values;
        FLUX
      }

      it "returns the inner element type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "UNNEST with multiple containers" do
      let(:code) {
        <<~FLUX
          STRUCT Batch { nums: Number[] }
          batches = [
            Batch{ nums: [10, 20, 30] },
            Batch{ nums: [40] },
            Batch{ nums: [50, 60] }
          ];
          all_nums = batches s> UNNEST _.nums;
        FLUX
      }

      it "returns Number[]" do
        expect(result).to eq(:"Number[]")
      end
    end

    context "Error Handling: UNNEST on non-array field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [Item{ value: 10_i64 }];
          bad = items s> UNNEST _.value;
        FLUX
      }

      it "raises a semantic error suggesting SELECT" do
        expect { run(code) }.to raise_error(/UNNEST requires an array expression.*Use SELECT instead/)
      end
    end

    context "Error Handling: UNNEST on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> UNNEST _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot UNNEST non-list type/)
      end
    end
  end

  # ============================================================================
  # 2g. Higher-Order Functions: DISTINCT (Unique elements)
  # ============================================================================
  describe "Higher-Order Syntax (DISTINCT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic DISTINCT: unique elements by value" do
      let(:code) {
        <<~FLUX
          nums = [1, 2, 1, 3, 2, 4];
          unique = nums s> DISTINCT _;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Number[]")
      end
    end

    context "DISTINCT by struct field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { id: Int64, name: String[] }
          items = [
            Item{ id: 1_i64, name: %"a" },
            Item{ id: 2_i64, name: %"b" },
            Item{ id: 1_i64, name: %"c" }
          ];
          unique_by_id = items s> DISTINCT _.id;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "Error Handling: DISTINCT on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> DISTINCT _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot DISTINCT non-list type/)
      end
    end
  end

  describe "Affine Ownership & Move Semantics" do
    let(:preamble) {
      <<~FLUX
        STRUCT Config { id: Number }
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
        it "allows multiple uses of a primitive (Number)" do
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
              STRUCT Container { data: Byte[] }

              FN test() ->
                c = Container{ data: "hello" };
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
            FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

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
            FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

            FN test(n: Number) ->
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
            FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

            FN test(n: Number) ->
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
          FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

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
        code = "MUTABLE matrix: Number[][] = [[1, 2], [3, 4]];"
        local_ast = run(code)
        expect(local_ast.statements.last.value.full_type.to_s).to eq("Number[2][2]")
      end

      it "resolves a 3D array literal correctly" do
        code = "MUTABLE cube: Number[][][] = [[[1]]];"
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

  # LIFETIMES
  describe "Lifetimes" do
    let(:func_def) { ast.statements.find { |n| n.is_a?(AST::FunctionDef) } }
    context "simple valid lifetime" do
      let(:code) {
        <<~FLUX
          -- Define function that returns a Number
          FN identity(n: Number) RETURNS n:Number ->
            RETURN n;
          END

          identity(1);
        FLUX
      }

      it "parses annotation properly" do
        expect(func_def.return_lifetime.name).to eq("n")
        expect(result).to eq(:Number)
      end
    end

    context "simple invalid lifetime" do
      let(:code) {
        <<~FLUX
          -- Define function that returns a Number
          FN identity(n: Number) RETURNS x:Number ->
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
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
          FN identity(f: Foo) RETURNS Bar ->
            RETURN f.b;
          END

          identity(1);
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Cannot return/i)
      end
    end

    context "simple supplied field lifetime" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
          FN identity(f: Foo) RETURNS f:Bar ->
            RETURN f.b;
          END

          identity(Foo{ b: Bar{ index: 1 }});
        FLUX
      }

      it "parses successfully" do
        expect(func_def.return_lifetime.name).to eq("f")
        expect(result).to eq(:Bar)
      end
    end

    context "simple missing index lifetime" do
      let(:code) {
        <<~FLUX
          STRUCT User { index: Number }

          -- Define function that returns a Number
          FN identity(l: User[]) RETURNS User ->
            RETURN l[1];
          END

          identity([User{index: 1}, User{index: 2}]);
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Cannot return/i)
      end
    end

    context "block non-restricted mutable borrows" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
        expect(func_def.return_lifetime.name).to eq("f")
        expect(result).to eq(:Void)
      end
    end

    context "allow WITH RESTRICT multiple mutable borrows WITHOUT assignment" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
        expect(func_def.return_lifetime.name).to eq("f")
        expect(result).to eq(:Void)
      end
    end

    context "forbid WITH RESTRICT multiple mutable borrows WITH assignment" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Foo { b: Bar }

          FN changeBar!(MUTABLE f: Foo) ->
            f.b = Bar{index: 10};
          END

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Baz { name: String }
          STRUCT Foo { bar: Bar, baz: Baz }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Number
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
          STRUCT Bar { index: Number }
          STRUCT Baz { name: Byte[] }
          STRUCT Foo { bar: Bar, baz: Baz }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Number
          FN identity(r: Root) RETURNS r.foo.bar:Bar ->
            RETURN r.foo.bar;
          END

          r = Root{ foo: Foo{ bar: Bar{ index: 1 }, baz: Baz{ name: "Test"}}};
          identity(r);
        FLUX
      }

      it "succeeds" do
        class Track
          include OwnershipTracker
        end
        t = Track.new
        expect(t.get_lifetime_path(func_def)).to eq("r.foo.bar")
        expect(result).to eq(:Bar)
      end
    end

    context "allow valid sub-lifetimes" do
      let(:code) {
        <<~FLUX
          STRUCT Bar { index: Number }
          STRUCT Foo { bar1: Bar, bar2: Bar }
          STRUCT Root { foo: Foo }

          -- Define function that returns a Number
          FN identity(r: Root) RETURNS r.foo.bar2:Bar ->
            RETURN r.foo.bar1;
          END
        FLUX
      }

      it "errors" do
        expect { result }.to raise_error(/Lifetime Error/i)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Capability Annotations: @multiowned, @shared, @locked, @writeLocked
  # ---------------------------------------------------------------------------

  describe "@multiowned (reference-counted Rc wrapper)" do
    def multiowned_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @multiowned variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @multiowned;
        FLUX
      }

      it "annotates the variable as multiowned" do
        expect(multiowned_decl(code).type_info.multiowned?).to be true
      end

      it "preserves the base resolved type" do
        expect(multiowned_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "direct field access on a @multiowned variable (no WITH needed)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 10 } @multiowned;
          v = c.value;
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH on a plain (non-@multiowned) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH c { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "WITH EXCLUSIVE on a @multiowned variable (wrong capability for mutex)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @multiowned;
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error requiring @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @multiowned) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@shared (atomically reference-counted Arc wrapper)" do
    def shared_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @shared variable" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 1 } @shared;
        FLUX
      }

      it "annotates the variable as shared" do
        expect(shared_decl(code).type_info.shared?).to be true
      end

      it "preserves the base resolved type" do
        expect(shared_decl(code).type_info.resolved).to eq(:Point)
      end
    end

    context "direct field access on a @shared variable (no WITH needed)" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 5 } @shared;
          v = p.x;
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH on a plain (non-@shared) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 1 };
          WITH p { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          FN bad(p: Point @shared) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@locked (mutex-protected Locked(T) wrapper)" do
    def locked_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @locked variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
        FLUX
      }

      it "annotates the variable as locked" do
        expect(locked_decl(code).type_info.locked?).to be true
      end

      it "preserves the base resolved type" do
        expect(locked_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "WITH EXCLUSIVE acquires the mutex and binds an alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 42 } @locked;
          WITH EXCLUSIVE c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH (implicit) on a @locked variable infers EXCLUSIVE" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 0 } @locked;
          WITH c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (infers EXCLUSIVE for @locked)" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH EXCLUSIVE on a plain (non-locked) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "WITH EXCLUSIVE on a @shared variable (not a mutex)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @shared;
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires a sync variable" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "WITH (implicit) on a plain (non-locked, non-owned) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH c { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "mutation through the EXCLUSIVE alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner {
            inner.value = 99;
          }
        FLUX
      }

      it "allows mutation through the alias" do
        expect { ast }.not_to raise_error
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @locked) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@writeLocked (readers-writer RwLocked(T) wrapper)" do
    def write_locked_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @writeLocked variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
        FLUX
      }

      it "annotates the variable as write_locked" do
        expect(write_locked_decl(code).type_info.write_locked?).to be true
      end

      it "preserves the base resolved type" do
        expect(write_locked_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "WITH EXCLUSIVE acquires the write lock and binds an alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 7 } @writeLocked;
          WITH EXCLUSIVE c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (write access)" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH (implicit) on a @writeLocked variable acquires a read lock" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 3 } @writeLocked;
          WITH c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (read access)" do
        expect { ast }.not_to raise_error
      end
    end

    context "mutation through the EXCLUSIVE (write) alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
          WITH EXCLUSIVE c AS inner {
            inner.value = 100;
          }
        FLUX
      }

      it "allows mutation through the write alias" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH EXCLUSIVE on a plain variable (not write-locked)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @writeLocked) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DO block (fork-join parallelism)
  # ---------------------------------------------------------------------------

  describe "DO block (fork-join parallelism)" do
    context "simple expression branches" do
      let(:code) {
        <<~FLUX
          STRUCT Task { id: Number }
          FN process(t: Task) RETURNS Void -> RETURN; END
          a = Task{ id: 1 };
          b = Task{ id: 2 };
          DO {
            process(a),
            process(b)
          }
        FLUX
      }

      it "annotates as Void" do
        expect(result).to eq(:Void)
      end

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end
    end

    context "block branches with @locked shared state" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          }
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end

      it "annotates as Void" do
        expect(result).to eq(:Void)
      end
    end

    context "block branches with @writeLocked shared state" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH c AS inner_r { }
          }
        FLUX
      }

      it "succeeds (one write branch, one read branch)" do
        expect { ast }.not_to raise_error
      end
    end

    context "single branch DO block" do
      let(:code) {
        <<~FLUX
          FN work() RETURNS Void -> RETURN; END
          DO {
            work()
          }
        FLUX
      }

      it "succeeds and resolves to Void" do
        expect { ast }.not_to raise_error
        expect(result).to eq(:Void)
      end
    end

    context "type error inside a DO branch" do
      let(:code) {
        <<~FLUX
          FN add(a: Number, b: Number) RETURNS Number -> RETURN a + b; END
          x = "not-a-number";
          DO {
            add(x, 1)
          }
        FLUX
      }

      it "propagates the type error from inside the branch" do
        expect { ast }.to raise_error(/Type Error/i)
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
          p = Point{ x: 10, y: 5 };
          MUTABLE result = 0;
          MATCH p START
            {x: 10, ...} -> result = 1;,
            {x: 20, ...} -> result = 2;,
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
          p = Point{ x: 1, y: 99, z: 3 };
          MUTABLE result = 0;
          MATCH p START
            {x: 1, y: _, z: 3} -> result = 42;,
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
          m = Msg{ code: 5 };
          MATCH m START
            {code: 5, ...} -> x = 1;,
            {code: 10, ...} -> x = 2;,
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
  end

  describe "DO block" do

    context "three concurrent branches accessing the same @locked counter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          }
        FLUX
      }

      it "succeeds (mutex serialises concurrent mutations)" do
        expect { ast }.not_to raise_error
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
            x = native_add(3, 4);
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

  # ==========================================
  # UNION (Tagged Sum Types)
  # ==========================================
  describe "UNION" do
    # --------------------------------------------------
    # Declaration
    # --------------------------------------------------
    describe "declaration" do
      it "registers the union type in scope without error" do
        expect { run("UNION Shape { Circle: Number, Point }") }.not_to raise_error
      end

      it "resolves the UnionDef node as Void (like StructDef)" do
        ast = run("UNION Shape { Circle: Number, Point }")
        expect(ast.statements.first.resolved_type).to eq(:Void)
      end

      it "accepts PUB UNION without error" do
        expect { run("PUB UNION Result { Ok: Number, Err: Number }") }.not_to raise_error
      end

      it "accepts PRIVATE UNION without error" do
        expect { run("PRIVATE UNION Internal { A: Number, B }") }.not_to raise_error
      end

      it "allows unit variants (no payload type)" do
        expect { run("UNION Maybe { Some: Number, None }") }.not_to raise_error
      end

      it "allows multiple independent union types in the same file" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number, Point }
            UNION Result { Ok: Number, Err: Number }
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # Variant construction
    # --------------------------------------------------
    describe "variant construction" do
      context "payload variant: UnionType{ Variant: value }" do
        let(:code) {
          <<~CLEAR
            UNION Result { Ok: Number, Err: Number }
            r: Result = Result{ Ok: 42 };
          CLEAR
        }

        it "resolves the struct literal to the union type" do
          # The value of the BindExpr is a StructLit resolved to :Result
          expect(ast.statements.last.value.resolved_type).to eq(:Result)
        end

        it "resolves the declared variable to the union type" do
          expect(ast.statements.last.resolved_type).to eq(:Result)
        end
      end

      context "unit variant: UnionType.Variant (no payload — GetField)" do
        let(:code) {
          <<~CLEAR
            UNION Maybe { Some: Number, None }
            x: Maybe = Maybe.None;
          CLEAR
        }

        it "resolves the unit variant access to the union type" do
          expect(ast.statements.last.value.resolved_type).to eq(:Maybe)
        end

        it "resolves the declared variable to the union type" do
          expect(ast.statements.last.resolved_type).to eq(:Maybe)
        end
      end

      it "resolves all variants to the same union type" do
        ast = run(<<~CLEAR)
          UNION Shape { Circle: Number, Rectangle: Number, Point }
          a: Shape = Shape{ Circle: 1.0 };
          b: Shape = Shape{ Rectangle: 2.0 };
          c: Shape = Shape.Point;
        CLEAR
        ast.statements.drop(1).each do |stmt|
          expect(stmt.resolved_type).to eq(:Shape)
        end
      end
    end

    # --------------------------------------------------
    # Functions with union params / return types
    # --------------------------------------------------
    describe "union in function signatures" do
      let(:code) {
        <<~CLEAR
          UNION Result { Ok: Number, Err: Number }
          FN mirror(r: Result) RETURNS Result ->
            RETURN r;
          END
          FN cheatMain() RETURNS Void ->
            out = mirror(Result{ Ok: 1 });
          END
        CLEAR
      }

      it "accepts union as parameter type without error" do
        expect { ast }.not_to raise_error
      end

      it "resolves the call result to the union type" do
        fn   = ast.statements.last
        stmt = fn.body.last
        expect(stmt.resolved_type).to eq(:Result)
      end

      it "raises Type Error when wrong type is passed to union param" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number }
            FN use(r: Result) RETURNS Void ->
            END
            FN cheatMain() RETURNS Void ->
              use(42);
            END
          CLEAR
        }.to raise_error(/Type Error/i)
      end
    end

    # --------------------------------------------------
    # Optional union: ?UnionType
    # --------------------------------------------------
    describe "optional union (?UnionType)" do
      it "parses and type-checks ?Union as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number, Err: Number }
            FN maybe_result() RETURNS ?Result ->
              RETURN NIL;
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # Error union: !UnionType
    # --------------------------------------------------
    describe "error union (!UnionType)" do
      it "parses and type-checks !Union as a valid return type" do
        expect {
          run(<<~CLEAR)
            UNION Payload { Data: Number, Empty }
            FN risky() RETURNS !Payload ->
              RETURN Payload{ Data: 1 };
            END
          CLEAR
        }.not_to raise_error
      end
    end

    # --------------------------------------------------
    # MATCH on union values
    # --------------------------------------------------
    describe "MATCH" do
      it "type-checks MATCH cases against the union type without error" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number, Point }
            FN cheatMain() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              MATCH s START
                Shape.Circle -> n = 1_i64;,
                Shape.Point  -> n = 2_i64;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises an error when a MATCH case is a different union type" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number, Point }
            UNION Color  { Red, Blue }
            FN cheatMain() RETURNS Void ->
              s: Shape = Shape.Point;
              MUTABLE n = 0_i64;
              MATCH s START
                Color.Red -> n = 1_i64;
              END
            END
          CLEAR
        }.to raise_error(CompilerError, /MATCH case type Color does not match expression type Shape/)
      end
    end

    # --------------------------------------------------
    # Error messages
    # --------------------------------------------------
    describe "error messages" do
      it "raises 'Type Error: Union ... has no variant' for an unknown variant (dot access)" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number }
            x: Result = Result.Missing;
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union 'Result' has no variant 'Missing'/)
      end

      it "raises 'Type Error: Union ... has no variant' for an unknown variant in struct literal" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number }
            FN cheatMain() RETURNS Void ->
              x: Result = Result{ Nope: 1 };
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union 'Result' has no variant 'Nope'/)
      end

      it "raises 'Type Error: Union variant ... expects ...' for a payload type mismatch" do
        expect {
          run(<<~CLEAR)
            UNION Result { Ok: Number }
            FN cheatMain() RETURNS Void ->
              x: Result = Result{ Ok: TRUE };
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: Union variant 'Ok' expects Number, got Bool/)
      end

      it "raises 'Type Error: ... is a union type' when accessing a field on a union value" do
        expect {
          run(<<~CLEAR)
            UNION Shape { Circle: Number }
            FN cheatMain() RETURNS Void ->
              s: Shape = Shape{ Circle: 1.0 };
              bad = s.Circle;
            END
          CLEAR
        }.to raise_error(CompilerError, /Type Error: 'Shape' is a union type/)
      end
    end

    # --------------------------------------------------
    # Zig code generation
    # --------------------------------------------------
    describe "Zig code generation" do
      def transpile(src)
        ZigTranspiler.new.transpile(src)
      end

      it "emits a Zig tagged union declaration" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Number, Point }
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Shape = union(enum) {")
        expect(out).to include("    Circle: f64,")
        expect(out).to include("    Point: void,")
      end

      it "emits payload variant constructor as UnionType{ .Variant = payload }" do
        out = transpile(<<~CLEAR)
          UNION Result { Ok: Number }
          FN cheatMain() RETURNS Void ->
            r: Result = Result{ Ok: 42 };
          END
        CLEAR
        expect(out).to include("Result{ .Ok = 42 }")
      end

      it "emits unit variant constructor as UnionType{ .Variant = {} }" do
        out = transpile(<<~CLEAR)
          UNION Maybe { Some: Number, None }
          FN cheatMain() RETURNS Void ->
            x: Maybe = Maybe.None;
          END
        CLEAR
        expect(out).to include("Maybe{ .None = {} }")
      end

      it "emits MATCH on union using std.meta.activeTag" do
        out = transpile(<<~CLEAR)
          UNION Shape { Circle: Number, Point }
          FN cheatMain() RETURNS Void ->
            s: Shape = Shape.Point;
            MUTABLE n = 0_i64;
            MATCH s START
              Shape.Circle -> n = 1_i64;,
              Shape.Point  -> n = 2_i64;
            END
          END
        CLEAR
        expect(out).to include("std.meta.activeTag(s) == .Circle")
        expect(out).to include("std.meta.activeTag(s) == .Point")
      end

      it "includes PUB UNION in transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PUB UNION Result { Ok: Number, Err: Number }
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).to include("const Result = union(enum) {")
      end

      it "excludes PRIVATE UNION from transpile_module output" do
        out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
          PRIVATE UNION Internal { A: Number, B }
          FN cheatMain() RETURNS Void ->
          END
        CLEAR
        expect(out).not_to include("const Internal = union(enum) {")
      end
    end
  end

  # ==================================================
  # GENERICS — Phase 1: Generic Struct Definitions
  # ==================================================
  describe "GENERICS" do
    describe "generic struct definition" do
      it "parses a single type param without error" do
        expect { run("STRUCT Pair<T> { first: T, second: T }") }.not_to raise_error
      end

      it "parses multiple type params without error" do
        expect { run("STRUCT Map<K, V> { key: K, value: V }") }.not_to raise_error
      end

      it "stores type_params in the schema" do
        ast = run("STRUCT Pair<T> { first: T, second: T }")
        node = ast.statements.first
        expect(node).to be_a(AST::StructDef)
        expect(node.type_params).to eq(["T"])
      end

      it "stores multiple type params" do
        ast = run("STRUCT Map<K, V> { key: K, value: V }")
        expect(ast.statements.first.type_params).to eq(["K", "V"])
      end

      it "a non-generic struct has empty type_params" do
        ast = run("STRUCT User { id: Number }")
        expect(ast.statements.first.type_params).to be_nil.or(be_empty)
      end
    end

    describe "error messages" do
      it "raises an error for duplicate type parameter names" do
        expect {
          run("STRUCT Pair<T, T> { first: T, second: T }")
        }.to raise_error(CompilerError, /Type Error: Duplicate type parameter 'T' in generic struct 'Pair'/)
      end

      it "raises an error when a type parameter shadows a built-in type" do
        expect {
          run("STRUCT Foo<Number> { value: Number }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Number' shadows built-in type/)
      end

      it "raises an error when a type parameter shadows Bool" do
        expect {
          run("STRUCT Foo<Bool> { flag: Bool }")
        }.to raise_error(CompilerError, /Type Error: Type parameter 'Bool' shadows built-in type/)
      end

      # NOTE: The following validations are Phase 2 (type annotation instantiation):
      #   - Using a generic type without type args: `x: Pair` should error
      #   - Wrong number of type args: `x: Pair<Number, String>` when Pair<T> expects 1
      #   - Value supplied instead of type: `x: Pair<42>` (parser-level check)
    end

    describe "Zig code generation" do
      it "emits a comptime function for a single-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Pair<T> { first: T, second: T }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Pair(comptime T: type) type")
        expect(out).to include("first: T")
        expect(out).to include("second: T")
      end

      it "emits multiple comptime params for a multi-param generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT Map<K, V> { key: K, value: V }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Map(comptime K: type, comptime V: type) type")
      end

      it "emits a plain const struct for a non-generic struct" do
        out = ZigTranspiler.new.transpile("STRUCT User { id: Number }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("const User = struct")
        expect(out).not_to include("comptime")
      end

      it "correctly emits field types that are type parameters" do
        out = ZigTranspiler.new.transpile("STRUCT Wrapper<T> { value: T }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("value: T")
      end

      it "emits three comptime params for a triple-param struct" do
        out = ZigTranspiler.new.transpile("STRUCT Triple<A, B, C> { a: A, b: B, c: C }\nFN cheatMain() RETURNS Void -> PASS END")
        expect(out).to include("fn Triple(comptime A: type, comptime B: type, comptime C: type) type")
      end
    end
  end
end

