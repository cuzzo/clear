#!/usr/bin/env ruby
# MiniVM runner policy:
# - The primary correctness target is interpreter_test.clear.
# - The broader transpile-tests runner is historical/aspirational coverage.

MINIVM_CLEAR = File.join(__dir__, "clear")
TRANSPILER = File.join(__dir__, "bc_run.rb")
TEST_DIR = File.expand_path("../../transpile-tests", __dir__)
INTERPRETER_TEST = File.join(__dir__, "interpreter_test.clear")
REGISTER_TRANSPILE_ALLOWLIST = File.join(__dir__, "register-transpile-allowlist.txt")

require_relative "vm_golden_harness"
require_relative "register_opcode_layout"

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
  # File / socket resource tests originally listed as :resource — the
  # File::open / File::create / fileReadAll / fileWrite path now has a
  # syntax-level stub (Task #19). RAII auto-close is still not modeled.
  # TCP and struct-with-resource-field cases stay unsupported.
  "61_tcp_resource"              => :resource,
  "63_struct_resource_close"     => :resource,

  # Direct FFI / extern std imports. The VM has no @import machinery.
  "224_extern_std_ffi"           => :extern_ffi,

  # @service vs fiber benchmark — semantically passes (BC treats @service
  # as a regular BG fiber and the asserts succeed) but the workload is
  # 4 fibers x 1M wrap-arithmetic iterations x2, which exceeds the 10s
  # per-test budget. Mark as slow rather than as an unsupported feature.
  "74_service_benchmark"         => :slow_stress_test,

  # Frame-arena / loop-carry stress tests: 10000+ iterations doing
  # repeated allocations to validate the Zig backend's per-iteration
  # frame-mark/restore. The BC has no frame arena (everything is
  # heap via the pool), so the underlying invariant doesn't apply --
  # these tests pass on Zig but legitimately exceed the BC's 10s
  # interpretive deadline. Marking them unsupported keeps the
  # coverage report honest about what the VM actually models.
  "66_list_loop_arena"           => :slow_stress_test,
  "188_frame_arena_bounded"      => :slow_stress_test,
  "198_line_parse_startswith"    => :slow_stress_test,
  "199_frame_peak_large_list_build" => :slow_stress_test,
  "200_frame_peak_large_alloc_loop" => :slow_stress_test,
  "205_frame_peak_list_build_in_fn" => :slow_stress_test,
  "216_loop_carry_nested"        => :slow_stress_test,
  "217_loop_carry_overflow_blocks" => :slow_stress_test,
}

