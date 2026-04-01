#! /usr/bin/env ruby

require 'fileutils'
require 'benchmark'

# Returns true if binary is missing or any source is newer than binary.
def needs_rebuild?(binary, *sources)
  return true unless File.exist?(binary)
  bin_mtime = File.mtime(binary)
  sources.flatten.compact.any? { |src| File.exist?(src) && File.mtime(src) > bin_mtime }
end

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

# -------------------------------------------------------------------------
# Structured output protocol
# -------------------------------------------------------------------------
# Benchmarks print lines matching:  metric_name: value [unit]
# The runner captures these as { "metric_name" => "value unit" }.
# Numeric values (with optional unit) are parsed for tabular display.
# Non-matching lines are passed through to the console as-is.

def parse_bench_output(output)
  metrics = {}
  output.each_line do |line|
    # Handle pipe-separated multi-metric lines: "Insert: 1.2 ms | Lookup: 3.4 ms"
    if line.include?("|") && line =~ /:/
      line.split("|").each do |part|
        if part =~ /^\s*(?:\[[\w-]*\]\s*)?(\w[\w\s]*\w|\w+)\s*:\s+(.+)$/
          metrics[$1.strip.downcase] = $2.strip
        end
      end
    elsif line =~ /^\s*(?:\[[\w-]*\]\s*)?(\w[\w\s]*\w|\w+)\s*:\s+(.+)$/
      key = $1.strip.downcase
      metrics[key] = $2.strip
    end
  end
  metrics
end

# Normalize time unit aliases: "seconds" -> "s", "milliseconds" -> "ms"
UNIT_ALIASES = { "seconds" => "s", "second" => "s", "milliseconds" => "ms", "microseconds" => "us", "nanoseconds" => "ns" }.freeze
TIME_UNITS = %w[ms s us ns].freeze

def parse_metric_value(s)
  return nil unless s
  if s =~ /^([\d.]+)\s*(\w+)?$/
    val = $1.to_f
    unit = $2
    unit = UNIT_ALIASES[unit.downcase] if unit && UNIT_ALIASES[unit.downcase]
    [val, unit]
  elsif s =~ /^(\d+)$/
    [$1.to_i, nil]
  else
    nil
  end
end

# Normalize a timing value to milliseconds for comparison.
def to_ms(val, unit)
  case unit&.downcase
  when "s"  then val * 1000.0
  when "ms" then val
  when "us" then val / 1000.0
  when "ns" then val / 1_000_000.0
  else val
  end
end

def format_metric(s)
  parsed = parse_metric_value(s)
  return s unless parsed
  val, unit = parsed
  # Normalize time to ms for display
  if unit && TIME_UNITS.include?(unit.downcase)
    ms = to_ms(val, unit)
    return ms == ms.to_i ? "#{ms.to_i} ms" : "#{'%.1f' % ms} ms"
  end
  if unit
    val == val.to_i ? "#{val.to_i} #{unit}" : "#{'%.1f' % val} #{unit}"
  else
    val.is_a?(Float) && val == val.to_i ? val.to_i.to_s : (val.is_a?(Float) ? "#{'%.1f' % val}" : val.to_s)
  end
end

# Run a command, capture stdout via tempfile, return [wall_time, parsed_metrics].
# Uses shell redirect instead of backtick to handle programs that don't flush
# stdout on pipe (e.g. Zig's buffered writer).
def measure_once(command)
  require 'tempfile'
  tmpf = Tempfile.new('bench_output')
  t = Benchmark.measure { system("#{command} > #{tmpf.path} 2>&1") }.real
  output = File.read(tmpf.path)
  tmpf.unlink
  metrics = parse_bench_output(output)
  [t, metrics]
end

# Run a command `runs` times, return [best_wall_time, metrics_from_best_run].
def measure_min(command, runs = 5)
  results = runs.times.map { measure_once(command) }
  results.min_by { |t, _| t }
end

# -------------------------------------------------------------------------
# Tabular reporting for standard benchmarks
# -------------------------------------------------------------------------
LANG_LABELS = {
  c:     "C",
  go:    "Go",
  rust:  "Rust",
  clear: "CLEAR",
}.freeze

