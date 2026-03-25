#! /usr/bin/env ruby

require 'fileutils'
require 'benchmark'

def measure_min(command, runs = 5)
  times = runs.times.map { Benchmark.measure { `#{command}` }.real }
  times.min
end

def run_bench(dir)
  puts "=== BENCHMARK: #{dir} ==="

  has_c    = File.exist?("#{dir}/bench.c")
  has_rust = File.exist?("#{dir}/bench.rs") && system("command -v rustc > /dev/null 2>&1")
  has_go   = File.exist?("#{dir}/bench.go") && system("command -v go > /dev/null 2>&1")

  # 1. Compile C Baseline
  if has_c
    puts "Compiling C baseline..."
    `gcc -O3 #{dir}/bench.c -o #{dir}/bench_c`
  end

  # 2. Compile Rust Baseline
  if has_rust
    puts "Compiling Rust baseline..."
    `rustc -C opt-level=3 #{dir}/bench.rs -o #{dir}/bench_rust`
  end

  # 3. Compile Go Baseline
  if has_go
    puts "Compiling Go baseline..."
    Dir.chdir(dir) do
      `go build -o bench_go .`
    end
  end

  # 4. Compile CLEAR
  # bench.zt: pure Zig benchmark (runtime-level, no CLEAR transpilation needed).
  # bench.cht with "@use_zig": scheduler-dependent Zig (e.g. socket I/O, fiber benchmarks).
  use_zt  = File.exist?("#{dir}/bench.zt")
  use_zig = !use_zt &&
            File.exist?("#{dir}/bench.zig") &&
            File.exist?("#{dir}/bench.cht") &&
            File.read("#{dir}/bench.cht").include?("@use_zig")

  if use_zt
    puts "Compiling CLEAR (runtime Zig, .zt)..."
    FileUtils.cp("#{dir}/bench.zt", "zig/bench.zig")
  elsif use_zig
    puts "Compiling CLEAR (native Zig, scheduler required)..."
    FileUtils.cp("#{dir}/bench.zig", "zig/bench.zig")
  elsif File.exist?("#{dir}/bench.cht")
    puts "Transpiling CLEAR..."
    # Run from root to ensure relative requires in src/ work
    `ruby src/transpiler.rb #{dir}/bench.cht > zig/bench.zig`
    puts "Compiling CLEAR (Zig output)..."
  else
    puts "No CLEAR source found, skipping CLEAR."
  end

  has_clear = false
  if File.exist?("zig/bench.zig")
    Dir.chdir("zig") do
      `zig build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc`
    end
    if File.exist?("zig/bench_clear")
      FileUtils.mv("zig/bench_clear", "#{dir}/bench_clear")
      has_clear = true
    else
      puts "WARNING: bench_clear was not generated."
    end
    FileUtils.rm("zig/bench.zig") if File.exist?("zig/bench.zig")
  end

  # 5. Execution & Timing
  results = {}

  if has_c && File.exist?("#{dir}/bench_c")
    puts "Running C baseline (best of 5)..."
    results[:c] = measure_min("./#{dir}/bench_c")
  end

  if has_rust && File.exist?("#{dir}/bench_rust")
    puts "Running Rust baseline (best of 5)..."
    results[:rust] = measure_min("./#{dir}/bench_rust")
  end

  if has_go && File.exist?("#{dir}/bench_go")
    puts "Running Go baseline (best of 5)..."
    results[:go] = measure_min("./#{dir}/bench_go")
  end

  if has_clear
    puts "Running CLEAR (best of 5)..."
    results[:clear] = measure_min("./#{dir}/bench_clear")
  end

  # 6. Reporting
  puts "\nRESULTS for #{dir}:"

  baseline_key = [:c, :go, :rust].find { |k| results[k] }
  baseline_label = { c: "C", go: "Go", rust: "Rust" }

  results.each do |lang, t|
    label = { c: "C (Perfect)", go: "Go (goroutines)", rust: "Rust (threads)",
              clear: "CLEAR (fibers)" }[lang]
    puts "#{'%-22s' % label} #{'%.4f' % t} s"
  end

  if results[:clear] && baseline_key
    overhead = (results[:clear] / results[baseline_key]) * 100 - 100
    sign = overhead >= 0 ? "+" : ""
    puts "CLEAR vs #{baseline_label[baseline_key]}:         #{sign}#{'%.2f' % overhead}%"
  end
end

if ARGV.empty?
  # Run all benchmark directories
  dirs = Dir.glob("benchmarks/0*").sort
  dirs.each { |d| run_bench(d); puts }
elsif ARGV[0] == "--all"
  dirs = Dir.glob("benchmarks/0*").sort + Dir.glob("benchmarks/1*").sort
  dirs.each { |d| run_bench(d); puts }
else
  run_bench(ARGV[0])
end
