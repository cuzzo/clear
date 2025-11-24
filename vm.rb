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
    @structs = {} # Stores "Name" => { "field" => "Type" }
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
        target_reg = reg_idx[ins[1]]
        type_name  = ins[2]
        val = frame.registers[target_reg]
        schema = @structs[type_name] # Assuming @structs is the global registry

        # --- 1. PRIMITIVES / COERCION ---
        if type_name == "String"
          # Fix #1: Coercion
          frame.registers[target_reg] = val.to_s
          return
        elsif type_name == "Number"
          raise "Cast Error" unless val.is_a?(Numeric)
          # Note: Add logic here if you want to convert Float -> Int
          return
        elsif type_name == "Bool"
          raise "Cast Error" unless (val == true || val == false)
          return

        # --- 2. STRUCT CHECK ---
        elsif @structs.key?(type_name)
          # If the outer check fails, we immediately raise an error.
          unless check_type(val, type_name, @structs)
             # The recursive check will already raise a specific error, but this is a final fail-safe.
             raise "Runtime Error: Struct validation failed for '#{type_name}'"
          end

        else
          raise "Runtime Error: Unknown Type '#{type_name}'"
        end
        # If successful, the value remains in the register (no-op)

      when :DEF_GLOBAL
        # Format: [:DEF_GLOBAL, "func_name", "R_source"]
        global_name = ins[1]
        src_reg = reg_idx[ins[2]]

        # Take the Closure/Value from the register
        val = frame.registers[src_reg]

        # Save it to the VM's global registry
        @globals[global_name] = val

      when :DEF_STRUCT
        name = ins[1]
        schema = ins[2] # The ruby hash from the compiler
        @structs[name] = schema

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

      when :CALL_FUNC
        # Format: [:CALL_FUNC, "R_target", "func_name", argc, "R_arg1"...]
        target_reg = reg_idx[ins[1]]
        func_name  = ins[2]
        # argc = ins[3] (Unused here, but useful for Arity checks)
        arg_regs   = ins[4..-1].map { |r| reg_idx[r] }
        args       = arg_regs.map { |r| frame.registers[r] }

        # 1. Resolve the Function
        # Priority: 
        #   A. Is it a variable in the current scope? (e.g., VAR f = FN...)
        #   B. Is it a global function? (e.g., defined with FN name...)
        
        func = nil
        
        # Check if 'func_name' matches a local variable holding a Closure
        # (This requires your compiler to support first-class functions in vars)
        # local_reg = resolve_local_reg(func_name) ... (Skipping for v0.1 simplicity)

        # Check Globals (Standard Definitions)
        if @globals.key?(func_name)
           func = @globals[func_name]
        end

        if func
           # 2. Execute the Function
           # execute_function spins up a new frame, runs the loop, and returns the :RETURN value
           result = execute_function(func, args)
           
           # 3. Store the result in the Target Register (CRITICAL for Pipes!)
           frame.registers[target_reg] = result
        else
           raise "Runtime Error: Undefined function '#{func_name}'"
        end

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

      when :ADD
        target = reg_idx[ins[1]]
        lhs    = frame.registers[reg_idx[ins[2]]]
        rhs    = frame.registers[reg_idx[ins[3]]]

        if lhs.is_a?(Numeric) && rhs.is_a?(Numeric)
          # 1. Math Path (Fast)
          frame.registers[target] = lhs + rhs

        elsif lhs.is_a?(String) || rhs.is_a?(String)
          # 2. String Path (Concat)
          # This handles "A" + "B", "A" + 1, and 1 + "A"
          frame.registers[target] = lhs.to_s + rhs.to_s

        else
          raise "Runtime Error: Cannot ADD types #{lhs.class} and #{rhs.class}"
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

        # Is it an Error? If so, treat as FALSE (don't jump)
        is_error = val.is_a?(Hash) && val["__type"] == "Error"

        # Ruby semantics: false and nil are falsey. Everything else is true.
        if val != false && !val.nil? && !is_error?
          frame.ip = target_ip
        end

      when :JMP_IF_ERROR
        # JMP_IF_ERROR R_val, target_ip
        val_reg   = reg_idx[ins[1]]
        target_ip = ins[2]

        val = frame.registers[val_reg]

        # Check if it is a Hash (Struct) and has the type "Error"
        if val.is_a?(Hash) && val["__type"] == "Error"
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

  def check_type(val, required_type, structs_registry)
    case required_type
    when "Any"
      return true
    when "Number"
      return val.is_a?(Numeric)
    when "String"
      return val.is_a?(String)
    when "Bool"
      return (val == true || val == false)
    else
      # Recursive Struct Check: Check against the schema registry
      if structs_registry.key?(required_type)
        # Check if the value is a runtime Struct/Hash AND the fields match the schema
        return val.is_a?(Hash) && validate_struct(val, structs_registry[required_type], structs_registry)
      else
        # Unknown type name (e.g., a custom type that wasn't defined)
        return false
      end
    end
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