def report_table(dir, results)
  langs = results.keys
  times = results.transform_values { |r| r[:wall] }
  all_metrics = results.transform_values { |r| r[:metrics] || {} }

  # Collect all metric keys in order of first appearance (from first language)
  metric_keys = []
  langs.each do |lang|
    all_metrics[lang].each_key { |k| metric_keys << k unless metric_keys.include?(k) }
  end

  # Separate timing metrics from verification metrics
  timing_keys = metric_keys.select do |k|
    # A timing metric has a numeric value with a time unit in at least one language
    langs.any? do |lang|
      v = all_metrics[lang][k]
      parsed = parse_metric_value(v)
      parsed && parsed[1] && %w[ms s us ns].include?(parsed[1].downcase)
    end
  end
  verify_keys = metric_keys - timing_keys

  # Column widths
  label_w = 14
  col_w = langs.size > 2 ? 14 : 16
  delta_w = 10

  # Header
  has_baseline = langs.size > 1 && langs.first != :clear
  header = "  #{'%-*s' % [label_w, '']}"
  langs.each { |l| header += "%*s" % [col_w, LANG_LABELS[l]] }
  header += "%*s" % [delta_w, "Delta"] if has_baseline
  puts header
  puts "  " + "-" * (label_w + langs.size * col_w + (has_baseline ? delta_w : 0))

  baseline_lang = (langs - [:clear]).first

  # Timing metric rows
  timing_keys.each do |key|
    row = "  %-*s" % [label_w, key]
    values = langs.map { |l| all_metrics[l][key] }
    langs.each_with_index do |l, i|
      row += "%*s" % [col_w, values[i] ? format_metric(values[i]) : "--"]
    end
    if has_baseline && baseline_lang
      bv = parse_metric_value(all_metrics[baseline_lang][key])
      cv = parse_metric_value(all_metrics[:clear]&.dig(key))
      if bv && cv && bv[0] > 0
        b_ms = to_ms(bv[0], bv[1])
        c_ms = to_ms(cv[0], cv[1])
        pct = (c_ms / b_ms) * 100 - 100
        sign = pct >= 0 ? "+" : ""
        row += "%*s" % [delta_w, "#{sign}#{'%.1f' % pct}%"]
      else
        row += "%*s" % [delta_w, "--"]
      end
    end
    puts row
  end

  # Separator + total (wall time)
  puts "  " + "-" * (label_w + langs.size * col_w + (has_baseline ? delta_w : 0))
  row = "  %-*s" % [label_w, "total (wall)"]
  langs.each { |l| row += "%*s" % [col_w, "#{'%.1f' % (times[l] * 1000)} ms"] }
  if has_baseline && baseline_lang && times[:clear] && times[baseline_lang]
    pct = (times[:clear] / times[baseline_lang]) * 100 - 100
    sign = pct >= 0 ? "+" : ""
    row += "%*s" % [delta_w, "#{sign}#{'%.1f' % pct}%"]
  end
  puts row

  # Verification rows (checksum, count, etc.)
  verify_keys.each do |key|
    row = "  %-*s" % [label_w, key]
    values = langs.map { |l| all_metrics[l][key] }
    langs.each_with_index do |l, i|
      row += "%*s" % [col_w, values[i] || "--"]
    end
    if has_baseline && baseline_lang
      bv = all_metrics[baseline_lang][key]
      cv = all_metrics[:clear]&.dig(key)
      if bv && cv
        row += "%*s" % [delta_w, bv == cv ? "ok" : "MISMATCH"]
      else
        row += "%*s" % [delta_w, "--"]
      end
    end
    puts row
  end
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

  # Compiler sources that invalidate CLEAR builds when changed.
  clear_compiler_deps = Dir.glob("src/*.rb") + ["zig/runtime-header.zig"]

  # 1. Compile C Baseline
  if has_c
    if needs_rebuild?("#{dir}/bench_c", "#{dir}/bench.c")
      puts "Compiling C baseline..."
      `gcc -O3 #{dir}/bench.c -o #{dir}/bench_c`
    else
      puts "C baseline up to date."
    end
  end

  # 2. Compile Rust Baseline
  if has_rust
    if File.exist?("#{dir}/Cargo.toml")
      if needs_rebuild?("#{dir}/bench_rust", Dir.glob("#{dir}/src/*.rs") + ["#{dir}/Cargo.toml"])
        puts "Compiling Rust baseline (cargo)..."
        Dir.chdir(dir) { `cargo build --release -q 2>&1` }
        src = "#{dir}/target/release/bench_rust"
        FileUtils.cp(src, "#{dir}/bench_rust") if File.exist?(src)
      else
        puts "Rust baseline up to date."
      end
    else
      if needs_rebuild?("#{dir}/bench_rust", "#{dir}/bench.rs")
        puts "Compiling Rust baseline..."
        `rustc -C opt-level=3 #{dir}/bench.rs -o #{dir}/bench_rust`
      else
        puts "Rust baseline up to date."
      end
    end
  end

  # 3. Compile Go Baseline
  if has_go
    if needs_rebuild?("#{dir}/bench_go", "#{dir}/bench.go")
      puts "Compiling Go baseline..."
      Dir.chdir(dir) do
        `go mod init bench 2>/dev/null` unless File.exist?("go.mod")
        `go build -o bench_go bench.go`
      end
    else
      puts "Go baseline up to date."
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

  clear_src = if use_zt then "#{dir}/bench.zt"
              elsif use_zig then "#{dir}/bench.zig"
              elsif File.exist?("#{dir}/bench.cht") then "#{dir}/bench.cht"
              end

  if clear_src && !needs_rebuild?("#{dir}/bench_clear", clear_src, clear_compiler_deps)
    puts "CLEAR up to date."
    has_clear = File.exist?("#{dir}/bench_clear")
  else
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
  end