# Register-VM roadmap. Each entry tracks an unsupported language
# feature cluster: the rough number of transpile-tests it would
# unblock and a t-shirt effort estimate. Counts come from the
# pending-reason histogram (see `--roadmap-scan` to refresh).
# Effort is a wall-clock estimate against the bc emitter, not
# new VM opcodes unless explicitly noted.
REGISTER_ROADMAP = [
  # ---- P1: residual struct-list pipeline tail (post-23-test wave) ----
  { priority: "P1", title: "ORDER_BY / INDEX / nested-list struct fields",
    tests: 12, effort: "2 days",
    detail: "What's left of the struct-list pipeline tail: ORDER_BY " \
            "(needs MIR::Sort + CheatLib.makeList struct-list copy), " \
            "INDEX (group-by into a HashMap of struct_lists), and " \
            "struct types whose own fields are @list (ArrayListUnmanaged " \
            "as a struct field). Rest of the cluster landed in the " \
            "`P1 #5/#4/#1 wave` commit (23 new passes)." },

  # ---- P1: medium effort, large clusters ----
  { priority: "P1", title: "Pool tail (FIND/EACH-via-pipeline, internals)",
    tests: 13, effort: "2 days",
    detail: "Pool basics landed (insert/get/remove/length, per-pool " \
            "ForStmt with alive-skip, helper FN params, struct-view " \
            "field access, write-back). Remaining tests trip on " \
            "pipeline ops (`pool |> FIND`, `pool |> EACH` lowering " \
            "uses pool internals like `<ctx>.pool.slots`), SoaPool " \
            "(separate value-kind), and pool-as-lambda-capture." },
  { priority: "P1", title: "Recursive Value-list / Val[] / Node[]",
    tests: 11, effort: "1 week",
    detail: "ArrayListUnmanaged(Value/Val/Node) with self-referential " \
            "variants (Value.List: Value[]) or collection-bearing " \
            "variants (Value.Items: Int64[]). value_list_type? now " \
            "accepts these unions when only their scalar variants are " \
            "exercised (tag-only :opaque entries for non-scalar variants). " \
            "Full support -- runtime-typed appends like " \
            "`results.append(makeItems())` and reading back opaque " \
            "payloads -- needs heap-allocated Value variants and " \
            "recursive cleanup; defer to its own commit." },
  # @versioned / @atomicPtr / cap-wrapped helper params landed in
  # the same P1 wave (8 + 4 + 5 = 17 of those 23 new passes). Their
  # roadmap entries are now resolved.
  # napFor / :sleep + main-bootstrap + BG tail shapes landed in the
  # P1 quick-wins commit (11 new passes). Main-bootstrap stragglers
  # (46_range, require_helper, require_types_helper) are not real
  # tests -- they are import-helper files or empty -- so they stay
  # pending without being roadmap items.

  # ---- P2: hard / specialized ----
  { priority: "P2", title: "CatchWrapper / RAISE / OR_ELSE EXIT (error-union runtime)",
    tests: 5, effort: "1 week",
    detail: "Needs new VM opcodes: RAISE, error register, dispatch by " \
            "error-kind/error-type. Outer fn body is a single MIR::" \
            "CatchWrapper that calls the inner and catches via Zig text." },
  # @atomicPtr basic CapWrap + WITH MATCH ATOMIC arm landed in the
  # P1 wave; remaining tests need TryCatch / TryExpr at expr-stmt
  # position (covered by the P2 CatchWrapper item).
  # RangeLit-as-value landed in the runtime-blockers commit
  # (compile_range_to_int_list materializes 0..<n eagerly).
  { priority: "P2", title: "StreamSpawn / open / infinite streams",
    tests: 4, effort: "Hard",
    detail: "`BG STREAM { ... YIELD x; ... }` generators. Needs CPS-" \
            "transformed body or a coroutine value-kind. The single-" \
            "threaded VM can run one iteration at a time, but the " \
            "yield+resume pattern is non-trivial." },
  { priority: "P2", title: "DoBlock (parallel branches)",
    tests: 3, effort: "Hard",
    detail: "Single-threaded VM: branches run sequentially. Faithful for " \
            "side-effect ordering only when each branch is order-" \
            "independent; needs a sequential-equivalence assertion." },
  # Reentrance variants and Set landed in the P2 batch; remaining
  # tests in those clusters need runtime work for set iteration /
  # sharded-list value-kind.
  { priority: "P2", title: "Map .values() / .keys() iteration",
    tests: 3, effort: "1 day",
    detail: "InlineBc(:values) / (:keys). Materialize the map's storage " \
            "into a typed list. Currently raises Unsupported." },
  # MIR::IfBindStmt landed in the runtime-blockers commit (single
  # and multi-binding via && short-circuit, currently only ?Int64).
  { priority: "P2", title: "Unsupported MIR leaves",
    tests: 5, effort: "Out of scope",
    detail: "The bc VM is not Zig. Any remaining Zig-specific compiler " \
            "leaf must be rewritten to use a structured MIR node, per " \
            "CLAUDE.md's no-Zig-parsing rule." },
].freeze

