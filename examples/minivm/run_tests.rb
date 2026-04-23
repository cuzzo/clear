#!/usr/bin/env ruby
# MiniVM runner policy:
# - The primary correctness target is interpreter_test.cht.
# - The broader transpile-tests runner is historical/aspirational coverage.

MINIVM_CLEAR = File.join(__dir__, "clear")
TRANSPILER = File.join(__dir__, "bc_run.rb")
TEST_DIR = File.expand_path("../../transpile-tests", __dir__)
INTERPRETER_TEST = File.join(__dir__, "interpreter_test.cht")

HISTORICAL_KNOWN_PASSING = %w[
  01_stack_alloc
  02_heap_leak_cheat
  03_string_mutation
  05_move_frees
  06_heap_return
  07_loop_scope
  08_where
  09_array
  10_concat
  11_smooth_pipe
  12_while_loop
  14_hashmap
  15_select
  16_file_io
  17_shell
  13_if_else
  20_subfield_move
  21_subfield_return
  22_heap_subfield_move
  23_optional
  24_error_returns
  26_reduce
  27_order_by
  28_limit
  30_distinct
  31_multiowned
  32_multiowned_return
  33_multiowned_param
  34_multiowned_struct_field
  35_shared
  36_shared_return
  37_shared_param
  38_move_ownership
  39_move_return
  44_do_block
  45_match
  46_match_when
  46_range
  47_match_destructure
  49_visibility
  50_require
  51_enum
  52_union
  53_generic_struct
  53_writefile
  54_generic_fn
  54_writefile_bg
  55_generic_union
  55_string_ops
  56_else_if_chain
  56_match_enum_exhaustive
  48_multidim_array
  57_line_parser
  57_match_union_capture
  58_bg
  58_string_return_leak
  59_bg_concurrent
  59_string_temp_takes
]

HISTORICAL_CANDIDATES = %w[
  04_stack_return
  07_loop_scope
  19_copy_struct
  20_subfield_move
  21_subfield_return
  55_string_ops
  56_else_if_chain
  57_line_parser
]

# Tests that require runtime infrastructure the VM doesn't have. Counted
# separately in coverage reports so the denominator reflects what's actually
# achievable on the bytecode-VM path.
VM_UNSUPPORTED = {
  # Infinite generators (WHILE TRUE + YIELD): VM has no fiber scheduler,
  # so eager BG STREAM materialization loops forever.
  "76_inf_stream"                => :infinite_stream,
  "218_yield_string_stream"      => :infinite_stream,
  "234_limit_streams"            => :infinite_stream,
  "235_stream_reduce"            => :infinite_stream,
  "237_tap_inf_stream"           => :infinite_stream,
  "238_distinct_streams"         => :infinite_stream,
  "239_index_inf_stream"         => :infinite_stream,

  # File / socket resource tests originally listed as :resource — the
  # File::open / File::create / fileReadAll / fileWrite path now has a
  # syntax-level stub (Task #19). RAII auto-close is still not modeled.
  # TCP and struct-with-resource-field cases stay unsupported.
  "61_tcp_resource"              => :resource,
  "63_struct_resource_close"     => :resource,

  # Other infrastructure-heavy tests:
  "74_service_benchmark"         => :service_runtime,
  "185_borrowed_iterator"        => :borrowed_iterator,

  # Narrow numeric types (Int8/Int16/Int32/UInt8..UInt64) and Float32.
  # The VM's Value union only has Int64Val and Number (f64); there's no
  # storage variant for smaller widths. The MIR lowering emits @intCast
  # and similar conversions that have no VM equivalent. Would need either
  # new Value variants + typed arithmetic, or lowering-time gating.
  "69_numeric_types"             => :narrow_numeric_types,

  # Direct FFI / extern std imports. The VM has no @import machinery.
  "224_extern_std_ffi"           => :extern_ffi,
}

def run_primary_test
  system(MINIVM_CLEAR, "test", INTERPRETER_TEST)
  $?.exitstatus || 1
