#! /usr/bin/env ruby

require 'fileutils'
require 'benchmark'

# Find the Zig compiler (local or system). Resolve to absolute path
# since the runner chdir's into zig/ for compilation.
ZIG = [
  File.expand_path("zig/zig-new/zig"),
  File.expand_path("zig/zig/zig"),
  `which zig 2>/dev/null`.strip
].find { |p| !p.empty? && File.exist?(p) } || "zig"

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
    if File.exist?("#{dir}/Cargo.toml")
      puts "Compiling Rust baseline (cargo)..."
      Dir.chdir(dir) { `cargo build --release -q 2>&1` }
      src = "#{dir}/target/release/bench_rust"
      FileUtils.cp(src, "#{dir}/bench_rust") if File.exist?(src)
    else
      puts "Compiling Rust baseline..."
      `rustc -C opt-level=3 #{dir}/bench.rs -o #{dir}/bench_rust`
    end
  end

  # 3. Compile Go Baseline
  if has_go
    puts "Compiling Go baseline..."
    Dir.chdir(dir) do
      `go mod init bench 2>/dev/null` unless File.exist?("go.mod")
      `go build -o bench_go bench.go`
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
      `#{ZIG} build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc`
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
    # Match Go/Rust behavior: use all available cores by default.
    # Go defaults to GOMAXPROCS=num_cpu; Tokio defaults to num_cpu threads.
    # CLEAR defaults to 1 thread unless CLEAR_THREADS is set.
    threads = ENV['CLEAR_THREADS'] || `nproc 2>/dev/null`.strip
    threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

    # Use jemalloc for CLEAR benchmarks if available. CLEAR's runtime uses
    # std.heap.c_allocator (libc malloc); jemalloc provides per-thread arenas
    # with less fragmentation and better multi-threaded scaling.
    jemalloc_lib = Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
                   Dir.glob("/usr/lib/libjemalloc.so*").first ||
                   Dir.glob("/usr/local/lib/libjemalloc.so*").first
    jemalloc_preload = jemalloc_lib ? "LD_PRELOAD=#{jemalloc_lib} " : ""
    jemalloc_note = jemalloc_lib ? ", jemalloc" : ""

    puts "Running CLEAR (best of 5, CLEAR_THREADS=#{threads}#{jemalloc_note})..."
    results[:clear] = measure_min("#{jemalloc_preload}CLEAR_THREADS=#{threads} ./#{dir}/bench_clear")
  end

  # 6. Reporting
  puts "\nRESULTS for #{dir}:"

  rust_label = File.exist?("#{dir}/Cargo.toml") ? "Rust (tokio)" : "Rust (threads)"
  label_map  = { c: "C (Perfect)", go: "Go (goroutines)", rust: rust_label,
                 clear: "CLEAR (fibers)" }
  baseline_label = { c: "C", go: "Go", rust: "Rust" }

  results.each do |lang, t|
    puts "#{'%-22s' % label_map[lang]} #{'%.4f' % t} s"
  end

  [:c, :go, :rust].each do |k|
    next unless results[:clear] && results[k]
    overhead = (results[:clear] / results[k]) * 100 - 100
    sign = overhead >= 0 ? "+" : ""
    puts "CLEAR vs #{baseline_label[k]}:         #{sign}#{'%.2f' % overhead}%"
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
