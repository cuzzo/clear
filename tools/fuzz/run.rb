#!/usr/bin/env ruby
# Driver for the combinatorial fuzz harness.
#
# Modes:
#   ruby tools/fuzz/run.rb --count 20 --seed 42         # sample, per-file run (default)
#   ruby tools/fuzz/run.rb --matrix                      # full matrix
#   ruby tools/fuzz/run.rb --generate-only               # generate only, don't run
#   ruby tools/fuzz/run.rb --templates t1,t2             # restrict to named templates
#
# When COVERAGE=1, this runner is compile-only: it exercises the Ruby
# compile/lower/emit path like transpile-tests/gen.rb without running Zig tests
# or spawning per-file `clear` subprocesses.
#
# Cells may be marked :in_dev to reserve matrix space for unlanded features
# (e.g., LEND). They are emitted as comments and not run.

require 'optparse'
require 'fileutils'
require 'digest'
require 'etc'
require 'open3'
require 'rbconfig'
require_relative 'generator'
# Route SimpleCov to a 'fuzz' resultset key (gen.rb defaults to
# 'transpile-tests') so fuzz cell hits stay attributable.
ENV['COVERAGE_BOOTSTRAP_NAME'] ||= 'fuzz' if ENV['COVERAGE'] == '1'
require_relative '../../transpile-tests/gen'

LITEDB_ROOT = File.expand_path('../..', __dir__)

