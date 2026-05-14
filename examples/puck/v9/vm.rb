require_relative 'compiler'
require_relative 'macro_expander'

# Heap entries are now all the same shape: a payload (always an Array of
# values) plus a refcount. V5's special scalar-string payload is gone —
# strings are stored as arrays of integer codepoints, just like any other
# heap-allocated collection. The bytecode ops differ in how they interpret
# the array (`LOAD_REF` always touches `value[0]`; `ARRAY_GET` indexes),
# but the heap layout is one thing.
HeapValue = Struct.new(:value, :refs)
HeapRef = Struct.new(:id)

# Our VM is a Stack Machine
# ip = instruction pointer (where on the stack we are)
class VM
  def run(program)
    @heap = []
    @files = []
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
        when :ALLOC      then stack.push(allocate_codepoints(code.arg))
        when :ALLOC_CELL then stack.push(allocate_cells([stack.pop]))
        when :ALLOC_ARRAY
          size = stack.pop
          stack.push(allocate_cells(Array.new(size, 0)))
        when :LOAD       then stack.push(retain(memory[code.arg]))
        when :LOAD_REF
          ref = memory[code.arg]
          stack.push(retain(@heap[ref.id].value[0]))
        when :ARRAY_LEN
          ref = stack.pop
          stack.push(@heap[ref.id].value.length)
          release(ref)
        when :MATH       then math(code.arg, stack)
        when :COMPARE    then compare(code.arg, stack)
        when :JUMP       then ip = code.arg
        when :JUMP_IF_FALSE then ip = code.arg unless stack.pop

        when :STORE
          release(memory[code.arg])
          memory[code.arg] = stack.pop

        when :STORE_REF
          new_value = stack.pop
          ref = memory[code.arg]
          release(@heap[ref.id].value[0])
          @heap[ref.id].value[0] = new_value

        when :ARRAY_GET
          index = stack.pop
          ref = stack.pop
          stack.push(retain(@heap[ref.id].value[index]))
          release(ref)

        when :ARRAY_SET
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

        when :SYSCALL then handle_syscall(code.arg, stack)
      end
    end

    cleanup(memory)
  end

  # ID dispatch for syscalls. Each ID is a tiny piece of host (Ruby) plumbing
  # that we deliberately keep narrow so the C VM rewrite in V10 can mirror it
  # 1:1 with `puts` / `fgets` / `fopen` / `fclose`.
  def handle_syscall(id, stack)
    case id
    when 1  # print: top-of-stack value with the same "OUTPUT: " prefix as earlier versions
      value = stack.pop
      puts "OUTPUT: #{display(value)}"
      release(value)
    when 2  # read a line from stdin, push it as a codepoint-array string
      line = $stdin.gets&.chomp || ""
      stack.push(allocate_codepoints(line))
    when 3  # open a file by name (string on stack), push integer handle
      name = display(stack.pop)
      @files << File.open(name, "r")
      stack.push(@files.length - 1)
    when 4  # read a line from open file (handle on stack); push string or 0 at EOF
      handle = stack.pop
      line = @files[handle].gets
      stack.push(line.nil? ? 0 : allocate_codepoints(line.chomp))
    when 5  # close file (handle on stack)
      handle = stack.pop
      @files[handle].close
    when 6  # current monotonic time in milliseconds
      stack.push((Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i)
    when 7  # open file for write (path string on stack) -> push integer handle
      name = display(stack.pop)
      @files << File.open(name, "w")
      stack.push(@files.length - 1)
    when 8  # write string + newline (handle then string on stack)
      string = stack.pop
      handle = stack.pop
      @files[handle].puts(display(string))
      release(string)
    else
      raise "Unknown SYSCALL id #{id}"
    end
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

  # Strings, REF cells, and arrays now share one allocator. The payload is
  # always an Array; the bytecode op decides how to interpret it.
  def allocate_codepoints(str)
    allocate_cells(str.codepoints)
  end

  def allocate_cells(cells)
    id = @heap.length
    @heap << HeapValue.new(cells, 1)
    HeapRef.new(id)
  end

  def retain(value)
    @heap[value.id].refs += 1 if value.is_a?(HeapRef)
    value
  end

  # Refcount-driven release. With strings now stored as codepoint arrays,
  # every heap payload is an Array — we always recurse so any nested refs
  # release first.
  def release(value)
    return unless value.is_a?(HeapRef)

    @heap[value.id].refs -= 1
    if @heap[value.id].refs.zero?
      @heap[value.id].value.each { |v| release(v) }
      @heap[value.id] = nil
    end
  end

  def cleanup(memory)
    memory.each { |value| release(value) }
  end

  # Render a heap value for SYSCALL 1. Codepoint arrays come back as their
  # packed UTF-8 string. Non-ref values (Integers) print directly.
  def display(value)
    return value unless value.is_a?(HeapRef)
    @heap[value.id].value.pack("U*")
  end
end

if __FILE__ == $PROGRAM_NAME
  source_path = ARGV[0] || File.expand_path("example.puck", __dir__)
  code = File.read(source_path)
  tokens = Tokenizer.new(code).tokenize
  core_path = File.expand_path("core.puck", __dir__)
  ast = Parser.new(tokens, core_path: core_path).parse
  ast = MacroExpander.new.expand(ast)
  program = Compiler.new.compile(ast)

  VM.new.run(program)
end
