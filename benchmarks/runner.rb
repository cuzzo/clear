#! /usr/bin/env ruby

require 'fileutils'
require 'benchmark'

def run_bench(dir)
  puts "=== BENCHMARK: #{dir} ==="
  
  # 1. Compile C Baseline
  puts "Compiling C baseline..."
  `gcc -O3 #{dir}/bench.c -o #{dir}/bench_c`

  # 1.1 Compile Rust Baseline (Optional)
  has_rust = system("command -v rustc > /dev/null 2>&1")
  if has_rust
    puts "Compiling Rust baseline..."
    `rustc -C opt-level=3 #{dir}/bench.rs -o #{dir}/bench_rust`
  end

  # 2. Transpile and Compile CLEAR
  puts "Transpiling CLEAR..."
  # Run from root to ensure relative requires in src/ work
  `ruby src/transpiler.rb #{dir}/bench.cht > zig/bench.zig`
  
  # Ensure runtime headers are linked correctly for Zig compilation
  puts "Compiling CLEAR (Zig output)..."
  Dir.chdir("zig") do
    `zig build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc`
  end
  
  if File.exist?("zig/bench_clear")
    FileUtils.mv("zig/bench_clear", "#{dir}/bench_clear")
  else
    puts "ERROR: bench_clear was not generated."
    exit 1
  end
  FileUtils.rm("zig/bench.zig") if File.exist?("zig/bench.zig")
  
  # 3. Execution & Timing
  results = {}
  
  puts "Running C baseline..."
  results[:c] = Benchmark.measure { `./#{dir}/bench_c` }.real
  
  if has_rust
    puts "Running Rust baseline..."
    results[:rust] = Benchmark.measure { `./#{dir}/bench_rust` }.real
  end
  
  puts "Running CLEAR..."
  results[:clear] = Benchmark.measure { `./#{dir}/bench_clear` }.real
  
  # 4. Reporting
  puts "\nRESULTS for #{dir}:"
  puts "C (Perfect):    #{'%.4f' % results[:c]} s"
  puts "Rust (Perf):    #{'%.4f' % (results[:rust] || 0)} s" if has_rust
  puts "CLEAR (Transp): #{'%.4f' % results[:clear]} s"
  
  overhead = (results[:clear] / results[:c]) * 100 - 100
  puts "CLEAR Overhead: #{'%.2f' % overhead}%"
end

if ARGV.empty?
  puts "Usage: ruby runner.rb <benchmark_dir>"
else
  run_bench(ARGV[0])
end
