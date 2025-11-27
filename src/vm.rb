#! /usr/bin/env ruby

require "byebug"
require_relative "lexer"
require_relative "parser"
require_relative "compiler"
require "msgpack"
require "optparse"
require "logger"

$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{severity}] #{msg}\n"
end

OptionParser.new do |opts|
  opts.on('--log-level LEVEL', 'Set log level (DEBUG, INFO, WARN, ERROR)') do |level|
    $logger.level = Logger.const_get(level.upcase)
  end
end.parse!

# ==========================================
# 6. THE VIRTUAL MACHINE
# ==========================================
class VM
  UNWIND_SIGNAL = :__vm_unwind_signal__
  EXIT_SIGNAL = :__vm_program_exit__

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
    # 1. Capture the stack depth when this specific loop starts
    start_depth = @frames.size

    catch(EXIT_SIGNAL) do
    catch(UNWIND_SIGNAL) do
    loop do
      # If we catch the tag, it means the program is DONE.
      # Return the result (the value)
      #if tag == EXIT_SIGNAL
      #   byebug
      #   return result
      #end

      frame = @frames.last

      # Safety check: If we somehow popped below our depth without returning
      return UNWIND_SIGNAL if !frame || @frames.size < start_depth

      # 2. Fetch Instruction
      ins = frame.chunk.code[frame.ip]
      frame.ip += 1

      $logger.debug("PROCESS: #{ins}")

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
      when :SETFIELD then process_setfield(reg_idx, ins, frame);
      when :SETHASH then process_sethash(reg_idx, ins, frame);
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
      when :SMOOTH then process_pipe(reg_idx, ins, frame);
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

      # RETURN IS SPECIAL
      # IT MUST BE DIRECTLY IN MAIN_LOOP TO BREAK IT
      when :RETURN then
        val = process_return(reg_idx, ins, frame, start_depth)
        return val unless val.nil?
      end
    end
    end
    end
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
    frame.registers[target] = {}
  end

  def process_newstruct(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    struct_name = ins[2]
    # We can implement Structs simply as Ruby Hashes for now
    # You might want to store the struct_name in a special key like '__type'
    frame.registers[target_reg] = { "__type" => struct_name }
  end

  def process_setfield(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    key = ins[2]
    val_reg = reg_idx[ins[3]]

    target = frame.registers[target_reg]
    val = frame.registers[val_reg]

    # Safety Check
    unless target.is_a?(Hash)
      raise "Runtime Error: Cannot set field '#{key}' on #{target.class}"
    end

    target[key] = val
  end

  def process_sethash(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    key = ins[2]
    val_reg = reg_idx[ins[3]]
    frame.registers[target][key] = frame.registers[val_reg]
  end

  def process_newlist(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    frame.registers[target] = []
  end

  def process_append(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    val_reg = reg_idx[ins[2]]
    frame.registers[target] << frame.registers[val_reg]
  end

  def process_cast(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    type_name  = ins[2]
    val = frame.registers[target_reg]
    schema = @structs[type_name] # Assuming @structs is the global registry

    $logger.debug("TRY CAST TO #{type_name}")

    # --- 1. PRIMITIVES / COERCION ---
    if type_name == "String"
      # Fix #1: Coercion
      frame.registers[target_reg] = val.to_s
      $logger.debug("SUCCESFULLY CASTED: #{val.to_s}")
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
      unless check_type(val, type_name, @structs)
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
    @structs[name] = schema
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
    # Format: [:CALL_FUNC, "R_target", "func_name", argc, "R_arg1"...]
    target_reg = reg_idx[ins[1]]
    func_name = ins[2]
    # argc = ins[3] (Unused here, but useful for Arity checks)
    arg_regs = ins[4..-1].map { |r| reg_idx[r] }
    args = arg_regs.map { |r| frame.registers[r] }

    # 1. Resolve the Function
    # Priority:
    #   A. Is it a variable in the current scope? (e.g., VAR f = FN...)
    #   B. Is it a global function? (e.g., defined with FN name...)

    # Check if 'func_name' matches a local variable holding a Closure
    # (This requires your compiler to support first-class functions in vars)
    # local_reg = resolve_local_reg(func_name) ... (Skipping for v0.1 simplicity)
    # Check Globals (Standard Definitions)
    raise "Runtime Error: Undefined function '#{func_name}'" unless @globals.key?(func_name)
    func = @globals[func_name]

    # 2. Execute the Function
    # execute_function spins up a new frame, runs the loop, and returns the :RETURN value
    result = execute_function(func, args)
    $logger.debug("Call returned: #{result.inspect} -> Writing to R#{target_reg}")

    # DON'T OBLITERATE REGISTER ON ERROR
    return if result == UNWIND_SIGNAL

    # 3. Store the result in the Target Register (CRITICAL for Pipes!)
    frame.registers[target_reg] = result
  end

  def process_call_method(reg_idx, ins, frame)
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

  def process_pipe(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    lhs = reg_idx[ins[2]]
    frame.registers[target] = frame.registers[lhs]
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
    val.is_a?(RuntimeError)
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
    unless list.is_a?(Array) || list.is_a?(String)
       raise "Runtime Error: Attempt to index a #{list.class}"
    end

    # Ruby arrays handle out-of-bounds by returning nil, which works fine for us
    frame.registers[target_reg] = list[index]
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

  def process_throw(reg_idx, ins, frame)
    $logger.debug("IN THROW")
    r_msg = reg_idx[ins[1]]
    error_obj = frame.registers[r_msg]

    # Pass control to the unwinding mechanism
    raise_error(error_obj)
  end

  def process_throw_if_error(reg_idx, ins, frame)
    $logger.debug("IN THROW_IF_ERROR")
    # THROW_IF_ERROR R_val
    val_reg = reg_idx[ins[1]]
    val = frame.registers[val_reg]

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

      if handler
        # CAUGHT! (Since it's function-level, we always catch if handler_info is present)

        # A. Set IP to handler start
        frame.ip = handler[:handler]

        # B. Inject the error object into the designated register (R_err)
        frame.registers[handler[:err_reg]] = error_obj

        return # Resume the run_loop where the IP is now the CATCH block
      else
        # UNWINDING: Pop and Signal!
        @frames.pop

        # If we just pop, the loop continues and returns nil.
        # We throw :vm_unwind to force run_loop to stop immediately.
        throw UNWIND_SIGNAL
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

    vm = VM.new()
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
    $logger.debug("\n" + code)

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


if __FILE__ == $0
  vm = VM.new()
  puts vm.run_file(ARGV.first)
end