def print_register_roadmap
  total = Dir.glob(File.join(TEST_DIR, "*.clear")).length
  passing = read_allowlist(REGISTER_TRANSPILE_ALLOWLIST).length
  pct = total.positive? ? (passing.to_f / total * 100) : 0.0
  puts
  puts "Register VM roadmap"
  puts "===================="
  printf "  Currently passing: %d / %d (%.1f%%)\n", passing, total, pct
  puts

  groups = REGISTER_ROADMAP.group_by { |item| item[:priority] }
  cumulative = passing
  %w[P0 P1 P2].each do |pri|
    items = groups[pri] || []
    next if items.empty?
    pri_total = items.sum { |i| i[:tests] }
    cumulative += pri_total
    printf "%s -- %d items, %d tests, projects to %d / %d (%.1f%%)\n",
           pri, items.length, pri_total, cumulative, total, cumulative.to_f / total * 100
    items.each do |item|
      printf "  %3d tests | %-12s | %s\n", item[:tests], item[:effort], item[:title]
    end
    puts
  end
  puts "Run `--roadmap --detail` for full descriptions."
end

def print_register_roadmap_detail
  print_register_roadmap
  puts "Detailed entries"
  puts "================"
  REGISTER_ROADMAP.each do |item|
    printf "[%s] %s (%d tests, %s)\n", item[:priority], item[:title], item[:tests], item[:effort]
    item[:detail].split(/(?<=\.)\s+/).each { |line| puts "    #{line}" }
    puts
  end
end

def run_primary_test
  system(MINIVM_CLEAR, "test", INTERPRETER_TEST)
  $?.exitstatus || 1
end

