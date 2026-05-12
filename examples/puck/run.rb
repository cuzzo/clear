#!/usr/bin/env ruby

require 'io/console'
require 'stringio'

begin
  require 'tty-screen'
  require 'tty-cursor'
  require 'tty-reader'
rescue LoadError
  # The runner can still work without tty-* gems, but tmux/Linux behaves better with them.
end

Frame = Struct.new(:name, :codes, :ip, :memory, :last_ip, keyword_init: true)
TraceHeapValue = Struct.new(:value, :refs)
TraceHeapRef = Struct.new(:id)
TraceState = Struct.new(:frames, :stack, :output, :touched_memory, :heap, :halted, keyword_init: true)
TraceProgram = Struct.new(:version, :source, :codes, :procedures, keyword_init: true)

class VersionLoader
  VERSIONS = ["v1", "v2", "v3", "v4", "v5"]

  def self.load(version, source_path)
    source = File.read(source_path || File.expand_path("#{version}/example.puck", __dir__))
    path = File.expand_path("#{version}/#{version == "v1" ? "puck.rb" : "vm.rb"}", __dir__)

    silence_stdout { Kernel.load path }

    tokens = Tokenizer.new(source).tokenize
    ast = Parser.new(tokens).parse
    compiled = Compiler.new.compile(ast)

    if compiled.is_a?(Hash)
      TraceProgram.new(version: version, source: source, codes: compiled[:codes], procedures: compiled[:procedures])
    else
      TraceProgram.new(version: version, source: source, codes: TraceCompiler.new.compile_calls(compiled), procedures: {})
    end
  end

  def self.silence_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old_stdout
  end
end

class TraceCompiler
  def compile_calls(codes)
    codes.map do |code|
      if code.op == :CALL && code.arg.is_a?(Hash)
        ByteCode.new(:CALL, compile_procedure(code.arg))
      else
        code
      end
    end
  end

  def compile_procedure(procedure)
    return procedure if procedure[:codes]

    if procedure[:expression]
      mem = { procedure[:param] => 0 }
      codes = []
      compile_expression(procedure[:expression], codes, mem)
      codes << ByteCode.new(:RETURN)
      { params: [procedure[:param]], codes: compile_calls(codes) }
    elsif procedure[:body]
      mem = {}
      procedure[:params].each { |param| mem[param] ||= mem.length }
      { params: procedure[:params], codes: compile_statements(procedure[:body], mem) }
    else
      procedure
    end
  end

  def compile_statements(nodes, mem)
    codes = []

    nodes.each do |node|
      if node.type == :Assignment
        compile_expression(node.val, codes, mem)
        codes << ByteCode.new(:STORE, mem[node.var] ||= mem.length)

      elsif node.type == :Return
        compile_expression(node.val, codes, mem)
        codes << ByteCode.new(:RETURN)

      elsif node.type == :If
        compile_expression(node.val[:condition], codes, mem)
        jump = codes.length
        codes << ByteCode.new(:JUMP_IF_FALSE)
        codes.concat(compile_statements(node.val[:body], mem))
        codes[jump].arg = codes.length

      elsif node.type == :Syscall
        codes << ByteCode.new(:LOAD, mem.fetch(node.var))
        codes << ByteCode.new(:SYSCALL, node.val)

      elsif node.type == :CallStatement
        node.val.each { |arg| compile_expression(arg, codes, mem) }
        raise "Nested call statements are not available in this visualizer path"
      end
    end

    compile_calls(codes)
  end

  def compile_expression(expression, codes, mem)
    case expression.type
      when :Integer
        codes << ByteCode.new(:PUSH, expression.value)
      when :String
        codes << ByteCode.new(:ALLOC, { type: :String, value: expression.value })
      when :Variable
        codes << ByteCode.new(:LOAD, mem.fetch(expression.name))
      when :Add
        compile_expression(expression.left, codes, mem)
        compile_expression(expression.right, codes, mem)
        codes << ByteCode.new(:MATH, :+)
      when :Math
        compile_expression(expression.left, codes, mem)
        compile_expression(expression.right, codes, mem)
        codes << ByteCode.new(:MATH, expression.value)
      when :Equal
        compile_expression(expression.left, codes, mem)
        compile_expression(expression.right, codes, mem)
        codes << ByteCode.new(:COMPARE, :==)
      when :Call
        args = expression.respond_to?(:args) && expression.args ? expression.args : [expression.arg]
        args.each { |arg| compile_expression(arg, codes, mem) }
        raise "Nested calls are not available in this visualizer path"
    end
  end