end

def run_historical_test(path)
  # Use a short kill-after so infinite-loop tests don't hang the runner.
  output = `timeout --kill-after=2 10 ruby #{TRANSPILER} #{path} --run 2>&1`
  clean  = output.gsub(/\e\[[0-9;]*m/, '')  # strip ANSI color

  # In-test ASSERT FAILED must take priority over completion — the VM
  # prints "ASSERT FAILED: <msg>" but still runs to completion.
  if clean.match?(/^ASSERT FAILED: /m)
    msg = clean[/^ASSERT FAILED: (.+)/, 1]
    [:fail, msg&.slice(0, 100)]
  elsif clean.include?("SCHEME ASSERT FAILED")
    msg = clean.scan(/SCHEME ASSERT FAILED: (.+)/).flatten.first
    [:fail, msg]
  elsif clean.include?("SCHEME: all expressions completed")
    [:pass, nil]
  elsif clean.match?(/unhandled (expr|stmt): AST::(\w+)/)
    [:unimpl, clean[/unhandled (?:expr|stmt): AST::(\w+)/, 1]]
  elsif clean.match?(/Bytecode compilation error: (.+)/)
    [:unimpl, clean[/Bytecode compilation error: (.+)/, 1]&.slice(0, 90)]
  elsif clean.match?(/free\(\)|malloc\(\)|malloc_consolidate|double free|corrupted|munmap|unaligned|memcpy arguments alias|General protection exception|Task Crashed/)
    sig = clean[/(free\(\)[^|\n]*|malloc\(\)[^|\n]*|malloc_consolidate[^|\n]*|double free[^|\n]*|corrupted[^|\n]*|munmap[^|\n]*|memcpy arguments alias|General protection exception|Task Crashed[^|\n]*)/, 1]
    [:heap_corrupt, sig&.slice(0, 80)]
  elsif clean.include?("panic:")
    msg = clean[/panic: (.+)/, 1]
    [:panic, msg&.slice(0, 80)]
  elsif clean.match?(/error\.OutOfMemory/)
    [:panic, "out of memory"]
  elsif clean.strip.empty?
    [:timeout, nil]
  elsif clean.include?("error:") || clean.include?("Error")
    msg = clean.lines.find { |l| l.include?("error") || l.include?("Error") }&.strip
    [:error, msg&.slice(0, 120)]
  else
    [:unknown, clean.lines.first&.strip&.slice(0, 120)]
  end
end

def run_historical_suite(tests, label)
  puts "\n#{label}"
  puts "=" * 60
  pass = 0
  fail = 0
  error = 0

  tests.each do |name|
    path = name.include?("/") ? name : File.join(TEST_DIR, "#{name}.cht")
    unless File.exist?(path)
      puts "  SKIP  #{name} (file not found)"
      next
    end

    result, msg = run_historical_test(path)
    case result
    when :pass
      puts "  PASS  #{name}"
      pass += 1
    when :fail
      puts "  FAIL  #{name}: #{msg}"
      fail += 1
    when :error
      puts "  ERR   #{name}: #{msg}"
      error += 1
    else
      puts "  ???   #{name}: #{msg}"
      error += 1
    end
  end

  puts "-" * 60
  puts "  #{pass} passed, #{fail} failed, #{error} errors (#{tests.length} total)"
  fail.zero? && error.zero?
end

def run_vm_coverage
  # Walk every .cht file in TEST_DIR (except ffi/module integration dirs and
  # helpers). Skip VM_UNSUPPORTED outright. Bucket everything else by outcome
  # category so we can see at a glance what stands between us and 100%.
  exclude = %w[require_helper require_types_helper]
  all = Dir.glob(File.join(TEST_DIR, "*.cht")).sort.reject do |p|
    name = File.basename(p, ".cht")
    exclude.include?(name)
  end

  buckets = Hash.new { |h, k| h[k] = [] }
  all.each do |path|
    name = File.basename(path, ".cht")
    if VM_UNSUPPORTED.key?(name)
      buckets[:unsupported] << [name, VM_UNSUPPORTED[name]]
      next
    end
    result, msg = run_historical_test(path)
    buckets[result] << [name, msg]
  end

  total        = all.length
  unsupported  = buckets[:unsupported].length
  supportable  = total - unsupported
  passed       = buckets[:pass].length

  puts ""
  puts "VM Coverage (transpile-tests via bc_run.rb)"
  puts "=" * 60
  puts "  PASS:           #{passed} / #{supportable} supportable"
  puts "  PASS (pct):     #{supportable.positive? ? (passed * 100 / supportable) : 0}%"
  puts ""
  [:pass, :fail, :panic, :heap_corrupt, :unimpl, :timeout, :error, :unknown, :unsupported].each do |k|
    rows = buckets[k]
    next if rows.empty?
    label = k.to_s.upcase.ljust(14)
    puts "  #{label} #{rows.length.to_s.rjust(3)}"
    rows.sort.each { |name, msg| puts "    #{name.ljust(48)} #{msg}" }
    puts ""
  end
  puts "  Total:          #{total}"
  puts "  Unsupported:    #{unsupported}  (infinite-stream, resources, etc.)"
  puts "  Supportable:    #{supportable}"
  puts "  Passing:        #{passed}  (#{supportable.positive? ? (passed * 100 / supportable) : 0}%)"
  passed == supportable
end

def usage
  puts "Usage:"
  puts "  ruby examples/minivm/run_tests.rb"
  puts "    Runs the primary MiniVM regression target: interpreter_test.cht"
  puts
  puts "  ruby examples/minivm/run_tests.rb --historical"
  puts "    Runs the broader historical transpile-tests coverage"
  puts
  puts "  ruby examples/minivm/run_tests.rb --all"
  puts "    Runs the historical known-passing list plus additional candidates"
  puts
  puts "  ruby examples/minivm/run_tests.rb --discover"
  puts "    Tries all numbered transpile-tests <= 60"
  puts
  puts "  ruby examples/minivm/run_tests.rb --vm-coverage"
  puts "    Runs every transpile test, skips VM_UNSUPPORTED, prints a"
  puts "    PASS percentage over supportable tests. Targets 100%."
  puts
  puts "  ruby examples/minivm/run_tests.rb path/to/test.cht"
  puts "    Runs a single transpile test through bc_run"
end

if ARGV.empty?
  exit(run_primary_test)
elsif ARGV[0] == "--historical"
  ok = run_historical_suite(HISTORICAL_KNOWN_PASSING, "Historical Known-Passing Tests")
  exit(ok ? 0 : 1)
elsif ARGV[0] == "--all"
  ok = run_historical_suite(HISTORICAL_KNOWN_PASSING, "Historical Known-Passing Tests")
  ok &&= run_historical_suite(HISTORICAL_CANDIDATES, "Historical Additional Candidates")
  exit(ok ? 0 : 1)
elsif ARGV[0] == "--vm-coverage"
  ok = run_vm_coverage
  exit(ok ? 0 : 1)
elsif ARGV[0] == "--discover"
  all = Dir.glob(File.join(TEST_DIR, "*.cht"))
    .map { |f| File.basename(f, ".cht") }
    .select { |f| f.match?(/^\d+_/) && f.split("_").first.to_i <= 60 }
    .sort_by { |f| f.split("_").first.to_i }
  ok = run_historical_suite(all, "Historical Discovery: all tests <= 60")
  exit(ok ? 0 : 1)
elsif ARGV[0].start_with?("-")
  usage
  exit 1
else
  ARGV.each do |path|
    result, msg = run_historical_test(path)
    case result
    when :pass
      puts "PASS: #{path}"
    when :fail
      puts "FAIL: #{path}: #{msg}"
      exit 1
    when :error
      puts "ERROR: #{path}: #{msg}"
      exit 1
    else
      puts "???: #{path}: #{msg}"
      exit 1
    end
  end
end
