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
require_relative 'generator'

LITEDB_ROOT = File.expand_path('../..', __dir__)

opts = {
  count: 20,
  seed: nil,
  out: File.expand_path('../../transpile-tests/fuzz', __dir__),
  mode: :sample,        # :sample | :matrix
  generate_only: false,
  clean: false,
  templates: nil,
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
# Bundled runner: build one zig/all-fuzz.zig, run zig test once. Mirrors
# transpile-tests/gen.rb's bulk pattern. Per-file mode invokes ./clear test
# per program — slower but isolates failures cleanly.

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

pass, fails, leaks, mir_errors, unexpected_pass = per_file_run(emitted)

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
