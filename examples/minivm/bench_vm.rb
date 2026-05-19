#!/usr/bin/env ruby
# frozen_string_literal: true

require "benchmark"
require "open3"
require "optparse"
require "timeout"
require_relative "vm_golden_harness"

TEST_DIR = File.expand_path("../../transpile-tests", __dir__)
ALLOWLIST = File.join(__dir__, "register-transpile-allowlist.txt")
BENCHMARK_ALLOWLIST = File.join(__dir__, "register-benchmark-allowlist.txt")

options = {
  iterations: 1,
  allowlist: ALLOWLIST,
  run: false,
  suite: :transpile,
  optimized: true,
  compare_languages: false,
  all_vm_bench: false,
  all_benchmarks: false,
  single_core: true,
  timeout_seconds: 30,
  profile_register_bytecode: false,
  smoke: false,
  skip_stack_vm: false,
  smoke_cases: nil,
  summarize_register_blockers: false,
  write_register_compile_ok: nil,
  write_register_run_ok: nil,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby examples/minivm/bench_vm.rb [options] [tests...]"
  opts.on("--iterations=N", Integer, "Repeat the corpus N times") { |n| options[:iterations] = n }
  opts.on("--allowlist=PATH", "Read tests from PATH when no tests are passed") { |p| options[:allowlist] = p }
  opts.on("--golden", "Benchmark examples/minivm/vm-tests instead of transpile-tests") { options[:golden] = true }
  opts.on("--vm-bench", "Benchmark benchmarks/vm cases instead of transpile-tests") do
    options[:suite] = :vm_bench
    options[:allowlist] = BENCHMARK_ALLOWLIST
    options[:compare_languages] = true
  end
  opts.on("--all-vm-bench", "Benchmark all benchmarks/vm CLEAR cases, including register-pending cases") do
    options[:suite] = :vm_bench
    options[:all_vm_bench] = true
    options[:compare_languages] = true
  end
  opts.on("--all-benchmarks", "Survey every benchmark .cht under benchmarks/ with the VM targets") do
    options[:suite] = :all_benchmarks
    options[:all_benchmarks] = true
    options[:allowlist] = nil
    options[:compare_languages] = false
    options[:summarize_register_blockers] = true
  end
  opts.on("--compare-languages", "Run sibling Ruby/Python/Lua benchmark files when available") { options[:compare_languages] = true }
  opts.on("--no-compare-languages", "Skip sibling Ruby/Python/Lua benchmark files") { options[:compare_languages] = false }
  opts.on("--single-core", "Pin comparison to one core where possible (default)") { options[:single_core] = true }
  opts.on("--no-single-core", "Do not pin comparison to one core") { options[:single_core] = false }
  opts.on("--timeout=N", Integer, "Per-run timeout in seconds") { |n| options[:timeout_seconds] = n }
  opts.on("--profile-register-bytecode", "Print static register opcode frequency for compiled inputs") do
    options[:profile_register_bytecode] = true
  end
  opts.on("--run", "Include VM execution timing") { options[:run] = true }
  opts.on("--compile-only", "Skip VM execution timing (default for now)") { options[:run] = false }
  opts.on("--optimized", "Run optimized VM runners when executing benchmarks") { options[:optimized] = true }
  opts.on("--no-optimized", "Run debug VM runners when executing benchmarks") { options[:optimized] = false }
  # `--smoke`: short, noisy run for fast iteration. Mirrors
  # `benchmarks/runner.rb --smoke`. Implies:
  #   - register VM only (the stack VM is the deprecated path and
  #     burns a substantial fraction of the wall time per case)
  #   - --vm-bench corpus
  #   - shorter per-run timeout
  #   - first 6 cases only (override with --smoke-cases=N)
  opts.on("--smoke", "Smoke benchmark (register VM, 6 cases, short timeout)") do
    options[:smoke] = true
    options[:run] = true
    options[:suite] = :vm_bench
    options[:allowlist] = BENCHMARK_ALLOWLIST
    options[:compare_languages] = true
    options[:skip_stack_vm] = true
    options[:timeout_seconds] = [options[:timeout_seconds], 10].min
    options[:smoke_cases] ||= 6
  end
  opts.on("--smoke-cases=N", Integer, "Number of cases for --smoke (default 6)") { |n| options[:smoke_cases] = n }
  opts.on("--skip-stack-vm", "Skip the deprecated stack VM run path") { options[:skip_stack_vm] = true }
  opts.on("--summarize-register-blockers", "Group register VM pending/error cases by first failure line") do
    options[:summarize_register_blockers] = true
  end
  opts.on("--write-register-compile-ok=PATH", "Write register compile-OK benchmark case names to PATH") do |path|
    options[:write_register_compile_ok] = path
  end
  opts.on("--write-register-run-ok=PATH", "Write register run-OK benchmark case names to PATH") do |path|
    options[:write_register_run_ok] = path
  end
end
parser.parse!(ARGV)

if options[:run] && %i[vm_bench all_benchmarks].include?(options[:suite]) && !options[:optimized]
  abort "Benchmark execution requires the optimized register VM runner. Remove --no-optimized."
end

def read_allowlist(path)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).filter_map do |line|
    line = line.sub(/#.*/, "").strip
    next if line.empty?

    line
  end
end

def resolve_transpile_test(name)
  return name if File.exist?(name)

  root_cht = File.expand_path(File.join(MiniVM::Golden::ROOT, "#{name}.cht"))
  return root_cht if File.exist?(root_cht)

  root_relative = File.expand_path(File.join(MiniVM::Golden::ROOT, name))
  return root_relative if File.exist?(root_relative)

  candidate = File.join(TEST_DIR, "#{name}.cht")
  return candidate if File.exist?(candidate)

  candidate = File.join(TEST_DIR, name)
  return candidate if File.exist?(candidate)

  name
end

def time_once
  elapsed = nil
  result = nil
  elapsed = Benchmark.realtime { result = yield }
  [elapsed, result]
end

def silence_compiler_noise
  return yield if ENV["MINIVM_BENCH_VERBOSE"] == "1"

  original_stdout = $stdout.dup
  original_stderr = $stderr.dup
  File.open(File::NULL, "w") do |null|
    $stdout.reopen(null)
    $stderr.reopen(null)
    yield
  ensure
    $stdout.reopen(original_stdout)
    $stderr.reopen(original_stderr)
    original_stdout.close
    original_stderr.close
  end
end

def bench_ms(raw)
  MiniVM::Golden.bench_ms(raw)
end

def sibling_benchmark(path, ext)
  sibling = path.sub(/\.cht\z/, ext)
  File.exist?(sibling) ? sibling : nil
end

def benchmark_sources(root = File.join(MiniVM::Golden::ROOT, "benchmarks"))
  Dir.glob(File.join(root, "**", "*.cht")).sort.reject do |path|
    parts = path.split(File::SEPARATOR)
    File.basename(path).start_with?("minivm-golden-") ||
      parts.any? { |part| part.start_with?(".") } ||
      path.include?("#{File::SEPARATOR}bench.profile#{File::SEPARATOR}")
  end
end

def command_available?(cmd)
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
    File.executable?(File.join(dir, cmd))
  end
end

LANGUAGE_COMMANDS = {
  ruby: ["ruby"],
  python: ["python3"],
  lua: ["lua"],
}.freeze

def single_core_command(cmd)
  command_available?("taskset") ? ["taskset", "-c", "0", *cmd] : cmd
end

def run_language_benchmark(lang, path, timeout_seconds:, single_core:)
  cmd = LANGUAGE_COMMANDS.fetch(lang)
  cmd = single_core_command(cmd) if single_core
  raw = nil
  status = nil
  Timeout.timeout(timeout_seconds) do
    raw, status = Open3.capture2e(*cmd, path)
  end
  [status.success?, raw, bench_ms(raw)]
rescue Timeout::Error
  [false, "", nil]
end

def profile_register_bytecode!(stats, bytecode)
  program = MiniVM::Register::Program.decode(bytecode.ops)
  stats[:register_packing_profile].merge!(MiniVM::Register::OpcodeSpec.profile_packing(program))
  program.instructions.each do |insn|
    stats[:register_opcode_counts][insn.opcode] += 1
    stats[:register_instruction_count] += 1
    stats[:register_operand_count] += insn.args.length
  end
end

def warm_optimized_register_runner!
  warm_source = File.join(MiniVM::Golden::ROOT, "examples", "minivm", "vm-tests", "basics", "return_i64.cht")
  return unless File.exist?(warm_source)

  env = { "BC_OPT" => "1" }
  raw, status = Open3.capture2e(
    env,
    "timeout", "--kill-after=2", "300",
    "ruby", MiniVM::Golden::BC_RUN, warm_source, "--run", "--vm=register"
  )
  return if status.success?

  warn "WARNING: optimized register VM warmup failed: #{raw.lines.last&.strip || "exit #{status.exitstatus}"}"
end

def first_status_line(message)
  line = message.to_s.lines.first.to_s.strip
  line.empty? ? nil : line
end

def register_blocker_reason(row, phase)
  case phase
  when :compile
    first_status_line(row[:register_compile_message]) || "register compile #{row[:register_compile_status]}"
  when :run
    first_status_line(row[:register_run_message]) || "register run #{row[:register_status]}"
  else
    raise ArgumentError, "unknown blocker phase #{phase.inspect}"
  end
end

def print_register_blocker_group(title, rows, phase)
  groups = Hash.new { |h, k| h[k] = [] }
  rows.each do |row|
    groups[register_blocker_reason(row, phase)] << row[:name]
  end

  puts "#{title}:"
  if groups.empty?
    puts "  none"
    return
  end

  groups
    .sort_by { |reason, names| [-names.length, reason] }
    .each do |reason, names|
      puts format("  %3d  %s", names.length, reason)
      names.first(8).each { |name| puts "       - #{name}" }
      puts format("       ... %d more", names.length - 8) if names.length > 8
    end
end

def print_register_blocker_summary(case_rows, include_run:)
  compile_blockers = case_rows.reject { |row| row[:register_compile_status] == :ok }
  puts
  puts "register blockers:"
  print_register_blocker_group("  compile", compile_blockers, :compile)

  return unless include_run

  run_blockers = case_rows.select do |row|
    row[:register_compile_status] == :ok &&
      row[:register_status] &&
      row[:register_status] != :pass
  end
  print_register_blocker_group("  run", run_blockers, :run)
end

paths = if options[:golden]
          MiniVM::Golden::Case.all.map(&:path)
        elsif options[:suite] == :all_benchmarks && ARGV.empty?
          benchmark_sources
        elsif options[:suite] == :vm_bench && options[:all_vm_bench] && ARGV.empty?
          Dir.glob(File.join(MiniVM::Golden::ROOT, "benchmarks", "vm", "*.cht")).sort
        elsif options[:suite] == :vm_bench && ARGV.empty?
          read_allowlist(options[:allowlist]).map { |name| resolve_transpile_test(name) }
        elsif ARGV.empty?
          read_allowlist(options[:allowlist]).map { |name| resolve_transpile_test(name) }
        else
          ARGV.map { |name| resolve_transpile_test(name) }
        end

if paths.empty?
  warn "No benchmark inputs. Add tests to #{options[:allowlist]} or pass paths on the command line."
  exit 1
end

cases = paths.map do |path|
  unless File.exist?(path)
    warn "Skipping missing benchmark input: #{path}"
    next
  end
  MiniVM::Golden::Case.new(path: File.expand_path(path))
end.compact

cases = cases.first(options[:smoke_cases]) if options[:smoke_cases]
name_root = if options[:suite] == :vm_bench
              File.join(MiniVM::Golden::ROOT, "benchmarks", "vm")
            elsif options[:suite] == :all_benchmarks
              File.join(MiniVM::Golden::ROOT, "benchmarks")
            else
              File.join(MiniVM::Golden::ROOT, "transpile-tests")
            end

ENV["CLEAR_THREADS"] ||= "1" if options[:single_core]
warm_optimized_register_runner! if options[:run] && options[:optimized]

stats = {
  stack_compile_seconds: 0.0,
  register_compile_seconds: 0.0,
  stack_run_seconds: 0.0,
  register_run_seconds: 0.0,
  stack_compile_ok: 0,
  register_compile_ok: 0,
  stack_run_ok: 0,
  register_run_ok: 0,
  register_compile_pending: 0,
  register_run_pending: 0,
  stack_ops: 0,
  register_ops: 0,
  stack_raw_bytes: 0,
  register_raw_bytes: 0,
  stack_compile_error: 0,
  stack_run_error: 0,
  register_compile_error: 0,
  register_run_error: 0,
  stack_bench_ms: 0,
  register_bench_ms: 0,
  stack_bench_count: 0,
  register_bench_count: 0,
  register_instruction_count: 0,
  register_operand_count: 0,
  register_opcode_counts: Hash.new(0),
  register_packing_profile: MiniVM::Register::OpcodeSpec::PackingProfile.new,
  languages: Hash.new do |h, k|
    h[k] = {
      ok: 0,
      missing: 0,
      error: 0,
      seconds: 0.0,
      bench_ms: 0,
      bench_count: 0,
    }
  end,
}

case_rows = []

options[:iterations].times do
  cases.each do |test_case|
    source = test_case.source
    source_dir = test_case.source_dir
    row = {
      name: test_case.relative_path(name_root),
      stack_compile_status: nil,
      stack_compile_message: nil,
      register_compile_status: nil,
      register_compile_message: nil,
      stack_status: nil,
      register_status: nil,
      register_run_message: nil,
      stack_bench_ms: nil,
      register_bench_ms: nil,
      languages: {},
    }

    begin
      stack_bc = nil
      elapsed, stack_bc = time_once do
        silence_compiler_noise do
          MiniVM::Golden.stack.compile(source, source_dir: source_dir)
        end
      end
      stats[:stack_compile_seconds] += elapsed
      stats[:stack_compile_ok] += 1
      stats[:stack_ops] += stack_bc.ops.length
      stats[:stack_raw_bytes] += stack_bc.raw_snapshot.bytesize
      row[:stack_compile_status] = :ok
    rescue => e
      row[:stack_compile_status] = :error
      row[:stack_compile_message] = e.message
      stats[:stack_compile_error] += 1
    end

    begin
      register_bc = nil
      elapsed, register_bc = time_once do
        silence_compiler_noise do
          MiniVM::Golden.register.compile(source, source_dir: source_dir)
        end
      end
      stats[:register_compile_seconds] += elapsed
      stats[:register_compile_ok] += 1
      stats[:register_ops] += register_bc.ops.length
      stats[:register_raw_bytes] += register_bc.raw_snapshot.bytesize
      profile_register_bytecode!(stats, register_bc) if options[:profile_register_bytecode]
      row[:register_compile_status] = :ok
    rescue MiniVM::Golden::PendingTarget => e
      row[:register_compile_status] = :pending
      row[:register_compile_message] = e.message
      stats[:register_compile_pending] += 1
    rescue => e
      row[:register_compile_status] = :error
      row[:register_compile_message] = e.message
      stats[:register_compile_error] += 1
    end

    if options[:run] && !options[:skip_stack_vm]
      begin
        elapsed, stack_result = time_once do
          MiniVM::Golden.stack.run(source, source_dir: source_dir, optimized: options[:optimized], timeout_seconds: options[:timeout_seconds])
        end
        stats[:stack_run_seconds] += elapsed
        row[:stack_status] = stack_result.status
        row[:stack_bench_ms] = stack_result.bench_ms
        if stack_result.status == :pass
          stats[:stack_run_ok] += 1
          if stack_result.bench_ms
            stats[:stack_bench_ms] += stack_result.bench_ms
            stats[:stack_bench_count] += 1
          end
        else
          stats[:stack_run_error] += 1
        end
      rescue
        row[:stack_status] = :error
        stats[:stack_run_error] += 1
      end
    end

    if options[:run]

      begin
        elapsed, register_result = time_once do
          MiniVM::Golden.register.run(source, source_dir: source_dir, optimized: options[:optimized], timeout_seconds: options[:timeout_seconds])
        end
        stats[:register_run_seconds] += elapsed
        row[:register_status] = register_result.status
        row[:register_bench_ms] = register_result.bench_ms
        row[:register_run_message] = register_result.raw_output unless register_result.status == :pass
        if register_result.status == :pass
          stats[:register_run_ok] += 1
          if register_result.bench_ms
            stats[:register_bench_ms] += register_result.bench_ms
            stats[:register_bench_count] += 1
          end
        else
          stats[:register_run_error] += 1
        end
      rescue MiniVM::Golden::PendingTarget
        row[:register_status] = :pending
        row[:register_run_message] = $!.message
        stats[:register_run_pending] += 1
      rescue => e
        row[:register_status] = :error
        row[:register_run_message] = e.message
        stats[:register_run_error] += 1
      end

      if options[:compare_languages] && options[:suite] == :vm_bench
        {
          ruby: ".rb",
          python: ".py",
          lua: ".lua",
        }.each do |lang, ext|
          lang_stats = stats[:languages][lang]
          sibling = sibling_benchmark(test_case.path, ext)
          unless sibling && command_available?(LANGUAGE_COMMANDS.fetch(lang).first)
            lang_stats[:missing] += 1
            row[:languages][lang] = { status: :missing, bench_ms: nil }
            next
          end

          elapsed, result = time_once do
            run_language_benchmark(
              lang,
              sibling,
              timeout_seconds: options[:timeout_seconds],
              single_core: options[:single_core]
            )
          end
          ok, _raw, parsed_ms = result
          lang_stats[:seconds] += elapsed
          if ok
            lang_stats[:ok] += 1
            row[:languages][lang] = { status: :pass, bench_ms: parsed_ms }
            if parsed_ms
              lang_stats[:bench_ms] += parsed_ms
              lang_stats[:bench_count] += 1
            end
          else
            row[:languages][lang] = { status: :error, bench_ms: nil }
            lang_stats[:error] += 1
          end
        end
      end
    end
    case_rows << row
  end
end

attempts = cases.length * options[:iterations]
puts "MiniVM VM Benchmark"
puts "=" * 60
puts "inputs=#{cases.length}"
puts "iterations=#{options[:iterations]}"
puts "attempts=#{attempts}"
puts "optimized=#{options[:optimized] ? 1 : 0}"
puts "single_core=#{options[:single_core] ? 1 : 0}"
puts "clear_threads=#{ENV["CLEAR_THREADS"] || "(default)"}"
puts "timeout_seconds=#{options[:timeout_seconds]}"
puts
puts "compile:"
puts format("  stack_ok=%d", stats[:stack_compile_ok])
puts format("  stack_error=%d", stats[:stack_compile_error])
puts format("  register_ok=%d", stats[:register_compile_ok])
puts format("  register_pending=%d", stats[:register_compile_pending])
puts format("  register_error=%d", stats[:register_compile_error])
puts format("  stack_seconds=%.6f", stats[:stack_compile_seconds])
puts format("  register_seconds=%.6f", stats[:register_compile_seconds])
if stats[:stack_compile_seconds].positive? && stats[:register_compile_seconds].positive?
  puts format("  register_vs_stack_compile_ratio=%.3f", stats[:register_compile_seconds] / stats[:stack_compile_seconds])
end
puts
puts "cases:"
if options[:run]
  header = ["case", "stack_compile", "register_compile", "stack_ms", "register_ms"]
  header.concat(%w[ruby_ms python_ms lua_ms]) if options[:compare_languages] && options[:suite] == :vm_bench
  puts "  " + header.join("\t")
  case_rows.each do |row|
    values = [
      row[:name],
      row[:stack_compile_status] || "-",
      row[:register_compile_status] || "-",
      row[:stack_bench_ms] || row[:stack_status] || "-",
      row[:register_bench_ms] || row[:register_status] || "-",
    ]
    if options[:compare_languages] && options[:suite] == :vm_bench
      %i[ruby python lua].each do |lang|
        lang_row = row[:languages][lang] || { status: :missing, bench_ms: nil }
        values << (lang_row[:bench_ms] || lang_row[:status] || "-")
      end
    end
    puts "  " + values.join("\t")
  end
else
  header = ["case", "stack_compile", "register_compile", "register_reason"]
  puts "  " + header.join("\t")
  case_rows.each do |row|
    reason = row[:register_compile_message].to_s.lines.first.to_s.strip
    reason = reason[0, 160] if reason.length > 160
    values = [
      row[:name],
      row[:stack_compile_status] || "-",
      row[:register_compile_status] || "-",
      reason.empty? ? "-" : reason,
    ]
    puts "  " + values.join("\t")
  end
end

if options[:run]
  puts
  puts "run:"
  puts format("  stack_ok=%d", stats[:stack_run_ok])
  puts format("  stack_error=%d", stats[:stack_run_error])
  puts format("  register_ok=%d", stats[:register_run_ok])
  puts format("  register_pending=%d", stats[:register_run_pending])
  puts format("  register_error=%d", stats[:register_run_error])
  puts format("  stack_harness_seconds=%.6f", stats[:stack_run_seconds])
  puts format("  register_harness_seconds=%.6f", stats[:register_run_seconds])
  if stats[:stack_run_ok].positive? &&
     stats[:register_run_ok].positive? &&
     stats[:stack_run_error].zero? &&
     stats[:register_run_pending].zero? &&
     stats[:register_run_error].zero?
    puts format("  register_vs_stack_harness_ratio=%.3f", stats[:register_run_seconds] / stats[:stack_run_seconds])
  else
    puts "  register_vs_stack_harness_ratio=unavailable"
  end
  if stats[:stack_bench_count].positive? &&
     stats[:register_bench_count] == stats[:stack_bench_count]
    puts format("  stack_bench_ms=%.3f", stats[:stack_bench_ms])
    puts format("  register_bench_ms=%.3f", stats[:register_bench_ms])
    if stats[:stack_bench_ms].positive?
      puts format("  register_vs_stack_bench_ratio=%.3f", stats[:register_bench_ms].to_f / stats[:stack_bench_ms])
    end
  else
    puts "  bench_result_ms=unavailable"
  end
  if options[:compare_languages] && options[:suite] == :vm_bench
    puts
    puts "languages:"
    stats[:languages].keys.sort.each do |lang|
      lang_stats = stats[:languages][lang]
      puts format("  %s_ok=%d", lang, lang_stats[:ok])
      puts format("  %s_missing=%d", lang, lang_stats[:missing])
      puts format("  %s_error=%d", lang, lang_stats[:error])
      puts format("  %s_seconds=%.6f", lang, lang_stats[:seconds])
      if lang_stats[:bench_count].positive?
        puts format("  %s_bench_ms=%.3f", lang, lang_stats[:bench_ms])
        if stats[:register_bench_ms].positive? &&
           stats[:register_bench_count] == lang_stats[:bench_count]
          puts format("  register_vs_%s_bench_ratio=%.3f", lang, stats[:register_bench_ms].to_f / lang_stats[:bench_ms])
        end
      else
        puts format("  %s_bench_ms=unavailable", lang)
      end
    end
  end
else
  puts "run: skipped (--compile-only)"
end

print_register_blocker_summary(case_rows, include_run: options[:run]) if options[:summarize_register_blockers]

if options[:write_register_compile_ok]
  names = case_rows
    .select { |row| row[:register_compile_status] == :ok }
    .map { |row| row[:name] }
    .sort
  File.write(options[:write_register_compile_ok], names.join("\n") + (names.empty? ? "" : "\n"))
  puts "wrote_register_compile_ok=#{options[:write_register_compile_ok]} count=#{names.length}"
end

if options[:write_register_run_ok]
  names = case_rows
    .select { |row| row[:register_status] == :pass }
    .map { |row| row[:name] }
    .sort
  File.write(options[:write_register_run_ok], names.join("\n") + (names.empty? ? "" : "\n"))
  puts "wrote_register_run_ok=#{options[:write_register_run_ok]} count=#{names.length}"
end

puts
puts "bytecode:"
puts format("  stack_ops=%d", stats[:stack_ops])
puts format("  register_ops=%d", stats[:register_ops])
puts format("  stack_raw_bytes=%d", stats[:stack_raw_bytes])
puts format("  register_raw_bytes=%d", stats[:register_raw_bytes])
if options[:profile_register_bytecode]
  puts
  puts "register bytecode profile:"
  puts format("  instructions=%d", stats[:register_instruction_count])
  puts format("  operands=%d", stats[:register_operand_count])
  if stats[:register_instruction_count].positive?
    avg = stats[:register_operand_count].to_f / stats[:register_instruction_count]
    puts format("  operands_per_instruction=%.3f", avg)
  end
  stats[:register_opcode_counts]
    .sort_by { |_opcode, count| [-count, _opcode] }
    .each do |opcode, count|
      spec = MiniVM::Register::OpcodeSpec::BY_CODE[opcode]
      name = spec ? spec.name : :"ROP_#{opcode}"
      pct = stats[:register_instruction_count].positive? ? (count * 100.0 / stats[:register_instruction_count]) : 0.0
      puts format("  %-10s %5d  %5.1f%%", name, count, pct)
    end
  packing = stats[:register_packing_profile]
  puts
  puts "register packing profile:"
  puts format("  packable=%s", packing.packable? ? "yes" : "no")
  puts format("  raw_i64_bytes=%d", packing.raw_i64_bytes)
  puts format("  estimated_packed_bytes=%d", packing.packed_bytes)
  if packing.raw_i64_bytes.positive?
    puts format("  estimated_packed_ratio=%.3f", packing.packed_bytes.to_f / packing.raw_i64_bytes)
  end
  puts "  max:"
  packing.max_by_kind.keys.sort.each do |kind|
    puts format("    %-10s %d", kind, packing.max_by_kind[kind])
  end
  puts "  counts:"
  packing.count_by_kind.keys.sort.each do |kind|
    puts format("    %-10s %d", kind, packing.count_by_kind[kind])
  end
  unless packing.packable?
    puts "  failures:"
    packing.failures.first(20).each { |failure| puts "    #{failure}" }
    puts format("    ... %d more", packing.failures.length - 20) if packing.failures.length > 20
  end
end
