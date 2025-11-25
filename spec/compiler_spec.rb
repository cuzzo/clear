require 'rspec'
require_relative '../parser' # Adjust path to your parser.rb
require_relative 'support/ast_matchers'
require "byebug"

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
        expect(code[1]).to eq([:RETURN, "R0"])
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

  # TODO: TEST SET, FUNCTION DEF, CLOSURE DEF, CAST

  describe 'Syntax: x s> fn() OR EXIT s> next_fn()' do
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

      setfield_idx = code.find_index { |ins| ins[0] == :SETFIELD && ins[2] == "context" }
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
end

