#!/usr/bin/env ruby
# Compile a Puck source file to a `.puckc` bytecode file the C VM reads.
#
# Usage: ruby compile.rb <input.puck> <output.puckc>
#
# Reuses the V9 Ruby tokenizer / parser / macro expander / compiler — there
# is no separate V10 front end. V10 only changes what runs the bytecode.

require_relative "../v9/parser"
require_relative "../v9/macro_expander"
require_relative "../v9/compiler"

in_path  = ARGV[0] or (warn "Usage: compile.rb <input.puck> <output.puckc>"; exit 1)
out_path = ARGV[1] or (warn "Usage: compile.rb <input.puck> <output.puckc>"; exit 1)

source = File.read(in_path)
core_path = File.expand_path("core.puck", __dir__)
if File.exist?(core_path)
  core_src = File.read(core_path)
  # Same splice trick as benchmarks/vm/run_puck.rb: drop core.puck into the
  # MODULE's declaration block just before BEGIN.
  source = source.sub(/^BEGIN\b/m) { "#{core_src}\nBEGIN" }
end

tokens  = Tokenizer.new(source).tokenize
ast     = Parser.new(tokens).parse
ast     = MacroExpander.new.expand(ast)
program = Compiler.new.compile(ast)

# ---------------------------------------------------------------------------
# Serialization. Two things to lower out of the Ruby in-memory program:
#   - String literals (ALLOC's arg) get interned into a flat strings table;
#     ALLOC ops are rewritten to reference a string-table index.
#   - Procedure references (CALL's arg, which is a Ruby hash) get interned
#     into a flat procedure table; CALL ops are rewritten to reference a
#     procedure-table index. Procedure 0 is always main.
# ---------------------------------------------------------------------------

strings = []
string_index = {}
intern_string = lambda do |s|
  string_index[s] ||= (strings << s; strings.length - 1)
end

procs = [{ params: 0, var_params: 0, codes: program[:codes] }]  # main
proc_index = {}
program[:procedures].each_value do |pr|
  proc_index[pr.object_id] = procs.length
  procs << { params: pr[:params].length, var_params: pr[:var_params].length, codes: pr[:codes] }
end

# Rewrite each ALLOC.arg to a string-table index. CALL.arg becomes the
# proc-table index. Other args pass through.
def serialize_arg(code, intern_string, proc_index)
  case code.op
  when :ALLOC then intern_string.call(code.arg).to_s
  when :CALL then proc_index.fetch(code.arg.object_id).to_s
  when :MATH, :COMPARE then code.arg.to_s
  when :PUSH, :LOAD, :LOAD_REF, :STORE, :STORE_REF, :JUMP, :JUMP_IF_FALSE, :SYSCALL
    code.arg.to_s
  else
    ""  # no-arg ops: ALLOC_CELL/ALLOC_ARRAY/ARRAY_GET/ARRAY_SET/ARRAY_LEN/RETURN
  end
end

# Pre-walk: any ALLOC must intern its string before we write line by line, so
# the indices are stable.
procs.each do |p|
  p[:codes].each { |c| intern_string.call(c.arg) if c.op == :ALLOC }
end

File.open(out_path, "w") do |f|
  f.puts "PUCKC 1"
  f.puts "STRINGS #{strings.length}"
  strings.each { |s| f.puts s }
  f.puts "PROCS #{procs.length}"
  procs.each do |p|
    f.puts "PROC #{p[:params]} #{p[:var_params]} #{p[:codes].length}"
    p[:codes].each do |code|
      arg = serialize_arg(code, intern_string, proc_index)
      f.puts arg.empty? ? code.op.to_s : "#{code.op} #{arg}"
    end
  end
end
