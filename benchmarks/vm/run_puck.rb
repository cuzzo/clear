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

source = File.read(bench_path)
core_path = File.expand_path("../../examples/puck/v9/core.puck", __dir__)
tokens = Tokenizer.new(source).tokenize
# Parser auto-requires core.puck for any MODULE — no manual splice here.
ast = Parser.new(tokens, core_path: core_path).parse
ast = MacroExpander.new.expand(ast)
program = Compiler.new.compile(ast)
VM.new.run(program)
