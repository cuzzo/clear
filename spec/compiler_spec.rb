require 'rspec'
require_relative '../src/lexer'
require_relative '../src/parser'
require_relative '../src/compiler'
require_relative 'support/ast_matchers'

RSpec.configure do |c|
  c.include AstMatchers
end

RSpec.describe Compiler do
  # Helper to compile source directly to a Chunk
  def parse(source)
    lexer = Lexer.new(source)
    tokens = lexer.tokenize
    Parser.new(tokens).parse
  end

  def compile(source)
    lexer = Lexer.new(source)
    tokens = lexer.tokenize
    parser = Parser.new(tokens)
    ast = parser.parse
    compiler = Compiler.new
    compiler.compile(ast)
  end

  def compile_ops(source)
    compile(source).code
  end


  describe 'Syntax: VAR x = <BLAH>;' do
    let(:source) {
      <<~FLUX
        VAR x = #{x};
      FLUX
    }

    context 'x = 5' do
      let(:x) { 5 }

      it 'parses into the correct AST structure (Left-Associative)' do
        program = parse(source)
        stmt = program.statements[0] # The VAR ASSIGNMENT (index 0)

        ast_str = <<~AST
          VarDecl(name: x, type: :Any, value: #{x})
        AST

        expect(stmt).to match_ast(ast_str)
      end

      it 'compiles' do
        chunk = compile(source)
        code = chunk.code

        expect(code[0]).to eq([:LOADK, "R0", "K0"])
        expect(code[1]).to eq([:DEF_GLOBAL, "x", "R0"])
      end
    end

    context 'x = %[1, 2, 3]' do
      let(:x) { '%[1, 2, 3]' }

      it 'parses into the correct AST structure (Left-Associative)' do
        program = parse(source)
        stmt = program.statements[0] # The VAR ASSIGNMENT (index 0)

        # Don't match on type here
        ast_str = <<~AST
          VarDecl(name: x, type: :Any, value: [1, 2, 3])
        AST

        expect(stmt).to match_ast(ast_str)
      end
    end

    context 'x = %{ name:  "test" }' do
      let(:x) { '%{ name: "test" }' }

      it 'parses into the correct AST structure (Left-Associative)' do
        program = parse(source)
        stmt = program.statements[0] # The VAR ASSIGNMENT (index 0)

        # Don't match on type here
        ast_str = <<~AST
          VarDecl(name: x, type: :Any, value: { name: "test" })
        AST

        expect(stmt).to match_ast(ast_str)
      end
    end
  end

  describe 'Keyword: DIE' do
    context 'DIE "Fatal Error";' do
      let(:source) { 'DIE "Fatal Error";' }

      it 'parses to DieNode' do
        program = parse(source)
        stmt = program.statements[0]
        expect(stmt).to match_ast('DieNode(status: "Fatal Error")')
      end

      it 'compiles to EXIT_PROGRAM instruction' do
        ops = compile_ops(source)
        # 1. LOADK "Fatal Error" -> R0
        # 2. EXIT_PROGRAM R0
        expect(ops[0]).to include(:LOADK)
        expect(ops[1]).to eq([:EXIT_PROGRAM, "R0"])
      end
    end

    context "DIE;" do
      let(:source) { 'DIE;' }

      it 'parses to DieNode with default 1' do
        program = parse(source)
        stmt = program.statements[0]
        expect(stmt).to match_ast('DieNode(status: 1)')
      end
    end
  end

  # TODO: FUNCTION DEF, CLOSURE DEF, CAST

  describe 'Syntax: SMOOTH Operator `s>`' do
    # BYTE CODE TRANSLATION
    #
    #      [ INPUT (10) ]
    #          |
    #          v
    #  < 1. INPUT GUARD >----(Is Error?)----> [ THROW / SKIP ]
    #          | NO
    #          v
    #    [ 2. SNAPSHOT ] -------------------> (Saved for later)
    #          |
    #          v
    #  [ 3. EXECUTE CMD (print) ]
    #          |
    #          v
    #  < 4. OUTPUT GUARD >---(Is Error?)----> [ ENRICH & THROW ]
    #          | NO                             ^      |
    #          |                                |      |
    #          |      (Attach Snapshot)---------+      |
    #          |                                       |
    #          v                                       v
    #   [ FINAL RESULT ]                           [ EXIT ]
    context 'Basic Identifier Pipe: 10 s> print' do
      let(:source) {
        <<~FLUX
          VAR x = 10 s> print;
        FLUX
      }

      it 'compiles into a guard-call-guard sequence' do
        ops = compile_ops(source)

        # Step 0: Load 10 (The Input)
        expect(ops[0]).to include(:LOADK)

        # --- START OF SMOOTH OPERATOR ---

        # Step 1: Input Guard (Hard Mode)
        # Must crash if the number 10 was actually an error
        expect(ops[1]).to eq([:THROW_IF_ERROR, "R0"])

        # Step 2: Snapshot
        expect(ops[2]).to include(:MOVE)

        # Step 3: The Call
        # Note: print takes 1 argument (the piped 10)
        # [:CALL_FUNC, Target, Name, Arity, Arg0]
        expect(ops[3]).to match([:PRINT, "R0"])

        # Step 4: Error Enrichment Logic (JMP_IF_OK + SET_FIELD)
        expect(ops[4]).to include(:JMP_IF_OK)
        expect(ops[5]).to include(:SET_FIELD) # Snapshot -> The error internally is just a hash like any other

        # Find where 'x' is defined.
        # This ignores the implicit "RETURN 0" at the very end of the chunk.
        assign_idx = ops.find_index { |op| op[0] == :DEF_GLOBAL && op[1] == "x" }

        # Step 5: Output Guard (Hard Mode)
        # Must crash if print returned an error
        # (Note: index depends on patch location, usually around here)
        expect(ops[assign_idx]).to eq([:DEF_GLOBAL, "x", "R0"]) # Final assignment

        # Find the output guard before the assignment
        # It should be the instruction right before DEF_GLOBAL
        expect(ops[assign_idx-1]).to eq([:THROW_IF_ERROR, "R0"])
      end
    end

    context 'Basic Identifier Pipe: 10 s> print() (WITH PARENS)' do
      let(:source) {
        <<~FLUX
          VAR x = 10 s> print();
        FLUX
      }

      it 'compiles into a guard-call-guard sequence' do
        ops = compile_ops(source)

        expect(ops[0]).to include(:LOADK)
        expect(ops[1]).to eq([:THROW_IF_ERROR, "R0"])
        expect(ops[2]).to include(:MOVE)
        expect(ops[3]).to match([:PRINT, "R0"])
        expect(ops[4]).to include(:JMP_IF_OK)
        expect(ops[5]).to include(:SET_FIELD) # Snapshot -> The error internally is just a hash like any other
        assign_idx = ops.find_index { |op| op[0] == :DEF_GLOBAL && op[1] == "x" }
        expect(ops[assign_idx]).to eq([:DEF_GLOBAL, "x", "R0"]) # Final assignment

        expect(ops[assign_idx-1]).to eq([:THROW_IF_ERROR, "R0"])
      end
    end

    context 'Argument Injection: 10 s> add(5)' do
      let(:source) {
        <<~FLUX
          -- Should compile to add(10, 5)
          VAR x = 10 s> add(5);
        FLUX
      }

      it 'injects the piped value as the FIRST argument' do
        ops = compile_ops(source)

        # Look for the CALL_FUNC instruction
        call_op = ops.find { |op| op[0] == :CALL_FUNC && op[2] == "add" }

        # [:CALL_FUNC, Target, "add", Arity, Arg1, Arg2]
        # Arg1 (Piped Value) should be R0
        # Arg2 (Literal 5) should be R1 (or R2 depending on temp usage)

        arity = call_op[3]
        arg_1 = call_op[4]

        expect(arity).to eq(2) # 1 piped + 1 explicit
        expect(arg_1).to eq("R0") # The piped value comes FIRST
      end
    end

    let(:source) {
      <<~FLUX
        VAR x = %[1, 2, 3];
        x s> fail_task OR EXIT "NOK" s> recover_task;
      FLUX
    }

    it 'parses into the correct AST structure (Left-Associative)' do
      program = parse(source)
      stmt = program.statements[1] # The pipe statement (index 1)

      ast_str = <<~AST
        Smooth(
          left: OrRescue(
            left: Smooth(left: Var(x), right: Var(fail_task)),
            right: ThrowNode("NOK")
          ),
          right: Var(recover_task)
        )
      AST

      expect(stmt).to match_ast(ast_str)
    end

    it 'compiles into the correct Bytecode flow' do
      chunk = compile(source)
      code = chunk.code

      # Extract just the opcodes for easier reading
      opcodes = code.map { |ins| ins[0] }

      # --- Verify The Sequence ---

      # 1. Setup variable x
      expect(opcodes).to include(:LOADK)

      # 2. First Function Call (fail_task)
      fail_call_idx = opcodes.find_index { |op| op == :CALL_FUNC }
      expect(fail_call_idx).not_to be_nil
      # We expect fail_task to be called early
      expect(chunk.code[fail_call_idx]).to include("fail_task")

      # 3. The OR Check (JMP_IF_OK)
      # This must happen AFTER fail_task but BEFORE the throw
      # It checks if the result of fail_task was valid
      jmp_ok_idx = opcodes.find_index(:JMP_IF_OK)
      expect(jmp_ok_idx).to be > fail_call_idx

      # 4. The EXIT (THROW)
      # This must happen immediately after the check (inside the failure block)
      throw_idx = opcodes.find_index(:THROW)
      expect(throw_idx).to be > jmp_ok_idx

      # 5. The Second Function Call (recover_task)
      # This must happen LAST (it consumes the result of the OR group)
      # Note: We search from the end to ensure we find the second call
      recover_call_idx = opcodes.rindex { |op| op == :CALL_FUNC }
      expect(recover_call_idx).to be > throw_idx
      expect(chunk.code[recover_call_idx]).to include("recover_task")
    end

    it 'handles Context Strings: OR EXIT "Message"' do
      source_with_context = 'VAR x = 1; x s> fail OR EXIT "Bad Thing" s> next;'
      chunk = compile(source_with_context)
      code = chunk.code

      setfield_idx = code.find_index { |ins| ins[0] == :SET_FIELD && ins[2] == "context" }
      throw_idx = code.find_index { |ins| ins[0] == :THROW }

      expect(setfield_idx).not_to be_nil
      expect(setfield_idx).to be < throw_idx # Must happen before throw
    end
  end

  describe 'UnaryOp :NOT (!)' do
    context 'when negating a literal (!TRUE)' do
      it 'emits a NOT instruction' do
        chunk = compile("VAR x = !TRUE;")
        code = chunk.code

        # We expect:
        # 1. LOADK (load TRUE)
        # 2. NOT (flip it)
        # 3. MOVE (assign to x) (Or result ends up in variable slot directly depending on visit logic)

        # Find the NOT instruction
        not_instr = code.find { |ins| ins[0] == :NOT }
        expect(not_instr).not_to be_nil

        # Verify structure: [:NOT, "R_dest", "R_src"]
        target_reg = not_instr[1]
        src_reg    = not_instr[2]

        expect(target_reg).to match(/^R\d+$/)
        expect(src_reg).to match(/^R\d+$/)

        # Crucial: They should be valid register strings, not "R" or "Rnil"
        expect(target_reg.length).to be > 1
      end
    end

    context 'when double negating (!!TRUE)' do
      it 'chains the registers correctly' do
        chunk = compile("VAR x = !!TRUE;")
        code = chunk.code

        # We need to find two NOT instructions
        nots = code.select { |ins| ins[0] == :NOT }
        expect(nots.size).to eq(2)

        first_not  = nots[0] # Inner !
        second_not = nots[1] # Outer !

        # Logic Chain Check:
        # The TARGET of the first NOT must be the SOURCE of the second NOT
        # !true -> R_temp
        # !R_temp -> R_final

        first_target = first_not[1]
        second_source = second_not[2]

        expect(first_target).to eq(second_source)
      end
    end

    context 'when used in Control Flow (IF !var)' do
      it 'JMP_FALSE checks the result of the NOT, not the variable' do
        source = <<~FLUX
          VAR is_sad = FALSE;
          IF !is_sad THEN
            print(1);
          END
        FLUX
        chunk = compile(source)
        code = chunk.code

        # 1. Find the NOT instruction
        not_instr = code.find { |ins| ins[0] == :NOT }
        expect(not_instr).not_to be_nil
        not_result_reg = not_instr[1]

        # 2. Find the JMP_FALSE instruction
        jmp_instr = code.find { |ins| ins[0] == :JMP_FALSE }
        expect(jmp_instr).not_to be_nil
        jmp_cond_reg = jmp_instr[1]

        # 3. CRITICAL ASSERTION:
        # The Jump must look at the register created by NOT.
        # If this fails, you have the "Ghost Variable" bug.
        expect(jmp_cond_reg).to eq(not_result_reg)
      end
    end

    context 'when negating a variable (!x)' do
      it 'does not overwrite the source variable (Non-destructive)' do
        source = <<~FLUX
          VAR x = TRUE;
          VAR y = !x;
        FLUX
        chunk = compile(source)
        code = chunk.code

        # Trace x
        # x is declared first, so it is likely in R0 or R1.
        # We look for the MOVE or LOAD that initializes x (R_x)

        # Locate the NOT instruction
        not_instr = code.find { |ins| ins[0] == :NOT }
        target_reg = not_instr[1]
        src_reg    = not_instr[2]

        # Use different registers!
        # If src == target, we corrupted 'x'
        expect(target_reg).not_to eq(src_reg)
      end
    end

    context 'Regression Test: Register Formatting' do
      it 'does not generate empty register numbers (Rnil)' do
        chunk = compile("VAR x = !TRUE;")

        chunk.code.each do |ins|
          # Check all operands starting with "R"
          ins[1..-1].each do |operand|
            if operand.is_a?(String) && operand.start_with?("R")
              # Ensure it is "R0", "R1", etc., not "R"
              expect(operand).to match(/^R\d+$/), "Found malformed register: #{operand}"
            end
          end
        end
      end
    end
  end

  context 'Closures: Capturing Variables' do
    let(:source) {
      <<~FLUX
        VAR outer = 10;
        FN inner %() USE(outer) ->
          RETURN outer;
        END
      FLUX
    }

    it 'detects the capture and emits the CLOSURE opcode with arguments' do
      ops = compile_ops(source)

      # 1. Find where 'outer' is defined (e.g., R0)
      def_op = ops.find { |op| op[0] == :DEF_GLOBAL && op[1] == "outer" }
      outer_reg = def_op[2] # e.g. "R0"

      # 2. Find the CLOSURE instruction
      # Format: [:CLOSURE, TargetReg, ChunkConst, Capture1, Capture2...]
      closure_op = ops.find { |op| op[0] == :CLOSURE }

      expect(closure_op).to_not be_nil

      # The 4th element (index 3) should be the register of 'outer'
      expect(closure_op[3]).to eq(outer_reg)
    end
  end

  context 'Closures: Missing Capture' do
    let(:source) {
      <<~FLUX
        VAR outer = 10;
        FN inner %() ->
          RETURN outer; -- Missing USE(outer)
        END
      FLUX
    }

    it 'raises a Compile Error for undefined variables' do
      expect {
        compile(source)
      }.to raise_error(RuntimeError, /Undefined variable 'outer'/)
    end
  end

  context 'Control Flow: Short-Circuit AND (&&)' do
    let(:source) {
      <<~FLUX
        VAR x = FALSE && print("Don't Print Me");
      FLUX
    }

    it 'emits a JMP_FALSE to skip the right-hand side' do
      ops = compile_ops(source)

      # 1. Look for the JMP_FALSE
      jmp_op = ops.find { |op| op[0] == :JMP_FALSE }
      expect(jmp_op).to_not be_nil

      # 2. Verify the Jump Target
      # The target index should be AFTER the instructions for 'print'
      # print instruction is likely index 3 or 4
      target_idx = jmp_op[2]

      # The instruction at the target should be the result assignment (or Move)
      # It definitely should NOT be the PRINT instruction
      target_instruction = ops[target_idx]

      expect(target_instruction[0]).to_not eq(:PRINT)
    end
  end

  context 'Struct Mutation: SET p.x = 10' do
    let(:source) {
      <<~FLUX
        STRUCT Point { x: Number }
        MUTABLE p = %Point{ x: 0 };
        SET p.x = 10;
      FLUX
    }

    it 'compiles into SET_FIELD instructions instead of MOVE' do
      # If your compiler doesn't handle this, it might crash here
      ops = compile_ops(source)

      # We expect a SET_FIELD instruction
      # Format: [:SET_FIELD, R_Struct, "x", R_Value]
      set_op = ops.find { |op| op[0] == :SET_FIELD }

      expect(set_op).to_not be_nil
      expect(set_op[2]).to eq("x")
    end
  end

  describe 'Nested Data Structures (Register Discipline)' do
    # Ensure the inner hash is built in a *higher* register than the outer hash
    context 'Hash inside Hash: %{ "inner": %{ "a": 1 } }' do
      let(:source) {
        <<~FLUX
          VAR config = %{ "core": %{ "debug": 1 } };
        FLUX
      }

      it 'compiles the inner hash completely before attaching to outer' do
        ops = compile_ops(source)

        # 1. Find the Outer Hash creation
        # It should be the first NEWHASH
        outer_hash_op = ops.find { |op| op[0] == :NEWHASH }
        outer_reg = outer_hash_op[1] # e.g. "R0"

        # 2. Find the Inner Hash creation
        # It should use a DIFFERENT register (usually R0 + 1)
        # We filter for NEWHASH, get the second one
        inner_hash_op = ops.select { |op| op[0] == :NEWHASH }[1]
        inner_reg = inner_hash_op[1] # e.g. "R1"

        expect(inner_reg).to_not eq(outer_reg)

        # 3. Verify the Link
        # Look for the SET_HASH that attaches the inner to the outer
        # SET_HASH OuterReg, Key, InnerReg
        link_op = ops.find { |op| op[0] == :SET_HASH && op[1] == outer_reg && op[3] == inner_reg }

        expect(link_op).to_not be_nil, "Failed to find SET_HASH linking #{outer_reg} and #{inner_reg}"
      end
    end

    # 2. List inside Hash
    # Ensure the list is built in a temp register, then moved into the hash
    context 'List inside Hash: %{ "tags": %[1, 2] }' do
      let(:source) {
        <<~FLUX
          VAR user = %{ "tags": %[10, 20] };
        FLUX
      }

      it 'creates the list separately and sets it as a hash field' do
        ops = compile_ops(source)

        # 1. Detect Hash and List creation
        hash_op = ops.find { |op| op[0] == :NEWHASH }
        list_op = ops.find { |op| op[0] == :NEWLIST }

        hash_reg = hash_op[1]
        list_reg = list_op[1]

        # 2. Ensure they use different registers
        expect(hash_reg).to_not eq(list_reg)

        # 3. Verify the List Population
        # Look for APPEND instructions targeting the list_reg
        append_ops = ops.select { |op| op[0] == :APPEND && op[1] == list_reg }
        expect(append_ops.size).to eq(2)

        # 4. Verify the Link (SET_HASH)
        # SET_HASH HashReg, "tags", ListReg
        link_op = ops.find { |op| op[0] == :SET_HASH && op[1] == hash_reg && op[3] == list_reg }
        expect(link_op).to_not be_nil
      end
    end

    # 3. List of Lists (Matrix)
    context 'List of Lists: %[ %[1], %[2] ]' do
      let(:source) {
        <<~FLUX
          VAR matrix = %[ %[1], %[2] ];
        FLUX
      }

      it 'compiles inner lists using temporary registers' do
        ops = compile_ops(source)

        # 1. Identify the Main List (The one that gets assigned to 'matrix')
        # It's usually the first NEWLIST or the one passed to DEF_GLOBAL
        def_op = ops.find { |op| op[0] == :DEF_GLOBAL }
        main_list_reg = def_op[2]

        # 2. Count all NEWLIST instructions
        new_lists = ops.select { |op| op[0] == :NEWLIST }
        expect(new_lists.size).to eq(3) # 1 Outer + 2 Inner

        # 3. Verify APPENDS to the Main List
        # We expect 2 APPENDS where the target is main_list_reg
        main_appends = ops.select { |op| op[0] == :APPEND && op[1] == main_list_reg }
        expect(main_appends.size).to eq(2)

        # 4. Verify the values being appended are indeed other registers (the inner lists)
        # NOT constants
        main_appends.each do |append|
          val_reg = append[2] # The value being appended
          expect(val_reg).to start_with("R") # Must be a register, not "K..."
          expect(val_reg).to_not eq(main_list_reg) # Cannot append self
        end
      end
    end

    # 4. List of Hashes
    context 'List of Hashes: %[ %{ "id": 1 } ]' do
      let(:source) {
        <<~FLUX
          VAR users = %[ %{ "id": 1 } ];
        FLUX
      }

      it 'creates a hash and appends it to the list' do
        ops = compile_ops(source)

        # 1. Find List and Hash creation
        list_op = ops.find { |op| op[0] == :NEWLIST }
        hash_op = ops.find { |op| op[0] == :NEWHASH }

        list_reg = list_op[1]
        hash_reg = hash_op[1]

        # 2. Ensure registers don't clash
        expect(list_reg).to_not eq(hash_reg)

        # 3. Check that the hash was populated
        # SET_HASH HashReg, "id", Val
        set_op = ops.find { |op| op[0] == :SET_HASH && op[1] == hash_reg }
        expect(set_op).to_not be_nil

        # 4. Check that the hash was appended to the list
        # APPEND ListReg, HashReg
        append_op = ops.find { |op| op[0] == :APPEND && op[1] == list_reg && op[2] == hash_reg }
        expect(append_op).to_not be_nil
      end
    end
  end

  def compile_if_statement(node, target_reg)
    # Assuming target_reg is the register for the overall result
    # (though IF is likely treated as a statement here)

    # 1. Compile the Condition (R_cond)
    # We use target_reg for the condition's result
    r_cond = visit(node.condition, target_reg)

    # 2. JUMP A: JMP_FALSE to the ELSE block's address (Placeholder 0)
    # The 'false_jump' instruction needs patching later.
    false_jump_ip = @chunk.emit_with_index(:JMP_FALSE, "R#{r_cond}", 0)

    # 3. THEN Block Compilation
    node.then_branch.each { |stmt| visit(stmt) }

    # Get the address right after the THEN block (Start of ELSE)
    else_start_ip = @chunk.code.length

    # 4. JUMP B: JMP unconditionally over the ELSE block (Placeholder 0)
    # The 'end_jump' instruction needs patching later.
    end_jump_ip = @chunk.emit_with_index(:JMP, 0)

    # 5. Patch JUMP A
    # JMP_FALSE should jump to the instruction right after JUMP B (IP 4 in example)
    @chunk.patch(false_jump_ip, else_start_ip)

    # 6. ELSE Block Compilation (if present)
    if node.else_branch.any?
      node.else_branch.each { |stmt| visit(stmt) }
    end

    # Get the address right after the ELSE block
    end_ip = @chunk.code.length

    # 7. Patch JUMP B
    @chunk.patch(end_jump_ip, end_ip)
  end
end

