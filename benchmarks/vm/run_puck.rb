#!/usr/bin/env ruby
# Run a Puck (tutorial v9) benchmark.
#
# Splices examples/puck/v9/core.puck into the benchmark's MODULE declaration
# block (just before BEGIN), then hands the combined source to the v9
# tokenizer / parser / macro expander / compiler / VM. Used by run.sh.
#
# Usage: ruby run_puck.rb path/to/bench.puck

require_relative "../../examples/puck/v9/parser"
require_relative "../../examples/puck/v9/macro_expander"
require_relative "../../examples/puck/v9/compiler"
require_relative "../../examples/puck/v9/vm"

bench_path = ARGV[0] || (warn "Usage: run_puck.rb <file.puck>"; exit 1)

bench_src = File.read(bench_path)
core_src  = File.read(File.expand_path("../../examples/puck/v9/core.puck", __dir__))

# Splice core.puck between `MODULE Name;` and `BEGIN`. We rely on each
# benchmark having a single `BEGIN` at the start of its execution block; the
# substitution puts the core declarations just before it.
combined = bench_src.sub(/^BEGIN\b/m) { "#{core_src}\nBEGIN" }

tokens = Tokenizer.new(combined).tokenize
ast = Parser.new(tokens).parse
ast = MacroExpander.new.expand(ast)
program = Compiler.new.compile(ast)
VM.new.run(program)