end

class TraceVM
  attr_reader :history, :state

  def initialize(program)
    @program = program
    @state = TraceState.new(
      frames: [Frame.new(name: "main", codes: program.codes, ip: 0, memory: [], last_ip: nil)],
      stack: [],
      output: [],
      touched_memory: nil,
      heap: [],
      halted: false
    )
    @history = [snapshot]
  end

  def step
    return if @state.halted

    frame = current_frame
    if frame.nil? || frame.ip >= frame.codes.length
      cleanup(frame.memory) if frame
      @state.frames.pop
      @state.halted = @state.frames.empty?
      @history << snapshot
      return
    end

    @state.touched_memory = nil
    code = frame.codes[frame.ip]
    frame.last_ip = frame.ip
    frame.ip += 1

    execute(code, frame)
    @history << snapshot
  end

  def back
    return if @history.length <= 1

    @history.pop
    restore(@history.last)
  end

  def current_frame
    @state.frames.last
  end

  def current_code
    frame = current_frame
    return nil unless frame
    frame.codes[frame.ip]
  end

  private

  def execute(code, frame)
    case code.op
      when :PUSH
        @state.stack.push(code.arg)
      when :ALLOC
        @state.stack.push(allocate(code.arg))
      when :LOAD
        @state.touched_memory = code.arg
        @state.stack.push(retain(frame.memory[code.arg]))
      when :STORE
        @state.touched_memory = code.arg
        release(frame.memory[code.arg])
        frame.memory[code.arg] = @state.stack.pop
      when :MATH
        right = @state.stack.pop
        left = @state.stack.pop
        @state.stack.push(left.send(code.arg, right))
      when :COMPARE
        right = @state.stack.pop
        left = @state.stack.pop
        @state.stack.push(left == right)
      when :JUMP
        frame.ip = code.arg
      when :JUMP_IF_FALSE
        frame.ip = code.arg unless @state.stack.pop
      when :CALL
        call_procedure(code.arg)
      when :RETURN
        result = @state.stack.pop
        cleanup(frame.memory)
        @state.frames.pop
        @state.stack.push(result) unless result.nil?
        @state.halted = @state.frames.empty?
      when :SYSCALL
        value = @state.stack.pop
        @state.output << "OUTPUT: #{display(value)}"
        release(value)
    end
  end

  def call_procedure(procedure)
    if procedure[:codes]
      args = @state.stack.pop(procedure[:params].length)
      @state.frames << Frame.new(name: "procedure", codes: procedure[:codes], ip: 0, memory: args, last_ip: nil)
    elsif procedure[:body]
      result = run_ast_procedure(procedure)
      @state.stack.push(result) unless result.nil?
    else
      arg = @state.stack.pop
      @state.stack.push(run_expression(procedure[:expression], { procedure[:param] => arg }))
    end
  end

  def run_ast_procedure(procedure)
    args = @state.stack.pop(procedure[:params].length)
    memory = procedure[:params].zip(args).to_h
    run_statements(procedure[:body], memory)
  end

  def run_statements(nodes, memory)
    nodes.each do |node|
      if node.type == :Assignment
        memory[node.var] = run_expression(node.val, memory)
      elsif node.type == :Return
        return run_expression(node.val, memory)
      elsif node.type == :If
        run_statements(node.val[:body], memory) if run_expression(node.val[:condition], memory)
      elsif node.type == :Syscall
        @state.output << "OUTPUT: #{memory.fetch(node.var)}"
      end
    end

    nil
  end

  def run_expression(expression, memory)
    case expression.type
      when :Integer then expression.value
      when :Variable then memory.fetch(expression.name)
      when :Add then run_expression(expression.left, memory) + run_expression(expression.right, memory)
      when :Math then run_expression(expression.left, memory).send(expression.value, run_expression(expression.right, memory))
      when :Equal then run_expression(expression.left, memory) == run_expression(expression.right, memory)
      when :Call then raise "Nested calls in AST-only procedures are not visualized yet."
    end
  end

  def snapshot
    TraceState.new(
      frames: @state.frames.map { |f| Frame.new(name: f.name, codes: f.codes, ip: f.ip, memory: f.memory.dup, last_ip: f.last_ip) },
      stack: @state.stack.dup,
      output: @state.output.dup,
      touched_memory: @state.touched_memory,
      heap: @state.heap.map { |value| value && TraceHeapValue.new(value.value, value.refs) },
      halted: @state.halted
    )
  end

  def restore(snap)
    @state = TraceState.new(
      frames: snap.frames.map { |f| Frame.new(name: f.name, codes: f.codes, ip: f.ip, memory: f.memory.dup, last_ip: f.last_ip) },
      stack: snap.stack.dup,
      output: snap.output.dup,
      touched_memory: snap.touched_memory,
      heap: snap.heap.map { |value| value && TraceHeapValue.new(value.value, value.refs) },
      halted: snap.halted
    )
  end

  def allocate(arg)
    return allocate_string(arg[:value]) if arg[:type] == :String

    raise "Unexpected allocation type."
  end

  def allocate_string(value)
    id = @state.heap.length
    @state.heap << TraceHeapValue.new(value, 1)
    TraceHeapRef.new(id)
  end

  def retain(value)
    @state.heap[value.id].refs += 1 if value.is_a?(TraceHeapRef)
    value
  end

  def release(value)
    return unless value.is_a?(TraceHeapRef)
    return unless @state.heap[value.id]

    @state.heap[value.id].refs -= 1
    @state.heap[value.id] = nil if @state.heap[value.id].refs.zero?
  end

  def cleanup(memory)
    memory.each { |value| release(value) }
  end

  def display(value)
    return @state.heap[value.id].value if value.is_a?(TraceHeapRef) && @state.heap[value.id]

    value
  end
