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

RUN_TIMEOUT = (ENV['BENCH_TIMEOUT'] || 2).to_i

# Per-benchmark timeout: read TIMEOUT file if present.
# Returns nil for server benchmarks with no file (no timeout = original behavior).
# Returns integer for standalone benchmarks with no file (falls back to RUN_TIMEOUT).
def bench_timeout(dir)
  f = "#{dir}/TIMEOUT"
  File.exist?(f) ? File.read(f).strip.to_i : nil
end

# Benchmark output protocol:
#   If a binary prints "BENCH_RESULT: <ms> ms" to stdout or stderr, that value
#   is used as the measurement instead of wall time. This allows benchmarks that
#   run multiple variants (warmup, reference runs, etc.) to declare exactly which
#   number the runner should record. Benchmarks without BENCH_RESULT fall back to
#   wall time (backward compatible).
def measure_min(command, runs = 5, timeout: RUN_TIMEOUT)
  times = runs.times.filter_map do
    output = ""
    t = Benchmark.measure { output = `timeout #{timeout}s sh -c "#{command.gsub('"', '\\"')} 2>&1"` }.real
    next unless $?.success?
    if output =~ /BENCH_RESULT:\s*(\d+(?:\.\d+)?)\s*ms/
      $1.to_f / 1000.0
    else
      t
    end
  end
  times.empty? ? nil : times.min
end

# -------------------------------------------------------------------------
# Standard benchmark: self-contained binary, timed externally
# -------------------------------------------------------------------------
def run_bench(dir)
  leak_mode = ENV['BENCH_MODE'] == 'leak'

  bto = bench_timeout(dir)

  # Detect server benchmarks (have client.go + server.cht)
  if File.exist?("#{dir}/client.go") && File.exist?("#{dir}/server.cht")
    if leak_mode
      puts "=== LEAK CHECK: #{dir} === SKIP (server benchmark)"
      return
    end
    # Server benchmarks: only apply timeout if TIMEOUT file exists.
    return run_server_bench(dir, timeout: bto)
  end

  puts leak_mode ? "=== LEAK CHECK: #{dir} ===" : "=== BENCHMARK: #{dir} ==="

  has_c    = !leak_mode && File.exist?("#{dir}/bench.c")
  has_rust = !leak_mode && File.exist?("#{dir}/bench.rs") && system("command -v rustc > /dev/null 2>&1")
  has_go   = !leak_mode && File.exist?("#{dir}/bench.go") && system("command -v go > /dev/null 2>&1")

  # Clean stale binaries before recompiling
  %w[bench_c bench_rust bench_go bench_clear].each { |b| FileUtils.rm_f("#{dir}/#{b}") }

  # 1. Compile C Baseline
  if has_c
    puts "Compiling C baseline..."
    `gcc -O3 #{dir}/bench.c -o #{dir}/bench_c`
  end

  # 2. Compile Rust Baseline
  if has_rust
    if File.exist?("#{dir}/Cargo.toml")
      puts "Compiling Rust baseline (cargo)..."
      Dir.chdir(dir) { `RUSTFLAGS="-A warnings" cargo build --release -q 2>&1` }
      src = "#{dir}/target/release/bench_rust"
      FileUtils.cp(src, "#{dir}/bench_rust") if File.exist?(src)
    else
      puts "Compiling Rust baseline..."
      `rustc -C opt-level=3 -A warnings #{dir}/bench.rs -o #{dir}/bench_rust`
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
  has_clear = false
  if leak_mode
    # Leak mode: build with ./clear build (debug, GPA leak detection enabled)
    if File.exist?("#{dir}/bench.cht")
      src = File.read("#{dir}/bench.cht")

      # @leak_skip: benchmark has no heap allocations, leak check is pointless
      if src.include?("@leak_skip")
        puts "  SKIP (no heap allocations)"
        return
      end

      # @leak: old -> new  (reduce iteration counts for debug mode)
      build_src = "#{dir}/bench.cht"
      subs = src.scan(/^--\s*@leak:\s*(.+?)\s*->\s*(.+?)\s*$/)
      if subs.any?
        # Split into comment and code lines so sub! doesn't match the @leak comment itself
        comment_lines = []
        code_lines = []
        src.each_line { |l| (l.match?(/^\s*--/) ? comment_lines : code_lines) << l }
        code_text = code_lines.join
        subs.each { |old, new_val| code_text.sub!(old.strip, new_val.strip) }
        patched = comment_lines.join + code_text
        build_src = "/tmp/bench_leak_#{File.basename(dir)}.cht"
        File.write(build_src, patched)
      end

      puts "Compiling CLEAR (debug, leak detection)..."
      output = `./clear build #{build_src} -o #{dir}/bench_clear 2>&1`
      if File.exist?("#{dir}/bench_clear")
        has_clear = true
      else
        puts "WARNING: debug build failed: #{output.lines.last&.strip}"
      end
      FileUtils.rm_f(build_src) if build_src != "#{dir}/bench.cht"
    else
      puts "No CLEAR source found, skipping."
    end
  else
    use_zt  = File.exist?("#{dir}/bench.zt")
    use_zig = !use_zt &&
              File.exist?("#{dir}/bench.zig") &&
              File.exist?("#{dir}/bench.cht") &&
              File.read("#{dir}/bench.cht").include?("@use_zig")

    if use_zt
      puts "Compiling CLEAR (runtime Zig, .zt)..."
      FileUtils.cp("#{dir}/bench.zt", "zig/bench.zig")
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
    elsif use_zig
      puts "Compiling CLEAR (native Zig, scheduler required)..."
      FileUtils.cp("#{dir}/bench.zig", "zig/bench.zig")
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
    elsif File.exist?("#{dir}/bench.cht")
      puts "Compiling CLEAR..."
      output = `./clear build --optimized #{dir}/bench.cht -o #{dir}/bench_clear 2>&1`
      if File.exist?("#{dir}/bench_clear")
        has_clear = true
      else
        puts "WARNING: CLEAR build failed: #{output.lines.last&.strip}"
      end
    else
      puts "No CLEAR source found, skipping CLEAR."
    end
  end

