require "rspec"
require "byebug"

require_relative "../src/types"
require_relative "../src/value"
require_relative "../src/vm"
require_relative "../src/chunk"
require_relative "support/ast_matchers"

RSpec.configure do |c|
  c.include AstMatchers
end

RSpec.describe VM do
  # Helper to compile source directly to a Chunk
  def run(source)
    vm = VM.new(source)
    vm.run_code(source)
  end

  def make_error(msg, context = nil)
    FluxHash.new({ "__type" => :Error, "message" => msg, "context" => context }, register: :static)
  end

  def run_bytecode(constants, instructions)
    # 1. Create a raw Chunk
    chunk = Chunk.new("unit_test")
    chunk.constants = constants
    chunk.code = instructions

    # 2. Fake line numbers (so your new logger doesn't crash)
    chunk.line_info = Array.new(instructions.size, 1)

    # 3. Run VM
    vm = VM.new("")
    vm.run(chunk)
  end

  def make_chunk(name, ops, constants=[])
    c = Chunk.new(name)
    c.code = ops
    c.constants = constants
    c.line_info = Array.new(ops.size, 1)
    c
  end

  describe "Smoke Tests" do
    let(:resp) { run(source).first }

    context "VAR Assignment to 42" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
          RETURN x;
        FLUX
      }

      it "is 42" do
        expect(resp).to eq(42)
      end
    end

    context "VAR Reassignment" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
          SET x = 0;
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /'x' is immutable/)
      end
    end

    context "MUTABLE Reassignment" do
      let(:source) {
        <<~FLUX
          MUTABLE x = 42;
          SET x = 0;
          RETURN x;
        FLUX
      }

      it "succeeds" do
        expect(resp).to eq(0)
      end
    end

    context "VAR List Reassign" do
      let(:source) {
        <<~FLUX
          VAR x = %[ 42 ];
          SET x[0] = 0;
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Cannot modify index of immutable list 'x'/)
      end
    end

    context "MUTABLE List Reassign" do
      let(:source) {
        <<~FLUX
          MUTABLE x = %[ 42 ];
          SET x[0] = 7;
          RETURN x[0];
        FLUX
      }

      it "raises failure" do
        expect(resp).to eq(7)
      end
    end

    context "VAR Hash Reassign" do
      let(:source) {
        <<~FLUX
          VAR x = %{ y: 42 };
          SET x.y = 0;
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Cannot modify/)
      end
    end

    context "MUTABLE Hash Reassign" do
      let(:source) {
        <<~FLUX
          MUTABLE x = %{ y: 42 };
          SET x.y = 7;
          RETURN x.y;
        FLUX
      }

      it "raises failure" do
        expect(resp).to eq(7)
      end
    end

    context "Assigment of default function argument" do
      let(:source) {
        <<~FLUX
          FN mut(x) -> SET x = 0; END
          VAR z = 0;
          mut(x);
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Variable 'x' is immutable/)
      end
    end

    context "Cannot create a MUTABLE func without `!` suffix" do
      let(:source) {
        <<~FLUX
          FN mut(MUTABLE x) -> SET x = 0; END
          VAR z = 0;
          mut(z);
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Its name must end in/)
      end
    end

    context "Cannot pass a VAR as a MUTABLE into a func" do
      let(:source) {
        <<~FLUX
          FN mut!(MUTABLE x) -> SET x = 0; END
          VAR z = 0;
          mut!(z);
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Argument 1 .* is MUTABLE/)
      end
    end

    context "MUTABLE primitives are not allowed as parameters" do
      let(:source) {
        <<~FLUX
          FN mut!(MUTABLE x: Number) -> SET x = 0; END
          VAR z = 0;
          mut!(z);
        FLUX
      }

      it "raises failure" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Argument 1 .* is MUTABLE/)
      end
    end

    context "Can pass a MUTABLE as a MUTABLE into a MUTABLE func" do
      let(:source) {
        <<~FLUX
          FN mut!(MUTABLE x) -> SET x.p = 0; END
          MUTABLE z = %{ p: 42 };
          mut!(z);
          RETURN z.p;
        FLUX
      }

      it "succeeds" do
        expect(resp).to eq(0)
      end
    end

    context "Can create a dynamic list" do
      let(:source) {
        <<~FLUX
          VAR l : Number[] = %[ 0, 1, 2, 3 ];
          RETURN l[1];
        FLUX
      }

      it "succeeds" do
        expect(resp).to eq(1)
      end
    end

    context "Can create a fixed list of unspecified size" do
      let(:source) {
        <<~FLUX
          VAR l : Number[*] = %[ 0, 1, 2, 3 ];
          RETURN l[1];
        FLUX
      }

      it "succeeds" do
        expect(resp).to eq(1)
      end
    end

    context "Can create a fixed list of specified size (large enough)" do
      let(:source) {
        <<~FLUX
          VAR l : Number[10] = %[ 0, 1, 2, 3 ];
          RETURN l[1];
        FLUX
      }

      it "succeeds" do
        expect(resp).to eq(1)
      end
    end

    context "Cannot create a fixed list of specified size not large enough" do
      let(:source) {
        <<~FLUX
          VAR l : Number[2] = %[ 0, 1, 2, 3 ];
          RETURN l[1];
        FLUX
      }

      it "fails" do
        expect {
          resp
        }.to raise_error(RuntimeError, /Cannot initialize array of size 4 to fixed-size/)
      end
    end

    context "Can create a list of Int64" do
      let(:source) {
        <<~FLUX
          VAR l : Int64[*] = %[ 0, 1, 2, 3 ];
          RETURN l[1];
        FLUX
      }

      it "fails" do
        expect(resp).to eq(1)
      end
    end

    context "condition goes to 7" do
      let(:source) {
        <<~FLUX
          MUTABLE x = 42;
          IF x > 100 THEN
            SET x = 100;
          ELSE
            SET x = 7;
          END
          RETURN x;
        FLUX
      }

      it "is 7" do
        expect(resp).to eq(7)
      end
    end

    context "named function returns 'Hello World'" do
      let(:source) {
        <<~FLUX
          FN x() -> RETURN %"Hello World"; END
          RETURN x();
        FLUX
      }

      it "is 'Hello World'" do
        expect(resp).to eq("Hello World")
      end
    end

    # TODO: Need to implement Lambda assignment to variables
    context "lambda returns 'Hello World'" do
      let(:source) {
        <<~FLUX
          VAR x = %(y)-> %"Hello World";
          RETURN x(1);
        FLUX
      }

      it "is 'Hello World'" do
        expect(resp).to eq("Hello World")
      end
    end

    context "SMOOTH passes the result of the previous function as the first argument to the next" do
      let(:source) { <<~FLUX
        FN step1() -> RETURN 10; END
        FN step2(n) -> RETURN n * 2; END
        FN step3(n) -> RETURN n + 5; END

        FN main() ->
          -- Should be ((10 * 2) + 5) = 25
          RETURN step1() s> step2 s> step3;
        END

        RETURN main();
      FLUX
      }
      it "flows" do
        expect(resp).to eq(25)
      end
    end
  end

  describe "VM OpCode: JMP_IF_ERROR" do
    # Define reusable constants
    let(:error_struct) {  }
    let(:safe_string)  { "All Good" }
    let(:success_val)  { 100 }
    let(:fail_val)     { -1 }

    context "when R0 contains an Error" do
      it "jumps to the target IP" do
        # Program Logic:
        # 0. LOADK R0 <Error>
        # 1. JMP_IF_ERROR R0 3  (Jump to index 3)
        # 2. LOADK R0 <Fail>    (Should be skipped)
        # 3. LOADK R0 <Success> (Target)
        # 4. RETURN R0

        consts = [error_struct, fail_val, success_val]
        ops = [
          [:LOADK, "R0", "K0"],        # R0 = Error
          [:JMP_IF_ERROR, "R0", 3],    # Jump to IP 3
          [:LOADK, "R0", "K1"],        # R0 = -1 (Should Skip)
          [:LOADK, "R0", "K2"],        # R0 = 100 (Land Here)
          [:RETURN, "R0"]
        ]

        result = run_bytecode(consts, ops)
        expect(result).to eq(100)
      end
    end

    context "when R0 contains a String (Not an Error)" do
      it "does NOT jump and executes the next instruction" do
        # Program Logic:
        # 0. LOADK R0 <String>
        # 1. JMP_IF_ERROR R0 3  (Should NOT Jump)
        # 2. LOADK R0 <Success> (Should execute)
        # 3. RETURN R0          (Early return)
        # ...

        consts = [safe_string, fail_val, success_val]
        ops = [
          [:LOADK, "R0", "K0"],        # R0 = "All Good"
          [:JMP_IF_ERROR, "R0", 4],    # Check (Should Fallthrough)
          [:LOADK, "R0", "K2"],        # R0 = 100
          [:RETURN, "R0"],             # Return 100
          [:LOADK, "R0", "K1"],        # R0 = -1 (Jump target - Avoid!)
          [:RETURN, "R0"]
        ]

        result = run_bytecode(consts, ops)
        expect(result).to eq(100)
      end
    end
  end

  context  "VM Stack Unwinding Unit Test" do
    it "unwinds through an intermediate frame that has no handler" do
      # --- 1. The Inner Function (Throws Error) ---
      # Logic: THROW ErrorObject
      error_obj = make_error("Deep Error")
      chunk_fail = make_chunk("Fail", [
        [:LOADK, "R0", "K0"],
        [:THROW, "R0"]
      ], [error_obj])

      # --- 2. The Middle Function (Pass-through) ---
      # Logic: Just calls Fail(). Has NO Handler info.
      # If the VM crashes here, it means it can't handle frames without handlers.
      chunk_mid = make_chunk("Middle", [
        [:NEW_CLOSURE, "R0", "K0"],      # Load 'Fail' chunk
        [:CALL_CLOSURE, "R0", "Fail", 0], # Call it
        [:RETURN, "R0"]
      ], [chunk_fail])

      # --- 3. The Main Function (The Catcher) ---
      # Logic: Calls Middle(). Has a Handler that returns "Recovered".
      chunk_main = make_chunk("Main", [
        [:NEW_CLOSURE, "R0", "K0"],        # Load 'Middle' chunk
        [:CALL_CLOSURE, "R0", "Middle", 0], # Call it (It will blow up)
        [:RETURN, "R0"],               # (Should trigger Handler)
        # --- HANDLER CODE AT IP: 3 ---
        [:LOADK, "R0", "K1"],          # Load "Recovered"
        [:RETURN, "R0"]
      ], [chunk_mid, "Recovered"])

      # Manually attach Handler Info to Main
      # If error occurs, jump to IP 3 (The LOADK "Recovered")
      chunk_main.handler_info = {
        handler: 3,
        err_reg: 1 # Store error in R1 (unused, but required)
      }

      # --- 4. Run ---
      vm = VM.new("Unit Test")
      result = vm.run(chunk_main)

      expect(Value.unbox(result)).to eq("Recovered")
    end
  end

  describe "VM: Program Exit & Return Values" do
    it "returns the value in the register specified by RETURN" do
      # Logic: LOADK 42 -> RETURN 42
      # This bypasses the Compiler's 'force return 0' logic, testing the VM mechanics directly.
      chunk = make_chunk("ExitTest", [
        [:LOADK, "R0", "K0"],
        [:RETURN, "R0"]
      ], [42])

      vm = VM.new("ExitTest")
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq(42)
    end

    it "returns the result of a function call as the program result" do
      # Logic:
      # 1. Main calls Inner
      # 2. Inner returns 99
      # 3. Main returns result of Inner

      chunk_inner = make_chunk("Inner", [
        [:LOADK, "R0", "K0"], # 99
        [:RETURN, "R0"]
      ], [99])

      chunk_main = make_chunk("Main", [
        [:NEW_CLOSURE, "R0", "K0"],         # Load Inner
        [:CALL_CLOSURE, "R0", "R0", 0], # Call Inner -> Result in R0
        [:RETURN, "R0"]                 # Return result
      ], [chunk_inner])

      vm = VM.new("ExitTest")
      result = vm.run(chunk_main)

      expect(Value.unbox(result)).to eq(99)
    end
  end

  describe "VM: Function Calls & Arguments" do
    it "passes arguments from Caller registers to Callee R0..Rn" do
      # --- The Callee (Adder) ---
      # Params: a (R0), b (R1)
      # Logic: R2 = R0 + R1; RETURN R2
      chunk_add = make_chunk("Adder", [
        [:ADD, "R2", "R0", "R1"],
        [:RETURN, "R2"]
      ], [])

      # --- The Caller (Main) ---
      # Logic:
      # R5 = 10
      # R6 = 20
      # R7 = Adder
      # CALL_CLOSURE R0, R7, 2, R5, R6  (Result goes to R0, Args are R5, R6)
      chunk_main = make_chunk("Main", [
        [:LOADK,   "R5", "K0"], # 10
        [:LOADK,   "R6", "K1"], # 20
        [:NEW_CLOSURE, "R7", "K2"], # Adder Code

        # This is the critical line:
        # Target: R0
        # Closure: R7
        # Arg Count: 2
        # Args: R5, R6
        [:CALL_CLOSURE, "R0", "R7", 2, "R5", "R6"],
        [:RETURN, "R0"]
      ], [10, 20, chunk_add])

      vm = VM.new("ArgsTest")
      result = vm.run(chunk_main)

      expect(Value.unbox(result)).to eq(30)
    end
  end

  describe "VM: CALL_METHOD (.map)" do
    it "executes the native Array.map logic with a callback" do
      # --- The Callback (Square) ---
      # Logic: x (R0) -> x * x
      chunk_sq = make_chunk("Square", [
        [:MUL, "R1", "R0", "R0"],
        [:RETURN, "R1"]
      ], [])

      # --- Main ---
      # Logic:
      # R1 = [1, 2, 3]
      # R2 = Square
      # CALL_METHOD R0, R1, "map", R2
      chunk_main = make_chunk("Main", [
        [:NEW_LIST, "R1"],
        [:LOADK, "R2", "K0"], [:APPEND, "R1", "R2"], # Add 1
        [:LOADK, "R2", "K1"], [:APPEND, "R1", "R2"], # Add 2
        [:LOADK, "R2", "K2"], [:APPEND, "R1", "R2"], # Add 3

        [:NEW_CLOSURE, "R2", "K3"], # Load Callback

        # Call .map on the list
        [:CALL_METHOD, "R0", "R1", "map", "R2"],

        [:RETURN, "R0"]
      ], [1, 2, 3, chunk_sq]) # Constants

      vm = VM.new("MapTest")
      result = vm.run(chunk_main)

      flux_array = Value.unbox(result)
      unboxed_data = flux_array.data.map { |x| Value.unbox(x) }

      expect(unboxed_data).to eq([1, 4, 9])
    end
  end

  describe "VM: CALL_FUNC (Global Functions)" do
    it "looks up a function by name in @globals and executes it" do
      # --- 1. Define the Global Function (The Callee) ---
      # Name: "Triple"
      # Logic: x (R0) -> x * 3
      chunk_triple = make_chunk("Triple", [
        [:LOADK, "R1", "K0"],        # Load 3
        [:MUL,   "R2", "R0", "R1"],  # R2 = Input(R0) * 3
        [:RETURN, "R2"]
      ], [3])

      # --- 2. Define the Main Chunk (The Caller) ---
      # Logic:
      # R1 = 10
      # CALL_FUNC R0, "Triple", 1, R1  (Result -> R0)
      chunk_main = make_chunk("Main", [
        [:LOADK, "R1", "K0"],

        # Instruction: CALL_FUNC
        [:CALL_FUNC,
           "R0",  # Target
           "Triple",  # Global Func Name
           1,  # arity
           "R1"],  # argument_list, in this case only one

        [:RETURN, "R0"]  # Return TargetReg updated by previous CALL_FUNC
      ], [10])

      vm = VM.new("GlobalTest")

      # --- 3. Manually Register the Global (Critical Step) ---
      # This mimics what the compiler does with DEF_GLOBAL
      # We wrap the chunk in a Closure (captures=[] for global funcs)
      global_closure = FluxClosure.new(chunk_triple, [], register: :static)
      boxed_global = Value.box_obj(global_closure)
      vm.instance_variable_get(:@globals)["Triple"] = boxed_global

      # --- 4. Run ---
      result = vm.run(chunk_main)

      expect(Value.unbox(result)).to eq(30)
    end

    it "raises a Runtime Error if the global function is missing" do
      chunk_broken = make_chunk("Broken", [
        [:CALL_FUNC, "R0", "GhostFunction", 0],
        [:RETURN, "R0"]
      ], [])

      vm = VM.new("BrokenTest")

      expect {
        vm.run(chunk_broken)
      }.to raise_error(RuntimeError, /Undefined function 'GhostFunction'/)
    end
  end

  describe "VM: Structs" do
    it "creates a struct, sets fields, and retrieves them" do
      # Logic:
      # 1. p = Point{}
      # 2. p.x = 10
      # 3. result = p.x
      # 4. Return result

      chunk = make_chunk("StructTest", [
        [:DEF_STRUCT, "Point", {x: "Number", y: "Number"}],
        [:NEW_STRUCT, "R0", "Point"],   # R0 = %Point{}

        # Set x = 10
        [:LOADK,     "R1", "K0"],      # R1 = 10
        [:SET_FIELD,  "R0", "x", "R1"], # R0["x"] = 10

        # Set y = 20 (Just to ensure we can have multiple fields)
        [:LOADK,     "R1", "K1"],      # R1 = 20
        [:SET_FIELD,  "R0", "y", "R1"], # R0["y"] = 20

        # Get x
        [:GET_FIELD, "R2", "R0", "x"], # R2 = R0["x"]

        [:RETURN,    "R2"]
      ], [10, 20])

      vm = VM.new("StructTest")
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq(10)
    end
  end

  describe "VM: Hashes" do
    it "creates a hash, sets keys, and retrieves values" do
      # Logic:
      # 1. h = {}
      # 2. h["status"] = "active"
      # 3. result = h.status

      chunk = make_chunk("HashTest", [
        [:NEW_HASH, "R0"],              # R0 = {}

        [:LOADK,   "R1", "K0"],        # R1 = "active"
        [:SET_HASH, "R0", "status", "R1"], # R0["status"] = "active"

        # In your VM, GET_FIELD reads hash keys if the object is a Hash
        [:GET_FIELD, "R2", "R0", "status"],

        [:RETURN, "R2"]
      ], ["active"])

      vm = VM.new("HashTest")
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("active")
    end
  end

  describe "VM: Lists" do
    it "creates a list, appends items, and accesses by index" do
      # Logic:
      # 1. list = []
      # 2. list << 100
      # 3. list << 200
      # 4. result = list[1] (Should be 200)

      chunk = make_chunk("ListTest", [
        [:NEW_LIST, "R0"],              # R0 = []

        # Append 100
        [:LOADK,   "R1", "K0"],        # R1 = 100
        [:APPEND,  "R0", "R1"],        # R0 = [100]

        # Append 200
        [:LOADK,   "R1", "K1"],        # R1 = 200
        [:APPEND,  "R0", "R1"],        # R0 = [100, 200]

        # Access Index 1
        [:LOADK,     "R2", "K2"],      # R2 = 1 (The index)
        [:GET_INDEX, "R3", "R0", "R2"], # R3 = R0[R2]

        [:RETURN, "R3"]
      ], [100, 200, 1])

      vm = VM.new("ListTest")
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq(200)
    end
  end

  describe "VM: Opcode THROW" do
    it "initiates stack unwinding and jumps to the local handler" do
      # Logic:
      # 1. Create Error Object
      # 2. THROW it
      # 3. (Should Jump to Handler)
      # 4. Handler returns "Caught"

      error_obj = make_error("Boom")

      chunk = make_chunk("ThrowTest", [
        [:LOADK, "R0", "K0"],        # Load Error
        [:THROW, "R0"],              # Throw it!
        [:LOADK, "R0", "K1"],        # Load "Failed" (Should be skipped)
        [:RETURN, "R0"],

        # --- HANDLER at IP: 4 ---
        [:LOADK, "R0", "K2"],        # Load "Caught"
        [:RETURN, "R0"]
      ], [error_obj, "Failed", "Caught"])

      # Register the handler
      chunk.handler_info = { handler: 4, err_reg: 1 }

      vm = VM.new("ThrowTest")
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Caught")
    end
  end

  describe "VM: Opcode THROW_IF_ERROR" do
    let(:error_obj) { make_error("Pipe Break") }
    let(:valid_val) { "Valid Data" }

    context "when register contains an Error" do
      it "triggers a throw and jumps to handler" do
        chunk = make_chunk("HardPipeFail", [
          [:LOADK, "R0", "K0"],          # R0 = Error Object

          # This should detect the error and jump to handler (IP 4)
          [:THROW_IF_ERROR, "R0"],

          [:LOADK, "R0", "K1"],          # R0 = "BadPath" (Should be skipped)
          [:RETURN, "R0"],

          # --- HANDLER at IP: 4 ---
          [:LOADK, "R0", "K2"],          # R0 = "Rescued"
          [:RETURN, "R0"]
        ], [error_obj, "BadPath", "Rescued"])

        chunk.handler_info = { handler: 4, err_reg: 1 }

        vm = VM.new("HardPipeFail")
        result = vm.run(chunk)

        expect(Value.unbox(result)).to eq("Rescued")
      end
    end

    context "when register contains valid data" do
      it "does nothing and proceeds to next instruction" do
        chunk = make_chunk("HardPipeSuccess", [
          [:LOADK, "R0", "K0"],          # R0 = "Valid Data"

          # This should pass (No-op)
          [:THROW_IF_ERROR, "R0"],

          [:LOADK, "R0", "K1"],          # R0 = "Success" (Should execute)
          [:RETURN, "R0"]
        ], [valid_val, "Success"])

        # Even if we have a handler, it shouldn't be used
        chunk.handler_info = { handler: 99, err_reg: 1 }

        vm = VM.new("HardPipeSuccess")
        result = vm.run(chunk)

        expect(Value.unbox(result)).to eq("Success")
      end
    end
  end

  describe "Opcode: JMP (Unconditional)" do
    it "skips instructions unconditionally" do
      # Logic:
      # 1. R0 = "Start"
      # 2. JMP to index 3 (Skipping the overwrite)
      # 3. R0 = "Skipped" (This line is jumped over)
      # 4. RETURN R0
      chunk = make_chunk("JmpTest", [
        [:LOADK, "R0", "K0"],
        [:JMP, 3],
        [:LOADK, "R0", "K1"],
        [:RETURN, "R0"]
      ], ["Start", "Skipped"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Start")
    end
  end

  describe "Opcode: JMP_FALSE (&& logic)" do
    it "jumps to target if the value is FALSE" do
      # Logic:
      # 1. R0 = false
      # 2. IF R0 is false GOTO 4
      # 3. R1 = "No Jump" (Skipped)
      # 4. R1 = "Jumped"
      # 5. RETURN R1
      chunk = make_chunk("JmpFalseTest", [
        [:LOADK, "R0", "K0"],
        [:JMP_FALSE, "R0", 3],
        [:LOADK, "R1", "K1"],
        [:LOADK, "R1", "K2"],
        [:RETURN, "R1"]
      ], [false, "No Jump", "Jumped"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Jumped")
    end

    it "falls through if the value is TRUE" do
      # Logic:
      # 1. R0 = true
      # 2. IF R0 is false GOTO 4 (It is true, so don't jump)
      # 3. R1 = "Fallthrough"
      # 4. RETURN R1
      chunk = make_chunk("JmpFalseFallthrough", [
        [:LOADK, "R0", "K0"],
        [:JMP_FALSE, "R0", 4],
        [:LOADK, "R1", "K1"],
        [:RETURN, "R1"],
        [:LOADK, "R1", "K2"], # Target (Unreachable)
      ], [true, "Fallthrough", "Jumped"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Fallthrough")
    end
  end

  describe "Opcode: JMP_TRUE (|| logic)" do
    it "jumps to target if the value is TRUE" do
      # Logic:
      # 1. R0 = true
      # 2. IF R0 is true GOTO 4
      # 3. R1 = "No Jump"
      # 4. R1 = "Jumped"
      chunk = make_chunk("JmpTrueTest", [
        [:LOADK, "R0", "K0"],
        [:JMP_TRUE, "R0", 3],
        [:LOADK, "R1", "K1"],
        [:LOADK, "R1", "K2"],
        [:RETURN, "R1"]
      ], [true, "No Jump", "Jumped"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Jumped")
    end

    it "falls through if the value is FALSE" do
      # Logic: This is critical for 'OR EXIT' chains
      # 1. R0 = ErrorStruct
      # 2. IF R0 is truthy (and not error) GOTO 4
      # 3. R1 = "Rescue Path" (Because Error acts like False)
      # 4. RETURN R1

      error_struct = make_error("oops")

      chunk = make_chunk("ErrorCheckTest", [
        [:LOADK, "R0", "K0"],   # Load Error
        [:JMP_TRUE, "R0", 4],   # Should NOT jump (Error is falsy)
        [:LOADK, "R1", "K1"],   # Load Rescue
        [:RETURN, "R1"],
        [:LOADK, "R1", "K2"],   # Load "Success" (Target - Unreachable)
      ], [error_struct, "Rescue Path", "Success"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Rescue Path")
    end

    it "treats ERROR objects as FALSE (does not jump)" do
      # Logic: This is critical for 'OR EXIT' chains
      # 1. R0 = ErrorStruct
      # 2. IF R0 is truthy (and not error) GOTO 4
      # 3. R1 = "Rescue Path" (Because Error acts like False)
      # 4. RETURN R1

      error_struct = make_error("oops")

      chunk = make_chunk("ErrorCheckTest", [
        [:LOADK, "R0", "K0"],   # Load Error
        [:JMP_TRUE, "R0", 4],   # Should NOT jump (Error is falsy)
        [:LOADK, "R1", "K1"],   # Load Rescue
        [:RETURN, "R1"],
        [:LOADK, "R1", "K2"],   # Load "Success" (Unreachable)
      ], [error_struct, "Rescue Path", "Success"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(Value.unbox(result)).to eq("Rescue Path")
    end
  end

  describe 'VM: Higher-Order Functions & Currying' do
    it "handles immediate invocation of a returned function: myGen(5)(1, 2)" do
      # SOURCE:
      # FN adder_gen(base) ->
      #   RETURN %(x, y) USE(base) -> base + x + y;
      # END
      #
      # VAR fn = adder_gen(5);
      # fn(1, 2);

      # --- 1. The Inner Lambda (Closure) ---
      # Captures: 'base' (at index 0 in capture list)
      # Args: x (R0), y (R1)
      # Logic: base + x + y
      chunk_inner = make_chunk("InnerLambda", [
        [:LOADK, "R3", "K0"],   # R3 = "Inner" (debug name)

        # Stack: R0=x, R1=y, R2=captured_base
        [:ADD,   "R4", "R2", "R0"], # R4 = base + x
        [:ADD,   "R5", "R4", "R1"], # R5 = (base + x) + y
        [:RETURN, "R5"]
      ], ["Inner"])

      # --- 2. The Generator Function ---
      # Args: base (R0)
      # Logic: Create closure capturing R0, return it.
      chunk_gen = make_chunk("Generator", [
        [:NEW_CLOSURE, "R1", "K0", "R0"], # Create Inner, capture 'base' (R0)
        [:RETURN, "R1"]               # Return the closure
      ], [chunk_inner])

      # --- 3. Main Program ---
      # Logic: myGen(5)(1, 2)
      chunk_main = make_chunk("Main", [
        # 1. Call myGen(5) -> Returns Closure into R1
        [:LOADK, "R2", "K0"],         # Load 5
        [:CALL_FUNC, "R1", "myGen", 1, "R2"],

        # 2. Call the result (R1) with (1, 2) -> Returns result into R0
        [:LOADK, "R3", "K1"],         # Load 1
        [:LOADK, "R4", "K2"],         # Load 2
        # CALL_FUNC with a Register operand ("R1") instead of a name
        [:CALL_CLOSURE, "R0", "R1", 2, "R3", "R4"],

        [:RETURN, "R0"]
      ], [5, 1, 2, chunk_gen])

      # Inject the generator into globals manually for this test
      vm = VM.new
      # We need to wrap the chunk in a closure to store it in globals?
      # Or just store the chunk directly if your VM supports raw chunk calls.
      # Based on your VM code, we need a Closure object or raw chunk.
      # Let's support raw chunk for simplicity in tests:
      vm.instance_variable_get(:@globals)["myGen"] = chunk_gen

      result = vm.run(chunk_main)

      # 5 + 1 + 2 = 8
      expect(Value.unbox(result)).to eq(8)
    end
  end

  context 'DIE "Fatal";' do
    let(:source) { 'DIE "Fatal Error";' }
    it 'halts the VM with a signal and correct payload' do
      allow($stderr).to receive(:puts)
      result, _chunk = run(source)
      expect($stderr).to have_received(:puts).with("Fatal Error")
      expect(result).to eq(1)
    end
  end

  context "DIE;" do
    let(:source) { 'DIE;' }
    it 'halts the VM with exit code 1' do
      result, _chunk = run(source)
      expect(result).to eq(1)
    end
  end

  context "Memory Management" do
    it "crashes when accessing a View after the Owner has returned (popped stack)" do
      code = <<~FLUX
        FN get_dangling_view() ->
          VAR list = %[10, 20, 30];
          -- Create a view of local list
          VAR v = list[0..1];
          -- Return view, but 'list' dies here!
          RETURN v;
        END

        VAR crash = get_dangling_view();
        print(crash[0]); -- Should Explode here
      FLUX

      vm = VM.new
      expect { vm.run_code(code) }.to raise_error(/Memory Error: Dangling Pointer/)
    end
  end

  context "Implicit Deref Coercion (View-First)" do
    it "automatically converts a Struct Owner to a Pointer and dereferences it on access" do
      code = <<~FLUX
        STRUCT Point { x: Number, y: Number }

        FN get_x(p) ->
          -- 'p' arrives as a FluxPtr (View)
          -- accessing .x triggers the implicit deref in the VM
          RETURN p.x;
        END

        VAR pt = %Point{ x: 42, y: 100 };

        -- This call triggers 'implicit_deref_coerce_arg' in the compiler
        RETURN get_x(pt);
      FLUX

      vm = VM.new
      result, _ = vm.run_code(code)

      expect(result).to eq(42)
    end

    it "allows mutation via the implicit pointer" do
      # Note: This requires the object to be MUTABLE to pass the freeze check
      code = <<~FLUX
        STRUCT Box { val: Number }

        FN set_val!(MUTABLE b) ->
          -- Implicit Deref allows SET_FIELD on a Pointer
          SET b.val = 99;
        END

        MUTABLE box = %Box{ val: 0 };
        set_val!(box);

        RETURN box.val;
      FLUX

      vm = VM.new
      result, _ = vm.run_code(code)

      expect(result).to eq(99)
    end
  end
end


describe "VM Memory Safety: pop_and_return" do

  # Helper to build chunks easily
  def make_chunk(name, instructions, constants=[])
    c = Chunk.new(name)
    c.code = instructions
    c.constants = constants
    c.line_info = Array.new(instructions.size, 1)
    c
  end

  before(:each) do
    Arena.reset!
  end

  context "Heap Object Survival (RVO)" do
    it "poison!s local objects that are NOT returned (Garbage Collection verification)" do
      # 1. Setup: Create a list, but don't return it. Return something else (or nothing).
      #    We simulate a function that makes a list then discards it.

      # Since we need to inspect the "dead" object, we can't easily do it via VM return.
      # We have to inspect the Arena directly after execution.

      # Code:
      # R0 = NEW_LIST(0)
      # RETURN R0

      chunk = make_chunk("LocalDeath", [
        [:NEW_LIST, 0, 0],         # R0 = [] (This will be returned and survive)
        [:NEW_LIST, 1, 0],         # R1 = [] (This is waste, should die)
        [:RETURN, "R0"]
      ])

      vm = VM.new
      result_ref = vm.run(chunk)

      # The Survivor
      survivor = Value.as_obj(result_ref)
      expect(survivor).to be_a(FluxArray)
      expect(survivor.is_alive?).to be(true) # The returned object must be alive

      # The Victim
      # We have to look inside the Arena's live_objects to ensure R1 is GONE.
      # Or, if we held a reference (which we can't easily in the VM flow), check poison.
      # Ideally, the Arena allocation count should only reflect the survivor.

      # Current Mark should be 1 (The survivor), not 2.
      expect(Arena.current.mark).to eq(1)
    end

    it "successfully returns a HEAP LIST preventing Use-After-Free" do
      # This explicitly tests pop_and_return logic:
      # 1. promote(list)
      # 2. rewind(stack) -> list is NOT in stack, so it isn't poisoned
      # 3. register(list) -> list is back on top

      chunk = make_chunk("HeapListReturn", [
        [:NEW_LIST, 0, 0],      # R0 = []
        [:RETURN, "R0"]         # Return the list
      ])

      vm = VM.new
      result_ref = vm.run(chunk)
      result_obj = Value.as_obj(result_ref)

      expect(result_obj).to be_a(FluxArray)
      expect(result_obj.is_alive?).to be(true)
    end

    it "preserves data inside the returned HEAP LIST" do
      # Code:
      # R0 = []
      # R1 = "Hello"
      # APPEND(R0, R1)
      # RETURN R0

      chunk = make_chunk("ListContent", [
        [:NEW_LIST, "R0", nil],      # R0 = []
        [:LOADK,    "R1", "K0"],      # R1 = "Hello" (Const index 0)
        [:APPEND,   "R0", "R1"],# R0 << R1
        [:RETURN,   "R0"]
      ], ["Hello"])

      vm = VM.new
      result_ref = vm.run(chunk)
      list = Value.as_obj(result_ref)

      expect(list.is_alive?).to be(true)
      expect(list.size).to eq(1)

      # Verify content
      content_ref = list[0]
      content_obj = Value.as_obj(content_ref)
      expect(content_obj.to_s).to eq("Hello")
    end
  end

  context "Nested Stack Frames" do
    it "promotes an object correctly across stack frames" do
      # 1. Start State
      Arena.reset!
      frame_start_mark = Arena.current.mark # 0

      # 2. Allocate "Local" Object in Frame
      local_list = FluxArray.new(nil, [])

      expect(local_list.is_alive?).to be(true)
      expect(Arena.current.mark).to eq(1) # [local_list]

      # 3. Simulate pop_and_return(local_list)
      #    We manually invoke the Arena logic that VM uses

      # A. PROMOTE
      survivors = Arena.current.promote(local_list)
      expect(survivors).to be_a(Array)
      expect(survivors).to include(local_list)

      # At this exact moment, list is removed from allocations, so mark drops
      expect(Arena.current.mark).to eq(0)

      # B. REWIND (POISON)
      # Rewind to where the frame started.
      Arena.current.rewind(frame_start_mark)
      # Since list was promoted (removed), rewind catches nothing.
      expect(local_list.is_alive?).to be(true)

      # C. REGISTER (Push back to caller scope)
      survivors.each { |s| Arena.current.register(s) }

      expect(Arena.current.mark).to eq(1)
      expect(local_list.is_alive?).to be(true)
    end

    it "poisons objects that were NOT promoted during a frame pop" do
      Arena.reset!
      frame_start_mark = Arena.current.mark

      # 1. Allocate Survivor
      survivor_list = FluxArray.new(nil, [])

      # 2. Allocate Victim (Local garbage)
      victim_list = FluxArray.new(nil, [])

      expect(Arena.current.mark).to eq(2)

      # 3. Execute VM Logic: pop_and_return(survivor)

      # A. Promote Survivor
      Arena.current.promote(survivor_list) # Removes survivor from list

      # B. Rewind (Should catch Victim)
      Arena.current.rewind(frame_start_mark)

      # C. Register Survivor
      Arena.current.register(survivor_list)

      # Assertions
      expect(survivor_list.is_alive?).to be(true)
      expect(victim_list.is_alive?).to be(false)
      expect(Arena.current.mark).to eq(1) # Only survivor remains
    end
  end

  context "Edge Cases" do
    it "handles returning nil/constants (Primitives) without crashing" do
      # Primitives usually don't need promotion logic, but the method shouldn't crash.
      # If pop_and_return is passed a constant, promote returns nil, registers nothing?
      # Let's check the logic:
      # promote(int) -> returns nil.
      # register(nil) -> crashes? The VM code says: `Arena.current.register(survivor) if survivor`

      chunk = make_chunk("ReturnConst", [
        [:LOADK, "R0", "K0"],
        [:RETURN, "R0"]
      ], ["ConstantString"])

      vm = VM.new
      result = vm.run(chunk)
      # Should run without error
      expect(Value.unbox(result)).to eq("ConstantString")
    end
  end
end

RSpec.describe "RVO (Return Value Optimization) & Heap Safety" do
  def run(source)
    VM.new(source).run_code(source).first
  end

  describe "Level 1: Simple Heap Objects" do
    it "safely returns a String (Heap Object) from a function" do
      source = <<~FLUX
        FN get_str() ->
          VAR s = %"I survived the stack unwind!";
          RETURN s;
        END
        RETURN get_str();
      FLUX
      expect(run(source)).to eq("I survived the stack unwind!")
    end

    it "safely returns a Mutable String modified inside the function" do
      source = <<~FLUX
        FN make_str() ->
          MUTABLE s = %"Part 1";
          SET s = s + " and Part 2";
          RETURN s;
        END
        RETURN make_str();
      FLUX
      expect(run(source)).to eq("Part 1 and Part 2")
    end
  end

  describe "Level 2: Shallow Containers (Primitives)" do
    it "safely returns a Heap List of Numbers" do
      source = <<~FLUX
        FN get_list() ->
          VAR l = %[ 10, 20, 30 ];
          RETURN l;
        END
        VAR res = get_list();
        RETURN res[1];
      FLUX
      expect(run(source)).to eq(20)
    end

    #it "safely returns a Heap List that was dynamically appended to" do
    #  source = <<~FLUX
    #    FN build_list() ->
    #      MUTABLE l = %[ 1 ];
    #      SET l = l << 2;
    #      SET l = l << 3;
    #      RETURN l;
    #    END
    #    VAR res = build_list();
    #    RETURN res[2];
    #  FLUX
    #  expect(run(source)).to eq(3)
    #end
  end

  # THIS IS LIKELY WHERE YOUR CURRENT CODE FAILS
  describe "Level 3: Deep Containers (Nested Heap Objects)" do
    it "safely returns a List containing Heap Strings" do
      source = <<~FLUX
        FN get_str_list() ->
          -- The List is on the Heap. The Strings inside are ALSO on the Heap.
          -- If RVO is shallow, the List survives but the Strings die.
          RETURN %[ %"Alive", %"Dead?" ];
        END
        VAR res = get_str_list();
        RETURN res[0];
      FLUX
      expect(run(source)).to eq("Alive")
    end

    it "safely returns a Nested List (List of Lists)" do
      source = <<~FLUX
        FN get_matrix() ->
          VAR row1 = %[ 1, 2 ];
          VAR row2 = %[ 3, 4 ];
          RETURN %[ row1, row2 ];
        END
        VAR mat = get_matrix();
        VAR r2 = mat[1];
        RETURN r2[0];
      FLUX
      expect(run(source)).to eq(3)
    end

    it "safely returns a Struct containing a String" do
      source = <<~FLUX
        STRUCT User { name: String }
        FN make_user() ->
          RETURN %User { name: %"FluxUser" };
        END
        VAR u = make_user();
        RETURN u.name;
      FLUX
      expect(run(source)).to eq("FluxUser")
    end
  end

  describe "Level 4: Closures & Captures" do
    it "returns a Closure that captures a Heap Value" do
      source = <<~FLUX
        FN make_greeter() ->
          VAR name = %"World";
          -- The closure captures 'name' (a Heap String).
          -- Both the Closure AND 'name' must survive.
          RETURN %(prefix) USE(name) -> prefix + %" " + name;
        END
        VAR greet = make_greeter();
        RETURN greet("Hello");
      FLUX
      expect(run(source)).to eq("Hello World")
    end

    #it "returns a Closure that captures a Mutable Heap List" do
    #  source = <<~FLUX
    #    FN make_pusher() ->
    #      MUTABLE list = %[ 1 ];
    #      RETURN %(val) USE(list) -> list << val;
    #    END
    #    VAR push = make_pusher();
    #    push(2);
    #    VAR res_list = push(3); -- Returns the list [1, 2, 3]
    #    RETURN res_list[2];
    #  FLUX
    #  expect(run(source)).to eq(3)
    #end
  end

  describe "Level 5: The Gauntlet (Chained Stack Unwinding)" do
    it "survives passing a heap object up multiple stack frames" do
      source = <<~FLUX
        FN level_3() -> RETURN %[ %"Deep" ]; END
        FN level_2() -> RETURN level_3(); END
        FN level_1() -> RETURN level_2(); END

        VAR res = level_1();
        RETURN res[0];
      FLUX
      expect(run(source)).to eq("Deep")
    end
  end
end
