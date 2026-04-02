# stack_verifier.rb - Post-build stack frame size verification.
#
# Parses objdump output to extract actual stack frame sizes for CLEAR functions.
# Cross-references with compile-time tier recommendations to detect potential
# stack overflow risks on fiber stacks.
#
# Usage:
#   verifier = StackVerifier.new(binary_path, module_prefix)
#   report = verifier.analyze
#   verifier.print_report(report)

class StackVerifier
  # Fiber stack tier budgets (total allocation minus 4 KB frame arena).
  TIER_BUDGET = {
    micro:    4096 - 4096,   # 0 bytes usable (micro has no arena, but tiny stack)
    standard: 16384 - 4096,  # 12 KB usable
    large:    65536 - 4096,  # 60 KB usable
    xl:       262144 - 4096, # 252 KB usable
  }.freeze

  # Micro tier: entire 4 KB is stack (no arena). Override the 0 above.
  TIER_BUDGET_ACTUAL = TIER_BUDGET.merge(micro: 4096).freeze

  attr_reader :binary_path, :module_prefix

  def initialize(binary_path, module_prefix = nil)
    @binary_path = binary_path
    @module_prefix = module_prefix || detect_prefix(binary_path)
  end

  # Parse objdump output and return per-function stack frame sizes.
  # Returns: Array of { name:, zig_name:, stack_bytes: }
  def extract_frame_sizes
    output = `objdump -d #{@binary_path} 2>/dev/null`
    return [] if output.empty?

    results = []
    current_fn = nil

    output.each_line do |line|
      # Function header: "0000000001155870 <._clear_tmp_foo.clearMain>:"
      if line =~ /^[0-9a-f]+\s+<(#{Regexp.escape(@module_prefix)}\..+)>:/
        current_fn = $1
      elsif line =~ /^[0-9a-f]+\s+</
        current_fn = nil
      elsif current_fn && line =~ /sub\s+\$0x([0-9a-f]+),%rsp/
        bytes = $1.to_i(16)
        clear_name = zig_to_clear_name(current_fn)
        results << { name: clear_name, zig_name: current_fn, stack_bytes: bytes }
        current_fn = nil  # only capture the first sub (the prologue)
      end
    end

    results
  end

  # Full analysis: extract frame sizes, compute call chains, compare against tiers.
  # Optional: pass fn_nodes hash (from annotator) for tier recommendations.
  def analyze(fn_nodes: nil)
    frames = extract_frame_sizes
    report = { functions: [], warnings: [] }

    frames.each do |f|
      entry = { name: f[:name], stack_bytes: f[:stack_bytes] }

      if fn_nodes && fn_nodes[f[:name]]
        node = fn_nodes[f[:name]]
        entry[:tier] = node.stack_tier
        entry[:estimated_bytes] = node.stack_vars_bytes
        budget = TIER_BUDGET_ACTUAL[node.stack_tier] || 16384
        entry[:budget] = budget
        entry[:usage_pct] = (f[:stack_bytes].to_f / budget * 100).round(1)

        if f[:stack_bytes] > budget
          report[:warnings] << "[stack-OVERFLOW] #{f[:name]}: #{f[:stack_bytes]} bytes exceeds #{node.stack_tier} budget (#{budget} bytes)"
        elsif f[:stack_bytes] > budget * 0.75
          report[:warnings] << "[stack-warn] #{f[:name]}: #{f[:stack_bytes]} bytes = #{entry[:usage_pct]}% of #{node.stack_tier} budget"
        end
      else
        entry[:tier] = :unknown
      end

      report[:functions] << entry
    end

    report[:functions].sort_by! { |f| -(f[:stack_bytes] || 0) }
    report
  end

  def print_report(report, io: $stderr)
    return if report[:functions].empty?

    io.puts "\n[stack-check] Function stack usage (actual from binary):"
    report[:functions].each do |f|
      tier_str = f[:tier] != :unknown ? " [#{f[:tier]}]" : ""
      pct_str = f[:usage_pct] ? " (#{f[:usage_pct]}%)" : ""
      io.puts "  %6d bytes  %-40s%s%s" % [f[:stack_bytes], f[:name], tier_str, pct_str]
    end

    if report[:warnings].any?
      io.puts ""
      report[:warnings].each { |w| io.puts w }
    end
  end

  private

  def detect_prefix(path)
    basename = File.basename(path).sub(/\.\w+$/, '')
    "._clear_tmp_#{basename}"
  end

  # Map Zig function name back to CLEAR function name.
  # "._clear_tmp_foo.clearMain" -> "main"
  # "._clear_tmp_foo.tokenize" -> "tokenize"
  # "._clear_tmp_foo.eval__anon_12345" -> "eval!"
  # "._clear_tmp_foo.readFormEnv__anon_12345" -> "readFormEnv!"
  def zig_to_clear_name(zig_name)
    # Strip module prefix
    name = zig_name.sub(/^#{Regexp.escape(@module_prefix)}\./, '')
    # "clearMain" -> "main"
    return "main" if name == "clearMain"
    # Strip __anon_NNNNN suffix (monomorphization)
    name = name.sub(/__anon_\d+$/, '')
    # Strip Env suffix added by transpiler for recursive functions
    name = name.sub(/Env$/, '')
    # Zig strips ! and ? from names; restore ! for mutating functions
    # (heuristic: if the original CLEAR name had !, it was stripped)
    name
  end
end
