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

  ReturnSignal = Struct.new(:value)

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
      type = if i < signature.size
               signature[i]
             else
               # We are deeper than the signature.
               # If the signature ends with T_REST, treat this as T_REST.
               if signature.last == OpCodes::T_REST
                 OpCodes::T_REST
               else
                 # Should not happen if Compiler validates correctly
                 raise "VM Error: Too many operands for #{opcode}"
               end
             end

      # 2. Resolve T_REST -> T_REG_R
      # T_REST is just a marker saying "The rest are Register Reads"
      type = OpCodes::T_REG_R if type == OpCodes::T_REST

      case type
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
      when OpCodes::T_RAW, OpCodes::T_UINT, OpCodes::T_REST
        operand # Pass the raw instruction data (e.g. the Schema Hash, Int)
      else
        operand # Fallback
      end
    end
  end

  AST::OP_CODE_SENDABLE_SYMS.keys.each do |op|
    define_method("process_#{op.to_s.downcase}") do |target_reg, args, frame|
      process_sendable_symbol(target_reg, args, frame, op)
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
        elsif result.is_a?(ReturnSignal)
          # We finished this function call. Return the unpacked value to the Ruby caller.
          return result.value
        elsif target_reg
          frame.registers[target_reg] = result
        end
      end

      # 4. Execute (The Big Switch)
      case opcode
      when :CAST then process_cast(reg_idx, ins, frame);
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

  def process_set_hash(target_reg, args, frame)
    boxed_hash = args[0]
    key = args[1].to_sym
    boxed_val = args[2]

    hash_obj = Value.as_obj(boxed_hash)
    hash_obj[key] = boxed_val

    nil
  end

  def process_new_list(target_reg, args, frame)
    Value.box_obj(FluxArray.new(nil, []))
  end

  def process_append(target_reg, args, frame)
    boxed_list = args[0]
    boxed_val = args[1]

    list = Value.as_obj(boxed_list)
    if list.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    list << boxed_val

    nil
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

  def process_def_global(target_reg, args, frame)
    global_name = args[0]
    boxed_val = args[1]
    @globals[global_name] = boxed_val
    nil
  end

  def process_def_struct(target_reg, args, frame)
    name = args[0].to_sym
    schema = args[1] # The ruby hash from the compiler
    @structs[name] = schema
    nil
  end

  def process_new_closure(target_reg, args, frame)
    fn_chunk = args.shift()
    captures = args
    closure = FluxClosure.new(fn_chunk, captures)
    Value.box_obj(closure)
  end

  def process_call_func(target_reg, args, frame)
    func_name = args.shift
    arity = args.shift

    boxed_func = @globals[func_name]

    func_obj = if boxed_func.is_a?(Compiler::Chunk)
                 boxed_func
               elsif boxed_func
                 Value.as_obj(boxed_func)
               else
                 nil
               end

    if func_obj.nil?
      raise "Runtime Error: Undefined function '#{func_name}'"
    end

    # 3. Execute
    result = invoke_function(func_obj, args, frame)
    $logger.debug("Call returned: #{result.inspect} -> Writing to R#{target_reg}")

    return result
  end

  def process_call_method(target_reg, args, frame)
    boxed_obj = args.shift()
    method_name = args.shift()

    obj = resolve_val(boxed_obj)

    if obj.is_a?(FluxArray) && method_name == "map"
      boxed_closure = args[0]
      closure_obj = Value.as_obj(boxed_closure)

      new_list = obj.map do |item_boxed|
        invoke_function(closure_obj, [item_boxed], frame) # TODO: What about errors?
      end
      result_obj = FluxArray.new(nil, new_list)
      return Value.box_obj(result_obj)

    # B. Struct Field Function
    elsif obj.is_a?(FluxHash) && obj.key?(method_name)
      func_boxed = obj[method_name]
      func_obj = Value.as_obj(func_boxed)
      return invoke_function(func_obj, args, frame)
    end

    raise "Runtime Error: Unknown method '#{method_name}' on #{obj.class}"
  end

  def process_call_closure(target_reg, args, frame)
    boxed_closure = args.shift()
    arity = args.shift()

    func_obj = Value.as_obj(boxed_closure)

    unless func_obj.is_a?(FluxClosure)
      raise "Runtime Error: Value in R#{closure_reg} is not a Closure."
    end

    return invoke_function(func_obj, args, frame)
  end

  def process_add(target_reg, args, frame)
    val_a = args[0]
    val_b = args[1]

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

    result
  end

  def process_sendable_symbol(target_reg, args, frame, opcode)
    val_a = args[0]
    val_b = args[1]

    tag_a = Value.get_tag(val_a)
    tag_b = Value.get_tag(val_b)
    sym = AST::OP_CODE_SENDABLE_SYMS[opcode]

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

    result
  end

  def process_not(target_reg, args, frame)
    boxed_val = args[0]
    is_falsey = Value.is_falsey?(boxed_val)
    Value.box_bool(is_falsey)
  end

  def process_call_native(target_reg, args, frame)
    class_name = args[0]
    method_name = args[1]
    func_args = args[2..-1] # The rest are boxed values from registers

    # 1. Find the Ruby Class (Security Risk in prod, fun for dev!)
    # Object.const_get("File") returns the actual Ruby File class
    ruby_class = Object.const_get(class_name)

    # 2. Call the method via Ruby reflection
    return ruby_class.send(method_name, *func_args)
  end

  def process_print(target_reg, args, frame)
    boxed_val = args[0]
    val = Value.unbox(boxed_val)
    puts "STDOUT > #{val.inspect}"
    nil
  end

  def process_return(target_reg, args, frame)
    return_val = args[0]

    pop_and_return(return_val)

    if @frames.empty?
     # This is the final program result.
     throw EXIT_SIGNAL, return_val
   end

    return ReturnSignal.new(return_val)
  end

  def process_jmp(target_reg, args, frame)
    target_ip = args[0]
    frame.ip = target_ip
    nil
  end

  def process_jmp_false(target_reg, args, frame)
    boxed_val = args[0]
    target_ip = args[1]

    if Value.is_falsey?(boxed_val)
      frame.ip = target_ip
    end

    nil
  end

  def process_jmp_true(target_reg, args, frame)
    boxed_val = args[0]
    target_ip = args[1]

    return nil if is_error?(boxed_val)
    return nil if Value.is_falsey?(boxed_val)

    frame.ip = target_ip

    nil
  end

  def process_jmp_if_error(target_reg, args, frame)
    boxed_val = args[0]
    target_ip = args[1]

    if is_error?(boxed_val)
      frame.ip = target_ip
    end

    nil
  end

  def process_jmp_if_ok(target_reg, args, frame)
    boxed_val = args[0]
    target_ip = args[1]

    unless is_error?(boxed_val)
      frame.ip = target_ip
    end

    nil
  end


  def process_get_index(target_reg, args, frame)
    boxed_list  = args[0]
    boxed_index = args[1]

    list = Value.as_obj(boxed_list) # FluxArray, FluxString, OR FluxView

    tag = Value.get_tag(boxed_index)
    idx_val = (tag == Value::TAG_NUMBER) ? Value.as_number(boxed_index).to_i : Value.as_byte(boxed_index)

    # 3. Access
    result = list[idx_val]

   if list.is_a?(FluxString) || (list.is_a?(FluxView) && list.owner.is_a?(FluxString))
      # TODO: Why is this special??
      # Box the character string
      Value.box_constant(result)
    else
      # Already boxed
      result
    end
  end

  def process_set_index(target_reg, args, frame)
    boxed_obj = args[0]
    boxed_index = args[1]
    boxed_val = args[2]

    target = Value.as_obj(boxed_obj)
    if target.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    tag = Value.get_tag(boxed_index)
    key = (tag == Value::TAG_NUMBER) ? Value.as_number(boxed_index).to_i : Value.as_byte(boxed_index)

    target[key] = boxed_val

    nil
  end

  def process_get_field(target_reg, args, frame)
    boxed_obj  = args[0]
    field_name = args[1].to_sym

    obj = resolve_val(boxed_obj)

    if !obj.is_a?(FluxHash)
      raise "Runtime Error: Cannot get field '#{field_name}' from #{obj.class}"
    end

    obj[field_name]
  end

  def process_assert(target_reg, args, frame)
    boxed_cond = args[0]
    msg = args[1]

    if Value.is_falsey?(boxed_con)
      raise "🛑 ASSERTION FAILED: #{msg}"
    end

    nil
  end

  def process_exit_program(target_idx, args, frame)
    boxed_val = args[0]
    exit_code = 1 # Default error

    tag = Value.get_tag(boxed_val)

    if tag == Value::TAG_NUMBER
      exit_code = Value.as_number(boxed_val).to_i
    elsif tag == Value::TAG_OBJ
      # If it's a string, print it to stderr
      obj = Value.as_obj(boxed_val)
      if obj.is_a?(FluxString)
        $stderr.puts(obj.to_s)
      end
    end

    throw EXIT_SIGNAL, exit_code
  end

  def process_freeze(target_id, args, frame)
    boxed_val = args[0]
    obj = Value.as_obj(boxed_val)
    if obj.respond_to?(:freeze!)
      obj.freeze!
    end
    nil
  end

  def process_take_ref(target_reg, args, frame)
    boxed_val = args[0]
    ptr = FluxPtr.new(boxed_val)
    Value.box_obj(ptr)
  end

  def process_new_slice(target_reg, args, frame)
    boxed_owner = args[0]
    boxed_start = args[1]
    boxed_end = args[2]

    s_idx = Value.unbox(boxed_start).to_i
    e_idx = Value.unbox(boxed_end).to_i

    # Unbox, don't deref.
    # If owner_obj is a FluxView, the new FluxView will wrap it (View of View).
    owner_obj = Value.as_obj(boxed_owner)

    len = e_idx - s_idx + 1
    if len < 0
      raise "Runtime Error: Invalid Slice range (End < Start)"
    end

    view = FluxView.new(owner_obj, s_idx, len)
    Value.box_obj(view)
  end

  def process_throw(target_reg, args, frame)
    boxed_err = args[0]
    raise_error(boxed_err)
    nil
  end

  def process_throw_if_error(target_reg, args, frame)
    boxed_val = args[0]

    if is_error?(boxed_val)
      raise_error(boxed_val)
    end

    nil
  end

  # Helper to run a function and handle the signal/unwind logic safely
  def invoke_function(func_obj, args, caller_frame)
    result = execute_function(func_obj, args)

    # 1. Propagate Hard Exits (DIE)
    return EXIT_SIGNAL if result == EXIT_SIGNAL

    # 2. Handle Unwinding
    if result == UNWIND_SIGNAL
       # If the caller frame is still alive, the error was caught here.
       # Swallow the signal and return nil.
       if @frames.include?(caller_frame)
         return nil
       else
         # Otherwise, the caller was popped. Keep unwinding.
         return UNWIND_SIGNAL
       end
    end

    # 3. Return Standard Result
    result
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