end

class Renderer
  STACK_WIDTH = 10
  MEMORY_WIDTH = 14
  HEAP_WIDTH = 18
  EFFECT_WIDTH = 20
  MAX_SOURCE_HEIGHT = 10
  MAX_PANE_HEIGHT = 10
  MIN_WIDTH = 70

  def initialize(program, vm)
    @program = program
    @vm = vm
    @source_lines = program.source.lines.map(&:chomp)
    @interactive = STDOUT.tty?
    @cursor = defined?(TTY::Cursor) ? TTY::Cursor : nil
  end

  def render
    height, width = terminal_size
    width = [width - 2, MIN_WIDTH].max
    source_height, pane_height = layout_heights(height)
    rows = [
      render_source(width, source_height),
      render_panes(width, pane_height),
      render_output(width),
      "space: step  backspace: back  q: quit"
    ].join("\n").lines.map(&:chomp)

    rows = rows.first(height)
    rows += Array.new([height - rows.length, 0].max, "")

    clear_and_home + rows.map { |row| truncate(row, width).ljust(width) }.join("\r\n")
  end

  private

  def terminal_size
    if defined?(TTY::Screen)
      return [TTY::Screen.height, TTY::Screen.width]
    end

    [STDOUT, STDIN, IO.console].compact.each do |io|
      rows, cols = io.winsize
      return [rows, cols] if rows.positive? && cols.positive?
    rescue SystemCallError, IOError
      next
    end

    rows, cols = `stty size 2>/dev/null`.split.map(&:to_i)
    return [rows, cols] if rows&.positive? && cols&.positive?

    rows = (ENV["LINES"] || 24).to_i
    cols = (ENV["COLUMNS"] || 80).to_i
    [[rows, 10].max, [cols, MIN_WIDTH].max]
  end

  def layout_heights(height)
    fixed_rows = 1 + 1 + 1 # pane header, output/padding, prompt
    available = [height - fixed_rows, 6].max
    source_height = [[MAX_SOURCE_HEIGHT, available / 2].min, 3].max
    pane_height = [[MAX_PANE_HEIGHT, available - source_height].min, 3].max
    [source_height, pane_height]
  end

  def clear_and_home
    return "" unless @interactive
    return "" if ENV["TERM"] == "dumb"

    if @cursor
      @cursor.clear_screen + @cursor.move_to(0, 0)
    else
      "\e[2J\e[H"
    end
  end

  def render_source(width, source_height)
    focus = source_focus
    start_focus = focus || first_nonblank_line
    start = [[start_focus - 4, 0].max, [@source_lines.length - source_height, 0].max].min
    lines = @source_lines[start, source_height] || [""]
    lines.each_with_index.map do |line, idx|
      line_no = start + idx
      marker = line_no == focus ? ">" : " "
      truncate("#{marker} #{format('%03d', line_no + 1)}: #{line}", width)
    end.join("\n")
  end

  def source_focus
    return nil if @vm.state.halted

    frame = @vm.current_frame
    code = @vm.current_code
    return first_nonblank_line unless frame

    ip = code ? frame.ip : frame.last_ip
    code ||= frame.codes[ip]
    return first_nonblank_line unless code

    return syscall_source_line(frame, ip) if code.op == :SYSCALL
    return syscall_source_line(frame, ip + 1) if code.op == :LOAD && next_op(frame, ip) == :SYSCALL
    call_ip = upcoming_call_ip(frame, ip)
    return call_source_line(frame, call_ip) if call_ip

    patterns = if frame.name == "procedure" && procedure_return_sequence?(frame, ip)
      [/RETURN/]
    else
      case code.op
      when :SYSCALL then [/SYSCALL/]
      when :LOAD
        next_op(frame, ip) == :SYSCALL ? [/SYSCALL/] : condition_patterns(frame, ip)
      when :PUSH, :MATH
        upcoming_store?(frame, ip) ? store_patterns(frame, ip) : condition_patterns(frame, ip)
      when :ALLOC
        upcoming_store?(frame, ip) && code.arg[:type] == :String ? string_store_patterns(code.arg[:value]) : [/\S/]
      when :COMPARE, :JUMP_IF_FALSE
        condition_patterns(frame, ip)
      when :JUMP
        [/\bLOOP\b/, /\bEXIT\b/]
      when :STORE
        store_patterns(frame, ip)
      when :CALL then call_patterns(frame, ip)
      else [/\S/]
      end
    end

    find_source_line(patterns)
  end

  def first_nonblank_line
    @source_lines.index { |line| line.match?(/\S/) } || 0
  end

  def find_source_line(patterns)
    patterns.each do |pattern|
      idx = @source_lines.index { |line| line.match?(pattern) }
      return idx if idx
    end

    first_nonblank_line
  end

  def syscall_source_line(frame, ip)
    syscall_idx = frame.codes[0..ip].count { |code| code.op == :SYSCALL } - 1
    lines = @source_lines.each_index.select { |idx| @source_lines[idx].match?(/SYSCALL/) }
    lines[syscall_idx] || first_nonblank_line
  end

  def call_source_line(frame, ip)
    call_idx = frame.codes[0..ip].count { |code| code.op == :CALL } - 1
    lines = @source_lines.each_index.select do |idx|
      @source_lines[idx].match?(/^\s*(?!PROCEDURE|SYSCALL)(?:\w+\s*:=\s*)?\w+\(.*\);/)
    end
    lines[call_idx] || first_nonblank_line
  end

  def condition_patterns(frame, ip)
    start = [ip - 5, 0].max
    finish = ip
    while finish < frame.codes.length && frame.codes[finish].op != :JUMP_IF_FALSE
      finish += 1
    end

    if finish >= frame.codes.length
      lookahead = frame.codes[ip, 4] || []
      return call_patterns(frame, ip) if lookahead.any? { |code| code.op == :CALL }
      return [/\S/]
    end

    window = frame.codes[start..finish] || []
    ops = window.map(&:op)
    args = window.map(&:arg)

    if ops.include?(:JUMP_IF_FALSE)
      return [/\bIF\b.*%/, /\bIF\b/] if args.include?(:%)
      return [/\bIF\b.*42/, /\bIF\b/] if args.include?(42)
      return [/\bIF\b.*limit/, /\bIF\b/]
    end

    if ops.include?(:CALL)
      return call_patterns(frame, ip)
    end

    [/\S/]
  end

  def next_op(frame, ip)
    frame.codes[ip + 1]&.op
  end

  def upcoming_call_ip(frame, ip)
    idx = ip
    while idx < frame.codes.length
      op = frame.codes[idx].op
      return idx if op == :CALL
      return nil if [:STORE, :SYSCALL, :RETURN, :JUMP, :JUMP_IF_FALSE].include?(op)
      idx += 1
    end

    nil
  end

  def upcoming_store?(frame, ip)
    (frame.codes[ip, 4] || []).any? { |code| code.op == :STORE }
  end

  def call_patterns(_frame, _ip)
    [/^\s*(?!PROCEDURE)\w+\s*:=.*\w+\(.*\);/, /^\s*(?!PROCEDURE|SYSCALL)\w+\(.*\);/]
  end

  def procedure_return_sequence?(frame, ip)
    start = [ip - 3, 0].max
    finish = [ip + 3, frame.codes.length - 1].min
    (frame.codes[start..finish] || []).any? { |code| code.op == :RETURN }
  end

  def store_patterns(frame, ip)
    previous = frame.codes[[ip - 4, 0].max, 4] || []
    string = previous.find { |code| code.op == :ALLOC && code.arg[:type] == :String }&.arg&.fetch(:value)
    return string_store_patterns(string) if string

    if previous.any? { |code| code.op == :MATH && code.arg == :+ }
      [/:=.*\+/, /:=/]
    else
      [/:=/]
    end
  end

  def string_store_patterns(value)
    [/:=.*"#{Regexp.escape(value)}"/, /:=/]
  end

  def render_panes(width, pane_height)
    heap_width = @vm.state.heap.any? ? HEAP_WIDTH : 0
    effect_width = heap_width.positive? ? 14 : EFFECT_WIDTH
    byte_width = [width - effect_width - STACK_WIDTH - MEMORY_WIDTH - heap_width - (heap_width.positive? ? 8 : 6), 12].max
    byte_rows = bytecode_lines(byte_width, pane_height)
    effect_rows = effect_lines(effect_width, pane_height)
    stack_rows = stack_lines(pane_height)
    memory_rows = memory_lines(pane_height)
    heap_rows = heap_lines(heap_width, pane_height)

    header = [
      "BYTECODE".ljust(byte_width),
      "EFFECT".ljust(effect_width),
      "STACK".ljust(STACK_WIDTH),
      "MEMORY".ljust(MEMORY_WIDTH),
      heap_width.positive? ? "HEAP".ljust(heap_width) : nil
    ].compact.join("  ")

    rows = pane_height.times.map do |idx|
      [
        (byte_rows[idx] || "").ljust(byte_width),
        (effect_rows[idx] || "").ljust(effect_width),
        (stack_rows[idx] || "").ljust(STACK_WIDTH),
        (memory_rows[idx] || "").ljust(MEMORY_WIDTH),
        heap_width.positive? ? (heap_rows[idx] || "").ljust(heap_width) : nil
      ].compact.join("  ")[0, width]
    end

    ([truncate(header, width)] + rows).join("\n")
  end

  def bytecode_lines(width, pane_height)
    frame = @vm.current_frame
    return ["<halted>"] unless frame

    start = [[frame.ip - 4, 0].max, [frame.codes.length - pane_height, 0].max].min
    frame.codes[start, pane_height].each_with_index.map do |code, idx|
      ip = start + idx
      marker = ip == current_bytecode_ip(frame) ? ">" : " "
      truncate("#{marker} #{format('%03d', ip)}: #{format_code(code)}", width)
    end
  end

  def current_bytecode_ip(frame)
    return frame.ip if frame.ip < frame.codes.length

    frame.last_ip || frame.codes.length - 1
  end

  def effect_lines(width, pane_height)
    lines = [truncate(current_effect, width)]
    lines + Array.new(pane_height - lines.length, "")
  end

  def current_effect
    frame = @vm.current_frame
    code = @vm.current_code
    stack = @vm.state.stack
    return "" unless frame && code

    case code.op
      when :PUSH
        "push #{format_value(code.arg)}"
      when :ALLOC
        "alloc #{code.arg[:value].inspect}"
      when :LOAD
        "M#{format('%02d', code.arg)} -> #{format_value(frame.memory[code.arg])}"
      when :STORE
        "#{format_value(stack[-1])} -> M#{format('%02d', code.arg)}"
      when :MATH
        "#{format_value(stack[-2])} #{code.arg} #{format_value(stack[-1])} -> #{format_value(stack_result(code.arg))}"
      when :COMPARE
        "#{format_value(stack[-2])} == #{format_value(stack[-1])} -> #{format_value(compare_result)}"
      when :JUMP
        "jump #{code.arg}"
      when :JUMP_IF_FALSE
        "#{format_value(stack[-1])} ? next : #{code.arg}"
      when :CALL
        argc = code.arg.is_a?(Hash) ? (code.arg[:params]&.length || 1) : 0
        args = stack.last(argc).map { |value| format_value(value) }.join(", ")
        "call(#{args})"
      when :RETURN
        "return #{format_value(stack[-1])}"
      when :SYSCALL
        "print #{format_value(stack[-1])}"
      else
        ""
    end
  end

  def stack_lines(pane_height)
    values = @vm.state.stack.last(pane_height)
    blanks = Array.new(pane_height - values.length, nil)
    first_value_idx = @vm.state.stack.length - values.length
    active = active_stack_indexes

    (blanks + values).each_with_index.map do |value, idx|
      stack_idx = idx < blanks.length ? nil : first_value_idx + idx - blanks.length
      marker = active.include?(stack_idx) ? "*" : " "
      "#{marker}#{format_value(value).rjust(STACK_WIDTH - 2)}"
    end
  end

  def memory_lines(pane_height)
    frame = @vm.current_frame
    memory = frame ? frame.memory : []
    focus = @vm.state.touched_memory || 0
    start = [[focus - 4, 0].max, [memory.length - pane_height, 0].max].min

    pane_height.times.map do |idx|
      slot = start + idx
      marker = if active_memory_slots.include?(slot)
        "*"
      elsif slot == @vm.state.touched_memory
        ">"
      else
        " "
      end
      "#{marker}M#{format('%02d', slot)}: #{format_value(memory[slot])}"
    end
  end

  def heap_lines(width, pane_height)
    return [] unless width.positive?

    rows = @vm.state.heap.each_with_index.map do |value, idx|
      if value
        "S#{format('%02d', idx)} r#{value.refs} #{value.value.inspect}"
      else
        "S#{format('%02d', idx)} free"
      end
    end

    rows.first(pane_height)
  end

  def active_stack_indexes
    code = @vm.current_code
    size = @vm.state.stack.length
    return [] unless code

    case code.op
      when :STORE, :JUMP_IF_FALSE, :RETURN, :SYSCALL
        [size - 1]
      when :MATH, :COMPARE
        [size - 2, size - 1]
      when :CALL
        argc = code.arg.is_a?(Hash) ? (code.arg[:params]&.length || 1) : 0
        ((size - argc)...size).to_a
      else
        []
    end.select { |idx| idx >= 0 }
  end

  def active_memory_slots
    code = @vm.current_code
    return [] unless code&.op == :LOAD

    [code.arg]
  end

  def stack_result(op)
    stack = @vm.state.stack
    return nil if stack.length < 2

    stack[-2].send(op, stack[-1])
  end

  def compare_result
    stack = @vm.state.stack
    return nil if stack.length < 2

    stack[-2] == stack[-1]
  end

  def render_output(width)
    lines = @vm.state.output.last(3)
    return "" if lines.empty?
    truncate(lines.join(" | "), width)
  end

  def format_code(code)
    arg = code.arg
    arg = "#{arg[:type]} #{arg[:value].inspect}" if code.op == :ALLOC
    arg = "proc" if arg.is_a?(Hash)
    [code.op, arg].compact.join(" ")
  end

  def format_value(value)
    case value
      when nil then "xxx"
      when true then "001"
      when false then "000"
      when TraceHeapRef then "S#{format('%02d', value.id)}"
      when Integer then format('%03d', value)
      else value.to_s[0, 3]
    end
  end

  def truncate(text, width)
    text = text.to_s
    text.length > width ? text[0, width] : text
  end