opts = {
  count: 20,
  seed: nil,
  out: File.expand_path('../../transpile-tests/fuzz', __dir__),
  mode: :sample,        # :sample | :matrix
  generate_only: false,
  clean: false,
  templates: nil,
  shard: nil,
  jobs: Integer(ENV.fetch('FUZZ_JOBS', Etc.nprocessors.to_s)),
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/fuzz/run.rb [options]"
  o.on('--count N', Integer)    { |v| opts[:count] = v }
  o.on('--seed S', Integer)     { |v| opts[:seed] = v }
  o.on('--out DIR')             { |v| opts[:out] = File.expand_path(v) }
  o.on('--matrix')              { opts[:mode] = :matrix }
  o.on('--generate-only')       { opts[:generate_only] = true }
  o.on('--clean')               { opts[:clean] = true }
  o.on('--templates LIST')      { |v| opts[:templates] = v.split(',').map(&:to_sym) }
  o.on('--exclude LIST')        { |v| opts[:exclude] = v.split(',').map(&:to_sym) }
  o.on('--jobs N', Integer)     { |v| opts[:jobs] = v }
  # Quarantine: tools/fuzz/quarantine.txt lists templates with a known
  # bug. --skip-quarantined runs the green gate (full matrix minus
  # quarantine); --only-quarantined runs just the quarantined set
  # (non-blocking informational job).
  o.on('--skip-quarantined')    { opts[:quarantine] = :skip }
  o.on('--only-quarantined')    { opts[:quarantine] = :only }
  o.on('--shard I/N') do |v|
    idx, total = v.split('/', 2).map(&:to_i)
    abort "--shard expects I/N with N > 0 and 0 <= I < N" unless total && total > 0 && idx && idx >= 0 && idx < total
    opts[:shard] = [idx, total]
  end
  o.on('-h', '--help')          { puts o; exit 0 }
end.parse!
opts[:jobs] = 1 if opts[:jobs] < 1

opts[:seed] ||= Random.new_seed

if opts[:clean] && Dir.exist?(opts[:out])
  Dir.glob(File.join(opts[:out], 'fuzz_*.cht')).each { |f| File.delete(f) }
  Dir.glob(File.join(opts[:out], 'fuzz_*.rb')).each { |f| File.delete(f) }
end

FileUtils.mkdir_p(opts[:out])

gen = FuzzGenerator.new(seed: opts[:seed])
tuples = opts[:mode] == :matrix ? gen.full_matrix : gen.sample(opts[:count])
if opts[:templates]
  tuples = tuples.select { |t| opts[:templates].include?(t[:template]) }
end
if opts[:exclude]
  tuples = tuples.reject { |t| opts[:exclude].include?(t[:template]) }
end
if opts[:quarantine]
  qfile = File.expand_path('quarantine.txt', __dir__)
  quarantined = File.readlines(qfile)
                    .map { |l| l.sub(/#.*/, '').strip }
                    .reject(&:empty?)
                    .map(&:to_sym)
                    .to_set
  before_quarantine = tuples.length
  tuples =
    if opts[:quarantine] == :skip
      tuples.reject { |t| quarantined.include?(t[:template]) }
    else
      tuples.select { |t| quarantined.include?(t[:template]) }
    end
  skipped = before_quarantine - tuples.length
  puts "[fuzz] quarantine filter=#{opts[:quarantine]} skipped=#{skipped} selected=#{tuples.length}"
end
if opts[:shard]
  idx, total = opts[:shard]
  tuples = tuples.each_with_index.select { |_tuple, i| (i % total) == idx }.map(&:first)
end

emitted = []   # array of { path:, expected:, kind:, error_code: }
in_dev_count = 0
tuples.each do |tuple|
  result = gen.emit(tuple)
  if result[:expected] == :in_dev
    in_dev_count += 1
    next
  end
  hash = Digest::SHA1.hexdigest(result[:source])[0, 10]
  ext = result[:kind] == :mir_checker ? "rb" : "cht"
  name = "fuzz_#{tuple[:template]}_#{hash}.#{ext}"
  path = File.join(opts[:out], name)
  File.write(path, result[:source])
  emitted << {
    path: path,
    expected: result[:expected],
    kind: result[:kind] || :cht,
    error_code: result[:error_code],
  }
end

puts "[fuzz] emitted #{emitted.size} programs to #{opts[:out]} (seed=#{opts[:seed]}, mode=#{opts[:mode]}, in_dev=#{in_dev_count})"
puts "[fuzz] skipped in_dev=#{in_dev_count}"
if in_dev_count.positive?
  warn "[fuzz] ERROR: :in_dev cells are not allowed in the required fuzz matrix"
  exit 1
end

if opts[:generate_only]
  exit 0
end

# ── Runner ──────────────────────────────────────────────────────────────
# Positive cells are bundled into one Zig test file, mirroring
# transpile-tests/gen.rb. Negative cells run in parallel through
# `clear build --no-stack-check`, which catches parser/compiler/MIR/Zig
# compile-time rejections without running runtime tests.

def zig_exe
  [
    File.join(File.expand_path('~'), 'zig-x86_64-linux-0.16.0', 'zig'),
    File.join(LITEDB_ROOT, 'zig', 'zig-new', 'zig'),
    File.join(LITEDB_ROOT, 'zig', 'zig', 'zig'),
    `which zig 2>/dev/null`.strip
  ].find { |p| !p.empty? && File.exist?(p) } || 'zig'
end

def ensure_symlink(link_path, target_path)
  if File.symlink?(link_path)
    return if File.readlink(link_path) == target_path
    File.delete(link_path)
  elsif File.exist?(link_path)
    FileUtils.rm_rf(link_path)
  end
  File.symlink(target_path, link_path)
end

def run_pass_bundle(entries, out_dir)
  return [[], [], [], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  build_dir = File.join(out_dir, ".bundle-#{$$}")
  FileUtils.rm_rf(build_dir)
  FileUtils.mkdir_p(build_dir)
  ensure_symlink(File.join(build_dir, 'runtime'), File.join(LITEDB_ROOT, 'zig', 'runtime'))
  ensure_symlink(File.join(build_dir, 'lib'), File.join(LITEDB_ROOT, 'zig', 'lib'))
  ensure_symlink(File.join(build_dir, 'experimental'), File.join(LITEDB_ROOT, 'zig', 'experimental'))
  ensure_symlink(File.join(build_dir, 'testdata'), File.join(LITEDB_ROOT, 'testdata'))

  zig_path = File.join(build_dir, 'all-fuzz.zig')
  generator = TestGenerator.new
  failed_transpile = []

  File.open(zig_path, 'w') do |f|
    frame_debug = ENV['CLEAR_FRAME_DEBUG'] == '1'
    f.puts "pub const CLEAR_FRAME_DEBUG = #{frame_debug};"
    f.puts 'const std = @import("std");'
    f.puts 'const CheatHeader = @import("runtime/runtime-header.zig");'
    f.puts 'const CheatLib = CheatHeader.CheatLib;'
    f.puts 'const Runtime = CheatHeader.Runtime;'
    f.puts 'const EbrContext = CheatHeader.EbrContext;'

    entries.each do |entry|
      path = entry[:path]
      begin
        block = generator.generate_test_block(File.basename(path), File.read(path), source_dir: File.dirname(path))
        f.puts "\n// --- FUZZ: #{File.basename(path)} ---"
        f.puts block
      rescue StandardError => e
        failed_transpile << [path, "#{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"]
      end
    end
  end

  return [[], [], failed_transpile, []] unless failed_transpile.empty?

  fmt_out, fmt_status = Open3.capture2e(zig_exe, 'fmt', zig_path)
  return [[], [[zig_path, fmt_out]], [], []] unless fmt_status.success?

  args = [
    zig_exe, 'test', 'all-fuzz.zig',
    'runtime/switch.S', 'runtime/onRoot.S',
    '-lc'
  ]
  out, status = Open3.capture2e(*args, chdir: build_dir)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] pass bundle: #{entries.size} cells in #{format('%.2f', elapsed)}s"

  if !status.success? || out.include?('FAIL')
    return [[], [[zig_path, out]], [], []]
  end

  leak = out =~ /MEMORY LEAKS:\s*[1-9]/ ||
         out.include?('[DebugAllocator] (err)') ||
         out.include?('[gpa] (err)') ||
         out =~ /\d+ tests leaked memory/
  return [[], [], [], [[zig_path, out]]] if leak

  [entries.map { |e| e[:path] }, [], [], []]
ensure
  FileUtils.rm_rf(build_dir) if build_dir && ENV['FUZZ_KEEP_BUNDLE'] != '1'
end

def print_failure_excerpt(out)
  lines = out.each_line.to_a
  failure_index = lines.index { |line| line.include?('FAIL') || line.include?('error:') }
  excerpt =
    if failure_index
      first = [failure_index - 8, 0].max
      lines[first, 40]
    else
      lines.first(40)
    end
  excerpt.each { |line| puts "      #{line}" }
  return unless lines.size > excerpt.size

  puts "      ... #{lines.size - excerpt.size} more lines omitted"
end

def fuzz_worker_count(entries, env_key, default_workers)
  [
    Integer(ENV.fetch(env_key, default_workers.to_s)),
    entries.size,
  ].min.then { |n| n < 1 ? 1 : n }
end

def simplecov_child_command!(name)
  return unless defined?(SimpleCov)

  SimpleCov.command_name("#{name}-#{Process.pid}") if SimpleCov.respond_to?(:command_name)
end

def parallel_compile_entries(entries, workers, label)
  return [[], []] if entries.empty?

  queue = entries.each_with_index.to_a
  chunks = Array.new(workers) { [] }
  queue.each_with_index { |item, index| chunks[index % workers] << item }
  readers = []
  pids = []

  chunks.reject(&:empty?).each do |chunk|
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      simplecov_child_command!("fuzz-#{label}")
      generator = TestGenerator.new
      results = chunk.map do |entry, _index|
        path = entry[:path]
        begin
          generator.generate_test_block(File.basename(path), File.read(path), source_dir: File.dirname(path))
          [entry, nil]
        rescue StandardError => e
          [entry, "#{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"]
        end
      end
      writer.write(Marshal.dump(results))
      writer.close
      exit 0
    rescue StandardError => e
      writer.write(Marshal.dump(chunk.map { |entry, _index| [entry, "#{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"] }))
      writer.close
      exit 1
    end
    writer.close
    readers << reader
    pids << pid
  end

  results = readers.flat_map do |reader|
    Marshal.load(reader.read)
  ensure
    reader.close
  end
  pids.each { |pid| Process.wait(pid) }
  results
end

def run_negative_builds(entries, out_dir, default_workers)
  return [[], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clear = File.expand_path('../../clear', __dir__)
  workers = fuzz_worker_count(entries, 'FUZZ_NEGATIVE_WORKERS', default_workers)
  queue = Queue.new
  entries.each_with_index { |entry, i| queue << [entry, i] }
  pass = []
  unexpected_pass = []
  mutex = Mutex.new

  threads = workers.times.map do
    Thread.new do
      loop do
        item = queue.pop(true) rescue nil
        break unless item

        entry, i = item
        path = entry[:path]
        bin = File.join(out_dir, ".neg-#{i}")
        out, status = Open3.capture2e(clear, 'build', path, '-o', bin, '--no-stack-check')
        mutex.synchronize do
          if status.success?
            unexpected_pass << [path, out]
          else
            pass << path
          end
        end
      end
    end
  end
  threads.each(&:join)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] negative builds: #{entries.size} cells with #{workers} workers in #{format('%.2f', elapsed)}s"
  [pass, unexpected_pass]
end

def run_mir_checker_negatives(entries, default_workers)
  return [[], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pass = []
  unexpected_pass = []
  workers = fuzz_worker_count(entries, 'FUZZ_MIR_NEGATIVE_WORKERS', default_workers)
  queue = Queue.new
  entries.each { |entry| queue << entry }
  mutex = Mutex.new

  threads = workers.times.map do
    Thread.new do
      loop do
        entry = queue.pop(true) rescue nil
        break unless entry

        out, status = Open3.capture2e(RbConfig.ruby, entry[:path], chdir: LITEDB_ROOT)
        mutex.synchronize do
          if status.success?
            pass << entry[:path]
          else
            unexpected_pass << [entry[:path], out]
          end
        end
      end
    end
  end
  threads.each(&:join)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] MIR checker negatives: #{entries.size} cells with #{workers} workers in #{format('%.2f', elapsed)}s"
  [pass, unexpected_pass]
end

def run_compile_only_positive_coverage(entries, default_workers)
  return [[], [], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  workers = fuzz_worker_count(entries, 'FUZZ_COVERAGE_WORKERS', default_workers)
  results = parallel_compile_entries(entries, workers, 'coverage-positive')
  pass = results.filter_map { |entry, error| entry[:path] unless error }
  mir_errors = results.filter_map { |entry, error| [entry[:path], error] if error }

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] coverage compile positives: #{entries.size} cells with #{workers} workers in #{format('%.2f', elapsed)}s"
  [pass, mir_errors, []]
end

def run_compile_only_negative_coverage(entries, default_workers)
  return [[], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  workers = fuzz_worker_count(entries, 'FUZZ_COVERAGE_WORKERS', default_workers)
  results = parallel_compile_entries(entries, workers, 'coverage-negative')
  rejected = results.count { |_entry, error| error }
  emitted = results.length - rejected
  pass = results.map { |entry, _error| entry[:path] }

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] coverage compile negatives: #{entries.size} cells with #{workers} workers in #{format('%.2f', elapsed)}s " \
       "(#{rejected} rejected by Ruby compile/lower, #{emitted} emitted for downstream gates)"
  [pass, []]
end

def compile_only_coverage_run(emitted, default_workers)
  pass_entries = emitted.select { |e| e[:kind] != :mir_checker && e[:expected] == :pass }
  negative_entries = emitted.select { |e| e[:kind] != :mir_checker && e[:expected] == :compile_error }
  mir_negative_entries = emitted.select { |e| e[:kind] == :mir_checker && e[:expected] == :compile_error }

  pass_ok, mir_errors, leaks = run_compile_only_positive_coverage(pass_entries, default_workers)
  negative_ok, unexpected_pass = run_compile_only_negative_coverage(negative_entries, default_workers)
  mir_negative_ok, mir_unexpected_pass = run_mir_checker_negatives(mir_negative_entries, default_workers)

  [
    pass_ok + negative_ok + mir_negative_ok,
    [],
    leaks,
    mir_errors,
    unexpected_pass + mir_unexpected_pass,
  ]
end

def async_runtime_cell?(entry)
  src = File.read(entry[:path])
  src.include?('BG') || src.include?('DO {')
end

def run_positive_files(entries, default_workers)
  return [[], [], [], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clear = File.expand_path('../../clear', __dir__)
  pass, fails, leaks, mir_errors = [], [], [], []
  workers = fuzz_worker_count(entries, 'FUZZ_ISOLATED_WORKERS', default_workers)
  queue = Queue.new
  entries.each { |entry| queue << entry }
  mutex = Mutex.new

  threads = workers.times.map do
    Thread.new do
      loop do
        entry = queue.pop(true) rescue nil
        break unless entry

        path = entry[:path]
        out, status = Open3.capture2e(clear, 'test', path)
        compile_error = out.include?('MIR ownership verification failed') ||
                        out.include?('[Compiler Error]') ||
                        out.include?('Transpilation failed') ||
                        out =~ /\.zig:\d+:\d+: error:/
        leak = out =~ /MEMORY LEAKS:\s*[1-9]/ ||
               out.include?('[DebugAllocator] (err)') ||
               out.include?('[gpa] (err)') ||
               out =~ /\d+ tests leaked memory/

        mutex.synchronize do
          if compile_error
            mir_errors << [path, out]
          elsif leak
            leaks << [path, out]
          elsif !status.success?
            fails << [path, out]
          else
            pass << path
          end
        end
      end
    end
  end
  threads.each(&:join)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts "[fuzz] isolated async positives: #{entries.size} cells with #{workers} workers in #{format('%.2f', elapsed)}s"
  [pass, fails, mir_errors, leaks]
end

def hybrid_run(emitted, out_dir, default_workers)
  pass_entries = emitted.select { |e| e[:kind] != :mir_checker && e[:expected] == :pass }
  negative_entries = emitted.select { |e| e[:kind] != :mir_checker && e[:expected] == :compile_error }
  mir_negative_entries = emitted.select { |e| e[:kind] == :mir_checker && e[:expected] == :compile_error }

  isolated_pass_entries, bundled_pass_entries = pass_entries.partition { |entry| async_runtime_cell?(entry) }
  pass_ok, fails, mir_errors, leaks = run_pass_bundle(bundled_pass_entries, out_dir)
  iso_ok, iso_fails, iso_mir_errors, iso_leaks = run_positive_files(isolated_pass_entries, default_workers)
  negative_ok, unexpected_pass = run_negative_builds(negative_entries, out_dir, default_workers)
  mir_negative_ok, mir_unexpected_pass = run_mir_checker_negatives(mir_negative_entries, default_workers)

  [
    pass_ok + iso_ok + negative_ok + mir_negative_ok,
    fails + iso_fails,
    leaks + iso_leaks,
    mir_errors + iso_mir_errors,
    unexpected_pass + mir_unexpected_pass,
  ]
end

def per_file_run(emitted)
  clear = File.expand_path('../../clear', __dir__)
  pass, fails, leaks, mir_errors, unexpected_pass = [], [], [], [], []

  emitted.each_with_index do |entry, i|
    path, expected = entry[:path], entry[:expected]
    short = File.basename(path)
    print "[#{i + 1}/#{emitted.size}] #{short} (#{expected})... "
    out = `#{clear} test #{path} 2>&1`
    status = $?.exitstatus

    compile_error = out.include?('MIR ownership verification failed') ||
                    out.include?('[Compiler Error]') ||
                    out.include?('Transpilation failed') ||
                    out =~ /\.zig:\d+:\d+: error:/
    # Both flavors: directory mode reports "MEMORY LEAKS: N"; single-file mode
    # reports per-address "[DebugAllocator] (err): ... leaked" then a summary
    # "N tests leaked memory".
    leak = out =~ /MEMORY LEAKS:\s*[1-9]/ ||
           out.include?('[DebugAllocator] (err)') ||
           out =~ /\d+ tests leaked memory/
    runtime_fail = (status != 0 && !compile_error)

    case expected
    when :pass
      if compile_error
        puts "MIR-FAIL"
        mir_errors << [path, out]
      elsif leak
        puts "LEAK"
        leaks << [path, out]
      elsif runtime_fail
        puts "FAIL (exit #{status})"
        fails << [path, out]
      else
        puts "ok"
        pass << path
      end
    when :compile_error
      if compile_error
        puts "ok (rejected)"
        pass << path
      else
        puts "UNEXPECTED-PASS"
        unexpected_pass << [path, out]
      end
    end
  end

  [pass, fails, leaks, mir_errors, unexpected_pass]
end

pass, fails, leaks, mir_errors, unexpected_pass =
  if ENV['COVERAGE'] == '1'
    compile_only_coverage_run(emitted, opts[:jobs])
  else
    hybrid_run(emitted, opts[:out], opts[:jobs])
  end

puts
puts "=" * 60
puts "Summary: #{emitted.size} run, #{pass.size} ok, #{fails.size} fail, #{leaks.size} leak, #{mir_errors.size} mir-error, #{unexpected_pass.size} unexpected-pass"
puts "=" * 60

[
  ["FAILURES",        fails],
  ["LEAKS",           leaks],
  ["MIR ERRORS",      mir_errors],
  ["UNEXPECTED PASS", unexpected_pass],
].each do |label, list|
  next if list.empty?
  puts
  puts "#{label}:"
  list.each do |path, out|
    puts "  - #{path}"
    print_failure_excerpt(out)
  end
end

ok = fails.empty? && leaks.empty? && mir_errors.empty? && unexpected_pass.empty?
exit ok ? 0 : 1
