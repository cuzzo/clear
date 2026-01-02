require "rspec"
require "byebug"

require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
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
          VAR result = 1 s> identity();
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
          VAR result = 1 s> add(2);
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
          VAR result = 1 s> require_string();
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
          VAR result = 1 s> identity;
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
          VAR result = 1 s> add;
        FLUX
      }

      it "raises error on arity mismatch (missing required args)" do
        expect { ast }.to raise_error(/expects \d+ arguments/i)
      end
    end

    context "when piping to Native/Intrinsics" do
      let(:code) {
        <<~FLUX
          VAR x = 10 s> print();
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
          VAR result = 5
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

          VAR result = s1() s> s2 s> s3;
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
          VAR x = get_num();
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
              VAR i : Int64 = 10;
              RETURN i;
            END
          FLUX
        }
        it "allows returning Int64 where Number is expected" do
          func_def = ast.statements.first
          return_node = func_def.body.last

          expect(return_node).to be_a(AST::ReturnNode) # Sanity check
          expect(return_node.coerced_type).to eq(:Number)
        end
      end

      context "Byte to Number" do
        let(:code) {
          <<~FLUX
            FN get_number() RETURNS Number ->
              VAR b : Byte = 255;
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

          expect(return_node.coerced_type).to eq(:"Number[]")
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
          VAR x = get_anything();
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
    #         VAR x = 1;
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
              SET x = x + 1;
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
              SET x = x + 1;
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
        expect { ast }.to raise_error(/Missing function/i)
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
            VAR n : Number = 100;
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
            VAR b : Byte = 255;
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
            VAR fixed : Number[3] = [1, 2, 3];
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
          VAR local_args = %[1, 2, 3];
          print_args(local_args);
        FLUX
        expect { run(code) }.not_to raise_error
      end

      it "accepts a STACK string" do
        # This creates a String[2] on the stack
        code = base_code + <<~FLUX
          VAR local_args = [1, 2, 3];
          print_args(local_args);
        FLUX
        expect { run(code) }.not_to raise_error
      end
    end

    context "Mutability Safety" do
      let(:mutable_func) {
        <<~FLUX
          FN modify!(MUTABLE x: Number) ->
            SET x = x + 1;
          END
        FLUX
      }

      it "errors when passing an immutable variable to a MUTABLE parameter" do
        code = mutable_func + <<~FLUX
          VAR im = 10; -- Implicitly immutable
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
          FN do_work() RETURNS Void -> VAR x = 1; END
          do_work();
        FLUX
        expect(get_last_type(code)).to eq(:Void)
      end
    end
  end

  describe "Assignments (SET x = ...)" do
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
            SET x = 20;
          FLUX
        }

        it "succeeds and resolves to the variable's type" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Number)
        end
      end

      context "when assigning to a VAR (Immutable)" do
        let(:code) {
          <<~FLUX
            VAR x = 10;
            SET x = 20;
          FLUX
        }

        it "raises an immutability error" do
          expect { ast }.to raise_error(/Variable 'x' is immutable/)
        end
      end

      context "when assigning to an undefined variable" do
        let(:code) {
          <<~FLUX
            SET y = 20;
          FLUX
        }

        it "raises an undefined variable error" do
          expect { ast }.to raise_error(/Cannot assign to undefined variable 'y'/)
        end
      end

      context "when types mismatch (Number = String)" do
        let(:code) {
          <<~FLUX
            MUTABLE x = 10;
            SET x = "hello";
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
            VAR b : Byte = 255;
            SET x = b;
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
            SET list[0] = 99;
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Number)
        end
      end

      context "when modifying a VAR (Immutable) list index" do
        let(:code) {
          <<~FLUX
            VAR list = [1, 2, 3];
            SET list[0] = 99;
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
            SET list[0] = "string";
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
            SET p.x = 100;
          FLUX
        }

        it "succeeds" do
          expect { ast }.not_to raise_error
          expect(result).to eq(:Number)
        end
      end

      context "when modifying a field of a VAR (Immutable) struct" do
        let(:code) {
          struct_def + <<~FLUX
            VAR p = Point{ x: 1, y: 2 };
            SET p.x = 100;
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
            SET p.x = "wrong";
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
            SET p.z = 100;
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
            VAR slice = data[0..1];        -- Immutable borrow because VAR
            SET slice[0] = 99;
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
            VAR b : Byte = 255;
            SET n = b;
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
             SET list = [1, 2, 3]; -- Literal is Number[3]
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
            VAR x : Number = 100;
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
            VAR b : Byte = 255;
            VAR x : Number = b;
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
            VAR x : Number = "hello";
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
            VAR list : Number[3] = [1, 2, 3];
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
            VAR list : Number[3] = [1, 2];
          FLUX
        }
        it "succeeds (fills remaining with default/garbage)" do
          expect { ast }.not_to raise_error
        end
      end

      context "Oversized Assignment (Size > Capacity)" do
        let(:code) {
          <<~FLUX
            VAR list : Number[1] = [1, 2, 3];
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
            VAR list : Number[5] = [];
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
            VAR list : Number[] = [1, 2, 3];
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
            VAR list : Number[*] = [1, 2, 3];
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
            VAR list : Number[] = %[1, 2, 3];
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
            VAR list : Number[3] = ["a", "b", "c"];
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
            VAR list : Number[] = [[1]];
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
            VAR p = Point{ x: 1, y: 2 };
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
              VAR b : Byte = 255;
              -- x takes literal Int64 (10), y takes Byte variable
              VAR p = Point{ x: 10, y: b };
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
            VAR w = Wrapper{
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
      #      VAR p = Point{ x: 1 };
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
            VAR p = Point{ x: 1, y: 2, z: 3 };
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
            VAR p = Point{ x: "bad", y: 2 };
          FLUX
        }

        it "raises a Type Mismatch error" do
          expect { ast }.to raise_error(/Field 'x' expected Number/i)
        end
      end

      context "Unknown Struct Name" do
        let(:code) {
          <<~FLUX
            VAR g = Ghost{ boo: 1 };
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
            VAR list = [1, 2, 3];
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
            VAR matrix = [[1, 2], [3, 4]];
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
            VAR list = [];
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
            VAR list = [1, "string"];
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
            VAR list = [[1], ["A"]];
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
            VAR list = [[1, 2], [3]];
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
              SET i = i + 1;
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
              VAR x = 1;
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
      #        VAR inner_var = 10;
      #      END
      #      -- Should fail: inner_var is out of scope
      #      VAR y = inner_var;
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
            VAR x = 1;
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
            VAR p1 = Point{ x: 1, y: 2 };
            VAR p2 = Point{ x: 3, y: 4 };

            -- Should resolve to add(p1, p2)
            VAR res = p1.add(p2);
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
            VAR p1 = Point{ x: 1, y: 2 };
            VAR p2 = Point{ x: 3, y: 4 };

            -- 1. p1.add(p2)    -> Point
            -- 2. .get_x()      -> Number
            -- 3. .to_list()    -> Number[]
            VAR res = p1.add(p2).get_x().to_list();
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
            VAR p = Point{ x: 1, y: 2 };
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
            VAR p1 = Point{ x: 1, y: 2 };
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
            VAR p1 = Point{ x: 1, y: 2 };
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
    #      VAR p = Point{ x: 1, y: 2 };
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
          VAR x = 100;

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
          VAR a = 10;
          VAR b = 20;

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
          VAR scalar = 5;

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
          VAR secret = 42;

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
          VAR data = "a,b,c";
          -- split returns a List of Strings (String[][])
          VAR parts = data.split(",");
        FLUX
      }
      it "resolves split to a List of Strings" do
        expect(result).to eq(:"%String[][]")
      end
    end

    context "String Manipulation (join)" do
      let(:code) {
        <<~FLUX
          VAR parts = ["a", "b"];
          -- join takes a List of Strings and returns a Heap String
          VAR s = parts.join("-");
        FLUX
      }
      it "resolves join to a Heap String" do
        expect(result).to eq(:"%String[]")
      end
    end

    context "String Manipulation (trim & chaining)" do
      let(:code) {
        <<~FLUX
          -- trim returns a String slice (String[])
          VAR clean = "  abc  ".trim();
        FLUX
      }
      it "resolves trim to a String slice" do
        expect(result).to eq(:"String[]")
      end
    end

    context "Polymorphic Conversion (toInt)" do
      context "when parsing a String" do
        let(:code) { 'VAR i = "123".toInt();' }
        it "resolves to Int64" do
          expect(result).to eq(:Int64)
        end
      end

      context "when casting a Float" do
        let(:code) { 'VAR i = 12.5.toInt();' }
        it "resolves to Int64" do
          expect(result).to eq(:Int64)
        end
      end
    end

    context "Polymorphic Conversion (toFloat)" do
      let(:code) { 'VAR f = "12.5".toFloat();' }
      it "resolves to Number" do
        expect(result).to eq(:Number)
      end
    end

    context "Collection Utilities (length/len)" do
      let(:code) {
        <<~FLUX
          VAR list = [1, 2, 3];
          VAR l = length(list);
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
          VAR words = [%"a", %"bb", %"ccc"];
          -- Project List<String> -> List<Int64> using .length()
          VAR lengths = words s> SELECT _.length();
        FLUX
      }

      it "infers the resulting list type based on the projection body" do
        # _.length() returns Int64, so result is Int64[]
        expect(result).to eq(:"%Int64[]")
      end
    end

    context "Chained Pipe: string s> split s> SELECT" do
      let(:code) {
        <<~FLUX
          VAR raw = "apple,banana";
          -- 1. split returns String[][]
          -- 2. SELECT iterates Strings
          -- 3. _.length() returns Int64
          VAR lengths = raw s> split(",") s> SELECT _.length();
        FLUX
      }

      it "correctly resolves types through the chain" do
        expect(result).to eq(:"%Int64[]")
      end
    end

    context "Struct/Hash Projection: list s> SELECT %{...}" do
      let(:code) {
        <<~FLUX
          VAR nums = [10, 20];

          -- Create a List of HashMaps
          VAR complex = nums s> SELECT %{
            "original": _,
            "doubled": _ * 2
          };
        FLUX
      }

      it "infers a List of HashMaps" do
        # The Hash contains Int64s (since _ is Int and 2 is Int inferred)
        # So it is HashMap<Int64>[]
        expect(result).to eq(:"%HashMap<Number>[]")
      end
    end

    context "Array Projection: list s> SELECT [_]" do
      let(:code) {
        <<~FLUX
          VAR nums = [1_i64, 2_i64];
          -- Wrap each item in a list -> [[1], [2]]
          VAR nested = nums s> SELECT [_];
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
          VAR num = 100;
          VAR bad = num s> SELECT _ + 1;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
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
              VAR a = 10;
              VAR b = a;    -- Copy
              VAR c = a;    -- 'a' should still be alive
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
              VAR a = Config { id: 1 };
              VAR b = a;    -- MOVE occurs here because Config is not primitive
              VAR c = a;    -- ERROR: Use after move
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
              VAR b = a;                -- 'a' is moved
              SET a = Config { id: 2 }; -- 'a' is reborn (live)
              VAR c = a;                -- Should be valid
            END
          FLUX
        }
        it "allows using a variable after it has been re-assigned" do
          expect { ast }.not_to raise_error
        end
      end
    end

    context "Function Calls" do
      context "Passing by Value (Explicit TAKES)" do
        let(:code) { preamble + <<~FLUX
            FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

            FN test() ->
              VAR x = Config { id: 1 };
              consume(x);   -- 'x' is moved into 'consume'
              VAR y = x;    -- ERROR: 'x' is dead
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
              VAR x = Config { id: 1 };

              IF n > 10 THEN
                consume(x); -- 'x' moved here
              ELSE
                -- 'x' alive here
              END

              -- Merge: x is dead because it died in the THEN branch
              VAR y = x;
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
              VAR x = Config { id: 1 };

              IF n > 10 THEN
                consume(x);
              ELSE
                consume(x);
              END

              -- x should definitely be dead
              VAR y = x;
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
              VAR x = Config { id: 1 };
              -- x is unused and Linear
              -- Should auto-drop here
            END
          END
        FLUX
      }

      it "attaches deferred drops to the scope node (IfStatement) for unused linear vars" do
        func_node = ast.statements.last
        if_node = func_node.body.first

        # Access the THEN branch scope (you might need to expose this in your AST logic)
        # Or check if `finalize_scope` modified the `if_node`

        # Assuming finalize_scope pushes to node.deferred_drops or similar:
        # We expect 'x' to be in the drop list of the IfStatement

        # Note: You need to ensure your AST::IfStatement has an accessor for deferred_drops
        expect(if_node.deferred_drops).to include(include(name: "x"))
      end
    end

    context "Loops (While)" do
      # Assuming you implement similar logic for While loops
      let(:code) { preamble + <<~FLUX
          FN consume(TAKES c: Config) RETURNS Number -> RETURN 0; END

          FN test() ->
            VAR x = Config { id: 1 };

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
      # We verify that ANY instance of Scope receives this message
      expect_any_instance_of(Scope).to receive(:mark_escaped).with(var_name)
    end

    def expect_no_escape
      expect_any_instance_of(Scope).not_to receive(:mark_escaped)
    end

    context "Return Statements" do
      it "promotes a variable when it is returned (Pass-by-Reference requirement)" do
        expect_escape("x")
        run(<<~FLUX)
          STRUCT Config { id: Number }
          FN create() RETURNS Config ->
            VAR x = Config { id: 1 };
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
            VAR x = 10;
            RETURN x;
          END
        FLUX
      end
    end

    context "Assignment to Persistent Storage" do
      it "promotes a variable assigned to a Global" do
        expect_escape("local")
        run(<<~FLUX)
          STRUCT Item { id: Number }
          STRUCT Container { item: Item }

          MUTABLE g = %Container { item: Item{id:0} }; -- Global Heap

          FN update() USE(MUTABLE g) ->
            VAR local = Item { id: 99 };
            SET g.item = local; -- 'local' escapes to Global
          END
        FLUX
      end

      it "does NOT promote when assigning to a local stack variable" do
        expect_no_escape
        run(<<~FLUX)
          STRUCT Item { id: Number }
          FN test() ->
            MUTABLE a = Item { id: 1 };
            VAR b = Item { id: 2 };
            SET a = b; -- 'b' moves to 'a', but both are stack. No escape.
          END
        FLUX
      end
    end
  end
end