end

class Runner
  def initialize(program)
    @program = program
    @vm = TraceVM.new(program)
    @renderer = Renderer.new(program, @vm)
    @reader = defined?(TTY::Reader) && STDIN.tty? ? TTY::Reader.new(interrupt: :exit) : nil
  end

  def auto(steps)
    puts @renderer.render
    steps.times do
      break if @vm.state.halted
      @vm.step
      puts "\n--- step ---\n"
      puts @renderer.render
    end
  end

  def interactive
    STDOUT.sync = true
    setup_terminal
    if @reader
      interactive_loop
    elsif STDIN.tty?
      STDIN.raw { interactive_loop }
    else
      interactive_loop
    end
  ensure
    restore_terminal
  end

  def interactive_loop
    loop do
      print @renderer.render
      action = read_action
      case action
        when :step then @vm.step
        when :back then @vm.back
        when :quit then break
      end
    end
  end

  def read_action
    if @reader
      key = @reader.read_keypress
      return :step if key == " "
      return :back if key == :backspace || key == "\u007F" || key == "\b"
      return :quit if key == "q" || key == "\u0003" || key.nil?
      return nil
    end

    key = STDIN.tty? ? STDIN.getch : STDIN.read(1)
    return :step if key == " "
    return :back if key == "\u007F" || key == "\b"
    return :quit if key == "q" || key == "\u0003" || key.nil?

    nil
  end

  def setup_terminal
    return unless STDOUT.tty?
    return if ENV["TERM"] == "dumb"

    if defined?(TTY::Cursor)
      print TTY::Cursor.hide
    else
      print "\e[?25l\e[0m"
    end
  end

  def restore_terminal
    return unless STDOUT.tty?
    return if ENV["TERM"] == "dumb"

    if defined?(TTY::Cursor)
      print TTY::Cursor.show
    else
      print "\e[?25h\e[0m"
    end
    print "\n"
    STDOUT.flush
  end
end

version = ARGV.shift || "v4"
source_path = ARGV[0] unless ARGV[0]&.start_with?("--")
steps_arg = ARGV.find { |arg| arg.start_with?("--steps=") }
steps = steps_arg&.split("=", 2)&.last&.to_i

unless VersionLoader::VERSIONS.include?(version)
  abort "Usage: ruby examples/puck/run.rb [v1|v2|v3|v4|v5] [source.puck] [--steps=N]"
end

program = VersionLoader.load(version, source_path)
runner = Runner.new(program)

if steps
  runner.auto(steps)
else
  runner.interactive
end
