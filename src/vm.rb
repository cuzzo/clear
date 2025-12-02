require "byebug"
require "optparse"
require "logger"

require_relative "lexer"
require_relative "parser"
require_relative "compiler"
require_relative "types"
require_relative "memory_visualizer"
require_relative "value"
require_relative "opcodes"

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

  def initialize(code_str = "")
    @globals = {} # To store global structs/functions
    @structs = {} # Stores "Name" => { "field" => "Type" }
    @source_lines = code_str.lines
  end

  def decode_args(ins, frame)
    opcode = ins[0]
    signature = OpCodes::DEFINITIONS[opcode]

    # Map raw operands (strings) to useful values based on the signature
    ins[1..-1].map.with_index do |operand, i|
      case signature[i]
      when OpCodes::T_REG_W
        # For Write, return the INDEX (integer)
        operand[1..-1].to_i
      when OpCodes::T_REG_R
        # Read: Return the BOXED VALUE from the register (e.g. 0xFFFF000000...)
        idx = operand[1..-1].to_i
        frame.registers[idx]
      when OpCodes::T_CONST
        # For Const, return the ACTUAL VALUE from the chunk
        idx = operand[1..-1].to_i
        frame.chunk.constants[idx]
      when OpCodes::T_STR
        operand.to_s # Return the raw string (e.g. "Point")
      else
        operand # Fallback
      end
    end
  end

  # A "Stack Frame" represents a running function
  class Frame
    attr_accessor :chunk, :ip, :registers, :arena_mark
    def initialize(chunk, arena_mark = 0) # Default 0 for main
      @chunk = chunk
      @ip = 0
      @registers = Array.new(256) # The 256 Registers
      @arena_mark = arena_mark
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
      if v.is_a?(FluxString) then "\"#{v}\""
      elsif v.is_a?(Numeric) then v
      elsif v.is_a?(Compiler::Chunk) then "\\#{v.name}"
      elsif v.is_a?(FluxClosure) then "λ"
      elsif v.is_a?(FluxHash) then "{}:#{v.keys.count}"
      elsif v.is_a?(FluxArray) then "[]:#{v.size}"
      else v.class
      end
    end
  end

  def is_error?(boxed_val)
    # 1. Check Tag
    tag = Value.get_tag(boxed_val)
    return false if tag != Value::TAG_OBJ

    # 2. Unbox
    val = Value.as_obj(boxed_val)

    # 3. Check Type
    (val.is_a?(FluxHash) && val["__type"] == :Error) || val.is_a?(RuntimeError)
  end

  # TODO: Needs to work with NanBox
  def resolve_val(boxed_val)
    # 1. Check Tag: If it's not an Object, it cannot be dereferenced.
    tag = Value.get_tag(boxed_val)
    return boxed_val if tag != Value::TAG_OBJ

    # 2. Unbox: Convert ID -> FluxObject
    obj = Value.as_obj(boxed_val)

    # 3. Recursively Deref (View/Pointer -> Owner)
    while obj.is_a?(FluxView) || obj.is_a?(FluxPtr)
      obj = obj.deref
    end

    # Return the raw FluxObject (FluxArray, FluxHash, FluxString)
    obj
  end

  def run(entry_chunk)
    Arena.reset!
    current_mark = Arena.current.mark
    # 1. Boot the VM with the top-level script
    @frames = [Frame.new(entry_chunk, current_mark)]
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
      reg_idx = ->(r) { r[1..-1].to_i }

      if OpCodes::DEFINITIONS.include?(opcode)
        signature = OpCodes::DEFINITIONS[opcode]
        args = decode_args(ins, frame)
        target_reg = nil
        if signature && signature.first == OpCodes::T_REG_W
          target_reg = args.shift # Remove target from the list passed to logic
        end
        result = send("process_#{opcode.to_s.downcase}", target_reg, args, frame)
        if result == UNWIND_SIGNAL || result == EXIT_SIGNAL
          return result
        end
        if target_reg
          frame.registers[target_reg] = result
        end
      end

      # 4. Execute (The Big Switch)
      case opcode
      when :SET_HASH then process_set_hash(reg_idx, ins, frame);
      when :SET_INDEX then process_set_index(reg_idx, ins, frame);
      when :NEW_LIST then process_new_list(reg_idx, ins, frame);
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
      when :NEW_SLICE then process_new_slice(reg_idx, ins, frame);
      when :TAKE_REF then process_take_ref(reg_idx ins, frame);

      # RETURN IS SPECIAL
      # IT MUST BE DIRECTLY IN MAIN_LOOP TO BREAK IT
      when :RETURN then
        val = process_return(reg_idx, ins, frame, start_depth)
        return val unless val.nil?
      end

      debug_instruction(ins, frame)
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

  def debug_instruction(ins, frame)
    return if $logger.level < Logger::DEBUG
    $logger.debug(debug_str(ins, frame))
  end

  def debug_memory
    return if $logger.level < Logger::DEBUG
    viz = MemoryVisualizer.new(self)
    $logger.debug("--- MERMAID GRAPH START ---")
    $logger.debug(viz.generate_mermaid)
    $logger.debug("--- MERMAID GRAPH END ---")
  end

  def process_loadk(target_reg, args, frame)
    Value.box_constant(args[0])
  end

  def process_move(target_reg, args, frame)
    args[0]
  end

  def process_new_hash(target_reg, args, frame)
    Value.box_obj(FluxHash.new)
  end

  def process_new_struct(target_reg, args, frame)
    struct_name = args[0].to_sym
    obj = FluxHash.new
    obj["__type"] = struct_name # Store type in hidden field to use in CAST
    Value.box_obj(obj)
  end

  def process_set_field(target_reg, args, frame)
    target_boxed = args[0]
    key = args[1].to_sym
    val_boxed = args[2]

    target_obj = resolve_val(target_boxed)

    if target_obj.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end
    unless target_obj.is_a?(FluxHash)
      raise "Runtime Error: Cannot set field '#{key}' on #{target_obj.class}"
    end

    target_obj[key] = val_boxed

    nil
  end

  def process_set_hash(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    key = ins[2].to_sym
    val_reg = reg_idx[ins[3]]

    # 1. UNBOX: Get the FluxHash
    boxed_hash = frame.registers[target_reg]
    hash_obj = Value.as_obj(boxed_hash)

    # 2. Store the boxed value
    val_boxed = frame.registers[val_reg]

    hash_obj[key] = val_boxed
  end

  def process_new_list(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    obj = FluxArray.new(nil, [])
    frame.registers[target] = Value.box_obj(obj)
  end

  def process_append(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    val_reg = reg_idx[ins[2]]

    # 1. UNBOX: Get the actual FluxArray from the register
    boxed_list = frame.registers[target_reg]
    list = Value.as_obj(boxed_list)

    # 2. Get the val (Keep it boxed! Arrays store boxed values)
    val_boxed = frame.registers[val_reg]

    if list.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    list << val_boxed
  end

  def process_cast(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    type_name = ins[2].to_sym
    val_boxed = frame.registers[target_reg]
    tag = Value.get_tag(val_boxed)

    if type_name == :String
      str = Value.unbox(val_boxed).to_s
      frame.registers[target_reg] = Value.box_obj(FluxString.new(str))
      return

    elsif type_name == :Number
      if tag == Value::TAG_BYTE
        raw = Value.as_byte(val_boxed)
        frame.registers[target_reg] = Value.box_number(raw)
        return
      elsif tag == Value::TAG_NUMBER
        return
      end
      raise "Cast Error: Cannot cast #{tag} to Number"

    elsif type_name == :Byte
      if tag == Value::TAG_NUMBER
        raw = Value.as_number(val_boxed)
        frame.registers[target_reg] = Value.box_byte(raw.to_i)
        return
      elsif tag == Value::TAG_BYTE
        return
      end
      raise "Cast Error: Cannot cast #{tag} to Byte"

    elsif type_name == :Bool
      raise "Cast Error" unless tag == Value::TAG_BOOL
      return

    elsif type_name.to_s.include?("[")
      if tag == Value::TAG_OBJ
         list_obj = Value.as_obj(val_boxed)
         match = type_name.to_s.match(/^(\w+)\[(.*)\]$/)

         if match
           constraint = match[2]
           if constraint =~ /^\d+$/
             limit = constraint.to_i
             if list_obj.size > limit
               raise "Runtime Error: Array too large for fixed size #{limit}"
             end
             new_arr = FluxArray.new(limit, list_obj.data)
             frame.registers[target_reg] = Value.box_obj(new_arr)
             return
           elsif constraint == "*"
             new_arr = FluxArray.new(list_obj.size, list_obj.data)
             frame.registers[target_reg] = Value.box_obj(new_arr)
             return
           end
         end
         return
      end

    elsif @structs.key?(type_name)
      unless check_type(val_boxed, type_name, @structs)
        raise "Runtime Error: Struct validation failed for '#{type_name}'"
      end
    else
      raise "Runtime Error: Unknown Type '#{type_name}'"
    end
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
    name = ins[1].to_sym
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
    closure = FluxClosure.new(fn_chunk, captured_values)

    # 3. Store it in the target register
    frame.registers[target] = Value.box_obj(closure)
  end


  def process_call_func(reg_idx, ins, frame)
    # Format: [:CALL_FUNC, "R_target", "Operand", argc, "R_arg1"...]
    target_reg = reg_idx[ins[1]]
    operand = ins[2] # Can be "print" (Global) OR "R4" (Register)

    # 1. Resolve Arguments
    #    (Map directly from instruction -> register index -> value)
    args = ins[4..-1].map { |r_str| frame.registers[reg_idx[r_str]] }

    # 2. Resolve Function
    func = nil

    if operand.start_with?("R")
      # CASE A: Closure in a Register (e.g., "R4")
      r = reg_idx[operand]
      boxed_func = frame.registers[r]
      # UNBOX
      if Value.get_tag(boxed_func) == Value::TAG_OBJ
        func = Value.as_obj(boxed_func)
      end
      raise "Runtime Error: Variable '#{operand}' is nil/not a function" if func.nil?
    else
      # CASE B: Global Name (e.g., "print", "cur")
      boxed_func = @globals[operand]
      if boxed_func.is_a?(Compiler::Chunk)
        func = boxed_func
      elsif boxed_func && Value.get_tag(boxed_func) == Value::TAG_OBJ
        func = Value.as_obj(boxed_func)
      end
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
    res_reg = reg_idx[ins[1]]
    obj_reg = reg_idx[ins[2]]
    method_name = ins[3]

    arg_regs = ins[4..-1].map { |r| reg_idx[r] }
    args = arg_regs.map { |r| frame.registers[r] }

    # 1. RESOLVE
    obj = resolve_val(frame.registers[obj_reg])

    # A. Native Methods (Map)
    if obj.is_a?(FluxArray) && method_name == "map"
      boxed_closure = args[0]
      closure_obj = Value.as_obj(boxed_closure)

      new_list = obj.map do |item_boxed|
        execute_function(closure_obj, [item_boxed])
      end
      result_obj = FluxArray.new(nil, new_list)
      frame.registers[res_reg] = Value.box_obj(result_obj)
      return
    end

    # B. Struct Field Function
    if obj.is_a?(FluxHash) && obj.key?(method_name)
      func_boxed = obj[method_name]
      func_obj = Value.as_obj(func_boxed)
      result = execute_function(func_obj, args)
      return UNWIND_SIGNAL if result == UNWIND_SIGNAL
      frame.registers[res_reg] = result
      return
    end

    raise "Runtime Error: Unknown method '#{method_name}' on #{obj.class}"
  end

  def process_call_closure(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    closure_reg = reg_idx[ins[2]]
    arg_regs = ins[4..-1].map { |r| reg_idx[r] }
    args = arg_regs.map { |r| frame.registers[r] }

    boxed_func = frame.registers[closure_reg]
    func_obj = Value.as_obj(boxed_func)

    unless func_obj.is_a?(FluxClosure)
      raise "Runtime Error: Value in R#{closure_reg} is not a Closure."
    end

    result = execute_function(func_obj, args)
    return if result == UNWIND_SIGNAL
    frame.registers[target_reg] = result
  end

  def process_add(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    val_a = frame.registers[reg_idx[ins[2]]]
    val_b = frame.registers[reg_idx[ins[3]]]

    tag_a = Value.get_tag(val_a)
    tag_b = Value.get_tag(val_b)

    result =
      case [tag_a, tag_b]

      # 1. Number + Number (Fast Math)
      #    Unbox to Float -> Add -> Box result
      when [Value::TAG_NUMBER, Value::TAG_NUMBER]
        Value.box_number(Value.as_number(val_a) + Value.as_number(val_b))

      # 2. Byte + Byte (Wrapping Math)
      #    Unbox to Integer -> Add -> Box result (box_byte handles % 256)
      when [Value::TAG_BYTE, Value::TAG_BYTE]
        raw_a = Value.as_byte(val_a)
        raw_b = Value.as_byte(val_b)
        Value.box_byte(raw_a + raw_b)

      # 3. Mixed Primitive Math (Coerce to Number)
      #    Unbox specific types -> Add -> Box as Number
      when [Value::TAG_NUMBER, Value::TAG_BYTE]
        Value.box_number(Value.as_number(val_a) + Value.as_byte(val_b))
      when [Value::TAG_BYTE, Value::TAG_NUMBER]
        Value.box_number(Value.as_byte(val_a) + Value.as_number(val_b))

      # 4. String Concatenation (LHS is String Object)
      when [Value::TAG_OBJ, Value::TAG_NUMBER],
           [Value::TAG_OBJ, Value::TAG_BYTE],
           [Value::TAG_OBJ, Value::TAG_OBJ]

        obj_a = Value.as_obj(val_a)

        unless obj_a.is_a?(FluxString)
          raise "Runtime Error: Cannot ADD object type #{obj_a.class}"
        end

        # FluxString#+ handles coercion of the RHS argument automatically
        # We simply unbox the RHS to get the raw value (Int/Float/FluxString)
        rhs_unboxed = Value.unbox(val_b)

        Value.box_obj(obj_a + rhs_unboxed)

      # 5. String Concatenation (RHS is String Object)
      when [Value::TAG_NUMBER, Value::TAG_OBJ],
           [Value::TAG_BYTE, Value::TAG_OBJ]

        obj_b = Value.as_obj(val_b)
        unless obj_b.is_a?(FluxString)
          raise "Runtime Error: Cannot ADD object type #{obj_b.class}"
        end

        # Convert LHS primitive to string, create new FluxString, then concat
        lhs_str = Value.unbox(val_a).to_s
        new_str = FluxString.new(lhs_str) + obj_b

        Value.box_obj(new_str)

      else
        raise "Runtime Error: Invalid operands for ADD: [#{tag_a}, #{tag_b}]"
      end

    frame.registers[target] = result
  end

  def process_sendable_symbol(reg_idx, ins, frame, opcode)
    target = reg_idx[ins[1]]
    val_a  = frame.registers[reg_idx[ins[2]]]
    val_b  = frame.registers[reg_idx[ins[3]]]

    tag_a = Value.get_tag(val_a)
    tag_b = Value.get_tag(val_b)
    sym   = AST::OP_CODE_SENDABLE_SYMS[opcode]

    # Helper to decide how to box the result
    is_comparison = [:EQ, :NEQ, :LT, :GT, :LTE, :GTE].include?(opcode)

    result = case [tag_a, tag_b]

             # 1. Number op Number
             when [Value::TAG_NUMBER, Value::TAG_NUMBER]
               res = Value.as_number(val_a).send(sym, Value.as_number(val_b))
               is_comparison ? Value.box_bool(res) : Value.box_number(res)

             # 2. Byte op Byte
             when [Value::TAG_BYTE, Value::TAG_BYTE]
               res = Value.as_byte(val_a).send(sym, Value.as_byte(val_b))
               is_comparison ? Value.box_bool(res) : Value.box_byte(res)

             # 3. Mixed (Promote to Number)
             when [Value::TAG_NUMBER, Value::TAG_BYTE]
               res = Value.as_number(val_a).send(sym, Value.as_byte(val_b))
               is_comparison ? Value.box_bool(res) : Value.box_number(res)

             when [Value::TAG_BYTE, Value::TAG_NUMBER]
               res = Value.as_byte(val_a).send(sym, Value.as_number(val_b))
               is_comparison ? Value.box_bool(res) : Value.box_number(res)

             # 4. Objects (Comparison Only)
             when [Value::TAG_OBJ, Value::TAG_OBJ]
               if is_comparison
                 res = Value.as_obj(val_a).send(sym, Value.as_obj(val_b))
                 Value.box_bool(res)
               else
                 raise "Runtime Error: Invalid math op '#{sym}' on Objects"
               end

             else
               if [:EQ, :NEQ].include?(opcode)
                 # Unbox to compare raw values (Ruby handles nil == nil correctly)
                 raw_a = Value.unbox(val_a)
                 raw_b = Value.unbox(val_b)

                 res = raw_a.send(sym, raw_b)
                 Value.box_bool(res)
              else
                raise "Runtime Error: Invalid operands [#{tag_a}, #{tag_b}] for #{opcode}"
              end
            end

    frame.registers[target] = result
  end

  def process_not(reg_idx, ins, frame)
    # NOT Rtarget, Rsrc
    target = reg_idx[ins[1]]
    src = reg_idx[ins[2]]
    val = frame.registers[src]

    # 1. Determine Truthiness (Simulate System Logic)
    #    In NanBoxing: nil and false have specific bit patterns. Everything else is true.
    is_falsey = Value.is_nil?(val) || (Value.is_bool?(val) && Value.as_bool(val) == false)

    # 2. Invert
    result_bool = is_falsey # If it was falsey, NOT makes it true.

    # 3. Box Result
    frame.registers[target] = Value.box_bool(result_bool)
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
    val = frame.registers[val_reg]

    puts "STDOUT > #{Value.unbox(val).inspect}"
  end

  def process_return(reg_idx, ins, frame, start_depth)
    result_reg = reg_idx[ins[1]]
    return_val = frame.registers[result_reg]

    pop_and_return(return_val)

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

    # Truthiness Logic for NanBoxing:
    # Only TAG_NIL and TAG_BOOL(false) are falsey.
    tag = Value.get_tag(val)

    is_falsey = (tag == Value::TAG_NIL) ||
                (tag == Value::TAG_BOOL && Value.as_bool(val) == false)

    if is_falsey
      frame.ip = target_ip
    end
  end

  def process_jmp_true(reg_idx, ins, frame)
    # JMP_TRUE Rcond, target_ip
    cond_reg = reg_idx[ins[1]]
    target_ip = ins[2]
    val = frame.registers[cond_reg]

    tag = Value.get_tag(val)
    is_falsey = (tag == Value::TAG_NIL) ||
                (tag == Value::TAG_BOOL && Value.as_bool(val) == false)
    is_error  = is_error?(val) # This helper now handles boxing

    if !is_falsey && !is_error
      frame.ip = target_ip
    end
  end

  def process_jmp_if_ok(reg_idx, ins, frame)
    # JMP_IF_OK R_val, target_ip
    val_reg = reg_idx[ins[1]]
    target_ip = ins[2]
    val = frame.registers[val_reg]

    is_error = val.is_a?(FluxHash) && val["__type"] == :Error

    # If it is NOT an error, take the jump (skip the OR block)
    if !is_error
      frame.ip = target_ip
    end
  end

  def process_jmp_if_error(reg_idx, ins, frame)
    # JMP_IF_ERROR R_val, target_ip
    val_reg = reg_idx[ins[1]]
    target_ip = ins[2]

    val = frame.registers[val_reg]

    # Check if it is a Hash (Struct) and has the type "Error"
    if val.is_a?(FluxHash) && val["__type"] == :Error
      frame.ip = target_ip
    end
  end

  def process_get_index(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    list_reg = reg_idx[ins[2]]
    idx_reg = reg_idx[ins[3]]

    # 1. Unbox (Do not Deref)
    boxed_list = frame.registers[list_reg]
    list = Value.as_obj(boxed_list) # FluxArray, FluxString, OR FluxView

    # 2. Unbox Index
    boxed_idx = frame.registers[idx_reg]

    idx_val = 0
    if Value.get_tag(boxed_idx) == Value::TAG_NUMBER
      idx_val = Value.as_number(boxed_idx).to_i
    else
      idx_val = Value.as_byte(boxed_idx)
    end

    # 3. Access
    result = list[idx_val]

    # 4. Box Result
    # If list is String or StringView, result is a raw String char -> Box it
    # If list is Array or ArrayView, result is already a Boxed Value -> Keep it
    if list.is_a?(FluxString) || (list.is_a?(FluxView) && list.owner.is_a?(FluxString))
      frame.registers[target_reg] = Value.box_constant(result)
    else
      frame.registers[target_reg] = result
    end
  end

  def process_set_index(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    key_reg = reg_idx[ins[2]]
    val_reg = reg_idx[ins[3]]

    # 1. Unbox Target
    boxed_target = frame.registers[target_reg]
    target = Value.as_obj(boxed_target)

    # 2. Unbox Key
    boxed_key = frame.registers[key_reg]
    # Assuming integer index for arrays
    key = Value.get_tag(boxed_key) == Value::TAG_NUMBER ? Value.as_number(boxed_key).to_i : Value.as_byte(boxed_key)

    val_boxed = frame.registers[val_reg]

    if target.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    # Target can be FluxArray OR FluxView (if view allows mutation)
    target[key] = val_boxed
  end

  def process_get_field(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    obj_reg = reg_idx[ins[2]]
    field_name = ins[3].to_sym # This is a raw string from the bytecode

    obj = resolve_val(frame.registers[obj_reg])

    # Determine how to read the field based on the object type
    if obj.is_a?(FluxHash)
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

    if Value.get_tag(val) == Value::TAG_OBJ
      obj = Value.as_obj(val)
      if obj.is_a?(FluxString)
        $stderr.puts(obj.to_s)
        val = Value.box_number(1) # Return generic error code
      end
    end

    # 3. Kill the VM immediately
    exit_code = (Value.get_tag(val) == Value::TAG_NUMBER) ? Value.as_number(val).to_i : 1
    throw EXIT_SIGNAL, exit_code
  end

  def process_freeze(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    val = frame.registers[target]
    val.respond_to?(:freeze!) ? val.freeze! # FluxObjects
      : val.freeze # Native Ruby Objects - TODO: Should never happend
  end

  def process_take_ref(reg_idx, ins, frame)
    target = reg_idx[ins[1]]
    src = reg_idx[ins[2]]

    val = frame.registers[src]

    # Create the View
    frame.registers[target] = FluxPtr.new(val)
  end

  def process_new_slice(reg_idx, ins, frame)
    target_reg = reg_idx[ins[1]]
    owner_boxed = frame.registers[reg_idx[ins[2]]]

    s_idx = Value.unbox(frame.registers[reg_idx[ins[3]]]).to_i
    e_idx = Value.unbox(frame.registers[reg_idx[ins[4]]]).to_i

    # Unbox, don't deref.
    # If owner_obj is a FluxView, the new FluxView will wrap it (View of View).
    owner_obj = Value.as_obj(owner_boxed)

    len = e_idx - s_idx + 1

    if len < 0
      raise "Runtime Error: Invalid Slice range (End < Start)"
    end

    view = FluxView.new(owner_obj, s_idx, len)
    frame.registers[target_reg] = Value.box_obj(view)
  end

  def process_throw(reg_idx, ins, frame)
    r_msg = reg_idx[ins[1]]
    error_obj = frame.registers[r_msg]

    # Pass control to the unwinding mechanism
    raise_error(error_obj)
  end

  def process_throw_if_error(reg_idx, ins, frame)
    # THROW_IF_ERROR R_val
    val_reg = reg_idx[ins[1]]
    val = frame.registers[val_reg]

    # Check if it is an Error Struct
    if is_error?(val)
      # Stop execution and unwind to the nearest CATCH
      raise_error(val)
    end
  end

  # Helper to run a chunk synchronously and return its result
  # This mimics a function call overhead
  def execute_function(func_obj, args)
    # Handle case where we might be passed a raw Chunk (main) vs a Closure
    chunk = func_obj.is_a?(FluxClosure) ? func_obj.chunk : func_obj
    captures = func_obj.is_a?(FluxClosure) ? func_obj.captures : []

    # 1. Create a new frame
    current_mark = Arena.current.mark
    frame = Frame.new(chunk, current_mark)

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

  def check_type(val_boxed, required_type, structs_registry)
    tag = Value.get_tag(val_boxed)
    case required_type
    when :Any then return true;
    when :Number then return tag == Value::TAG_NUMBER;
    when :Byte then return tag == Value::TAG_BYTE;
    when :Bool then return tag == Value::TAG_BOOL;
    when :String
      return false unless tag == Value::TAG_OBJ
      return Value.as_obj(val_boxed).is_a?(FluxString)
    else
      # Recursive Struct Check
      if structs_registry.key?(required_type)

        # If we don't check this, Value.as_obj will crash on Numbers
        return false unless tag == Value::TAG_OBJ

        val = Value.as_obj(val_boxed)
        return false unless val.is_a?(FluxHash)

        schema = structs_registry[required_type]

        schema.each do |field, field_type|
          return false unless val.key?(field)
          return false unless check_type(val[field], field_type.to_sym, structs_registry)
        end
        return true
      else
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
        pop_and_return(error_obj)
      end
    end

    # If the stack is empty, the error was unhandled
    abort "CRITICAL UNHANDLED ERROR: #{error_obj.inspect}"
  end

  # Unified logic for leaving a stack frame safely
  # Returns the object so you can chain it if needed
  def pop_and_return(keep_obj)
    debug_memory()
    frame = @frames.last
    return nil unless frame

    # 1. RVO: Save the object from the upcoming purge
    #    (If it's already promoted/safe, this is a no-op)
    Arena.current.promote(keep_obj)

    # 2. POISON: Kill everything allocated in this specific frame
    Arena.current.rewind(frame.arena_mark)

    # 3. POP: Remove the execution context
    @frames.pop

    return keep_obj
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

