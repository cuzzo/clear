#!/usr/bin/env ruby
# Driver for the combinatorial fuzz harness.
#
# Modes:
#   ruby tools/fuzz/run.rb --count 20 --seed 42         # sample, per-file run (default)
#   ruby tools/fuzz/run.rb --matrix                      # full matrix
#   ruby tools/fuzz/run.rb --generate-only               # generate only, don't run
#   ruby tools/fuzz/run.rb --templates t1,t2             # restrict to named templates
#
# Cells may be marked :in_dev to reserve matrix space for unlanded features
# (e.g., LEND). They are emitted as comments and not run.

require 'optparse'
require 'fileutils'
require 'digest'
require 'etc'
require 'open3'
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

opts[:seed] ||= Random.new_seed

if opts[:clean] && Dir.exist?(opts[:out])
  Dir.glob(File.join(opts[:out], 'fuzz_*.cht')).each { |f| File.delete(f) }
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
  tuples =
    if opts[:quarantine] == :skip
      tuples.reject { |t| quarantined.include?(t[:template]) }
    else
      tuples.select { |t| quarantined.include?(t[:template]) }
    end
end
if opts[:shard]
  idx, total = opts[:shard]
  tuples = tuples.each_with_index.select { |_tuple, i| (i % total) == idx }.map(&:first)
end

emitted = []   # array of { path:, expected: }
in_dev_count = 0
tuples.each do |tuple|
  result = gen.emit(tuple)
  if result[:expected] == :in_dev
    in_dev_count += 1
    next
  end
  hash = Digest::SHA1.hexdigest(result[:source])[0, 10]
  name = "fuzz_#{tuple[:template]}_#{hash}.cht"
  path = File.join(opts[:out], name)
  File.write(path, result[:source])
  emitted << { path: path, expected: result[:expected] }
end

puts "[fuzz] emitted #{emitted.size} programs to #{opts[:out]} (seed=#{opts[:seed]}, mode=#{opts[:mode]}, in_dev=#{in_dev_count})"

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
  FileUtils.rm_rf(build_dir) if build_dir
end

def run_negative_builds(entries, out_dir)
  return [[], []] if entries.empty?

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clear = File.expand_path('../../clear', __dir__)
  workers = [Etc.nprocessors, entries.size].min
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

def hybrid_run(emitted, out_dir)
  pass_entries = emitted.select { |e| e[:expected] == :pass }
  negative_entries = emitted.select { |e| e[:expected] == :compile_error }

  pass_ok, fails, mir_errors, leaks = run_pass_bundle(pass_entries, out_dir)
  negative_ok, unexpected_pass = run_negative_builds(negative_entries, out_dir)

  [pass_ok + negative_ok, fails, leaks, mir_errors, unexpected_pass]
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

pass, fails, leaks, mir_errors, unexpected_pass = hybrid_run(emitted, opts[:out])

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
    out.each_line.first(10).each { |l| puts "      #{l}" }
  end
end

exit (fails.empty? && leaks.empty? && mir_errors.empty? && unexpected_pass.empty?) ? 0 : 1
