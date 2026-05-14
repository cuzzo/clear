require_relative 'compiler'
require_relative 'macro_expander'

# A heap entry holds either a string payload (allocated via :ALLOC) or an
# array-of-values payload. The array form is shared by REF cells (a single
# cell holding one value) and ARRAY allocations (N cells). Both forms still
# use a refcount, so allocation/release is the same machinery as V5.
HeapValue = Struct.new(:value, :refs)
HeapRef = Struct.new(:id)

# Our VM is a Stack Machine
# ip = instruction pointer (where on the stack we are)
class VM
  def run(program)
    @heap = []
    run_codes(program[:codes], [], program[:procedures])
  end

  def run_codes(codes, memory, procedures)
    stack = []
    ip = 0

    while ip < codes.length
      code = codes[ip]
      ip += 1
      case code.op
        when :PUSH       then stack.push(code.arg)
        when :ALLOC      then stack.push(allocate_string(code.arg))
        when :ALLOC_CELL then stack.push(allocate_cells([stack.pop]))
        when :ALLOC_ARRAY
          size = stack.pop
          stack.push(allocate_cells(Array.new(size, 0)))
        when :LOAD       then stack.push(retain(memory[code.arg]))
        when :LOAD_REF
          # memory[slot] is a ref to a 1-cell heap entry. Push its value,
          # retaining if the value is itself a ref.
          ref = memory[code.arg]
          stack.push(retain(@heap[ref.id].value[0]))
        when :MATH       then math(code.arg, stack)
        when :COMPARE    then compare(code.arg, stack)
        when :JUMP       then ip = code.arg
        when :JUMP_IF_FALSE then ip = code.arg unless stack.pop

        when :STORE
          # Replace memory[slot] entirely. Release the old contents first.
          release(memory[code.arg])
          memory[code.arg] = stack.pop

        when :STORE_REF
          # Write THROUGH the ref at memory[slot]. The ref itself doesn't
          # change; the cell's payload gets replaced.
          new_value = stack.pop
          ref = memory[code.arg]
          release(@heap[ref.id].value[0])
          @heap[ref.id].value[0] = new_value

        when :ARRAY_GET
          # Stack order: [array_ref, index]. Pop index, then array_ref;
          # push heap[array_ref.id].value[index] (retained if it's a ref);
          # release the array_ref we consumed off the stack.
          index = stack.pop
          ref = stack.pop
          stack.push(retain(@heap[ref.id].value[index]))
          release(ref)

        when :ARRAY_SET
          # Stack order: [array_ref, index, value]. Pop value, index, ref;
          # release the old slot value and the array_ref.
          value = stack.pop
          index = stack.pop
          ref = stack.pop
          release(@heap[ref.id].value[index])
          @heap[ref.id].value[index] = value
          release(ref)

        when :CALL
          result = run_procedure(code.arg, stack, procedures)
          stack.push(result) unless result.nil?

        when :RETURN
          result = stack.pop
          cleanup(memory)
          return result

        # For now, hardcode all SYSCALLs to PRINT / Ruby's `puts`.
        when :SYSCALL
          value = stack.pop
          puts "OUTPUT: #{display(value)}"
          release(value)
      end
    end

    cleanup(memory)
  end

  def math(op, stack)
    right = stack.pop
    left = stack.pop
    stack.push(left.send(op, right))
  end

  def compare(op, stack)
    right = stack.pop
    left = stack.pop
    stack.push(left.send(op, right))
  end

  def run_procedure(procedure, stack, procedures)
    args = stack.pop(procedure[:params].length)
    memory = args
    run_codes(procedure[:codes], memory, procedures)
  end

  def allocate_string(value)
    id = @heap.length
    @heap << HeapValue.new(value, 1)
    HeapRef.new(id)
  end

  # Allocate a heap entry whose payload is an array of cells. Used for
  # both REF cells (size 1) and arrays (size N).
  def allocate_cells(cells)
    id = @heap.length
    @heap << HeapValue.new(cells, 1)
    HeapRef.new(id)
  end

  def retain(value)
    @heap[value.id].refs += 1 if value.is_a?(HeapRef)
    value
  end

  # When a refcount reaches zero, any HeapRefs stored inside the payload
  # also need releasing. Strings carry no nested refs; cell/array payloads
  # may contain refs to other heap entries.
  def release(value)
    return unless value.is_a?(HeapRef)

    @heap[value.id].refs -= 1
    if @heap[value.id].refs.zero?
      payload = @heap[value.id].value
      payload.each { |v| release(v) } if payload.is_a?(Array)
      @heap[value.id] = nil
    end
  end

  def cleanup(memory)
    memory.each { |value| release(value) }
  end

  def display(value)
    return @heap[value.id].value if value.is_a?(HeapRef)

    value
  end
end

if __FILE__ == $PROGRAM_NAME
  code = File.read(File.expand_path("example.puck", __dir__))
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  ast = MacroExpander.new.expand(ast)
  program = Compiler.new.compile(ast)

  VM.new.run(program)
end
