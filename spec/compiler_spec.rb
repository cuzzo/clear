require 'rspec'
require_relative '../parser' # Adjust path to your parser.rb

RSpec.describe Compiler do
  # Helper to compile source directly to a Chunk
  def compile(source)
    lexer = Lexer.new(source)
    tokens = lexer.tokenize
    parser = Parser.new(tokens)
    ast = parser.parse
    compiler = Compiler.new
    compiler.compile(ast)
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

