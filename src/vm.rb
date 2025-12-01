require "byebug"
require "optparse"
require "logger"

require_relative "lexer"
require_relative "parser"
require_relative "compiler"
require_relative "types"

if $logger.nil?
  $logger = Logger.new(STDOUT)
  $logger.level = Logger::INFO
  $logger.formatter = proc do |severity, datetime, progname, msg|
    "[#{severity}] #{msg}\n"
  end
end

# ==========================================
# 6. THE VIRTUAL MACHINE
# ==========================================
class VM
  UNWIND_SIGNAL = :__vm_unwind_signal__
  EXIT_SIGNAL = :__vm_program_exit__

  Closure = Struct.new(:chunk, :captures)

  def initialize(code_str = "")
    @globals = {} # To store global structs/functions
    @structs = {} # Stores "Name" => { "field" => "Type" }
    @source_lines = code_str.lines
  end

  # A "Stack Frame" represents a running function
  class Frame
    attr_accessor :chunk, :ip, :registers
    def initialize(chunk)
      @chunk = chunk
      @ip = 0
      @registers = Array.new(256) # The 256 Registers
    end

    def debug_str(ins)
      ins[1..]
        .map { |operand| operand_data(operand) }
        .zip(ins[1..]).map { |data, operand| joined_str(data, operand) }
        .join(" ")
    end

    def operand_data(operand)
      if operand.is_a?(String)
        idx = operand[1..].to_i
        case operand[0]
          when "R", "K"
            reg_debug_str(operand.start_with?("R") ? registers[idx] : @chunk.constants[idx])
          else
            operand # functions
        end
      else
        operand
      end
    end

    def joined_str(data, operand)
      case data == operand # instruction pointer (jmp target, etc)
        when true then operand.is_a?(Numeric) ? "IP: #{operand}" : "##{operand}";
        when false then "#{operand}(#{data})";
      end
    end

    def reg_debug_str(v)
      if v.is_a?(String) then "\"#{v}\""
      elsif v.is_a?(Numeric) then v
      elsif v.is_a?(Compiler::Chunk) then "\\#{v.name}"
      elsif v.is_a?(VM::Closure) then "λ"
      elsif v.is_a?(Hash) then "{}:#{v.keys.count}"
      elsif v.is_a?(Array) then "[]:#{v.size}"
      else v.class
      end
    end
  end

  def run(entry_chunk)
    # 1. Boot the VM with the top-level script
    @frames = [Frame.new(entry_chunk)]
    run_loop
  end

  def run_loop
    # 1. Capture the stack depth when this specific loop starts
    start_depth = @frames.size

    catch(EXIT_SIGNAL) do
    loop do
      frame = @frames.last

      # Safety check: If we somehow popped below our depth without returning
      return UNWIND_SIGNAL if !frame || @frames.size < start_depth

      # 2. Fetch Instruction
      ins = frame.chunk.code[frame.ip]
      frame.ip += 1

      # 3. Decode
      opcode = ins[0]
      # Helper to get register index (e.g. "R2" -> 2)
      reg_idx = ->(r) { r[1..-1].to_i }

      # 4. Execute (The Big Switch)
      case opcode
      when :LOADK then process_loadk(reg_idx, ins, frame);
      when :MOVE then process_move(reg_idx, ins, frame);
      when :NEWHASH then process_newhash(reg_idx, ins, frame);
      when :NEWSTRUCT then process_newstruct(reg_idx, ins, frame);
      when :SET_FIELD then process_set_field(reg_idx, ins, frame);
      when :SET_HASH then process_set_hash(reg_idx, ins, frame);
      when :SET_INDEX then process_set_index(reg_idx, ins, frame);
      when :NEWLIST then process_newlist(reg_idx, ins, frame);
      when :APPEND then process_append(reg_idx, ins, frame);
      when :CAST then process_cast(reg_idx, ins, frame);
      when :DEF_GLOBAL then process_def_global(reg_idx, ins, frame);
      when :DEF_STRUCT then process_def_struct(reg_idx, ins, frame);
      when :CLOSURE then process_closure(reg_idx, ins, frame);
      when :CALL_FUNC then process_call_func(reg_idx, ins, frame);
      when :CALL_METHOD then process_call_method(reg_idx, ins, frame);
      when :CALL_CLOSURE then process_call_closure(reg_idx, ins, frame);
      when :ADD then process_add(reg_idx, ins, frame);
      when *(AST::OP_CODE_SENDABLE_SYMS.keys) then process_sendable_symbol(reg_idx, ins, frame, opcode);
      when :NOT then process_not(reg_idx, ins, frame);
      when :CALL_NATIVE then process_call_native(reg_idx, ins, frame);
      # TODO: Replace this with std wrapper to CALL_NATIVE
      when :PRINT then process_print(reg_idx, ins, frame);
      when :JMP then process_jmp(reg_idx, ins, frame);
      when :JMP_FALSE then process_jmp_false(reg_idx, ins, frame);
      when :JMP_TRUE then process_jmp_true(reg_idx, ins, frame);
      when :JMP_IF_OK then process_jmp_if_ok(reg_idx, ins, frame);
      when :JMP_IF_ERROR then process_jmp_if_error(reg_idx, ins, frame);
      when :GET_INDEX then process_get_index(reg_idx, ins, frame);
      when :GET_FIELD then process_get_field(reg_idx, ins, frame);
      when :ASSERT then process_assert(reg_idx, ins, frame);
      when :THROW then process_throw(reg_idx, ins, frame);
      when :THROW_IF_ERROR then process_throw_if_error(reg_idx, ins, frame);
      when :EXIT_PROGRAM then process_exit_program(reg_idx, ins, frame);
      when :FREEZE then process_freeze(reg_idx, ins, frame);

      # RETURN IS SPECIAL
      # IT MUST BE DIRECTLY IN MAIN_LOOP TO BREAK IT
      when :RETURN then
        val = process_return(reg_idx, ins, frame, start_depth)
        return val unless val.nil?
      end

      $logger.debug(debug_str(ins, frame))
    end
    end
  end

  # current_frame has relative registers
  # current_chunk has relative constants
  def debug_str(ins, frame)
    line_num = frame.chunk.line_info[frame.ip]
    line_str = "L:#{line_num.to_s.rjust(3, '0')}"
    src_line = (line_num && line_num > 0 && @source_lines.length >= line_num) ?
               @source_lines[line_num - 1].strip : ""
    src_line = src_line.length > 30 ? src_line[0..27] + "..." : src_line
    ip = frame.ip.to_s.rjust(5, "0")
    indent = "  " * (@frames.size - 1)
    op_str = "#{indent}#{ins.first} -> #{frame.debug_str(ins)}".ljust(40)


    "[#{line_str}] #{ip}: #{op_str} | #{src_line}"
  end

  def process_loadk(reg_idx, ins, frame)
    # LOADK Rtarget, Kconst
    target = reg_idx[ins[1]]
    k_idx  = ins[2][1..-1].to_i
    val = frame.chunk.constants[k_idx]
    frame.registers[target] = val
  end

  def process_move(reg_idx, ins, frame)
    dest = reg_idx[ins[1]]
    src = reg_idx[ins[2]]
    frame.registers[dest] = frame.registers[src]
  end

  def process_newhash(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    frame.registers[target] = Hash.new
  end

  def process_newstruct(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    struct_name = ins[2]
    # We can implement Structs simply as Ruby Hashes for now
    # You might want to store the struct_name in a special key like '__type'
    frame.registers[target_reg] = { "__type" => struct_name }
  end

  def process_set_field(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    key = ins[2]
    val_reg = reg_idx[ins[3]]

    target = frame.registers[target_reg]
    val = frame.registers[val_reg]

    if target.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end
    unless target.is_a?(Hash)
      raise "Runtime Error: Cannot set field '#{key}' on #{target.class}"
    end

    target[key] = val
  end

  def process_set_hash(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    key = ins[2]
    val_reg = reg_idx[ins[3]]
    frame.registers[target][key] = frame.registers[val_reg]
  end

  def process_newlist(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    frame.registers[target] = Array.new()
  end

  def process_append(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    val_reg = reg_idx[ins[2]]

    target = frame.registers[target_reg]
    val = frame.registers[val_reg]

    if target.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    frame.registers[target_reg] << val
  end

  def process_cast(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    type_name = ins[2].to_s
    val = frame.registers[target_reg]
    schema = @structs[type_name] # Assuming @structs is the global registry

    # --- 1. PRIMITIVES / COERCION ---
    if type_name == "String"
      frame.registers[target_reg] = val.to_s
      return
    elsif type_name == "Number"
      if val.is_a?(FluxByte)
        frame.registers[target_reg] = val.value
        return
      end
      raise "Cast Error: Cannot cast #{val.class} to Number" unless val.is_a?(Numeric)
      return
    elsif type_name == "Bool"
      raise "Cast Error" unless (val == true || val == false)
      return
    elsif type_name == "Byte"
      # NEW: Wrap Number -> Byte (or re-wrap Byte -> Byte)
      # We extract the raw integer value to be safe, then wrap it.
      if val.is_a?(Numeric)
        frame.registers[target_reg] = FluxByte.new(val)
        return
      elsif val.is_a?(FluxByte)
        # Already a byte, but creating a new one creates a copy (safe)
        frame.registers[target_reg] = FluxByte.new(val.value)
        return
      end

    # --- 3. ARRAY CASTING ---
    elsif type_name.include?("[")
      match = type_name.match(/^(\w+)\[(.*)\]$/)

      if match
        constraint = match[2]

        # 1. Fixed Inferred [*]
        if constraint == "*"
          # Lock size to current count
          frame.registers[target_reg] = FluxArray.new(val.size, val)
          return
        end

        # 2. Fixed Explicit [N]
        if constraint =~ /^\d+$/
          limit = constraint.to_i

          # Runtime Check (for non-literals)
          if val.size > limit
            raise "Runtime Error: Array too large for fixed size #{limit}"
          end

          frame.registers[target_reg] = FluxArray.new(limit, val)
          return
        end
      end

    # --- 2. STRUCT CHECK ---
    # TODO: Why is Number in @structs ??
    elsif @structs.key?(type_name.to_sym)
      unless check_type(val, type_name.to_sym, @structs)
        raise "Runtime Error: Struct validation failed for '#{type_name}'"
      end
    else
      raise "Runtime Error: Unknown Type '#{type_name}'"
    end

    # If successful, the value remains in the register (no-op)
  end

  def process_def_global(reg_idx, ins, frame)
    # Format: [:DEF_GLOBAL, "func_name", "R_source"]
    global_name = ins[1]
    src_reg = reg_idx[ins[2]]

    # Take the Closure/Value from the register
    val = frame.registers[src_reg]

    # Save it to the VM's global registry
    @globals[global_name] = val
  end

  def process_def_struct(reg_idx, ins, frame)
    name = ins[1]
    schema = ins[2] # The ruby hash from the compiler
    @structs[name.to_sym] = schema
  end

  def process_closure(reg_idx, ins, frame)
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
  end


  def process_call_func(reg_idx, ins, frame)
    # Format: [:CALL_FUNC, "R_target", "Operand", argc, "R_arg1"...]
    target_reg = reg_idx[ins[1]]
    operand    = ins[2] # Can be "print" (Global) OR "R4" (Register)

    # 1. Resolve Arguments
    #    (Map directly from instruction -> register index -> value)
    args = ins[4..-1].map { |r_str| frame.registers[reg_idx[r_str]] }

    # 2. Resolve Function
    func = nil

    if operand.start_with?("R")
      # CASE A: Closure in a Register (e.g., "R4")
      r = reg_idx[operand]
      func = frame.registers[r]
      raise "Runtime Error: Variable '#{operand}' is nil/not a function" if func.nil?
    else
      # CASE B: Global Name (e.g., "print", "cur")
      func = @globals[operand]
      raise "Runtime Error: Undefined function '#{operand}'" if func.nil?
    end

    # 3. Execute
    result = execute_function(func, args)
    $logger.debug("Call returned: #{result.inspect} -> Writing to R#{target_reg}")

    # 4. Handle Unwinding (CRITICAL)
    #    If the inner function threw an error/signal, propagate it up immediately.
    return UNWIND_SIGNAL if result == UNWIND_SIGNAL

    # 5. Store Result
    frame.registers[target_reg] = result
  end

  def process_call_method(reg_idx, ins, frame)
    # CALL_METHOD Rresult, Robj, "method", Rargs...
    res_reg = reg_idx[ins[1]]
    obj_reg = reg_idx[ins[2]]
    method_name = ins[3]

    # 1. Collect Arguments
    arg_regs = ins[4..-1].map { |r| reg_idx[r] }
    args = arg_regs.map { |r| frame.registers[r] }

    obj = frame.registers[obj_reg]

    # --- DISPATCH LOGIC ---

    # A. Native Methods (e.g. Array.map)
    if obj.is_a?(Array) && method_name == "map"
      closure = args[0]
      new_list = obj.map do |item|
        execute_function(closure, [item])
      end
      frame.registers[res_reg] = new_list
      return
    end

    # B. Struct Field Call (e.g. h2.fun())
    #    This allows us to call a closure stored in a field
    if obj.is_a?(Hash) && obj.key?(method_name)
      func = obj[method_name]

      # Safety Check
      unless func.is_a?(Closure) || func.is_a?(Compiler::Chunk)
        raise "Runtime Error: Property '#{method_name}' is not a function."
      end

      # Execute
      result = execute_function(func, args)

      # Handle Unwinding
      return UNWIND_SIGNAL if result == UNWIND_SIGNAL

      frame.registers[res_reg] = result
      return
    end

    # C. Failure
    raise "Runtime Error: Unknown method '#{method_name}' on #{obj.class}"
  end

  def process_call_closure(reg_idx, ins, frame)
    # Format: [:CALL_CLOSURE, "R_target", "R_closure", argc, "R_arg1"...]
    target_reg = reg_idx[ins[1]]
    closure_reg = reg_idx[ins[2]]
    # argc = ins[3]
    arg_regs = ins[4..-1].map { |r| reg_idx[r] }
    args = arg_regs.map { |r| frame.registers[r] }

    # 1. Resolve the Function (which must be a Closure)
    func = frame.registers[closure_reg]

    unless func.is_a?(Closure)
      # This might happen if a local variable was overwritten
      raise "Runtime Error: Value in R#{closure_reg} is not a function/Closure."
    end

    # 2. Execute the Function
    result = execute_function(func, args)
    $logger.debug("Closure call returned: #{result.inspect} -> Writing to R#{target_reg}")

    return if result == UNWIND_SIGNAL

    # 3. Store the result in the Target Register
    frame.registers[target_reg] = result
  end

  def process_add(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    lhs = frame.registers[reg_idx[ins[2]]]
    rhs = frame.registers[reg_idx[ins[3]]]

    if lhs.is_a?(Numeric) && rhs.is_a?(Numeric)
      # 1. Math Path (Fast)
      frame.registers[target] = lhs + rhs

    elsif lhs.is_a?(FluxByte) && rhs.is_a?(FluxByte)
      # 1. Math Path (Fast)
      frame.registers[target] = lhs + rhs

    elsif lhs.is_a?(FluxByte) && rhs.is_a?(Numeric)
       frame.registers[target] = lhs + FluxByte.new(rhs)

    elsif lhs.is_a?(Numeric) && rhs.is_a?(FluxByte)
       frame.registers[target] = lhs + rhs.value

    elsif lhs.is_a?(String) || rhs.is_a?(String)
      # 2. String Path (Concat)
      # This handles "A" + "B", "A" + 1, and 1 + "A"
      frame.registers[target] = lhs.to_s + rhs.to_s

    else
      raise "Runtime Error: Cannot ADD types #{lhs.class} and #{rhs.class}"
    end
  end

  def process_sendable_symbol(reg_idx, ins, frame, opcode)
    target = reg_idx[ins[1]]
    lhs_val = frame.registers[reg_idx[ins[2]]]
    rhs_val = frame.registers[reg_idx[ins[3]]]

    sym = AST::OP_CODE_SENDABLE_SYMS[opcode]
    frame.registers[target] = lhs_val.send(sym, rhs_val)
  end

  def process_not(reg_idx, ins, frame)
    # NOT Rtarget, Rsrc
    target = reg_idx[ins[1]]
    src = reg_idx[ins[2]]
    val = frame.registers[src]

    # In Ruby, !nil is true, !false is true. Everything else is false.
    # We can just leverage Ruby's native operator:
    frame.registers[target] = !val
  end

  def process_call_native(reg_idx, ins, frame)
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
  end

  def process_print(reg_idx, ins, frame)
    # PRINT Rval
    val_reg = reg_idx[ins[1]]
    puts "STDOUT > #{frame.registers[val_reg].inspect}"
  end

  def process_return(reg_idx, ins, frame, start_depth)
    result_reg = reg_idx[ins[1]]
    return_val = frame.registers[result_reg]

    @frames.pop

    if @frames.empty?
     # This is the final program result.
     throw EXIT_SIGNAL, return_val
   end

    if @frames.size < start_depth
      # If the stack is now smaller than when we started, this specific
      # function call is complete. Return the value to the Ruby caller.
      return return_val
    end

    # If this was a return within the run_loop's original scope,
    # just continue to the next instruction in the caller's frame.
    return nil
  end

  def process_jmp(reg_idx, ins, frame)
    # JMP target_ip
    # Unconditionally jump to a specific instruction index
    target_ip = ins[1]
    frame.ip = target_ip
  end

  def process_jmp_false(reg_idx, ins, frame)
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
  end

  def is_error?(val)
    # Assuming your errors are instances of a class (e.g., RuntimeError or a custom Struct)
    # Adjust this check to match your actual Error object type.
    (val.is_a?(Hash) && val["__type"] == "Error") || val.is_a?(RuntimeError)
  end

  def process_jmp_true(reg_idx, ins, frame)
    # JMP_TRUE Rcond, target_ip
    cond_reg = reg_idx[ins[1]]
    target_ip = ins[2]
    val = frame.registers[cond_reg]

    # Is it an Error? If so, treat as FALSE (don't jump)
    is_error = val.is_a?(Hash) && val["__type"] == "Error"

    # Ruby semantics: false and nil are falsey. Everything else is true.
    if val != false && !val.nil? && !is_error?(val)
      frame.ip = target_ip
    end
  end

  def process_jmp_if_ok(reg_idx, ins, frame)
    # JMP_IF_OK R_val, target_ip
    val_reg   = reg_idx[ins[1]]
    target_ip = ins[2]
    val = frame.registers[val_reg]

    is_error = val.is_a?(Hash) && val["__type"] == "Error"

    # If it is NOT an error, take the jump (skip the OR block)
    if !is_error
      frame.ip = target_ip
    end
  end

  def process_jmp_if_error(reg_idx, ins, frame)
    # JMP_IF_ERROR R_val, target_ip
    val_reg   = reg_idx[ins[1]]
    target_ip = ins[2]

    val = frame.registers[val_reg]

    # Check if it is a Hash (Struct) and has the type "Error"
    if val.is_a?(Hash) && val["__type"] == "Error"
      frame.ip = target_ip
    end
  end

  def process_get_index(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    list_reg   = reg_idx[ins[2]]
    idx_reg    = reg_idx[ins[3]]

    list = frame.registers[list_reg]
    index = frame.registers[idx_reg]

    # Basic error checking
    unless list.is_a?(Array) || list.is_a?(FluxArray) || list.is_a?(String)
       raise "Runtime Error: Attempt to index a #{list.class}"
    end

    # Ruby arrays handle out-of-bounds by returning nil, which works fine for us
    frame.registers[target_reg] = list[index]
  end

  def process_set_index(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    key_reg = reg_idx[ins[2]]
    val_reg = reg_idx[ins[3]]

    target = frame.registers[target_reg]
    key = frame.registers[key_reg]
    val = frame.registers[val_reg]

    if target.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end
    unless target.is_a?(Array)
      raise "Runtime Error: Cannot set index '#{key}' on #{target.class}"
    end

    target[key] = val
  end


  def process_get_field(reg_idx, ins, frame)
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
  end

  def process_assert(reg_idx, ins, frame)
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

  def process_exit_program(reg_idx, ins, frame)
    # 1. Get the value (Number or String)
    val_reg = reg_idx[ins[1]]
    val = frame.registers[val_reg]

    # 2. Optional: If it's a String, print it to Stderr
    if val.is_a?(String)
      $stderr.puts(val)
      val = 1 # Return generic error code
    end

    # 3. Kill the VM immediately
    throw EXIT_SIGNAL, val
  end

  def process_freeze(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    val = frame.registers[target]
    # Ruby's native freeze works on Arrays, Hashes, and Strings
    val.freeze
  end

  def process_throw(reg_idx, ins, frame)
    $logger.debug("IN THROW")
    r_msg = reg_idx[ins[1]]
    error_obj = frame.registers[r_msg]

    # Pass control to the unwinding mechanism
    raise_error(error_obj)
  end

  def process_throw_if_error(reg_idx, ins, frame)
    # THROW_IF_ERROR R_val
    val_reg = reg_idx[ins[1]]
    val = frame.registers[val_reg]
    $logger.debug("IN THROW_IF_ERROR: #{val} => #{val.class}")

    # Check if it is an Error Struct
    if val.is_a?(Hash) && val["__type"] == "Error"
      # Stop execution and unwind to the nearest CATCH
      raise_error(val)
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
    when "Any" then return true;
    when "Number" then return val.is_a?(Numeric);
    when "String" then return val.is_a?(String);
    when "Bool" then return (val == true || val == false);
    else
      # Recursive Struct Check: Check against the schema registry
      if structs_registry.key?(required_type)
        schema = structs_registry[required_type]

        # Must be a Hash (Runtime Struct)
        return false unless val.is_a?(Hash)

        # Check every field recursively
        schema.each do |field, field_type|
          return false unless val.key?(field)

          # RECURSIVE CALL: Check the field's value against the field's required type
          return false unless check_type(val[field], field_type, structs_registry)
        end
      return true # All fields checked out
      else
        # Unknown type name (e.g., a custom type that wasn't defined)
        return false
      end
    end
  end

  def raise_error(error_obj)
    # 1. Loop through the frame stack (unwind from deepest function)
    while @frames.any?
      frame = @frames.last

      # 2. Check current function's chunk for a handler
      handler = frame.chunk.handler_info

      if handler && !handler.empty?
        # CAUGHT! (Since it's function-level, we always catch if handler_info is present)

        # A. Set IP to handler start
        frame.ip = handler[:handler]

        # B. Inject the error object into the designated register (R_err)
        frame.registers[handler[:err_reg]] = error_obj

        return # Resume the run_loop where the IP is now the CATCH block
      else
        # UNWINDING: Pop and Signal!
        @frames.pop
      end
    end

    # If the stack is empty, the error was unhandled
    abort "CRITICAL UNHANDLED ERROR: #{error_obj.inspect}"
  end

  def run_code(code_str)
    tokens = Lexer.new(code_str).tokenize
    ast = Parser.new(tokens).parse

    compiler = Compiler.new("main")

    chunk = compiler.compile(ast)
    print_all_chunks(chunk)

    vm = VM.new(code_str)
    resp = vm.run(chunk)

    # Clean-up Resp -- necesarry because there's no true integer system yet.
    if resp.is_a?(Float) && resp == 0.0
      resp = 0.to_i
    end

    [resp, chunk]
  end

  def run_file(fname)
    code = File.open(ARGV.first).read()
    $logger.debug("==== CODE =====")
    $logger.debug("\n" + code.lines.each_with_index.map { |l, idx| "L:#{(idx + 1).to_s.rjust(4, '0')}: #{l}" }.join())

    resp, chunk = run_code(code)

    File.binwrite(ARGV.first + 'c', chunk.to_h.to_msgpack)  # Fast, compact

    resp
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
end