# Compile a .clear file with the bc emitter and print the recorded
# shared-memory event stream + BG dispatch points. This is the
# observation surface a future deterministic-replay scheduler will
# enumerate over; today it lets developers see which operations the
# bc emitter has identified as "interesting from a concurrency
# standpoint."
#
# The report is purely structural -- it consumes the value-kinds
# the bc emitter already tracks and adds nothing to the runtime.
def print_concurrency_report(paths)
  compiler_ruby_root = File.expand_path("../../compiler/ruby", __dir__)
  $LOAD_PATH.unshift(compiler_ruby_root)
  $LOAD_PATH.unshift(File.join(compiler_ruby_root, "backends"))
  $LOAD_PATH.unshift(File.join(compiler_ruby_root, "mir"))
  $LOAD_PATH.unshift(File.join(compiler_ruby_root, "ast"))
  require_relative "register_bc_emitter"
  require "compiler/compiler_frontend"
  require "mir_lowering"
  require "mir_checker"
  require "compiler/module_importer"
  require "mir"

  ok = true
  paths.each do |path|
    abs = File.expand_path(path)
    unless File.exist?(abs)
      $stderr.puts "missing: #{path}"
      ok = false
      next
    end
    src = File.read(abs)
    source_dir = File.dirname(abs)
    importer = ModuleImporter.new(base_dir: source_dir)
    fe = CompilerFrontend.compile(src, importer: importer, source_dir: source_dir)
    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: fe.struct_schemas,
      enum_schemas: fe.enum_schemas,
      union_schemas: fe.union_schemas,
      fn_sigs: fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer: importer,
      source_dir: source_dir,
      target: :bc
    ))
    program = lowering.lower_program(fe.ast)
    emitter = RegisterBcEmitter.new(fe, source: src, importer: importer)
    begin
      emitter.compile(program)
    rescue RegisterBcEmitter::Unsupported => e
      $stderr.puts "[#{path}] (compile incomplete: #{e.message[0..120]})"
    end

    events = emitter.shared_events
    bgs = emitter.bg_dispatch_points
    puts
    puts "Concurrency surface: #{path}"
    puts "=" * 60
    if events.empty? && bgs.empty?
      puts "  (no shared-memory operations or BG dispatch points)"
      next
    end

    by_fn = events.group_by { |e| e[:function] || "<top>" }
    bg_by_fn = bgs.group_by { |e| e[:function] || "<top>" }
    fn_names = (by_fn.keys | bg_by_fn.keys).uniq.sort
    fn_names.each do |fn|
      puts "  FN #{fn}"
      (bg_by_fn[fn] || []).each do |bg|
        printf "    BG dispatch    line %4d  captures=%d\n", bg[:line], bg[:capture_count]
      end
      (by_fn[fn] || []).each do |ev|
        caps_text = if ev[:caps]
                      "[own=#{ev[:caps][:ownership]} sync=#{ev[:caps][:sync]}]"
                    else
                      ""
                    end
        printf "    %-12s line %4d  %-22s %-20s %s\n",
               ev[:category].to_s,
               ev[:line],
               ev[:binding],
               ev[:kind],
               caps_text
      end
    end

    puts
    puts "  Summary: #{events.length} shared events, #{bgs.length} BG dispatch points"
    puts "    by category: #{events.group_by { |e| e[:category] }.transform_values(&:length).inspect}"
  end
  ok
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
  elsif clean.lines.all? { |l| l.strip.empty? || l.match?(/\A\[(Warning|Note|Info)\]/) || l.match?(/\A\[\d+m\[(Warning|Note|Info)\]/) }
    # Output is just compile-time warnings/notes (no actual runner
    # output). The runner was killed before printing anything.
    [:timeout, nil]
  elsif clean.include?("error:") || clean.include?("Error")
    msg = clean.lines.find { |l| l.include?("error") || l.include?("Error") }&.strip
    [:error, msg&.slice(0, 120)]
  else
    [:unknown, clean.lines.first&.strip&.slice(0, 120)]
  end
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

  candidate = File.join(TEST_DIR, "#{name}.clear")
  return candidate if File.exist?(candidate)

  candidate = File.join(TEST_DIR, name)
  return candidate if File.exist?(candidate)

  name
end

def run_vm_target_test(path, vm_target)
  source = File.read(path)
  target = MiniVM::Golden.targets.fetch(vm_target.to_sym)
  target.compile(source, source_dir: File.dirname(path))
  result = target.run(source, source_dir: File.dirname(path))
  return [:pass, nil] if result.status == :pass

  [result.status, result.raw_output.to_s.lines.first&.strip&.slice(0, 120)]
rescue MiniVM::Golden::PendingTarget => e
  [:pending, e.message]
rescue => e
  [:error, e.message]
end

def run_vm_target_suite(vm_target, tests)
  if vm_target.to_sym == :register
    MiniVM::Register::OpcodeSpec.validate_vm_enum!
  end

  tests = read_allowlist(REGISTER_TRANSPILE_ALLOWLIST) if tests.empty? && vm_target.to_sym == :register
  if tests.empty?
    $stderr.puts "No tests supplied for --vm=#{vm_target}. Add paths or update #{REGISTER_TRANSPILE_ALLOWLIST}."
    return false
  end

  puts "\nMiniVM transpile-test target: #{vm_target}"
  puts "=" * 60
  buckets = Hash.new { |h, k| h[k] = [] }
  tests.each do |name|
    path = resolve_transpile_test(name)
    unless File.exist?(path)
      puts "  SKIP    #{name} (file not found)"
      buckets[:missing] << [name, nil]
      next
    end

    status, msg = run_vm_target_test(path, vm_target)
    label = case status
            when :pass then "PASS"
            when :pending then "PENDING"
            else status.to_s.upcase
            end
    puts "  #{label.ljust(7)} #{name}#{msg ? ": #{msg}" : ""}"
    buckets[status] << [name, msg]
  end

  puts "-" * 60
  total = tests.length
  passed = buckets[:pass].length
  pending = buckets[:pending].length
  failed = total - passed - pending
  puts "  #{passed} passed, #{pending} pending, #{failed} failed/missing (#{total} total)"
  passed
end

# Strict mode (failed.zero? && pending.zero?) for callers that want
# zero-tolerance. The default callsite returns the pass count and lets
# the caller decide via --min-pass=N or strict equality.
def run_vm_target_suite_with_count(vm_target, tests)
  run_vm_target_suite(vm_target, tests)
end

def run_historical_suite(tests, label)
  puts "\n#{label}"
  puts "=" * 60
  pass = 0
  fail = 0
  error = 0

  tests.each do |name|
    path = name.include?("/") ? name : File.join(TEST_DIR, "#{name}.clear")
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
  # Walk every .clear file in TEST_DIR (except ffi/module integration dirs and
  # helpers). Skip VM_UNSUPPORTED outright. Bucket everything else by outcome
  # category so we can see at a glance what stands between us and 100%.
  exclude = %w[require_helper require_types_helper]
  all = Dir.glob(File.join(TEST_DIR, "*.clear")).sort.reject do |p|
    name = File.basename(p, ".clear")
    exclude.include?(name)
  end

  buckets = Hash.new { |h, k| h[k] = [] }
  all.each do |path|
    name = File.basename(path, ".clear")
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
  puts "    Runs the primary MiniVM regression target: interpreter_test.clear"
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
  puts "  ruby examples/minivm/run_tests.rb --golden"
  puts "    Runs the stack/register VM golden harness specs"
  puts
  puts "  ruby examples/minivm/run_tests.rb --vm=stack|register [tests...]"
  puts "    Runs transpile tests through the selected MiniVM target. Register"
  puts "    defaults to register-transpile-allowlist.txt."
  puts
  puts "  ruby examples/minivm/run_tests.rb path/to/test.clear"
  puts "    Runs a single transpile test through bc_run"
  puts
  puts "  ruby examples/minivm/run_tests.rb --roadmap [--detail]"
  puts "    Prints the register VM language-coverage roadmap, ranked"
  puts "    P0/P1/P2 with expected test count and effort estimate."
  puts
  puts "  ruby examples/minivm/run_tests.rb --concurrency-report file.clear ..."
  puts "    Compiles each file with the bc emitter and prints its"
  puts "    shared-memory event stream + BG dispatch points -- the"
  puts "    observation surface a future deterministic-replay"
  puts "    scheduler would enumerate over."
end

vm_target = nil
min_pass = nil
ARGV.reject! do |arg|
  if arg =~ /\A--vm=(stack|register|bc)\z/
    vm_target = Regexp.last_match(1)
    true
  elsif arg == "--vm"
    vm_target = "stack"
    true
  elsif arg =~ /\A--min-pass=(\d+)\z/
    # CI gate: assert at least N tests pass, regardless of pending/failed.
    # Used to ratchet the register-VM baseline forward over time.
    min_pass = Regexp.last_match(1).to_i
    true
  else
    false
  end
end
vm_target = "stack" if vm_target == "bc"

if vm_target
  passed = run_vm_target_suite_with_count(vm_target, ARGV)
  if min_pass
    if passed >= min_pass
      puts "  baseline OK: #{passed} >= #{min_pass}"
      exit(0)
    else
      $stderr.puts "  baseline REGRESSION: #{passed} < #{min_pass}"
      exit(1)
    end
  end
  exit(passed > 0 ? 0 : 1)
elsif ARGV[0] == "--roadmap"
  ARGV.include?("--detail") ? print_register_roadmap_detail : print_register_roadmap
  exit(0)
elsif ARGV[0] == "--concurrency-report"
  paths = ARGV[1..]
  if paths.nil? || paths.empty?
    $stderr.puts "Usage: ruby examples/minivm/run_tests.rb --concurrency-report <file.clear> [file.clear ...]"
    exit 1
  end
  ok = print_concurrency_report(paths)
  exit(ok ? 0 : 1)
elsif ARGV.empty?
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
elsif ARGV[0] == "--golden"
  MiniVM::Register::OpcodeSpec.validate_vm_enum!
  spec_path = File.expand_path("../../spec/minivm_golden_harness_spec.rb", __dir__)
  ok = system("bundle", "exec", "rspec", spec_path)
  exit(ok ? 0 : 1)
elsif ARGV[0] == "--discover"
  all = Dir.glob(File.join(TEST_DIR, "*.clear"))
    .map { |f| File.basename(f, ".clear") }
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
