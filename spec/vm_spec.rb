require 'rspec'
require_relative '../src/vm'
require_relative 'support/ast_matchers'
require "byebug"

RSpec.configure do |c|
  c.include AstMatchers
end

RSpec.describe VM do
  # Helper to compile source directly to a Chunk
  def run(source)
    vm = VM.new(source)
    vm.run_code(source)
  end

  def run_bytecode(constants, instructions)
    # 1. Create a raw Chunk
    chunk = Compiler::Chunk.new("unit_test")
    chunk.constants = constants
    chunk.code = instructions

    # 2. Fake line numbers (so your new logger doesn't crash)
    chunk.line_info = Array.new(instructions.size, 1)

    # 3. Run VM
    vm = VM.new("")
    vm.run(chunk)
  end

  def make_chunk(name, ops, constants=[])
    c = Compiler::Chunk.new(name)
    c.code = ops
    c.constants = constants
    c.line_info = Array.new(ops.size, 1)
    c
  end

  describe "Smoke Tests" do
    let(:resp) { run(source).first }

    context "Variable Assignment to 42" do
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

    context "condition goes to 7" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
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
          FN x %() -> RETURN "Hello World"; END
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
          VAR x = %(y)-> "Hello World";
          RETURN x(1);
        FLUX
      }

      it "is 'Hello World'" do
        expect(resp).to eq("Hello World")
      end
    end
  end

  describe "VM OpCode: JMP_IF_ERROR" do
    # Define reusable constants
    let(:error_struct) { { "__type" => "Error", "message" => "TestError" } }
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
      error_obj = { "__type" => "Error", "message" => "Deep Error" }
      chunk_fail = make_chunk("Fail", [
        [:LOADK, "R0", "K0"],
        [:THROW, "R0"]
      ], [error_obj])

      # --- 2. The Middle Function (Pass-through) ---
      # Logic: Just calls Fail(). Has NO Handler info.
      # If the VM crashes here, it means it can't handle frames without handlers.
      chunk_mid = make_chunk("Middle", [
        [:CLOSURE, "R0", "K0"],      # Load 'Fail' chunk
        [:CALL_CLOSURE, "R0", "Fail", 0], # Call it
        [:RETURN, "R0"]
      ], [chunk_fail])

      # --- 3. The Main Function (The Catcher) ---
      # Logic: Calls Middle(). Has a Handler that returns "Recovered".
      chunk_main = make_chunk("Main", [
        [:CLOSURE, "R0", "K0"],        # Load 'Middle' chunk
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

      expect(result).to eq("Recovered")
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

      expect(result).to eq(42)
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
        [:CLOSURE, "R0", "K0"],         # Load Inner
        [:CALL_CLOSURE, "R0", "R0", 0], # Call Inner -> Result in R0
        [:RETURN, "R0"]                 # Return result
      ], [chunk_inner])

      vm = VM.new("ExitTest")
      result = vm.run(chunk_main)

      expect(result).to eq(99)
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
        [:CLOSURE, "R7", "K2"], # Adder Code

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

      expect(result).to eq(30)
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
        [:NEWLIST, "R1"],
        [:LOADK, "R2", "K0"], [:APPEND, "R1", "R2"], # Add 1
        [:LOADK, "R2", "K1"], [:APPEND, "R1", "R2"], # Add 2
        [:LOADK, "R2", "K2"], [:APPEND, "R1", "R2"], # Add 3

        [:CLOSURE, "R2", "K3"], # Load Callback

        # Call .map on the list
        [:CALL_METHOD, "R0", "R1", "map", "R2"],

        [:RETURN, "R0"]
      ], [1, 2, 3, chunk_sq]) # Constants

      vm = VM.new("MapTest")
      result = vm.run(chunk_main)

      expect(result).to eq([1, 4, 9])
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
      global_closure = VM::Closure.new(chunk_triple, [])
      vm.instance_variable_get(:@globals)["Triple"] = global_closure

      # --- 4. Run ---
      result = vm.run(chunk_main)

      expect(result).to eq(30)
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
        [:NEWSTRUCT, "R0", "Point"],   # R0 = %Point{}

        # Set x = 10
        [:LOADK,     "R1", "K0"],      # R1 = 10
        [:SETFIELD,  "R0", "x", "R1"], # R0["x"] = 10

        # Set y = 20 (Just to ensure we can have multiple fields)
        [:LOADK,     "R1", "K1"],      # R1 = 20
        [:SETFIELD,  "R0", "y", "R1"], # R0["y"] = 20

        # Get x
        [:GET_FIELD, "R2", "R0", "x"], # R2 = R0["x"]

        [:RETURN,    "R2"]
      ], [10, 20])

      vm = VM.new("StructTest")
      result = vm.run(chunk)

      expect(result).to eq(10)
    end
  end

  describe "VM: Hashes" do
    it "creates a hash, sets keys, and retrieves values" do
      # Logic:
      # 1. h = {}
      # 2. h["status"] = "active"
      # 3. result = h.status

      chunk = make_chunk("HashTest", [
        [:NEWHASH, "R0"],              # R0 = {}

        [:LOADK,   "R1", "K0"],        # R1 = "active"
        [:SETHASH, "R0", "status", "R1"], # R0["status"] = "active"

        # In your VM, GET_FIELD reads hash keys if the object is a Hash
        [:GET_FIELD, "R2", "R0", "status"],

        [:RETURN, "R2"]
      ], ["active"])

      vm = VM.new("HashTest")
      result = vm.run(chunk)

      expect(result).to eq("active")
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
        [:NEWLIST, "R0"],              # R0 = []

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

      expect(result).to eq(200)
    end
  end

  describe "VM: Opcode THROW" do
    it "initiates stack unwinding and jumps to the local handler" do
      # Logic:
      # 1. Create Error Object
      # 2. THROW it
      # 3. (Should Jump to Handler)
      # 4. Handler returns "Caught"

      error_obj = { "__type" => "Error", "msg" => "Boom" }

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

      expect(result).to eq("Caught")
    end
  end

  describe "VM: Opcode THROW_IF_ERROR" do
    let(:error_obj) { { "__type" => "Error", "msg" => "Pipe Break" } }
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

        expect(result).to eq("Rescued")
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

        expect(result).to eq("Success")
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

      expect(result).to eq("Start")
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

      expect(result).to eq("Jumped")
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

      expect(result).to eq("Fallthrough")
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

      expect(result).to eq("Jumped")
    end

    it "falls through if the value is FALSE" do
      # Logic: This is critical for 'OR EXIT' chains
      # 1. R0 = ErrorStruct
      # 2. IF R0 is truthy (and not error) GOTO 4
      # 3. R1 = "Rescue Path" (Because Error acts like False)
      # 4. RETURN R1

      error_struct = { "__type" => "Error", "msg" => "oops" }

      chunk = make_chunk("ErrorCheckTest", [
        [:LOADK, "R0", "K0"],   # Load Error
        [:JMP_TRUE, "R0", 4],   # Should NOT jump (Error is falsy)
        [:LOADK, "R1", "K1"],   # Load Rescue
        [:RETURN, "R1"],
        [:LOADK, "R1", "K2"],   # Load "Success" (Target - Unreachable)
      ], [error_struct, "Rescue Path", "Success"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(result).to eq("Rescue Path")
    end

    it "treats ERROR objects as FALSE (does not jump)" do
      # Logic: This is critical for 'OR EXIT' chains
      # 1. R0 = ErrorStruct
      # 2. IF R0 is truthy (and not error) GOTO 4
      # 3. R1 = "Rescue Path" (Because Error acts like False)
      # 4. RETURN R1

      error_struct = { "__type" => "Error", "message" => "oops" }

      chunk = make_chunk("ErrorCheckTest", [
        [:LOADK, "R0", "K0"],   # Load Error
        [:JMP_TRUE, "R0", 4],   # Should NOT jump (Error is falsy)
        [:LOADK, "R1", "K1"],   # Load Rescue
        [:RETURN, "R1"],
        [:LOADK, "R1", "K2"],   # Load "Success" (Unreachable)
      ], [error_struct, "Rescue Path", "Success"])

      vm = VM.new()
      result = vm.run(chunk)

      expect(result).to eq("Rescue Path")
    end
  end
end

