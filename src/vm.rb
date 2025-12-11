require "byebug"
require "logger"

require_relative "lexer"
require_relative "parser"
require_relative "annotator"
require_relative "compiler"
require_relative "types"
require_relative "memory_visualizer"
require_relative "value"
require_relative "opcodes"
require_relative "chunk"
require_relative "frame"
require_relative "optimizer"

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

  def initialize(code_str = "", args = [])
    @globals = {} # To store global structs/functions
    @structs = {} # Stores "Name" => { "field" => "Type" }
    @source_lines = code_str.lines


    flux_str_args = args.map do |arg|
      Value.box_obj(FluxString.new(arg, register: :static))
    end

    # 2. Create a FluxArray (Boxed)
    #    Type :obj because it holds Pointers (to Strings), not raw bytes
    argv_obj = FluxArray.new(flux_str_args.size, flux_str_args, type: :obj, register: :static)

    @globals["argv"] = Value.box_obj(argv_obj)
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

  def is_error?(boxed_val)
    # 1. Check Tag
    tag = Value.get_tag(boxed_val)
    return false if tag != Value::TAG_OBJ

    # 2. Unbox
    val = Value.as_obj(boxed_val)

    (val.is_a?(FluxArray) && val.struct_type == :Error) || # Standard Error
      (val.is_a?(FluxHash) && val["__type"] == :Error) || # Test Code Error
      val.is_a?(RuntimeError) # Internal Error - *should't* ever happen
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
    ip = frame.ip.to_s.rjust(4, "0")
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

  # TODO: How to do structs where schema is unknown?
  def process_new_hash(target_reg, args, frame)
    Value.box_obj(FluxHash.new)
  end

  def process_new_struct(target_reg, args, frame)
    struct_name = args[0].to_sym

    # 1. Look up Schema to determine Size
    schema = @structs[struct_name] # e.g. { x: :Number, y: :Number }
    size = schema.keys.size

    # 2. Allocate Binary Array (NanBoxed storage = :int64)
    # This creates a flat binary blob of size * 8 bytes
    obj = FluxArray.new(size, nil, type: :nanbox)

    # 3. Store Metadata (We need to know it's a "Point", not just an Array)
    # We can attach this to the object singleton, or wrap it.
    # For a prototype, let's just monkey-patch the type name onto this instance.
    obj.struct_type = struct_name

    Value.box_obj(obj)
  end

  def process_set_field(target_reg, args, frame)
    boxed_obj = args[0]
    boxed_val = args[1]
    index = args[2]

    struct_obj = Value.resolve_val(boxed_obj)
    if struct_obj.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    struct_obj.write_at(index, boxed_val)

    nil
  end

  def process_set_hash(target_reg, args, frame)
    boxed_hash = args[0]
    boxed_val = args[1]
    key = args[2].to_sym

    hash_obj = Value.as_obj(boxed_hash)
    if hash_obj.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    hash_obj[key] = boxed_val

    nil
  end

  def process_get_hash(target_reg, args, frame)
    boxed_hash = args[0]
    key = args[1].to_sym

    hash_obj = Value.as_obj(boxed_hash)
    hash_obj[key]
  end

  def process_new_list(target_reg, args, frame)
    if args.first.nil?
      type = :obj
      size = nil
    else
      size = args.first
    end
    Value.box_obj(FluxArray.new(size, nil, type: type))
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

  def process_cast(target_reg, args, frame)
    type_name = args[0].to_sym

    # 1. Read Input (In-place operation)
    val_boxed = frame.registers[target_reg]
    tag = Value.get_tag(val_boxed)

    if type_name == :String
      str = Value.unbox(val_boxed).to_s
      return Value.box_obj(FluxString.new(str, register: true))

    elsif type_name == :Number
      if tag == Value::TAG_BYTE
        # Promote Byte -> Number (Float)
        raw = Value.as_byte(val_boxed)
        return Value.box_number(raw)
      elsif tag == Value::TAG_NUMBER
        return val_boxed # Already a Number
      end
      raise "Cast Error: Cannot cast #{tag} to Number"

    elsif type_name == :Byte
      if tag == Value::TAG_NUMBER
        # Demote Number -> Byte (Truncate)
        raw = Value.as_number(val_boxed)
        return Value.box_byte(raw.to_i)
      elsif tag == Value::TAG_BYTE
        return val_boxed # Already a Byte
      end
      raise "Cast Error: Cannot cast #{tag} to Byte"

    elsif type_name == :Bool
      if tag == Value::TAG_BOOL
        return val_boxed
      end
      raise "Cast Error: Cannot cast #{tag} to Bool"

    elsif type_name.to_s.include?("[")
      return process_array_cast(val_boxed, type_name, tag)


    elsif @structs.key?(type_name)
      unless check_type(val_boxed, type_name, @structs)
        raise "Runtime Error: Struct validation failed for '#{type_name}'"
      end
    else
      raise "Runtime Error: Unknown Type '#{type_name}'"
    end
  end

  def process_array_cast(val_boxed, type_name, tag)
    raise "ARRAY CAST ERROR" if tag != Value::TAG_OBJ
    list_obj = Value.as_obj(val_boxed)
    match = type_name.to_s.match(/^(\w+)\[(.*)\]$/)

    raise "UNKNOWN ARRAY TYPE" if match.nil?

    base_type = match[1]
    constraint = match[2]

    storage_type = :obj
    storage_type = :int64 if base_type == "Int64"
    storage_type = :byte if base_type == "Byte"
    # TODO storage_type = :number if base_type == "Number"

    if constraint =~ /^\d+$/
      limit = constraint.to_i
      if list_obj.size > limit
        raise "Runtime Error: Array too large for fixed size #{limit}"
      end
      new_arr = FluxArray.new(limit, list_obj.data, type: storage_type)
      return Value.box_obj(new_arr)
    elsif constraint == "*"
      new_arr = FluxArray.new(list_obj.size, list_obj.data, type: storage_type)
      return Value.box_obj(new_arr)
    end
  end

  def process_def_global(target_reg, args, frame)
    global_name = args[0]
    boxed_val = args[1]
    @globals[global_name] = boxed_val
    nil
  end

  def process_get_global(target_reg, args, frame)
    name = args[0]
    val = @globals[name]

    if val.nil?
      raise "Runtime Error: Undefined Global '#{name}'"
    end

    val
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
    registration = captures.empty? ? :static : true
    closure = FluxClosure.new(fn_chunk, captures, register: registration)
    Value.box_obj(closure)
  end

  def process_call_func(target_reg, args, frame)
    func_name = args.shift
    arity = args.shift

    boxed_func = @globals[func_name]

    func_obj = if boxed_func.is_a?(Chunk)
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
    $logger.debug("Call returned: #{Value.to_native(result)} -> Writing to R#{target_reg}")

    return result
  end

  def process_call_method(target_reg, args, frame)
    boxed_obj = args.shift()
    method_name = args.shift().to_sym

    obj = Value.resolve_val(boxed_obj)

    is_heap_arr = obj.is_a?(FluxArray)
    is_stack_arr = obj.is_a?(MemorySlice)

    if (is_heap_arr || is_stack_arr) && method_name == :map
      boxed_closure = args[0]
      closure_obj = Value.as_obj(boxed_closure)

      # Result is on the heap, even for stack as of now.
      data = obj.respond_to?(:to_boxed_a) ? obj.to_boxed_a : obj.data

      new_list = data.map do |item_boxed|
        invoke_function(closure_obj, [item_boxed], frame) # TODO: What about errors?
      end
      result_obj = FluxArray.new(nil, new_list)
      return Value.box_obj(result_obj)

    # B. Struct Field Function
    elsif obj.is_a?(FluxHash) && obj.key?(method_name)
      func_boxed = obj[method_name]
      func_obj = Value.as_obj(func_boxed)
      # Safety: Check if it is callable
      unless func_obj.is_a?(FluxClosure) || func_obj.is_a?(Chunk)
        raise "Runtime Error: Property '#{method_name}' is not a function."
      end
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

  def process_add_nan(target_reg, args, frame)
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

      else
        raise "Runtime Error: Invalid operands for ADD: [#{tag_a}, #{tag_b}]"
      end

    result
  end

  # 2. INT64 MATH (Heap Pointers)
  def process_add_int64(target, args, frame)
    ptr_a = args[0]
    ptr_b = args[1]

    # Deref
    obj_a = Value.as_obj(ptr_a)
    obj_b = Value.as_obj(ptr_b)

    # Math
    new_obj = obj_a + obj_b

    # Box Pointer
    Value.box_obj(new_obj)
  end

  def process_concat_str(target, args, frame)
    # 1. Extract raw strings (handles Stack vs Heap automatically)
    str_a = Value.resolve_string_data(args[0])
    str_b = Value.resolve_string_data(args[1])

    # 2. Combine and Allocate new Heap String
    new_str = FluxString.new(str_a + str_b, register: true)

    Value.box_obj(new_str)
  end

  def process_concat_arr(target, args, frame)
    arr_a = Value.resolve_array_data(args[0])
    arr_b = Value.resolve_array_data(args[1])

    # 2. Combine and Allocate new HEAP Array
    # For now, default to HEAP objects.
    # TODO: Do this efficiently.
    new_arr = FluxArray.new(nil, arr_a + arr_b, type: :obj)

    Value.box_obj(new_arr)
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
    val = Formatter.to_native(boxed_val)
    puts "STDOUT > #{val}"
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
    boxed_seq = args[0]
    boxed_index = args[1]

    index = Value.unbox(boxed_index)
    seq = Value.resolve_val(boxed_seq)
    seq.read_at(index)
  end

  def process_set_index(target_reg, args, frame)
    boxed_seq = args[0]
    boxed_index = args[1]
    boxed_val = args[2]

    seq = Value.resolve_val(boxed_seq)
    if seq.frozen?
      raise "Runtime Error: Cannot modify immutable object."
    end

    index = Value.unbox(boxed_index)
    seq.write_at(index, boxed_val)

    nil
  end

  def process_get_field(target_reg, args, frame)
    boxed_obj = args[0]
    index = args[1]
    obj = Value.resolve_val(boxed_obj)
    obj.read_at(index)
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

  # Unused
  def process_take_ref(target_reg, args, frame)
    boxed_val = args[0]
    ptr = FluxHeapPtr.new(boxed_val)
    Value.box_obj(ptr)
  end

  def process_new_slice(target_reg, args, frame)
    boxed_owner = args[0]
    boxed_start = args[1]
    boxed_end = args[2]

    s_idx = Value.unbox(boxed_start).to_i
    e_idx = Value.unbox(boxed_end).to_i

    # Unbox, don't deref.
    # If owner_obj is a MemorySlice, the new MemorySlice will wrap it (View of View).
    owner_obj = Value.as_obj(boxed_owner)

    len = e_idx - s_idx + 1
    if len < 0
      raise "Runtime Error: Invalid Slice range (End < Start)"
    end

    slice = MemorySlice.new(owner_obj, s_idx, len)
    Value.box_obj(slice)
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

  # TODO: Support multi-dimensional arrays
  def process_alloca(target_reg, args, frame)
    type_str = args[0]
    struct_name = nil # TODO???

    # If any non-struct types have size > 1, this needs updated.
    if type_str.include?("[")
      type_str, size = type_str.split("[", 2)
      struct_name = type_str.to_sym

      type_size = @structs.has_key?(type_str.to_sym) ?
        type_size = @structs[type_str.to_sym].keys.size :
        1
      size = size.to_i * type_size
    else
      struct_name = type_str.to_sym
      schema = @structs[struct_name]
      size = schema.keys.size
    end

    offset = frame.alloca(size)

    ptr = MemorySlice.new(frame.stack_blob, offset, size)

    Value.box_obj(ptr)
  end

  def process_mem_copy(target_reg, args, frame)
    dest_slice = Value.resolve_val(args[0])
    src_obj = Value.resolve_val(args[1]) # Could be MemorySlice or Heap Object
    size = args[2]

    # 1. Validate Destination (Must be Stack Memory)
    unless dest_slice.is_a?(MemorySlice)
      raise "Runtime Error: MEM_COPY destination must be a Stack Pointer."
    end

    # 2. OPTIMIZATION: Bulk Binary Copy
    # Only possible if BOTH are binary blobs (Strings).
    # We check if underlying storage is a String.
    dest_blob = dest_slice.container.data
    src_blob  = src_obj.is_a?(MemorySlice) ? src_obj.container.data : src_obj.data

    if dest_blob.is_a?(String) && src_blob.is_a?(String)
      # Calculate byte offsets
      # If type is :byte, multiplier is 1. If :nanbox/:int64, multiplier is 8.
      dest_mult = (dest_slice.container.type == :byte) ? 1 : 8
      src_mult  = (src_obj.respond_to?(:container) && src_obj.container.type == :byte) ? 1 : 8

      # Handle Source Offset (0 if it's a raw Array, .offset if it's a Slice)
      src_offset_idx = src_obj.is_a?(MemorySlice) ? src_obj.offset : 0

      # Perform low-level string copy
      bytes_to_copy = size * src_mult
      raw_bytes = src_blob.byteslice(src_offset_idx * src_mult, bytes_to_copy)

      # Write to dest
      dest_blob[dest_slice.offset * dest_mult, bytes_to_copy] = raw_bytes

      return nil
    end

    # 3. FALLBACK: The Unified Loop (Polymorphic)
    # This handles ALL other cases:
    # - Copying :obj Array -> :nanbox Stack
    # - Copying :nanbox Stack -> :obj Array
    # - Copying Strings, etc.

    (0...size).each do |i|
      # read_at handles the source offset logic internally
      val = src_obj.read_at(i)

      # write_at handles the dest offset logic internally
      dest_slice.write_at(i, val)
    end


    nil
  end

  def process_tail_call(target_reg, args, frame)
    func_name = args.shift
    arity = args.shift

    # 2. Resolve the Function Object
    boxed_func = @globals[func_name]

    func_obj = if boxed_func.is_a?(Chunk)
                 boxed_func
               elsif boxed_func
                 Value.as_obj(boxed_func)
               else
                 nil
               end

    if func_obj.nil?
      raise "Runtime Error: Undefined function '#{func_name}'"
    end

    # 3. Unwrap Closure vs Chunk
    if func_obj.is_a?(FluxClosure)
      next_chunk = func_obj.chunk
      captures = func_obj.captures
    else
      next_chunk = func_obj
      captures = []
    end

    # =========================================================
    # 4. GARBAGE COLLECTION (Arena Rewind)
    # =========================================================
    # We are about to wipe the memory of the current frame.
    # We must ensure the things we need for the NEXT frame survive.

    # What must survive?
    # A. The Arguments for the next function
    # B. The Captures for the next function
    # C. The Closure Object itself (if it was created in this scope)
    roots = args + captures
    roots << func_obj if func_obj.is_a?(FluxClosure)

    # A. Promote: Move roots to safety (Caller's heap space)
    survivors = []
    roots.each do |root|
      # promote returns the survivor (or nil if it wasn't in the arena)
      s = Arena.current.promote(root)
      survivors << s if s
    end
    survivors.flatten!

    # B. Rewind: Kill all local variables allocated in this frame
    Arena.current.rewind(frame.arena_mark)

    # C. Register: Add survivors back to the live set
    #    This ensures the new function doesn't overwrite our args
    #    when it starts allocating its own objects.
    survivors.each { |s| Arena.current.register(s) }

    # =========================================================
    # 5. MUTATE THE CURRENT FRAME (TCO)
    # =========================================================
    # Instead of pushing a new frame, we repurpose the current one.

    # A. Overwrite Arguments
    # We write the new argument values into the registers starting at 0.
    # Since 'args' contains values already read from the old registers,
    # we don't have to worry about overwriting a source register before reading it.
    args.each_with_index do |arg_val, i|
      frame.registers[i] = arg_val
    end

    # B. Overwrite Captures
    # If the new function is a closure, it expects captures after the args.
    offset = args.size
    captures.each_with_index do |cap_val, i|
      frame.registers[offset + i] = cap_val
    end

    # May need to do this, in Crystal / Zig, this would just be memset.
    #start_wipe = offset + captures.size
    #(start_wipe...256).each do |i|
    #  frame.registers[i] = nil
    #end

    # C. Reset Stack Scratchpad
    # CRITICAL: We are restarting the frame, so we wipe the scratchpad allocation.
    # The new function gets the full 1KB blob to work with.
    frame.stack_pointer = 0

    # C. Swap the Code
    frame.chunk = next_chunk

    # D. Reset Instruction Pointer
    # The run_loop does `ins = chunk[ip]; ip += 1`.
    # By setting it to 0 here, the NEXT iteration of the loop will
    # read instruction 0 of the NEW chunk.
    frame.ip = 0
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
           return false unless check_type(val[field], field_type.to_sym, structs_registry)  # TODO: CHECK .to_sym
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
  # Returns the object to chain later if needed
  def pop_and_return(keep_obj)
    debug_memory()
    frame = @frames.last
    return nil unless frame

    # 1. RVO: Save the object from the upcoming purge
    #    (If it's already promoted/safe, this is a no-op)
    survivors = Arena.current.promote(keep_obj)

    # 2. POISON: Kill everything allocated in this specific frame
    Arena.current.rewind(frame.arena_mark)

    # 3. RE-STACK: Place the survivor back on the top of the stack (Caller's scope)
    #    Arena.register adds it to the END of @allocations.
    #    Since we just rewound, the "End" is now the top of the Caller's frame
    survivors.each { |s| Arena.current.register(s) }

    # 4. POP: Remove the execution context
    @frames.pop

    return keep_obj
  end

  def run_code(code_str, fname = "")
    tokens = Lexer.new(code_str).tokenize
    ast = Parser.new(tokens, code_str).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)

    compiler = Compiler.new("main", :Number, code_str, fname)

    chunk = compiler.compile(ast)
    optimizer = Optimizer.new()
    chunk = optimizer.optimize(chunk)

    print_all_chunks(chunk)

    resp = run(chunk)
    resp = Formatter.to_native(resp)
    resp = resp.is_a?(Float) ? resp.to_i : resp

    [resp, chunk]
  end

  def run_file(fname)
    code = File.open(fname).read()
    $logger.debug("==== CODE =====")
    $logger.debug("\n" + code.lines.each_with_index.map { |l, idx| "L:#{(idx + 1).to_s.rjust(4, '0')}: #{l}" }.join())

    resp, chunk = run_code(code, fname)

    File.binwrite(ARGV.first + 'c', chunk.to_h.to_msgpack)  # Fast, compact

    resp
  end

  # Recursive code printer
  def print_all_chunks(chunk)
    chunk.disassemble
    chunk.constants.each do |const|
      if const.is_a?(Chunk)
        print_all_chunks(const)
      end
    end
  end
end