# 5. Execution & Timing
  results = {}

  if has_c && File.exist?("#{dir}/bench_c")
    puts "Running C baseline (best of #{runs})..."
    wall, metrics = measure_min("./#{dir}/bench_c", runs)
    results[:c] = { wall: wall, metrics: metrics }
  end

  if has_rust && File.exist?("#{dir}/bench_rust")
    puts "Running Rust baseline (best of #{runs})..."
    wall, metrics = measure_min("TOKIO_WORKER_THREADS=#{cores} ./#{dir}/bench_rust", runs)
    results[:rust] = { wall: wall, metrics: metrics }
  end

  if has_go && File.exist?("#{dir}/bench_go")
    puts "Running Go baseline (best of #{runs})..."
    wall, metrics = measure_min("GOMAXPROCS=#{cores} ./#{dir}/bench_go", runs)
    results[:go] = { wall: wall, metrics: metrics }
  end

  if has_clear
    # Auto-detect threading: use cores for concurrent benchmarks, 1 for sequential.
    # Concurrent benchmarks use BG, CONCURRENT, or SHARD in their source.
    clear_src_file = clear_src || "#{dir}/bench.cht"
    clear_src_text = File.exist?(clear_src_file) ? File.read(clear_src_file) : ""
    needs_threads = clear_src_text.match?(/\bBG\b|\bCONCURRENT\b|\bSHARD\b/)
    threads = needs_threads ? cores : "1"
    threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

    # Use jemalloc for CLEAR benchmarks if available.
    jemalloc_lib = Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
                   Dir.glob("/usr/lib/libjemalloc.so*").first ||
                   Dir.glob("/usr/local/lib/libjemalloc.so*").first
    jemalloc_preload = jemalloc_lib ? "LD_PRELOAD=#{jemalloc_lib} " : ""
    jemalloc_note = jemalloc_lib ? ", jemalloc" : ""

    puts "Running CLEAR (best of #{runs}, CLEAR_THREADS=#{threads}#{jemalloc_note})..."
    wall, metrics = measure_min("#{jemalloc_preload}CLEAR_THREADS=#{threads} ./#{dir}/bench_clear", runs)
    results[:clear] = { wall: wall, metrics: metrics }
  end

  # 6. Reporting
  puts ""
  report_table(dir, results)
  puts ""
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

  threads = cores
  threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

  # 2. Run each server with the shared client
  results = {}

  # Use jemalloc for CLEAR server if available.
  jemalloc_lib = Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
                 Dir.glob("/usr/lib/libjemalloc.so*").first ||
                 Dir.glob("/usr/local/lib/libjemalloc.so*").first

  servers = []
  servers << { key: :rust,  label: "Rust (tokio)",    bin: "#{dir}/bench_rust",    env: { "TOKIO_WORKER_THREADS" => cores } } if has_rust && File.exist?("#{dir}/bench_rust")
  servers << { key: :go,    label: "Go (goroutines)",  bin: "#{dir}/server_go",     env: { "GOMAXPROCS" => cores } } if has_go && File.exist?("#{dir}/server_go")

  # Dragonfly: external RESP-compatible server (DragonflyDB model comparison)
  has_dragonfly = !clear_only && system("command -v dragonfly > /dev/null 2>&1")
  if has_dragonfly
    servers << { key: :dragonfly, label: "DragonflyDB",
                 bin: "dragonfly", absolute: true,
                 args: ["--port", PORT.to_s, "--dbfilename", "", "--dir", "/tmp", "--proactor_threads", cores],
                 env: {} }
  end

  clear_env = { "CLEAR_THREADS" => threads }
  clear_env["LD_PRELOAD"] = jemalloc_lib if jemalloc_lib
  servers << { key: :clear, label: "CLEAR (fibers)",   bin: "#{dir}/server_clear",  env: clear_env } if has_clear

  servers.each do |srv|
    # Clean data directory
    FileUtils.rm_rf("data")
    FileUtils.mkdir_p("data")

    # Start server
    puts "\nRunning #{srv[:label]}..."
    if srv[:args]
      pid = spawn(srv[:env], srv[:bin], *srv[:args], [:out, :err] => "/dev/null")
    elsif srv[:absolute]
      pid = spawn(srv[:env], srv[:bin], [:out, :err] => "/dev/null")
    else
      pid = spawn(srv[:env], "./#{srv[:bin]}", [:out, :err] => "/dev/null")
    end
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
  first_ratio = true
  (results.keys - [:clear]).each do |other|
    next unless results[:clear]&.dig(:peak_rss_kb)&.positive? && results[other]&.dig(:peak_rss_kb)&.positive?
    label = servers.find { |s| s[:key] == other }&.dig(:label) || other.to_s
    ratio = ((results[:clear][:peak_rss_kb].to_f / results[other][:peak_rss_kb]) * 100).round(1)
    puts(first_ratio ? "\nCLEAR peak RSS: #{ratio}% of #{label}" : "CLEAR peak RSS: #{ratio}% of #{label}")
    first_ratio = false
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
