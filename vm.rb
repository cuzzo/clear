#! /usr/bin/env ruby

require_relative "parser"

# ==========================================
# 6. THE VIRTUAL MACHINE
# ==========================================
class VM
  Closure = Struct.new(:chunk, :captures)

  def initialize
    @globals = {} # To store global structs/functions
  end

  # A "Stack Frame" represents a running function
  class Frame
    attr_accessor :chunk, :ip, :registers
    def initialize(chunk)
      @chunk = chunk
      @ip = 0
      @registers = Array.new(256) # The 256 Registers
    end
  end

  def run(entry_chunk)
    # 1. Boot the VM with the top-level script
    @frames = [Frame.new(entry_chunk)]
    run_loop
  end

  def run_loop
    loop do
      frame = @frames.last
      return unless frame # Halted

      # 2. Fetch Instruction
      ins = frame.chunk.code[frame.ip]
      frame.ip += 1

      # 3. Decode
      opcode = ins[0]
      # Helper to get register index (e.g. "R2" -> 2)
      reg_idx = ->(r) { r[1..-1].to_i }

      # 4. Execute (The Big Switch)
      case opcode
      when :LOADK
        # LOADK Rtarget, Kconst
        target = reg_idx[ins[1]]
        k_idx  = ins[2][1..-1].to_i
        val = frame.chunk.constants[k_idx]
        frame.registers[target] = val

      when :MOVE
        dest = reg_idx[ins[1]]
        src  = reg_idx[ins[2]]
        frame.registers[dest] = frame.registers[src]

      when :NEWHASH
        target = reg_idx[ins[1]]
        frame.registers[target] = {}

      when :SETHASH
        target = reg_idx[ins[1]]
        key    = ins[2]
        val_reg = reg_idx[ins[3]]
        frame.registers[target][key] = frame.registers[val_reg]

      when :NEWLIST
        target = reg_idx[ins[1]]
        frame.registers[target] = []

      when :APPEND
        target = reg_idx[ins[1]]
        val_reg = reg_idx[ins[2]]
        frame.registers[target] << frame.registers[val_reg]

      # --- THE CRITICAL LOGIC: CAST ---
      when :CAST
        # CAST Rtarget, "TypeName"
        target = reg_idx[ins[1]]
        type_name = ins[2]
        val = frame.registers[target]

        # In a real VM, you'd check a StructRegistry.
        # For v0.1, we'll hardcode the check for 'Config'
        if type_name == "Config"
          unless val.is_a?(Hash) && val.key?("debug") && val["debug"].is_a?(Integer)
             raise "Runtime Error: Cast Failed! Expected Config (debug: Number), got #{val}"
          end
        end
        # If successful, the value remains in the register (no-op)

      when :CLOSURE
        # CLOSURE Rtarget, Kfunc_chunk, Rcapture1, Rcapture2...
        target = reg_idx[ins[1]]
        k_idx = ins[2][1..-1].to_i
        fn_chunk = frame.chunk.constants[k_idx]

        # 1. Identify which registers in the CURRENT frame we need to capture
        # ins[3..-1] contains strings like ["R2", "R5"]
        captured_values = ins[3..-1].map do |reg_str|
          r = reg_idx[reg_str] # Convert "R2" -> 2
          frame.registers[r] # Grab the actual value (e.g., 10)
        end

        # 2. Create the Closure Object
        closure = Closure.new(fn_chunk, captured_values)

        # 3. Store it in the target register
        frame.registers[target] = closure

      when :CALL_METHOD
        # CALL_METHOD Rresult, Robj, "method", Rargs...
        res_reg = reg_idx[ins[1]]
        obj_reg = reg_idx[ins[2]]
        method = ins[3]
        arg_regs = ins[4..-1].map { |r| reg_idx[r] }

        obj = frame.registers[obj_reg]
        args = arg_regs.map { |r| frame.registers[r] }

        # --- NATIVE METHOD: map ---
        if obj.is_a?(Array) && method == "map"
          closure = args[0] # The lambda compiled chunk

          # Execute the REAL bytecode for every item
          new_list = obj.map do |item|
            # 1. Spin up a temporary VM frame for the lambda
            # 2. Pass 'item' as the first argument (R0)
            execute_function(closure, [item])
          end

          frame.registers[res_reg] = new_list
        else
           raise "Unknown method #{method} on #{obj}"
        end

      when *(AST::OP_CODE_SENDABLE_SYMS.keys)
        target = reg_idx[ins[1]]
        lhs_val = frame.registers[reg_idx[ins[2]]]
        rhs_val = frame.registers[reg_idx[ins[3]]]

        sym = AST::OP_CODE_SENDABLE_SYMS[opcode]
        puts "FRAME: #{frame.registers[1..10]}"
        puts "BINARY OP: #{lhs_val} #{sym} #{rhs_val}"
        frame.registers[target] = lhs_val.send(sym, rhs_val)

      when :PIPE
        # TODO - TEST
        target = reg_idx[ins[1]]
        lhs = reg_idx[ins[2]]
        frame.registers[target] = frame.registers[lhs]

      when :PRINT
        # PRINT Rval
        val_reg = reg_idx[ins[1]]
        puts "STDOUT > #{frame.registers[val_reg].inspect}"

      when :RETURN
        result_reg = reg_idx[ins[1]]
        return_val = frame.registers[result_reg]

        @frames.pop
        return return_val
      end
    end
  end

  # Helper to run a chunk synchronously and return its result
  # This mimics a function call overhead
  def execute_function(closure, args)
    # Handle case where we might be passed a raw Chunk (main) vs a Closure
    chunk = closure.is_a?(Closure) ? closure.chunk : closure
    captures = closure.is_a?(Closure) ? closure.captures : []

    # 1. Create a new frame
    frame = Frame.new(chunk)

    # 2. Load Arguments into Registers R0...Rn
    args.each_with_index do |arg, i|
      frame.registers[i] = arg
    end

    # 3. Load Captures into Registers Rn+1...Rm
    #    They sit immediately after the arguments.
    offset = args.size
    captures.each_with_index do |cap_val, i|
      frame.registers[offset + i] = cap_val
    end

    # 4. Push to stack
    @frames.push(frame)

    # 5. Run
    return run_loop
  end
end

# Recursive code printer
def print_all_chunks(chunk)
  chunk.disassemble
  chunk.constants.each do |const|
    if const.is_a?(Compiler::Chunk)
      print_all_chunks(const)
    end
  end
end

code = File.open("prog.flux").read()
puts "==== CODE ====="
puts code

tokens = Lexer.new(code).tokenize
ast = Parser.new(tokens).parse
compiler = Compiler.new

chunk = compiler.compile(ast)
print_all_chunks(chunk)

vm = VM.new()
main_chunk = chunk.constants[0]
resp = vm.run(main_chunk)

puts resp

