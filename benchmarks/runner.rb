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

# -------------------------------------------------------------------------
# Mode configuration: controls runs, server load, and language selection.
#   --smoke:   pre-commit sanity check (CLEAR only, minimal load)
#   --fast:    quick comparison (3 runs, reduced server load)
#   --normal:  default (5 runs, full server load)
#   --release: exhaustive (5 runs, 5x server load)
# -------------------------------------------------------------------------
MODES = {
  "smoke"   => { runs: 1, num_gets: 100,   concurrency: 5,  clear_only: true },
  "fast"    => { runs: 3, num_gets: 2500,  concurrency: 25, clear_only: false },
  "normal"  => { runs: 5, num_gets: 10000, concurrency: 50, clear_only: false },
  "release" => { runs: 5, num_gets: 50000, concurrency: 50, clear_only: false },
}.freeze

PORT = 6390

def measure_min(command, runs = 5)
  times = runs.times.map { Benchmark.measure { `#{command}` }.real }
  times.min
end

# -------------------------------------------------------------------------
# Standard benchmark: self-contained binary, timed externally
# -------------------------------------------------------------------------
def run_bench(dir, mode_cfg, cores)
  # Detect server benchmarks (have client.go + server.cht)
  if File.exist?("#{dir}/client.go") && File.exist?("#{dir}/server.cht")
    return run_server_bench(dir, mode_cfg, cores)
  end

  clear_only = mode_cfg[:clear_only]
  runs = mode_cfg[:runs]

  puts "=== BENCHMARK: #{dir} (#{$mode}, #{runs} runs#{clear_only ? ', CLEAR only' : ''}) ==="

  has_c    = !clear_only && File.exist?("#{dir}/bench.c")
  has_rust = !clear_only && File.exist?("#{dir}/bench.rs") && system("command -v rustc > /dev/null 2>&1")
  has_go   = !clear_only && File.exist?("#{dir}/bench.go") && system("command -v go > /dev/null 2>&1")

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
    puts "Running C baseline (best of #{runs})..."
    results[:c] = measure_min("./#{dir}/bench_c", runs)
  end

  if has_rust && File.exist?("#{dir}/bench_rust")
    puts "Running Rust baseline (best of #{runs})..."
    results[:rust] = measure_min("TOKIO_WORKER_THREADS=#{cores} ./#{dir}/bench_rust", runs)
  end

  if has_go && File.exist?("#{dir}/bench_go")
    puts "Running Go baseline (best of #{runs})..."
    results[:go] = measure_min("GOMAXPROCS=#{cores} ./#{dir}/bench_go", runs)
  end

  if has_clear
    threads = cores
    threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

    # Use jemalloc for CLEAR benchmarks if available.
    jemalloc_lib = Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
                   Dir.glob("/usr/lib/libjemalloc.so*").first ||
                   Dir.glob("/usr/local/lib/libjemalloc.so*").first
    jemalloc_preload = jemalloc_lib ? "LD_PRELOAD=#{jemalloc_lib} " : ""
    jemalloc_note = jemalloc_lib ? ", jemalloc" : ""

    puts "Running CLEAR (best of #{runs}, CLEAR_THREADS=#{threads}#{jemalloc_note})..."
    results[:clear] = measure_min("#{jemalloc_preload}CLEAR_THREADS=#{threads} ./#{dir}/bench_clear", runs)
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