# 5. Execution & Timing
  results = {}

  scale = ENV['BENCH_SCALE'] || "1.0"
  runs = case ENV['BENCH_MODE']
         when 'fast' then 3
         when 'release' then 5
         when 'leak' then 1
         else 5
         end

  # Leak mode: run CLEAR once with timeout, capture stderr for GPA leak reports
  if leak_mode
    if has_clear
      threads = ENV['BENCH_CORES'] || ENV['CLEAR_THREADS'] || `nproc 2>/dev/null`.strip
      threads = "0" if threads.empty?
      cmd = "BENCH_SCALE=#{scale} CLEAR_THREADS=#{threads} timeout 60 ./#{dir}/bench_clear"
      output = `#{cmd} 2>&1`
      exit_status = $?.exitstatus
      leak_lines = output.lines.select { |l| l.include?("leaked:") }
      leak_count = leak_lines.size

      if exit_status == 124
        puts "  TIMEOUT (60s in debug mode)"
      elsif exit_status != 0 && exit_status != 124
        puts "  CRASH (exit #{exit_status}), leaks: #{leak_count}"
        # Show first leak source if any
        if leak_count > 0
          sources = output.scan(/in (\S+) \(/).flatten.uniq
          sources.each { |s| puts "    - #{s}" }
        end
      elsif leak_count > 0
        puts "  LEAKS: #{leak_count}"
        sources = output.scan(/in (\S+) \(/).flatten
        # Group by unique source function
        tallied = sources.tally.sort_by { |_, c| -c }
        tallied.each { |fn, count| puts "    - #{fn} (#{count}x)" }
      else
        puts "  CLEAN"
      end
    else
      puts "  SKIP (no CLEAR source or build failed)"
    end
    FileUtils.rm_f("#{dir}/bench_clear")
    return
  end

  if has_c && File.exist?("#{dir}/bench_c")
    puts "Running C baseline (best of #{runs}, scale=#{scale})..."
    results[:c] = measure_min("BENCH_SCALE=#{scale} ./#{dir}/bench_c", runs, timeout: bto || RUN_TIMEOUT)
  end

  if has_rust && File.exist?("#{dir}/bench_rust")
    puts "Running Rust baseline (best of #{runs}, scale=#{scale})..."
    # Rust benchmarks using Tokio can be configured with TOKIO_WORKER_THREADS
    cores = ENV['BENCH_CORES'] || `nproc 2>/dev/null`.strip
    results[:rust] = measure_min("BENCH_SCALE=#{scale} TOKIO_WORKER_THREADS=#{cores} ./#{dir}/bench_rust", runs, timeout: bto || RUN_TIMEOUT)
  end

  if has_go && File.exist?("#{dir}/bench_go")
    puts "Running Go baseline (best of #{runs}, scale=#{scale})..."
    cores = ENV['BENCH_CORES'] || `nproc 2>/dev/null`.strip
    results[:go] = measure_min("BENCH_SCALE=#{scale} GOMAXPROCS=#{cores} ./#{dir}/bench_go", runs, timeout: bto || RUN_TIMEOUT)
  end

  if has_clear
    # Match Go/Rust behavior: use all available cores by default.
    # Go defaults to GOMAXPROCS=num_cpu; Tokio defaults to num_cpu threads.
    # CLEAR defaults to 1 thread unless CLEAR_THREADS is set.
    threads = ENV['BENCH_CORES'] || ENV['CLEAR_THREADS'] || `nproc 2>/dev/null`.strip
    threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

    # Use jemalloc for CLEAR benchmarks if available. CLEAR's runtime uses
    # std.heap.c_allocator (libc malloc); jemalloc provides per-thread arenas
    # with less fragmentation and better multi-threaded scaling.
    jemalloc_lib = Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
                   Dir.glob("/usr/lib/libjemalloc.so*").first ||
                   Dir.glob("/usr/local/lib/libjemalloc.so*").first
    jemalloc_preload = jemalloc_lib ? "LD_PRELOAD=#{jemalloc_lib} " : ""
    jemalloc_note = jemalloc_lib ? ", jemalloc" : ""

    puts "Running CLEAR (best of #{runs}, CLEAR_THREADS=#{threads}#{jemalloc_note}, scale=#{scale})..."
    results[:clear] = measure_min("#{jemalloc_preload}BENCH_SCALE=#{scale} CLEAR_THREADS=#{threads} ./#{dir}/bench_clear", runs, timeout: bto || RUN_TIMEOUT)
  end

  # 6. Capture peak RSS for each lang via /usr/bin/time
  peak_rss = {}
  [:c, :go, :rust, :clear].each do |lang|
    bin = case lang
          when :c     then "#{dir}/bench_c"
          when :go    then "#{dir}/bench_go"
          when :rust  then "#{dir}/bench_rust"
          when :clear then "#{dir}/bench_clear"
          end
    next unless bin && File.exist?(bin)
    env = lang == :clear ? "#{jemalloc_preload}CLEAR_THREADS=#{threads} " : ""
    rss_cmd = "#{env}/usr/bin/time -v #{bin}"
    output = `timeout #{bto || RUN_TIMEOUT}s sh -c "#{rss_cmd.gsub('"', '\\"')}" 2>&1`
    if output =~ /Maximum resident set size.*?:\s*(\d+)/
      peak_rss[lang] = $1.to_i
    end
  end

  # 7. Reporting
  puts "\nRESULTS for #{dir}:"

  rust_label = File.exist?("#{dir}/Cargo.toml") ? "Rust (tokio)" : "Rust (threads)"
  label_map  = { c: "C (Perfect)", go: "Go (goroutines)", rust: rust_label,
                 clear: "CLEAR (fibers)" }
  baseline_label = { c: "C", go: "Go", rust: "Rust" }

  results.each do |lang, t|
    rss_str = peak_rss[lang] ? "  RSS: #{peak_rss[lang]} KB" : ""
    if t.nil?
      puts "#{'%-22s' % label_map[lang]} TIMEOUT (#{bto || RUN_TIMEOUT}s)#{rss_str}"
    else
      puts "#{'%-22s' % label_map[lang]} #{'%.4f' % t} s#{rss_str}"
    end
  end

  [:c, :go, :rust].each do |k|
    next unless results[:clear] && results[k]
    overhead = (results[:clear] / results[k]) * 100 - 100
    sign = overhead >= 0 ? "+" : ""
    puts "CLEAR vs #{baseline_label[k]}:         #{sign}#{'%.2f' % overhead}%"
  end

  if peak_rss[:clear] && peak_rss[:c]
    ratio = ((peak_rss[:clear].to_f / peak_rss[:c]) * 100).round(1)
    puts "CLEAR RSS / C RSS:     #{ratio}%"
  end
end

# -------------------------------------------------------------------------
# Server benchmark: start server, run shared client, capture output
# -------------------------------------------------------------------------
PORT = 6390
DRAGONFLY_PORT = 6391
BASE_NUM_GETS = 100_000
CONCURRENCY = 50

# Wait until a TCP port accepts connections (max ~10s).
def wait_for_port(port, max_tries: 20, delay: 0.5)
  require 'socket'
  max_tries.times do
    begin
      TCPSocket.new("127.0.0.1", port).close
      return true
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT
      sleep delay
    end
  end
  false
end

def run_server_bench(dir, timeout: RUN_TIMEOUT)
  scale = (ENV['BENCH_SCALE'] || "1.0").to_f
  num_gets = (BASE_NUM_GETS * scale).to_i

  puts "=== SERVER BENCHMARK: #{dir} (num_gets=#{num_gets}) ==="

  has_rust = File.exist?("#{dir}/bench.rs") && system("command -v rustc > /dev/null 2>&1")
  has_go   = File.exist?("#{dir}/server.go") && system("command -v go > /dev/null 2>&1")

  # Clean stale binaries before recompiling
  %w[bench_rust server_go server_clear client_go].each { |b| FileUtils.rm_f("#{dir}/#{b}") }

  # 1. Compile everything
  # Client (shared Go binary)
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
      Dir.chdir(dir) { `RUSTFLAGS="-A warnings" cargo build --release -q 2>&1` }
      src = "#{dir}/target/release/bench_rust"
      FileUtils.cp(src, "#{dir}/bench_rust") if File.exist?(src)
    end
  end

  # CLEAR server
  has_clear = false
  if File.exist?("#{dir}/server.cht")
    puts "Compiling CLEAR server..."
    output = `./clear build --optimized #{dir}/server.cht -o #{dir}/server_clear 2>&1`
    if File.exist?("#{dir}/server_clear")
      has_clear = true
    else
      puts "WARNING: CLEAR server failed to compile: #{output.lines.last&.strip}"
    end
  end

  threads = ENV['BENCH_CORES'] || ENV['CLEAR_THREADS'] || `nproc 2>/dev/null`.strip
  threads = "0" if threads.empty?  # 0 = auto-detect in CLEAR

  jemalloc = [
    "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2",
    "/usr/lib/x86_64-linux-gnu/libjemalloc.so.1",
    "/usr/local/lib/libjemalloc.so.2",
  ].find { |p| File.exist?(p) }

  # 2. Run each server with the shared client
  results = {}

  clear_env = { "CLEAR_THREADS" => threads }
  clear_env["LD_PRELOAD"] = jemalloc if jemalloc

  # Detect DragonflyDB for benchmarks that opt in via USE_DRAGONFLY marker file.
  dragonfly_bin = nil
  if File.exist?("#{dir}/USE_DRAGONFLY")
    dragonfly_bin = [
      File.expand_path("~/.local/bin/dragonfly"),
      "/usr/local/bin/dragonfly",
      "/usr/bin/dragonfly",
      `which dragonfly 2>/dev/null`.strip,
    ].find { |p| !p.empty? && File.exist?(p) }
    puts "WARNING: USE_DRAGONFLY present but dragonfly binary not found" unless dragonfly_bin
  end

  servers = []
  servers << { key: :dragonfly, label: "DragonflyDB",      port: DRAGONFLY_PORT,
               bin: dragonfly_bin,  args: ["--port", DRAGONFLY_PORT.to_s,
               "--logtostderr=false", "--dbfilename="],
               env: {} } if dragonfly_bin
  servers << { key: :rust,      label: "Rust (tokio)",     port: PORT,
               bin: "#{dir}/bench_rust", args: [], env: {} } if has_rust && File.exist?("#{dir}/bench_rust")
  servers << { key: :go,        label: "Go (goroutines)",  port: PORT,
               bin: "#{dir}/server_go",  args: [], env: {} } if has_go && File.exist?("#{dir}/server_go")
  servers << { key: :clear,     label: "CLEAR (fibers)",   port: PORT,
               bin: "#{dir}/server_clear", args: [], env: clear_env } if has_clear

  servers.each do |srv|
    # Clean data directory
    FileUtils.rm_rf("data")
    FileUtils.mkdir_p("data")

    # Start server — use env hash (not string) so spawn doesn't wrap in sh -c,
    # giving us the real server PID for /proc/<pid>/status RSS tracking.
    puts "\nRunning #{srv[:label]}..."
    pid = spawn(srv[:env], srv[:bin], *srv[:args], [:out, :err] => "/dev/null")
    wait_for_port(srv[:port])

    # Run client (timeout only if TIMEOUT file present; otherwise no cap like original)
    client_cmd = "./#{dir}/client_go #{pid} #{srv[:port]} #{num_gets} #{CONCURRENCY} 2>&1"
    client_cmd = "timeout #{timeout}s #{client_cmd}" if timeout
    output = `#{client_cmd}`
    puts output

    # Kill server
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil

    # Parse results from client output
    results[srv[:key]] ||= {}
    r = results[srv[:key]]
    if output =~ /SET phase:\s+(\d+) ms/
      r[:set_ms] = $1.to_i
    end
    if output =~ /GET phase:\s+(\d+) ms/
      r[:get_ms] = $1.to_i
    end
    if output =~ /SET throughput:\s+([\d.]+) rps/
      r[:set_rps] = $1.to_f.round
    end
    if output =~ /GET throughput:\s+([\d.]+) rps/
      r[:get_rps] = $1.to_f.round
    end
    if output =~ /INCR throughput:\s+([\d.]+) rps/
      r[:incr_rps] = $1.to_f.round
    end
    # Phase-based output (bench 25 pathological): collect throughput per phase
    output.scan(/Phase \d+: (\S+).*?\n\s+Time: (\d+) ms\n\s+Throughput: ([\d.]+) req\/s/m).each do |name, time_ms, throughput|
      r[:phases] ||= []
      r[:phases] << { name: name, time_ms: time_ms.to_i, throughput: throughput.to_f.round(0).to_i }
    end
    if output =~ /Peak RSS \(VmHWM\):\s+(\d+) KB/
      r[:peak_rss_kb] = $1.to_i
    end
    if output =~ /RSS after(?: GETs)?:\s+(\d+) KB/
      r[:rss_after_kb] = $1.to_i
    end
    # Sum all Verified lines (multi-phase benchmarks have one per phase)
    verified_sum = 0; total_sum = 0
    output.scan(/Verified:\s+(\d+)\s*\/\s*(\d+)/).each do |v, t|
      verified_sum += v.to_i; total_sum += t.to_i
    end
    if total_sum > 0
      r[:verified] = verified_sum
      r[:total] = total_sum
    end
  end

  FileUtils.rm_rf("data")

  # 3. Report
  puts "\n#{'=' * 60}"
  puts "RESULTS for #{dir}:"
  puts "#{'=' * 60}"

  has_phases = results.any? { |_, r| r[:phases]&.any? }

  if has_phases
    # Phase-based display (bench 25 pathological)
    phase_names = results.values.flat_map { |r| (r[:phases] || []).map { |p| p[:name] } }.uniq
    header = "%-22s" % "Server"
    phase_names.each { |pn| header += " %12s" % "#{pn}(r/s)" }
    header += " %10s %10s" % ["Peak RSS", "Verified"]
    puts header
    puts "-" * header.length

    results.each do |key, r|
      label = servers.find { |s| s[:key] == key }&.dig(:label) || key.to_s
      verified = r[:verified] && r[:total] ? "#{r[:verified]}/#{r[:total]}" : "?"
      peak = r[:peak_rss_kb] ? "#{r[:peak_rss_kb]} KB" : "?"
      line = "%-22s" % label
      phase_names.each do |pn|
        phase = (r[:phases] || []).find { |p| p[:name] == pn }
        line += " %12s" % (phase ? phase[:throughput].to_s : "?")
      end
      line += " %10s %10s" % [peak, verified]
      puts line
    end
  else
    # Throughput display (rps) if any server reported rps, otherwise fall back to ms
    has_rps = results.any? { |_, r| r[:set_rps] }
    if has_rps
      puts "#{'%-22s' % 'Server'} #{'%12s' % 'SET(rps)'} #{'%12s' % 'GET(rps)'} #{'%12s' % 'INCR(rps)'} #{'%10s' % 'Peak RSS'}"
      puts "-" * 72
      results.each do |key, r|
        label = servers.find { |s| s[:key] == key }&.dig(:label) || key.to_s
        peak = r[:peak_rss_kb] ? "#{r[:peak_rss_kb]} KB" : "?"
        puts "#{'%-22s' % label} #{'%12s' % (r[:set_rps] || '?')} #{'%12s' % (r[:get_rps] || '?')} #{'%12s' % (r[:incr_rps] || '?')} #{'%10s' % peak}"
      end
    else
      puts "#{'%-22s' % 'Server'} #{'%8s' % 'SET(ms)'} #{'%8s' % 'GET(ms)'} #{'%10s' % 'Peak RSS'} #{'%10s' % 'RSS After'} #{'%10s' % 'Verified'}"
      puts "-" * 70
      results.each do |key, r|
        label = servers.find { |s| s[:key] == key }&.dig(:label) || key.to_s
        verified = r[:verified] && r[:total] ? "#{r[:verified]}/#{r[:total]}" : "?"
        peak = r[:peak_rss_kb] ? "#{r[:peak_rss_kb]} KB" : "?"
        rss  = r[:rss_after_kb] ? "#{r[:rss_after_kb]} KB" : "?"
        puts "#{'%-22s' % label} #{'%8s' % (r[:set_ms] || '?')} #{'%8s' % (r[:get_ms] || '?')} #{'%10s' % peak} #{'%10s' % rss} #{'%10s' % verified}"
      end
    end
  end

  # Throughput comparisons
  if results[:clear] && results[:dragonfly]
    puts ""
    { set: :set_rps, get: :get_rps, incr: :incr_rps }.each do |label, metric|
      c = results[:clear][metric]; d = results[:dragonfly][metric]
      next unless c && d && d > 0
      pct = (((c.to_f / d) - 1) * 100).round(1)
      sign = pct >= 0 ? "+" : ""
      puts "CLEAR #{label.upcase} vs DragonflyDB:  #{sign}#{pct}%"
    end
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
  if results[:clear] && results[:dragonfly] && results[:clear][:peak_rss_kb] && results[:dragonfly][:peak_rss_kb]
    ratio = ((results[:clear][:peak_rss_kb].to_f / results[:dragonfly][:peak_rss_kb]) * 100).round(1)
    puts "\nCLEAR peak RSS: #{ratio}% of DragonflyDB"
  end
end

if __FILE__ == $0
  dirs = []
  mode = "normal"
  scale = "1.0"
  cores = `nproc 2>/dev/null`.strip

  args = ARGV.dup
  while (arg = args.shift)
    case arg
    when "--fast"
      mode = "fast"
      scale = "0.25"
    when "--release"
      mode = "release"
      scale = "5.0"
    when "--normal"
      mode = "normal"
      scale = "1.0"
    when /^--cores=(\d+)$/
      cores = $1
    when "--leak"
      mode = "leak"
      scale = "0.001"
    when "--smoke"
      mode = "smoke"
      scale = "0.1"
    when "--all"
      dirs += Dir.glob("benchmarks/[0-9]*").select { |d| File.directory?(d) }.sort
    else
      dirs << arg
    end
  end

  if dirs.empty?
    if mode == "leak"
      # Leak mode: run ALL benchmarks by default
      dirs = Dir.glob("benchmarks/[0-9]*").select { |d| File.directory?(d) }.sort
    else
      dirs = Dir.glob("benchmarks/0*").sort
    end
  end

  ENV['BENCH_MODE'] = mode
  ENV['BENCH_SCALE'] = scale
  ENV['BENCH_CORES'] = cores

  dirs.each { |d| run_bench(d); puts }
end
