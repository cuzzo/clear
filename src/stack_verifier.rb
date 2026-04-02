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

class StackVerifier
  # Fiber stack tier budgets (total allocation minus 4 KB frame arena).
  TIER_BUDGET = {
    micro:    4096,           # 4 KB (no arena at micro tier)
    standard: 16384 - 4096,  # 12 KB usable
    large:    65536 - 4096,  # 60 KB usable
    xl:       262144 - 4096, # 252 KB usable
  }.freeze

  attr_reader :binary_path, :module_prefix

  def initialize(binary_path, module_prefix = nil)
    @binary_path = binary_path
    @module_prefix = module_prefix || detect_prefix(binary_path)
  end

  # Parse objdump output and return per-function stack frame sizes.
  def extract_frame_sizes
    output = `objdump -d #{@binary_path} 2>/dev/null`
    return [] if output.empty?

    results = []
    current_fn = nil

    output.each_line do |line|
      if line =~ /^[0-9a-f]+\s+<(#{Regexp.escape(@module_prefix)}\..+)>:/
        current_fn = $1
      elsif line =~ /^[0-9a-f]+\s+</
        current_fn = nil
      elsif current_fn && line =~ /sub\s+\$0x([0-9a-f]+),%rsp/
        bytes = $1.to_i(16)
        clear_name = zig_to_clear_name(current_fn)
        results << { name: clear_name, zig_name: current_fn, stack_bytes: bytes }
        current_fn = nil
      end
    end

    results
  end

  # Full analysis: extract frame sizes, compare against tiers.
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
        is_reentrant = fn.respond_to?(:reentrant) && fn.reentrant == :reentrant
        entry[:reentrant] = is_reentrant
        budget = TIER_BUDGET[fn.stack_tier] || 12288
        entry[:budget] = budget
        entry[:usage_pct] = (f[:stack_bytes].to_f / budget * 100).round(1)

        if is_reentrant
          # Reentrant functions have unknown total stack usage (depth-dependent).
          # Report per-frame size and flag as unbounded.
          loc = format_location(source_file, entry[:line])
          report[:warnings] << {
            level: :info,
            message: "#{loc}'#{f[:name]}' is @reentrant: #{f[:stack_bytes]} bytes/frame, " \
                     "depth unknown. Total = #{f[:stack_bytes]} * depth. " \
                     "Use @onSmash on BG blocks calling this function."
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

  def print_report(report, io: $stderr)
    return if report[:functions].empty?

    io.puts ""
    report[:functions].each do |f|
      tier_str = f[:tier] != :unknown ? " [#{f[:tier]}]" : ""
      pct_str = f[:usage_pct] ? " (#{f[:usage_pct]}%)" : ""
      marker = f[:overflow] ? " <<<" : ""
      marker = " (per frame, depth unknown)" if f[:reentrant]
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
  def has_errors?(report)
    report[:warnings]&.any? { |w| w[:level] == :error }
  end

  private

  def detect_prefix(path)
    basename = File.basename(path).sub(/\.\w+$/, '')
    "._clear_tmp_#{basename}"
  end

  def format_location(file, line)
    return "" unless file
    line ? "(#{File.basename(file)}:#{line}) " : "(#{File.basename(file)}) "
  end

  def zig_to_clear_name(zig_name)
    name = zig_name.sub(/^#{Regexp.escape(@module_prefix)}\./, '')
    return "main" if name == "clearMain"
    name = name.sub(/__anon_\d+$/, '')
    name = name.sub(/Env$/, '')
    name
  end
end
