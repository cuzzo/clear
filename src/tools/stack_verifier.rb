# typed: strict
# stack_verifier.rb - Post-build stack frame size verification.
#
# Parses objdump output to extract actual stack frame sizes for CLEAR functions.
# Cross-references with compile-time tier recommendations to detect potential
# stack overflow risks on fiber stacks.
#
# Usage:
#   verifier = StackVerifier.new(binary_path, module_prefix)
#   report = verifier.analyze(fn_nodes: fn_nodes, source_file: "foo.cht")
#   verifier.print_report(report)

require "sorbet-runtime"
require "stringio"
require_relative "../ast/ast"

class StackVerifier
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }

  # Fiber stack tier budgets (total allocation minus 4 KB frame arena).
  TIER_BUDGET = {
    micro:    4096,           # 4 KB (no arena at micro tier)
    standard: 16384 - 4096,  # 12 KB usable
    large:    65536 - 4096,  # 60 KB usable
    xl:       262144 - 4096, # 252 KB usable
    service:  4 * 1024 * 1024,
  }.freeze

  attr_reader :binary_path, :module_prefix

  sig { params(binary_path: String, module_prefix: T.nilable(String)).void }
  def initialize(binary_path, module_prefix = nil)
    @binary_path = binary_path
    @module_prefix = module_prefix || detect_prefix(binary_path)
    @objdump_output = nil
  end

  # Run objdump once and cache the output.
  sig { returns(String) }
  def objdump_output
    @objdump_output ||= `objdump -d #{@binary_path} 2>/dev/null`
  end

  # Parse objdump output and return per-function stack frame sizes.
  #
  # Two prologue shapes:
  #   1. Small frame: `sub $0xN,%rsp` -- single immediate.
  #   2. Huge frame (>~32 KB): `mov $0xN,%REG; sub %REG,%rsp` plus a
  #      stack-probe loop. LLVM/Zig emit this when the single-imm
  #      sub can't be fused with the per-page guard probe. Without
  #      handling this case, huge-frame functions are INVISIBLE to
  #      the verifier and never enter the cost path -- the binary
  #      ships under-tiered. Track the most recent `mov $imm,%REGd`
  #      and consume it on `sub %REG,%rsp`.
  #
  # This is fundamentally brittle (regex on objdump text). The
  # architecturally correct path is a Zig-emitted stackmap or DWARF
  # CFI parse; tracked separately.
  sig { returns(Array) }
  def extract_frame_sizes
    output = objdump_output
    return [] if output.empty?

    results = []
    current_fn = nil
    pending_mov = nil

    output.each_line do |line|
      if line =~ /^[0-9a-f]+\s+<(#{Regexp.escape(@module_prefix)}\..+)>:/
        current_fn = $1
        pending_mov = nil
      elsif line =~ /^[0-9a-f]+\s+</
        current_fn = nil
        pending_mov = nil
      elsif current_fn && line =~ /sub\s+\$0x([0-9a-f]+),%rsp/
        bytes = $1.to_i(16)
        clear_name = zig_to_clear_name(current_fn)
        results << { name: clear_name, zig_name: current_fn, stack_bytes: bytes }
        current_fn = nil
        pending_mov = nil
      elsif current_fn && line =~ /mov\s+\$0x([0-9a-f]+),%(r\d+)d/
        pending_mov = { bytes: $1.to_i(16), reg: $2 }
      elsif current_fn && pending_mov && line =~ /sub\s+%(r\d+),%rsp/ && Regexp.last_match(1) == pending_mov[:reg]
        clear_name = zig_to_clear_name(current_fn)
        results << { name: clear_name, zig_name: current_fn, stack_bytes: pending_mov[:bytes] }
        current_fn = nil
        pending_mov = nil
      end
    end

    results
  end

  # Full analysis: extract frame sizes, compare against tiers.
  sig { params(fn_nodes: T.nilable(Hash), source_file: T.nilable(String)).returns(Hash) }
  def analyze(fn_nodes: nil, source_file: nil)
    frames = extract_frame_sizes
    report = { functions: [], warnings: [], source_file: source_file }

    frames.each do |f|
      entry = { name: f[:name], stack_bytes: f[:stack_bytes] }

      fn = fn_nodes&.[](f[:name])
      if fn
        entry[:tier] = fn.stack_tier
        entry[:estimated_bytes] = fn.stack_vars_bytes
        entry[:line] = fn.respond_to?(:line) ? fn.line : nil
        is_unbounded = fn.stack_tier == :unbounded
        entry[:unbounded] = is_unbounded
        # Phase 4f.3 hook (Phase 4g will land the precise math):
        # if fn.max_depth_n is set, the worst-case stack is
        # f[:stack_bytes] * fn.max_depth_n -- a tighter bound than
        # the tier budget alone. The verifier should compare that
        # to the budget and warn if max_depth_n is suspiciously
        # large for the per-frame cost. Left as TODO until 4g.
        entry[:max_depth_n] = fn.max_depth_n if fn.respond_to?(:max_depth_n) && fn.max_depth_n
        budget = TIER_BUDGET[fn.stack_tier] || 12288
        entry[:budget] = budget
        entry[:usage_pct] = (f[:stack_bytes].to_f / budget * 100).round(1)

        if is_unbounded
          loc = format_location(source_file, entry[:line])
          report[:warnings] << {
            level: :info,
            message: "#{loc}'#{f[:name]}' is unbounded: #{f[:stack_bytes]} bytes/frame * unknown depth. " \
                     "Requires `@service` on BG/DO blocks (`@canSmash` is reserved for v0.3)."
          }
        elsif f[:stack_bytes] > budget
          entry[:overflow] = true
          loc = format_location(source_file, entry[:line])
          report[:warnings] << {
            level: :error,
            message: "#{loc}Stack overflow risk: '#{f[:name]}' uses #{f[:stack_bytes]} bytes " \
                     "but #{fn.stack_tier} tier budget is #{budget} bytes. " \
                     "Add @large to the BG block or use @onSmash to handle overflow."
          }
        elsif f[:stack_bytes] > budget * 0.75
          loc = format_location(source_file, entry[:line])
          report[:warnings] << {
            level: :warn,
            message: "#{loc}'#{f[:name]}' uses #{entry[:usage_pct]}% of #{fn.stack_tier} " \
                     "stack budget (#{f[:stack_bytes]}/#{budget} bytes)."
          }
        end
      else
        entry[:tier] = :unknown
      end

      report[:functions] << entry
    end

    report[:functions].sort_by! { |f| -(f[:stack_bytes] || 0) }
    report
  end

  sig { params(report: Hash, io: StringIO).returns(T.nilable(Array)) }
  def print_report(report, io: $stderr)
    return if report[:functions].empty?

    io.puts ""
    report[:functions].each do |f|
      tier_str = f[:tier] != :unknown ? " [#{f[:tier]}]" : ""
      pct_str = f[:usage_pct] ? " (#{f[:usage_pct]}%)" : ""
      marker = f[:overflow] ? " <<<" : ""
      marker = " (per frame, depth unknown)" if f[:unbounded]
      io.puts "  %6d bytes  %-40s%s%s%s" % [f[:stack_bytes], f[:name], tier_str, pct_str, marker]
    end

    if report[:warnings].any?
      io.puts ""
      report[:warnings].each do |w|
        case w[:level]
        when :error
          io.puts "\e[31m[stack error]\e[0m #{w[:message]}"
        when :warn
          io.puts "\e[33m[stack warning]\e[0m #{w[:message]}"
        when :info
          io.puts "\e[36m[stack info]\e[0m #{w[:message]}"
        end
      end
    end
  end

  # Returns true if any overflow errors were detected.
  sig { params(report: Hash).returns(T.nilable(T::Boolean)) }
  def has_errors?(report)
    report[:warnings]&.any? { |w| w[:level] == :error }
  end

  # Verify that @reentrant:tailCall functions were actually TCO'd in the binary.
  # A TCO'd function should NOT contain a `call <self>` instruction - only `jmp`.
  # Returns array of { name:, tco_verified: bool, has_self_call: bool }
  sig { params(fn_nodes: Hash).returns(Array) }
  def verify_tail_calls(fn_nodes)
    output = objdump_output
    return [] if output.empty?

    tail_call_fns = fn_nodes.select { |_, fn| fn.tail_call }.map { |name, _| name }
    return [] if tail_call_fns.empty?

    results = []
    current_fn = nil
    current_fn_clear = nil
    instructions = []

    output.each_line do |line|
      if line =~ /^[0-9a-f]+\s+<(#{Regexp.escape(@module_prefix)}\..+)>:/
        # Save $1 BEFORE the inst =~ scan below: the inner regex has no
        # captures, so its `=~` would clobber $1 to nil and `current_fn`
        # would end up nil on the next iteration.
        next_fn = $1
        # Process previous function
        if current_fn_clear && tail_call_fns.include?(current_fn_clear)
          has_self_call = instructions.any? { |inst| inst =~ /\bcall\b.*<#{Regexp.escape(current_fn)}>/ }
          results << { name: current_fn_clear, tco_verified: !has_self_call, has_self_call: has_self_call }
        end
        current_fn = next_fn
        current_fn_clear = zig_to_clear_name(current_fn)
        instructions = []
      elsif line =~ /^[0-9a-f]+\s+</
        if current_fn_clear && tail_call_fns.include?(current_fn_clear)
          has_self_call = instructions.any? { |inst| inst =~ /\bcall\b.*<#{Regexp.escape(current_fn)}>/ }
          results << { name: current_fn_clear, tco_verified: !has_self_call, has_self_call: has_self_call }
        end
        current_fn = nil
        current_fn_clear = nil
        instructions = []
      elsif current_fn
        instructions << line
      end
    end

    # Process last function
    if current_fn_clear && tail_call_fns.include?(current_fn_clear)
      has_self_call = instructions.any? { |inst| inst =~ /\bcall\b.*<#{Regexp.escape(current_fn)}>/ }
      results << { name: current_fn_clear, tco_verified: !has_self_call, has_self_call: has_self_call }
    end

    results
  end

  # ── Exact Stack Sizing ──────────────────────────────────────────

  # Parse ALL functions from objdump: frame sizes and call edges.
  # Returns { frame_sizes: { addr => bytes }, call_graph: { addr => [addr, ...] },
  #           fn_names: { addr => name }, bg_entries: [addr, ...] }
  sig { returns(T.nilable(Hash)) }
  def extract_full_call_graph
    output = objdump_output
    return nil if output.empty?

    frame_sizes = {}  # fn_addr => stack_bytes
    call_graph  = {}  # fn_addr => Set of callee addrs
    fn_names    = {}  # fn_addr => display name
    fn_addrs    = {}  # name => fn_addr (for resolving call targets)
    bg_entries  = []  # addrs of __BgCtx*.run functions

    current_addr = nil
    current_name = nil
    saw_frame    = false
    pending_mov  = nil  # huge-frame: see #extract_frame_sizes for shape

    output.each_line do |line|
      # Function header: "0000000001162520 <bench.clearMain>:"
      if line =~ /^([0-9a-f]+)\s+<(.+)>:\s*$/
        raw_addr, name = $1, $2   # capture before sub() clobbers $2
        addr = raw_addr.sub(/^0+/, '')  # normalize: strip leading zeros

        current_addr = addr
        current_name = name
        saw_frame = false
        pending_mov = nil
        fn_names[addr] = name
        fn_addrs[name] = addr
        call_graph[addr] ||= Set.new

        # Detect BG entry functions
        bg_entries << addr if name =~ /__BgCtx\d+\.run$/

      elsif current_addr
        # Stack frame allocation, small form: "sub $0xNN,%rsp"
        if !saw_frame && line =~ /sub\s+\$0x([0-9a-f]+),%rsp/
          frame_sizes[current_addr] = $1.to_i(16)
          saw_frame = true
        # Huge-frame prologue: "mov $0xN,%REGd; sub %REG,%rsp"
        elsif !saw_frame && line =~ /mov\s+\$0x([0-9a-f]+),%(r\d+)d/
          pending_mov = { bytes: $1.to_i(16), reg: $2 }
        elsif !saw_frame && pending_mov && line =~ /sub\s+%(r\d+),%rsp/ && Regexp.last_match(1) == pending_mov[:reg]
          frame_sizes[current_addr] = pending_mov[:bytes]
          saw_frame = true
          pending_mov = nil
        end

        # Call instruction: "call ADDR <name>"
        if line =~ /\bcall\s+([0-9a-f]+)\s+</
          call_graph[current_addr] << $1
        end
      end
    end

    { frame_sizes: frame_sizes, call_graph: call_graph,
      fn_names: fn_names, fn_addrs: fn_addrs, bg_entries: bg_entries }
  end

  # Functions that leave the fiber stack. Treated as leaf nodes: their
  # own frame counts, but callees do not execute on the fiber stack.
  #
  # Two categories:
  # 1. Trampoline/yield: execution continues on scheduler or OS thread stack
  # 2. Panic/abort: execution never returns (program terminates)
  LEAF_PATTERNS = %w[
    Scheduler.coopYield
    Fiber.yield
    switchContext
    onRootStack
    callOnStack
    defaultPanic
    FullPanic
    unexpectedErrno
    returnError
  ].freeze

  # Compute the deepest stack path cost from a given entry function address.
  # Uses DFS with memoization. Returns total bytes for the worst-case call chain.
  # Cycles (recursion) are detected and treated based on the recursing
  # function's reentrance kind (Phase 4g):
  #   - :reentrant_max_depth(N) -> own_frame * N (bounded by the runtime
  #                                  depth counter)
  #   - other / unknown          -> 0 (default underestimate; the
  #                                  compile-time tier already forces
  #                                  :unbounded -> :service for plain
  #                                  :reentrant, so this path only
  #                                  matters as a sanity check)
  # Functions that trampoline off the fiber stack are treated as leaf nodes.
  sig { params(entry_addr: String, graph_data: Hash, fn_nodes: T.nilable(FnNodes)).returns(Integer) }
  def deepest_path_cost(entry_addr, graph_data, fn_nodes: nil)
    frame_sizes = graph_data[:frame_sizes]
    call_graph  = graph_data[:call_graph]
    fn_names    = graph_data[:fn_names]
    memo = {}
    in_stack = Set.new  # cycle detection

    dfs = lambda do |addr|
      return memo[addr] if memo.key?(addr)
      if in_stack.include?(addr)
        # Cycle -> consult the CLEAR FunctionDef for a precise bound.
        clear_name = fn_names[addr] && zig_to_clear_name(fn_names[addr])
        fn = fn_nodes&.[](clear_name)
        if fn && fn.respond_to?(:reentrance_kind) && fn.reentrance_kind == :reentrant_max_depth && fn.max_depth_n
          return (frame_sizes[addr] || 0) * fn.max_depth_n
        end
        return 0
      end

      my_frame = frame_sizes[addr] || 0

      # Leaf functions: trampolines leave the fiber stack, panics abort.
      # Count their frame but don't follow their callees.
      name = fn_names[addr]
      if name && LEAF_PATTERNS.any? { |p| name.include?(p) }
        memo[addr] = my_frame
        return my_frame
      end

      in_stack.add(addr)
      callees = call_graph[addr] || Set.new

      max_callee_cost = 0
      callees.each do |callee_addr|
        cost = dfs.call(callee_addr)
        max_callee_cost = cost if cost > max_callee_cost
      end

      in_stack.delete(addr)
      total = my_frame + max_callee_cost
      memo[addr] = total
      total
    end

    dfs.call(entry_addr)
  end

  # Compute optimal tier for the main fiber (clearMain entry point).
  # Returns { entry_name:, path_cost:, optimal_tier: } or nil if clearMain not found.
  sig { params(fn_nodes: T.nilable(FnNodes)).returns(T.nilable(Hash)) }
  def compute_main_optimal_tier(fn_nodes: nil)
    graph_data = extract_full_call_graph
    return nil unless graph_data

    addr, name = graph_data[:fn_names].find { |_, n| n =~ /\.clearMain$/ }
    return nil unless addr

    cost = deepest_path_cost(addr, graph_data, fn_nodes: fn_nodes)
    { entry_name: name, path_cost: cost, optimal_tier: cost_to_tier(cost) }
  end

  # Compute optimal tiers for all BG entry functions in the binary.
  # Returns array of { bg_index:, entry_name:, path_cost:, optimal_tier:, current_tier: }
  sig { params(fn_nodes: T.nilable(FnNodes)).returns(Array) }
  def compute_optimal_tiers(fn_nodes: nil)
    graph_data = extract_full_call_graph
    return [] unless graph_data

    results = []
    graph_data[:bg_entries].each do |addr|
      name = graph_data[:fn_names][addr]
      # Extract BG index from name like "bench.clearMain.__BgCtx0.run"
      next unless name =~ /__BgCtx(\d+)\.run/
      bg_index = $1.to_i

      cost = deepest_path_cost(addr, graph_data, fn_nodes: fn_nodes)
      tier = cost_to_tier(cost)

      results << {
        bg_index: bg_index,
        entry_name: name,
        path_cost: cost,
        optimal_tier: tier,
      }
    end

    results.sort_by { |r| r[:bg_index] }
  end

  # Map a byte cost to the smallest tier that fits.
  sig { params(bytes: Integer).returns(Symbol) }
  def cost_to_tier(bytes)
    if bytes <= TIER_BUDGET[:micro]
      :micro
    elsif bytes <= TIER_BUDGET[:standard]
      :standard
    elsif bytes <= TIER_BUDGET[:large]
      :large
    elsif bytes <= TIER_BUDGET[:xl]
      :xl
    else
      :service
    end
  end

  # Print optimal tier report.
  sig { params(results: Array, io: StringIO).returns(T.nilable(Array)) }
  def print_tier_report(results, io: $stderr)
    return if results.empty?

    io.puts ""
    io.puts "  Exact stack analysis (deepest call path):"
    results.each do |r|
      tier_str = r[:optimal_tier].to_s.upcase
      io.puts "    BG##{r[:bg_index]}: #{r[:path_cost]} bytes -> #{tier_str}"
    end
  end

  private :extract_frame_sizes

  private

  sig { params(path: String).returns(String) }
  def detect_prefix(path)
    basename = File.basename(path).sub(/\.\w+$/, '')
    "._clear_tmp_#{basename}"
  end

  sig { params(file: T.nilable(String), line: T.nilable(Integer)).returns(String) }
  def format_location(file, line)
    return "" unless file
    line ? "(#{File.basename(file)}:#{line}) " : "(#{File.basename(file)}) "
  end

  sig { params(zig_name: String).returns(String) }
  def zig_to_clear_name(zig_name)
    name = zig_name.sub(/^#{Regexp.escape(@module_prefix)}\./, '')
    return "main" if name == "clearMain"
    name = name.sub(/__anon_\d+$/, '')
    name = name.sub(/Env$/, '')
    name
  end
end
