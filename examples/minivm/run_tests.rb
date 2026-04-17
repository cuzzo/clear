#!/usr/bin/env ruby
# MiniVM runner policy:
# - The primary correctness target is interpreter_test.cht.
# - The broader transpile-tests runner is historical/aspirational coverage.

MINIVM_CLEAR = File.join(__dir__, "clear")
TRANSPILER = File.join(__dir__, "scheme_transpiler.rb")
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

def run_primary_test
  system(MINIVM_CLEAR, "test", INTERPRETER_TEST)
  $?.exitstatus || 1
end

def run_historical_test(path)
  output = `ruby #{TRANSPILER} #{path} --run 2>&1`

  if output.include?("SCHEME ASSERT FAILED")
    msg = output.scan(/SCHEME ASSERT FAILED: (.+)/).flatten.first
    [:fail, msg]
  elsif output.include?("SCHEME: all expressions completed")
    [:pass, nil]
  elsif output.include?("error:") || output.include?("Error")
    msg = output.lines.find { |l| l.include?("error") || l.include?("Error") }&.strip
    [:error, msg&.slice(0, 120)]
  else
    [:unknown, output.lines.first&.strip&.slice(0, 120)]
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
  puts "  ruby examples/minivm/run_tests.rb path/to/test.cht"
  puts "    Runs a single transpile test through scheme_transpiler --run"
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
