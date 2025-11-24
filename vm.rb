#! /usr/bin/env ruby

require_relative "parser"
require "msgpack"

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

      when :NEWSTRUCT
        target_reg = reg_idx[ins[1]]
        struct_name = ins[2]
        # We can implement Structs simply as Ruby Hashes for now
        # You might want to store the struct_name in a special key like '__type'
        frame.registers[target_reg] = { "__type" => struct_name }

      when :SETFIELD
        target_reg = reg_idx[ins[1]]
        key        = ins[2]
        val_reg    = reg_idx[ins[3]]

        target = frame.registers[target_reg]
        val    = frame.registers[val_reg]

        # Safety Check
        unless target.is_a?(Hash)
          raise "Runtime Error: Cannot set field '#{key}' on #{target.class}"
        end

        target[key] = val

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
        frame.registers[target] = lhs_val.send(sym, rhs_val)

      when :PIPE
        # TODO - TEST
        target = reg_idx[ins[1]]
        lhs = reg_idx[ins[2]]
        frame.registers[target] = frame.registers[lhs]

      when :NOT
        # NOT Rtarget, Rsrc
        target = reg_idx[ins[1]]
        src = reg_idx[ins[2]]
        val = frame.registers[src]

        # In Ruby, !nil is true, !false is true. Everything else is false.
        # We can just leverage Ruby's native operator:
        frame.registers[target] = !val

      when :CALL_NATIVE
        # CALL_NATIVE R_result, "ClassName", "method_name", R_arg1, ...
        target_reg = reg_idx[ins[1]]
        class_name = ins[2]
        method_name = ins[3]
        arg_regs   = ins[4..-1].map { |r| reg_idx[r] }

        # 1. Collect Arguments
        args = arg_regs.map { |r| frame.registers[r] }

        # 2. Find the Ruby Class (Security Risk in prod, fun for dev!)
        # Object.const_get("File") returns the actual Ruby File class
        ruby_class = Object.const_get(class_name)

        # 3. Call the method via Ruby reflection
        result = ruby_class.send(method_name, *args)

        # 4. Store result
        frame.registers[target_reg] = result

      # TODO: Replace this with std wrapper to CALL_NATIVE
      when :PRINT
        # PRINT Rval
        val_reg = reg_idx[ins[1]]
        puts "STDOUT > #{frame.registers[val_reg].inspect}"

      when :RETURN
        result_reg = reg_idx[ins[1]]
        return_val = frame.registers[result_reg]

        @frames.pop
        return return_val

      when :JMP
        # JMP target_ip
        # Unconditionally jump to a specific instruction index
        target_ip = ins[1]
        frame.ip = target_ip

      when :JMP_FALSE
        # JMP_FALSE Rcond, target_ip
        # If the value in Rcond is "falsey", jump to target.
        # Otherwise, do nothing (and let the loop increment ip naturally).
        cond_reg = reg_idx[ins[1]]
        target_ip = ins[2]
        val = frame.registers[cond_reg]

        # DEFINE TRUTHINESS:
        # In Ruby, only false and nil are false. 0 is true. "" is true.
        # We will stick to Ruby semantics for simplicity:
        if val == false || val.nil?
          frame.ip = target_ip
        end

      when :JMP_TRUE
        # JMP_TRUE Rcond, target_ip
        cond_reg = reg_idx[ins[1]]
        target_ip = ins[2]
        val = frame.registers[cond_reg]

        # Ruby semantics: false and nil are falsey. Everything else is true.
        if val != false && !val.nil?
          frame.ip = target_ip
        end

      when :GET_INDEX
        target_reg = reg_idx[ins[1]]
        list_reg   = reg_idx[ins[2]]
        idx_reg    = reg_idx[ins[3]]

        list = frame.registers[list_reg]
        index = frame.registers[idx_reg]

        # Basic error checking
        unless list.is_a?(Array) || list.is_a?(String)
           raise "Runtime Error: Attempt to index a #{list.class}"
        end
        
        # Ruby arrays handle out-of-bounds by returning nil, which works fine for us
        frame.registers[target_reg] = list[index]

      when :GET_FIELD
        target_reg = reg_idx[ins[1]]
        obj_reg    = reg_idx[ins[2]]
        field_name = ins[3] # This is a raw string from the bytecode

        obj = frame.registers[obj_reg]
        
        # Determine how to read the field based on the object type
        if obj.is_a?(Hash)
          # For Structs/Maps implemented as Ruby Hashes
          frame.registers[target_reg] = obj[field_name] || obj[field_name.to_sym]
        else
          raise "Runtime Error: Cannot get field '#{field_name}' from #{obj.class}"
        end

      when :ASSERT
        # ASSERT R_cond, K_message
        cond_reg = reg_idx[ins[1]]
        k_idx    = ins[2][1..-1].to_i

        val = frame.registers[cond_reg]
        msg = frame.chunk.constants[k_idx]

        # Use standard Ruby truthiness (false/nil fail)
        if val == false || val.nil?
          raise "🛑 ASSERTION FAILED: #{msg}"
        end
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

code = File.open(ARGV.first).read()
puts "==== CODE ====="
puts code

tokens = Lexer.new(code).tokenize
ast = Parser.new(tokens).parse
compiler = Compiler.new

chunk = compiler.compile(ast)
print_all_chunks(chunk)

vm = VM.new()
resp = vm.run(chunk)

File.binwrite(ARGV.first + 'c', chunk.to_h.to_msgpack)  # Fast, compact

puts resp