# -------------------------------------------------------------------------
# Server benchmark: start server, run shared client, capture output
# -------------------------------------------------------------------------
def run_server_bench(dir, mode_cfg, cores)
  clear_only  = mode_cfg[:clear_only]
  num_gets    = mode_cfg[:num_gets]
  concurrency = mode_cfg[:concurrency]

  puts "=== SERVER BENCHMARK: #{dir} (#{$mode}, #{num_gets} GETs, #{concurrency} concurrent#{clear_only ? ', CLEAR only' : ''}) ==="

  has_rust = !clear_only && File.exist?("#{dir}/bench.rs") && system("command -v rustc > /dev/null 2>&1")
  has_go   = !clear_only && File.exist?("#{dir}/server.go") && system("command -v go > /dev/null 2>&1")

  # 1. Compile everything
  # Client (always needed)
  puts "Compiling client..."
  Dir.chdir(dir) do
    `go mod init bench 2>/dev/null` unless File.exist?("go.mod")
    `go build -o client_go client.go 2>&1`
  end
  unless File.exist?("#{dir}/client_go")
    puts "ERROR: client_go failed to build"; return
  end

  # Go server
  if has_go
    puts "Compiling Go server..."
    Dir.chdir(dir) { `go build -o server_go server.go 2>&1` }
  end

  # Rust server
  if has_rust
    if File.exist?("#{dir}/Cargo.toml")
      puts "Compiling Rust server (cargo)..."
      Dir.chdir(dir) { `cargo build --release -q 2>&1` }
      src = "#{dir}/target/release/bench_rust"
      FileUtils.cp(src, "#{dir}/bench_rust") if File.exist?(src)
    end
  end

  # CLEAR server
  has_clear = false
  if File.exist?("#{dir}/server.cht")
    puts "Transpiling CLEAR server..."
    `ruby src/transpiler.rb #{dir}/server.cht 2>/dev/null > zig/bench.zig`

    # Detect FFI modules: any .zig files in the benchmark dir
    ffi_modules = Dir.glob("#{dir}/*.zig").map { |f| File.basename(f, ".zig") }

    Dir.chdir("zig") do
      ffi_modules.each { |m| FileUtils.cp("../#{dir}/#{m}.zig", "#{m}.zig") }

      if ffi_modules.any?
        dep_flags = ffi_modules.map { |m| "--dep #{m}" }.join(" ")
        mod_flags = ffi_modules.map { |m| "-M#{m}=#{m}.zig" }.join(" ")
        cmd = "#{ZIG} build-exe #{dep_flags} -Mroot=bench.zig -lc switch.S onRoot.S #{mod_flags} -O ReleaseFast --name bench_clear"
        `#{cmd} 2>&1`
      else
        `#{ZIG} build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc 2>&1`
      end

      ffi_modules.each { |m| FileUtils.rm("#{m}.zig") if File.exist?("#{m}.zig") }
    end

    if File.exist?("zig/bench_clear")
      FileUtils.mv("zig/bench_clear", "#{dir}/server_clear")
      has_clear = true
    else
      puts "WARNING: CLEAR server failed to compile."
    end
    FileUtils.rm("zig/bench.zig") if File.exist?("zig/bench.zig")
  end

  threads = ENV['CLEAR_THREADS'] || "1"

  # 2. Run each server with the shared client
  results = {}

  servers = []
  servers << { key: :rust,  label: "Rust (tokio)",    bin: "#{dir}/bench_rust",    env: "TOKIO_WORKER_THREADS=#{cores} " } if has_rust && File.exist?("#{dir}/bench_rust")
  servers << { key: :go,    label: "Go (goroutines)",  bin: "#{dir}/server_go",     env: "GOMAXPROCS=#{cores} " } if has_go && File.exist?("#{dir}/server_go")
  servers << { key: :clear, label: "CLEAR (fibers)",   bin: "#{dir}/server_clear",  env: "CLEAR_THREADS=#{threads} " } if has_clear

  servers.each do |srv|
    # Clean data directory
    FileUtils.rm_rf("data")
    FileUtils.mkdir_p("data")

    # Start server
    puts "\nRunning #{srv[:label]}..."
    pid = spawn("#{srv[:env]}./#{srv[:bin]}", [:out, :err] => "/dev/null")
    sleep 1

    # Run client
    output = `./#{dir}/client_go #{pid} #{PORT} #{num_gets} #{concurrency} 2>&1`
    puts output

    # Kill server
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil

    # Parse results from client output
    if output =~ /SET phase:\s+(\d+) ms/
      results[srv[:key]] = { set_ms: $1.to_i }
    end
    if output =~ /GET phase:\s+(\d+) ms/
      results[srv[:key]][:get_ms] = $1.to_i if results[srv[:key]]
    end
    if output =~ /Peak RSS \(VmHWM\):\s+(\d+) KB/
      results[srv[:key]][:peak_rss_kb] = $1.to_i if results[srv[:key]]
    end
    if output =~ /RSS after GETs:\s+(\d+) KB/
      results[srv[:key]][:rss_after_kb] = $1.to_i if results[srv[:key]]
    end
    if output =~ /Verified:\s+(\d+)\s*\/\s*(\d+)/
      results[srv[:key]][:verified] = $1.to_i if results[srv[:key]]
      results[srv[:key]][:total] = $2.to_i if results[srv[:key]]
    end
  end

  FileUtils.rm_rf("data")

  # 3. Report
  puts "\n#{'=' * 60}"
  puts "RESULTS for #{dir}:"
  puts "#{'=' * 60}"
  puts "#{'%-22s' % 'Server'} #{'%8s' % 'SET(ms)'} #{'%8s' % 'GET(ms)'} #{'%10s' % 'Peak RSS'} #{'%10s' % 'RSS After'} #{'%10s' % 'Verified'}"
  puts "-" * 70

  results.each do |key, r|
    label = servers.find { |s| s[:key] == key }&.dig(:label) || key.to_s
    verified = r[:verified] && r[:total] ? "#{r[:verified]}/#{r[:total]}" : "?"
    peak = r[:peak_rss_kb] ? "#{r[:peak_rss_kb]} KB" : "?"
    rss  = r[:rss_after_kb] ? "#{r[:rss_after_kb]} KB" : "?"
    puts "#{'%-22s' % label} #{'%8s' % (r[:set_ms] || '?')} #{'%8s' % (r[:get_ms] || '?')} #{'%10s' % peak} #{'%10s' % rss} #{'%10s' % verified}"
  end

  # Memory comparison
  if results[:clear] && results[:go] && results[:clear][:peak_rss_kb] && results[:go][:peak_rss_kb]
    ratio = ((results[:clear][:peak_rss_kb].to_f / results[:go][:peak_rss_kb]) * 100).round(1)
    puts "\nCLEAR peak RSS: #{ratio}% of Go"
  end
  if results[:clear] && results[:rust] && results[:clear][:peak_rss_kb] && results[:rust][:peak_rss_kb]
    ratio = ((results[:clear][:peak_rss_kb].to_f / results[:rust][:peak_rss_kb]) * 100).round(1)
    puts "CLEAR peak RSS: #{ratio}% of Rust"
  end
end

if __FILE__ == $0
  dirs = []
  $mode = "normal"
  cores = `nproc 2>/dev/null`.strip

  args = ARGV.dup
  while (arg = args.shift)
    case arg
    when "--smoke"   then $mode = "smoke"
    when "--fast"    then $mode = "fast"
    when "--release" then $mode = "release"
    when "--normal"  then $mode = "normal"
    when /^--cores=(\d+)$/
      cores = $1
    when "--all"
      dirs += Dir.glob("benchmarks/0*").sort + Dir.glob("benchmarks/1*").sort + Dir.glob("benchmarks/2*").sort
    else
      dirs << arg
    end
  end

  if dirs.empty?
    dirs = Dir.glob("benchmarks/0*").sort
  end

  mode_cfg = MODES[$mode]

  dirs.each { |d| run_bench(d, mode_cfg, cores); puts }
end
