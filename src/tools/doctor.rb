# typed: true
require "sorbet-runtime"

require 'set'
require 'stringio'

# Analyzes a `clear profile` run. Reads heap/CPU/syscall/HW-counter/lock/MVCC
# data from the .profile/ directory and prints actionable advice.
#
# Each `section_*` method is independent — it reads its own profile file and
# returns nothing. State that crosses sections (sites/resolved for heap,
# llc_miss_rate for FREEZE) is collected in `run` and threaded through.
module Doctor
  STRING_OPS = %w[concat charAtCodepoint intToString floatToString smartAlloc].freeze
  FREEZE_LLC_THRESHOLD  = 20   # % LLC miss rate to consider high
  FREEZE_MIN_ALLOCS     = 5_000
  FREEZE_MIN_AVG_BYTES  = 16   # below this = arena string/int bytes, not struct nodes
  FREEZE_MAX_AVG_BYTES  = 512

  module_function

  # Scan a profile file for a `# WARNING: N samples dropped...` header
  # emitted by alloc-profile / lock-profile / mvcc-profile when the
  # open-addressed table saturates. Returns the line (without the
  # leading `# `) or nil. Runtime modules emit at most one warning
  # line per dump, so the first match is authoritative.
  def saturation_warning(file)
    return nil unless File.exist?(file)
    line = File.foreach(file).find { |l| l.start_with?('# WARNING:') }
    line&.sub(/\A# /, '')&.rstrip
  end

  def run(profile_dir, cumulative: false, focus: nil, ignore: nil, peek: nil, diff: nil, by: :bytes)
    if diff
      return run_diff(diff, profile_dir, focus: focus)
    end

    unless profile_dir && Dir.exist?(profile_dir)
      $stderr.puts "\e[31merror:\e[0m Usage: clear doctor <profile-dir> [--cumulative] [--focus=REGEX] [--ignore=REGEX] [--peek=REGEX] [--by=bytes|allocs|inuse_bytes|inuse_allocs] [--diff <before-dir>]"
      exit 1
    end

    @opts = T.let({ cumulative: cumulative, focus: focus, ignore: ignore, peek: peek, by: by }, T::Hash[T.untyped, T.untyped])

    if peek
      return run_peek(profile_dir, peek)
    end

    perf_data = File.join(profile_dir, 'perf.data')
    binary = profile_dir.chomp('/').sub(/\.profile$/, '')
    binary = nil unless File.exist?(binary.to_s)

    sites, resolved = section_heap(profile_dir, binary)
    section_cpu(profile_dir, perf_data)
    section_channels(profile_dir)
    section_fibers(profile_dir)
    section_locks(profile_dir)
    section_mvcc(profile_dir)
    section_atomic_escape(profile_dir)
    section_syscalls(profile_dir)
    llc_miss_rate = section_hardware(profile_dir)
    section_freeze(profile_dir, sites, resolved, llc_miss_rate)
  end

  # Returns true if a sample's trace (function names, leaf-first)
  # passes the focus/ignore filters. focus keeps only matches; ignore
  # drops matches; both can compose. With no filters set, every
  # sample passes.
  def focus_match?(funcs)
    return false if @opts && @opts[:ignore] && funcs.any? { |f| f =~ @opts[:ignore] }
    return true unless @opts && @opts[:focus]
    funcs.any? { |f| f =~ @opts[:focus] }
  end

  def cumulative?
    !!(@opts && @opts[:cumulative])
  end

  # Which Site field to sort/display by. Maps the user's --by flag
  # (`bytes` / `allocs` / `inuse_bytes` / `inuse_allocs`) to the
  # corresponding key in the parsed Site hash. Default `:bytes`.
  def sort_key
    return :bytes unless @opts && @opts[:by]
    case @opts[:by]
    when :allocs        then :allocs
    when :inuse_bytes   then :inuse_bytes
    when :inuse_allocs  then :inuse_allocs
    else :bytes
    end
  end

  # Human-readable label for the sort axis (used in section headers).
  def sort_label
    case sort_key
    when :allocs        then "allocations"
    when :inuse_bytes   then "in-use bytes (alloc - free)"
    when :inuse_allocs  then "in-use allocations (alloc - free)"
    else "bytes"
    end
  end

  # Format the sort metric as a string for the per-row display.
  # Bytes get KB/MB pretty-printing; counts get thousand-separators.
  def fmt_sort_value(s)
    v = s[sort_key]
    case sort_key
    when :allocs, :inuse_allocs
      "%s allocs" % v.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')
    else
      kb = v / 1024.0
      kb >= 1.0 ? ("%.1f KB" % kb) : ("%d B" % v)
    end
  end

  # ── Heap Profile ──
  def section_heap(profile_dir, binary)
    alloc_file = File.join(profile_dir, 'alloc.txt')
    unless File.exist?(alloc_file)
      puts "No heap profile found at #{alloc_file}"
      return [nil, nil]
    end

    lines = File.readlines(alloc_file).reject { |l| l.start_with?('#') || l.strip.empty? }
    total_line = File.readlines(alloc_file).find { |l| l.include?('total_allocs') }
    total = total_line ? total_line.scan(/\d+/).last.to_i : 0

    # alloc-profile v2: the first column may be a comma-separated
    # leaf-first stack trace. We treat the leaf address as the
    # primary site (matching v1 behaviour); the deeper frames are
    # available in `:trace` for richer views below if a future
    # caller wants them. v1 files (single addr, no comma) still parse
    # because `split(',')` on a no-comma string returns a 1-element
    # array.
    sites = lines.map do |line|
      parts = line.strip.split
      next nil if parts.size < 6
      trace = parts[0].split(',')
      allocs = parts[1].to_i
      frees  = parts[3].to_i
      bytes  = parts[2].to_i
      free_bytes = parts[4].to_i
      { addr: trace.first, trace: trace,
        allocs: allocs, bytes: bytes,
        frees: frees, free_bytes: free_bytes,
        live: parts[5].to_i,
        # Inuse columns: live counts derived from alloc - free.
        # Doctor uses these when --by=inuse_bytes / --by=inuse_allocs.
        inuse_allocs: [allocs - frees, 0].max,
        inuse_bytes:  [bytes  - free_bytes, 0].max }
    end.compact.sort_by { |s| -s[sort_key] }

    resolved = nil
    if binary
      resolved = {}
      # Resolve every address that appears in any trace, not just
      # the leaf, so callers can render full traces. uniq keeps the
      # addr2line invocation small on hot leaves.
      addrs = sites.flat_map { |s| s[:trace] }.uniq
      raw = IO.popen(['addr2line', '-e', binary, '-f'] + addrs, err: '/dev/null', &:read)
      lines_out = raw.split("\n")
      zig_source_path = File.join(profile_dir, 'transpiled.zig')
      zig_lines_cache = nil
      addrs.each_with_index do |addr, i|
        func = lines_out[i * 2]&.strip || "?"
        file = lines_out[i * 2 + 1]&.strip || "?"
        clear_line = nil
        # Only walk transpiled.zig for CLR markers if the address
        # actually came from the user's transpiled CLEAR file. Runtime
        # and stdlib zig files have no CLR markers; treating them as
        # user code led to runtime functions appearing at random
        # source.cht lines. addr2line emits the build-time filename
        # `._clear_tmp_<name>.zig` (the compile target), which is a
        # content copy of profile_dir/transpiled.zig.
        is_user_zig = File.exist?(zig_source_path) &&
                      File.basename(file.sub(/:\d+\b.*\z/, ''))
                          .match?(/\A\._clear_tmp_.*\.zig\z/)
        if is_user_zig && file =~ /:(\d+)\b/
          zig_line = $1.to_i
          zig_lines_cache ||= File.readlines(zig_source_path)
          (zig_line - 1).downto(0) do |li|
            break if li < 0 || li >= zig_lines_cache.size
            if zig_lines_cache[li] =~ %r{// CLR:(\d+)}
              clear_line = $1.to_i
              break
            end
          end
        end
        func = func.sub(/.*\./, '').sub(/__anon_\d+/, '')
        resolved[addr] = { func: func, file: file, clear_line: clear_line, is_user_zig: is_user_zig }
      end
    end

    # Cumulative bytes per leaf function: for every sample, every
    # frame in its trace (resolved to a function name) gets credit
    # for the sample's bytes/allocs. A leaf alone gets only flat
    # bytes; a function high in the stack accumulates its callees'
    # bytes too. This answers "who is on the call path of the most
    # bytes" not "who directly allocated the most bytes."
    cum_bytes = Hash.new(0)
    cum_allocs = Hash.new(0)
    sites.each do |s|
      seen = {} # one credit per (function, sample) so recursion doesn't double-count
      s[:trace].each do |a|
        f = resolved.dig(a)&.dig(:func) || a
        next if seen[f]
        seen[f] = true
        cum_bytes[f] += s[:bytes]
        cum_allocs[f] += s[:allocs]
      end
    end

    # --focus / --ignore filter which sites contribute to the top-10
    # list. focus keeps a site if any function in its trace matches
    # the regex; ignore drops one if any function matches. Both can
    # compose; ignore wins on overlap (a site that would pass focus
    # is dropped if it also matches ignore).
    if @opts && (@opts[:focus] || @opts[:ignore])
      sites = sites.select do |s|
        funcs = s[:trace].map { |a| resolved.dig(a)&.dig(:func) || a }
        focus_match?(funcs)
      end
    end

    puts "=== Allocation Profile (#{total.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')} allocs) ==="
    puts ""
    if (warn = saturation_warning(alloc_file))
      puts "  *** #{warn}"
      puts ""
    end
    if @opts && @opts[:focus]
      puts "Focus: /#{@opts[:focus].source}/"
    end
    if @opts && @opts[:ignore]
      puts "Ignore: /#{@opts[:ignore].source}/"
    end
    puts "" if @opts && (@opts[:focus] || @opts[:ignore])
    label = cumulative? ? "Top functions by cumulative #{sort_label}:" : "Top sites by #{sort_label}:"
    puts label

    if cumulative?
      ranked = cum_bytes.sort_by { |_f, b| -b }.first(10)
      ranked.each_with_index do |(func, bytes), i|
        kb = bytes / 1024.0
        ac = cum_allocs[func]
        if kb >= 1.0
          puts "  #{i + 1}. %-25s %6.1f KB cum  (on %s alloc paths)" %
               [func, kb, ac.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')]
        else
          puts "  #{i + 1}. %-25s %6d B  cum  (on %s alloc paths)" %
               [func, bytes, ac.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')]
        end
      end
      puts ""
      puts "  (\"cum\" = sum of bytes whose call path passes through this function)"
    else
      sites.first(10).each_with_index do |s, i|
        r = resolved.dig(s[:addr])
        func = r ? r[:func] : s[:addr]
        loc = if r&.dig(:clear_line) then "(line #{r[:clear_line]})"
              elsif r then "(#{r[:file].split('/').last})"
              else "" end
        avg = s[:allocs] > 0 ? s[:bytes] / s[:allocs] : 0
        kb = s[:bytes] / 1024.0
        leak = if s[:frees] == 0 && s[:allocs] > 0 && avg >= 16
                 "  (heap rc)"
               elsif s[:frees] == 0 && s[:allocs] > 0
                 "  (arena)"
               elsif s[:frees] > 0 && s[:frees] < s[:allocs]
                 "  ** LEAK ** (#{s[:allocs] - s[:frees]} unfreed)"
               else
                 ""
               end
        if kb >= 1.0
          puts "  #{i + 1}. %-25s %6.1f KB  (%s allocs, %d bytes avg)%s" % [
            "#{func} #{loc}", kb, s[:allocs].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,'), avg, leak]
        else
          puts "  #{i + 1}. %-25s %6d B   (%s allocs, %d bytes avg)%s" % [
            "#{func} #{loc}", s[:bytes], s[:allocs].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,'), avg, leak]
        end
      end
    end
    arena_count   = sites.first(10).count { |s| s[:frees] == 0 && s[:allocs] > 0 && (s[:allocs] > 0 ? s[:bytes] / s[:allocs] : 0) < 16 }
    heap_rc_count = sites.first(10).count { |s| s[:frees] == 0 && s[:allocs] > 0 && (s[:allocs] > 0 ? s[:bytes] / s[:allocs] : 0) >= 16 }
    leak_count    = sites.first(10).count { |s| s[:frees] > 0 && s[:frees] < s[:allocs] }
    if arena_count > 0 && leak_count == 0
      puts "  (arena) = frame-arena allocation, freed in bulk by rewind (not a leak)"
    end
    if heap_rc_count > 0
      puts "  (heap rc) = @multiowned RC allocation tracked by rcCreate"
    end
    puts ""

    [sites, resolved]
  end

  # ── CPU Profile + CLEAR Source Hot Lines ──
  def section_cpu(profile_dir, perf_data)
    return unless File.exist?(perf_data)
    puts "=== CPU Profile ==="
    puts ""
    report = `perf report -i #{perf_data} --stdio --no-children 2>/dev/null`
    top = report.lines.select { |l| l =~ /^\s+\d+\.\d+%/ }.first(10)
    if top.any?
      top.each { |l| puts "  #{l.strip}" }
    else
      puts "  (no samples collected - program may have run too briefly)"
    end
    puts ""

    # Attributes perf samples to CLEAR source lines by (a) asking perf
    # for srcline-sorted samples against the transpiled Zig, (b)
    # mapping each Zig line back to its CLEAR source line via the
    # `// CLR:N` comments the transpiler emits. Pipeline stages (lines
    # containing `|>`) are called out explicitly — they're the most
    # common perf "why is this slow" question.
    zig_source = File.join(profile_dir, 'transpiled.zig')
    clear_source = File.join(profile_dir, 'source.cht')
    return unless File.exist?(zig_source)

    zig_to_clear = {}
    current_clear = nil
    File.readlines(zig_source).each_with_index do |line, idx|
      if line =~ %r{// CLR:(\d+)}
        current_clear = $1.to_i
      end
      zig_to_clear[idx + 1] = current_clear if current_clear
    end

    srcline_out = `perf report -i #{perf_data} --stdio --no-children -g none --sort=srcline 2>/dev/null`
    clear_samples = Hash.new(0.0)
    # The running binary's debug info points perf at the original temp
    # Zig file (`._clear_tmp_<name>.zig` or `<basename>.zig`), not the
    # profile-dir copy. Match any Zig filename that isn't a known
    # runtime/stdlib file.
    runtime_zigs = %w[
      runtime.zig slab-alloc.zig parking-lot.zig Allocator.zig
      compiler_rt.zig array_list.zig format.zig fmt.zig io.zig
      start.zig mem.zig math.zig std.zig
    ].to_set
    srcline_out.each_line do |line|
      next unless line =~ /^\s*(\d+\.\d+)%.*?(\S+\.zig):(\d+)/
      pct = $1.to_f
      file = File.basename($2)
      zig_line = $3.to_i
      next if runtime_zigs.include?(file)
      clear_line = zig_to_clear[zig_line]
      clear_samples[clear_line] += pct if clear_line
    end

    return if clear_samples.empty?

    puts "=== CLEAR Source Hot Lines ==="
    puts ""
    source_lines = File.exist?(clear_source) ? File.readlines(clear_source) : []
    top = clear_samples.sort_by { |_, pct| -pct }.first(10)
    top.each do |line_no, pct|
      snippet = source_lines[line_no - 1]&.rstrip || ''
      # Detect `|>` as a standalone token.
      pipeline = snippet =~ /\|>/ ? ' [pipeline stage]' : ''
      trimmed = snippet.lstrip[0, 64]
      puts "  %5.1f%%  line %-4d  %s%s" % [pct, line_no, trimmed, pipeline]
    end
    puts ""
  end

  # ── Channel Saturation ──
  # Each BoundedChannel records pushes, pops, push_blocked, pop_blocked,
  # max_depth, capacity (comptime-gated in the runtime). Ratios reveal
  # fast-producer-slow-consumer (producer blocks often + max_depth at
  # capacity) or slow-producer-fast-consumer (consumer blocks often +
  # max_depth nowhere near capacity).
  def section_channels(profile_dir)
    channel_file = File.join(profile_dir, 'channels.txt')
    return unless File.exist?(channel_file)

    rows = File.readlines(channel_file).reject { |l| l.start_with?('#') || l.strip.empty? }
    channels = rows.map do |l|
      f = l.split
      next nil if f.size < 7
      {
        id: f[0].to_i, pushes: f[1].to_i, pops: f[2].to_i,
        push_blocked: f[3].to_i, pop_blocked: f[4].to_i,
        max_depth: f[5].to_i, capacity: f[6].to_i,
      }
    end.compact.reject { |c| c[:pushes] == 0 && c[:pops] == 0 }

    return if channels.empty?

    puts "=== Channel Saturation ==="
    puts ""
    printf "  %-4s %10s %10s %10s %10s %8s  %s\n",
           "id", "pushes", "pops", "pblk", "cblk", "depth/cap", "diagnosis"
    channels.each do |c|
      cap = c[:capacity]
      ratio = cap > 0 ? (c[:max_depth].to_f / cap * 100).round : 0
      push_blk_pct = c[:pushes] > 0 ? (c[:push_blocked].to_f / c[:pushes] * 100).round : 0
      pop_blk_pct  = c[:pops]   > 0 ? (c[:pop_blocked].to_f  / c[:pops]   * 100).round : 0
      diagnosis =
        if push_blk_pct >= 20 && ratio >= 80
          "slow consumer (producer blocked #{push_blk_pct}%, max depth #{ratio}%)"
        elsif pop_blk_pct >= 20 && ratio < 50
          "slow producer (consumer blocked #{pop_blk_pct}%, max depth #{ratio}%)"
        elsif push_blk_pct >= 20 || pop_blk_pct >= 20
          "backpressure (push #{push_blk_pct}% / pop #{pop_blk_pct}%)"
        else
          "balanced"
        end
      printf "  %-4d %10d %10d %10d %10d %7d%% %s\n",
             c[:id], c[:pushes], c[:pops], c[:push_blocked], c[:pop_blocked], ratio, diagnosis
    end
    puts ""
  end

  # ── Fibers & Workstealing Balance ──
  # Parses `.profile/fibers.txt`: fiber-lifetime summary + per-scheduler
  # fibers-run counter. Diagnoses micro-fiber overhead (fibers dominated
  # by sub-10us setup cost) and scheduler imbalance (one scheduler doing
  # most of the work while others are idle).
  def section_fibers(profile_dir)
    fiber_file = File.join(profile_dir, 'fibers.txt')
    return unless File.exist?(fiber_file)

    totals = {}
    sched_rows = []
    site_rows = []
    mode = nil
    File.readlines(fiber_file).each do |l|
      s = l.strip
      next if s.empty?
      if s.include?('per-scheduler')
        mode = :sched
        next
      elsif s.include?('per-site fibers')
        mode = :site
        next
      end
      next if s.start_with?('#')
      if mode == :sched
        f = s.split
        next if f.size < 2
        sched_rows << { idx: f[0].to_i, runs: f[1].to_i } if f[0] =~ /\A\d+\z/
      elsif mode == :site
        f = s.split(/\t/)
        next if f.size < 9 || f[0] !~ /\A\d+\z/
        scheds = {}
        f[8].to_s.split(',').each do |pair|
          sid, runs = pair.split(':', 2)
          scheds[sid.to_i] = runs.to_i if sid && runs
        end
        site_rows << {
          id: f[0].to_i,
          spawns: f[1].to_i,
          runs: f[2].to_i,
          exits: f[3].to_i,
          total_lifetime_ns: f[4].to_i,
          max_lifetime_ns: f[5].to_i,
          dispatch: f[6],
          form: f[7],
          scheds: scheds,
        }
      else
        if s =~ /\A(\w+):\s*(\d+)/
          totals[$1] = $2.to_i
        end
      end
    end

    if totals['total_fibers'] && totals['total_fibers'] > 0
      total = totals['total_fibers']
      short = totals['short_fibers_under_1ms'] || 0
      vshort = totals['vshort_fibers_under_10us'] || 0
      total_ns = totals['total_lifetime_ns'] || 0
      max_ns = totals['max_lifetime_ns'] || 0
      avg_ns = total > 0 ? total_ns / total : 0
      short_pct  = total > 0 ? (short.to_f / total * 100).round : 0
      vshort_pct = total > 0 ? (vshort.to_f / total * 100).round : 0

      puts "=== Fibers ==="
      puts ""
      puts "  total:   #{total}"
      puts "  average: #{(avg_ns / 1000.0).round(1)} us"
      puts "  max:     #{(max_ns / 1000.0).round(1)} us"
      puts "  < 1ms:   #{short} (#{short_pct}%)"
      puts "  < 10us:  #{vshort} (#{vshort_pct}%)"
      if vshort_pct >= 50 && total >= 50
        puts ""
        puts "  *** #{vshort_pct}% of fibers finished in under 10us. Setup cost"
        puts "      likely dominates work. Consider inlining, batching, or"
        puts "      a pool of long-lived workers instead of per-item BG."
      end
      puts ""
    end

    if sched_rows.any?
      puts "=== Workstealing Balance ==="
      puts ""
      total_runs = sched_rows.sum { |r| r[:runs] }
      max_runs   = sched_rows.map { |r| r[:runs] }.max || 0
      sched_rows.each do |r|
        pct = total_runs > 0 ? (r[:runs].to_f / total_runs * 100).round : 0
        bar = '█' * (pct * 40 / 100.0).round
        puts "  sched #{r[:idx]}: %6d  %3d%% %s" % [r[:runs], pct, bar]
      end
      imbalance_pct = total_runs > 0 ? (max_runs.to_f / total_runs * 100).round : 0
      if sched_rows.length >= 2 && imbalance_pct >= 80
        puts ""
        puts "  *** Scheduler imbalance: one scheduler ran #{imbalance_pct}%"
        puts "      of all fibers. Other schedulers were idle. BG spawn"
        puts "      policy may be routing too aggressively to a single target."
        emit_parallel_bg_hint!(profile_dir, site_rows)
      end
      puts ""
    end
  end

  def emit_parallel_bg_hint!(profile_dir, site_rows = [])
    metadata = task_site_metadata(profile_dir)
    imbalanced_sites = site_rows.select do |site|
      next false unless site[:runs] && site[:runs] > 0
      site_scheduler_skew(site) >= 0.80
    end
    local_sites = imbalanced_sites.select { |site| site[:dispatch] == 'local' }

    if local_sites.any?
      emit_exact_local_bg_sites!(profile_dir, local_sites, metadata)
      return
    end

    dispatch_counts = task_dispatch_counts(profile_dir)
    return unless local_dispatch_warning?(dispatch_counts)

    emit_generic_local_bg_hint!(local_bg_source_lines(File.join(profile_dir, 'source.cht')))
  end

  def emit_exact_local_bg_sites!(profile_dir, local_sites, metadata)
    puts ""
    puts "      Exact imbalanced local BG task sites:"
    local_sites.sort_by { |site| -site[:runs] }.first(8).each do |site|
      site_id = site[:id]
      runs = site[:runs]
      exits = site[:exits]
      line = (metadata[site_id] || {})[:line] || '?'
      snippet = source_line(profile_dir, line)
      max_sched, max_runs = site[:scheds].max_by { |_, runs| runs } || [nil, 0]
      pct = runs > 0 ? (max_runs.to_f / runs * 100).round : 0
      avg_us = exits > 0 ? (site[:total_lifetime_ns] / exits / 1000.0).round(1) : 0
      puts "        line #{line}: #{snippet}"
      puts "          site=#{site_id} form=#{site[:form]} runs=#{runs} sched=#{max_sched} #{pct}% avg=#{avg_us}us"
    end
    emit_parallel_bg_advice!
  end

  def emit_generic_local_bg_hint!(local_bg_lines)
    puts ""
    puts "      Profile contains local BG dispatches (`BG {}` defaults to the"
    puts "      current scheduler)."
    if local_bg_lines.any?
      puts "      Candidate BG sites:"
      local_bg_lines.first(6).each do |site|
        puts "        line #{site[:line]}: #{site[:text]}"
      end
    end
    emit_parallel_bg_advice!
  end

  def emit_parallel_bg_advice!
    puts "      Use `BG { @parallel -> ... }` for CPU-parallel worker fanout."
    puts "      Keep plain `BG {}` for scheduler-affine, IO-affine, or"
    puts "      locality-sensitive work."
  end

  def site_scheduler_skew(site)
    max_runs = site[:scheds].values.max || 0
    max_runs.to_f / site[:runs]
  end

  def task_dispatch_counts(profile_dir)
    zig_source = File.join(profile_dir, 'transpiled.zig')
    return { local: 0, parallel: 0 } unless File.exist?(zig_source)

    zig = File.read(zig_source)
    {
      local: zig.scan(/\bsubmitFsmSpawn\s*\(/).size + zig.scan(/\bsubmitSpawn\s*\(/).size,
      parallel: zig.scan(/\bspawnFsmBest\s*\(/).size + zig.scan(/\bspawnBest\s*\(/).size,
    }
  end

  def local_dispatch_warning?(counts)
    local = counts[:local]
    parallel = counts[:parallel]
    local > 0 && (parallel == 0 || local > parallel)
  end

  def task_site_metadata(profile_dir)
    zig_source = File.join(profile_dir, 'transpiled.zig')
    return {} unless File.exist?(zig_source)

    sites = {}
    File.foreach(zig_source) do |line|
      next unless line.include?('CLEAR_PROFILE_TASK_SITE')
      attrs = {}
      line.scan(/(\w+)=([^\s]+)/) { |k, v| attrs[k.to_sym] = v }
      id = attrs[:id].to_i
      next if id <= 0
      sites[id] = {
        kind: attrs[:kind],
        line: attrs[:line]&.to_i,
        column: attrs[:column]&.to_i,
        dispatch: attrs[:dispatch],
        form: attrs[:form],
      }
    end
    sites
  end

  def source_line(profile_dir, line)
    return '' unless line && line != '?'
    clear_source = File.join(profile_dir, 'source.cht')
    return '' unless File.exist?(clear_source)
    File.readlines(clear_source)[line.to_i - 1]&.strip.to_s[0, 90]
  end

  def local_bg_source_lines(clear_source)
    return [] unless File.exist?(clear_source)

    lines = File.readlines(clear_source)
    sites = []
    lines.each_with_index do |line, idx|
      next unless line.include?('BG') && line =~ /\bBG\s*\{/

      next if line.include?('@parallel')

      sites << { line: idx + 1, text: line.strip[0, 80] }
    end
    sites
  end

  # ── Lock Hold & Contention ──
  # Per-mutex stats from ParkingMutex + ParkingRwLock (write path).
  # Each row = one unique lock instance. Diagnoses:
  #   - high contention  (contended_acquires / acquires > 20%)
  #   - long critical sections (avg hold > 1ms)
  #   - hot lock (>10k acquires; recommends finer-grained locking)
  def section_locks(profile_dir)
    lock_prof = File.join(profile_dir, 'locks.txt')
    return unless File.exist?(lock_prof)

    rows = File.readlines(lock_prof).reject { |l| l.start_with?('#') || l.strip.empty? }
    # Columns: addr acquires contended total_wait max_wait total_hold max_hold
    #          read_acquires read_contended read_total_wait read_max_wait
    #          [caller_trace]   <-- v3, optional. `-` for empty; comma-
    #                                separated leaf-first when present.
    # With --sync-callstacks on, multiple rows can share the same `addr`
    # (one per (lock, caller-trace) pair). We aggregate by addr to
    # preserve the "one row per mutex" view; the trace data is kept on
    # the row for future caller-aware drilldowns.
    rows_parsed = rows.map do |l|
      f = l.split("\t").map(&:strip)
      # tab-split for v3 (caller_trace can contain `,`). Older v1/v2
      # files use whitespace-only separators; fall back to whitespace
      # split when the tab-split produced too few fields.
      f = l.strip.split if f.size < 11
      next nil if f.size < 11
      trace_field = f[11]
      trace = (trace_field.nil? || trace_field == '-') ? [] : trace_field.split(',')
      {
        addr: f[0], acquires: f[1].to_i, contended: f[2].to_i,
        total_wait_ns: f[3].to_i, max_wait_ns: f[4].to_i,
        total_hold_ns: f[5].to_i, max_hold_ns: f[6].to_i,
        read_acquires: f[7].to_i, read_contended: f[8].to_i,
        read_total_wait_ns: f[9].to_i, read_max_wait_ns: f[10].to_i,
        trace: trace,
      }
    end.compact

    # Aggregate (lock, trace) rows back to a single row per lock so
    # the existing "Top locks" view keeps its meaning. Counters sum;
    # max_* fields take the larger across rows.
    locks = rows_parsed.group_by { |r| r[:addr] }.map do |addr, group|
      {
        addr: addr,
        acquires: group.sum { |r| r[:acquires] },
        contended: group.sum { |r| r[:contended] },
        total_wait_ns: group.sum { |r| r[:total_wait_ns] },
        max_wait_ns: group.map { |r| r[:max_wait_ns] }.max,
        total_hold_ns: group.sum { |r| r[:total_hold_ns] },
        max_hold_ns: group.map { |r| r[:max_hold_ns] }.max,
        read_acquires: group.sum { |r| r[:read_acquires] },
        read_contended: group.sum { |r| r[:read_contended] },
        read_total_wait_ns: group.sum { |r| r[:read_total_wait_ns] },
        read_max_wait_ns: group.map { |r| r[:read_max_wait_ns] }.max,
        traces: group.map { |r| r[:trace] }.reject(&:empty?),
      }
    end.reject { |c| c[:acquires] == 0 && c[:read_acquires] == 0 }
       .sort_by { |c| -c[:total_hold_ns] }

    return if locks.empty?

    puts "=== Lock Hold & Contention ==="
    puts ""
    if (warn = saturation_warning(lock_prof))
      puts "  *** #{warn}"
      puts ""
    end
    printf "  %-12s %8s %8s %6s %5s %12s %10s %12s %10s  %s\n",
           "addr", "wr_acqs", "rd_acqs", "rd%", "cont%", "avg_hold", "max_hold", "avg_wait", "max_wait", "diagnosis"
    mvcc_candidates = []
    atomic_candidates = []
    atomic_ptr_candidates = []
    locks.first(10).each do |l|
      write_acqs = l[:acquires]
      read_acqs  = l[:read_acquires]
      total_acqs = write_acqs + read_acqs
      read_pct   = total_acqs > 0 ? (read_acqs.to_f / total_acqs * 100).round : 0
      # Combined contention% across read + write side (acquires that took the slow path).
      total_cont = l[:contended] + l[:read_contended]
      cont_pct   = total_acqs > 0 ? (total_cont.to_f / total_acqs * 100).round : 0
      avg_hold   = write_acqs > 0 ? l[:total_hold_ns] / write_acqs : 0
      # Wait time averaged across both sides (cleaner signal than write-only).
      total_wait = l[:total_wait_ns] + l[:read_total_wait_ns]
      avg_wait   = total_acqs > 0 ? total_wait / total_acqs : 0
      max_wait   = [l[:max_wait_ns], l[:read_max_wait_ns]].max

      # MVCC fit: read-heavy + frequent + contended. The read-side wait
      # time is the most direct signal — readers blocked behind a writer
      # are exactly what MVCC's lock-free read path eliminates.
      is_mvcc_fit = read_pct >= 80 && total_acqs >= 1_000 && cont_pct >= 10
      # Atomics M1.10 fit: write-heavy lock with EITHER real contention OR
      # very high acquire frequency. Atomic-eligible counters benefit two
      # ways: (1) the lock-acquire path itself is heavier than a single
      # LOCK XADDQ even uncontended (~30-50ns vs ~5-20ns), and (2) BG
      # auto-pinning kicks in for @shared:locked captures, hiding cross-
      # core opportunity. So we surface the suggestion either when
      # contention is already visible OR when the acquire count is large
      # enough that the per-op overhead dominates. The static eligibility
      # check below is the second gate -- both must hold.
      is_atomic_fit = read_pct < 50 && (
        (total_acqs >= 1_000 && cont_pct >= 10) ||
        total_acqs >= 100_000
      )
      # AtomicPtr M3.16 fit: a contended lock whose access pattern is
      # write-mostly publish OR read-heavy snapshot. Both shapes win
      # from a switch to @indirect:atomic IF the source has the
      # whole-struct-replace body shape (M3.15 static check). The
      # contention bar is permissive (any contention + minimum
      # acquire count) because the M3.15 static check IS the
      # false-positive gate -- a struct that isn't atomic-ptr-fit
      # never makes the candidate list. Distinct from is_atomic_fit
      # (M1.10) which targets single-primitive counters.
      is_atomic_ptr_fit = total_acqs >= 1_000 && cont_pct >= 10
      diagnosis =
        if is_mvcc_fit
          mvcc_candidates << l
          atomic_ptr_candidates << l
          "read-heavy (#{read_pct}%) + contended → try @shared:versioned (or @indirect:atomic for whole-struct publish)"
        elsif is_atomic_fit
          atomic_candidates << l
          atomic_ptr_candidates << l
          if cont_pct >= 10
            "write-heavy + contended → check static eligibility for @shared:atomic / @indirect:atomic"
          else
            "very hot lock + write-heavy → check static eligibility for @shared:atomic / @indirect:atomic"
          end
        elsif is_atomic_ptr_fit
          atomic_ptr_candidates << l
          "contended lock → check static eligibility for @indirect:atomic (whole-struct publish)"
        elsif cont_pct >= 20 && avg_hold > 1_000_000
          "hot lock + long hold — break up the critical section"
        elsif cont_pct >= 20
          "contended — consider @shared:versioned (if read-heavy) or finer-grained locking"
        elsif avg_hold > 1_000_000
          "long critical section (#{(avg_hold / 1_000_000.0).round(1)}ms avg)"
        else
          "ok"
        end

      printf "  %-12s %8d %8d %5d%% %4d%% %10.1fus %8.1fus %10.1fus %8.1fus  %s\n",
             l[:addr], write_acqs, read_acqs, read_pct, cont_pct,
             avg_hold / 1000.0, l[:max_hold_ns] / 1000.0,
             avg_wait / 1000.0, max_wait / 1000.0,
             diagnosis
    end

    if mvcc_candidates.any?
      puts ""
      puts "  MVCC fit detected. `@shared:versioned` swaps the RwLock for an"
      puts "  acquire-load + EBR pin on the read path — readers never block"
      puts "  on writers. Writer commits via CAS-loop with COW snapshot, so"
      puts "  it's a fit when:"
      puts "    - read-mostly (>=80% reads is a good rule of thumb)"
      puts "    - readers are blocking on writers today (cont% >= 10%)"
      puts "    - the protected struct is small (<256 bytes; large structs"
      puts "      copy on every write — wrap large fields in @indirect, or"
      puts "      stay with @shared:writeLocked)"
      puts ""
      puts "  Migration: change `@shared:writeLocked` -> `@shared:versioned`"
      puts "  on the binding. Read sites: replace `WITH x AS v { ... }` with"
      puts "  `WITH SNAPSHOT x AS v { ... }`. Write sites become"
      puts "  `WITH SNAPSHOT x AS MUTABLE v { ... }` -- the inline"
      puts "  `ON MvccConflict ...` is optional (the program SYNC POLICY's"
      puts "  default RAISE applies otherwise). For polymorphic helpers,"
      puts "  prefer `REQUIRES x: SNAPSHOTTED` (umbrella for @versioned"
      puts "  and @indirect:atomic) over the narrower `VERSIONED`. See"
      puts "  docs/mvcc.md and docs/agents/true-synchronization-polymorphism.md."
    end

    # Atomics M1.9 / M1.10: when the profile flagged any write-heavy
    # contended lock AND the source has atomic-eligible counter
    # patterns, surface the migration. The contention signal alone is
    # too vague (any contended lock could be a counter); the static
    # check alone is too noisy (every cold counter would surface).
    # Both signals together = a real migration win.
    emit_atomic_migration!(profile_dir) if atomic_candidates.any?

    # AtomicPtr M3.16: same gating, struct-publish path. Surfaces
    # @indirect:atomic candidates whose source-side whole-struct
    # replace shape lines up with the lock-profile contention.
    # Distinct from M1.10 (single-primitive counters); the two can
    # both fire on the same source if there's a mix of cells.
    emit_atomic_ptr_migration!(profile_dir) if atomic_ptr_candidates.any?
    puts ""
  end

  # Atomics M1.9 / M1.10: surface eligible @shared:locked / @locked
  # counter patterns from `source.cht`, scoped to runs whose lock-
  # profile already flagged write-heavy contention. Skipped silently
  # when source.cht is missing (the profile may have been recorded
  # before that capture landed) or when nothing eligible is found.
  def emit_atomic_migration!(profile_dir)
    src_path = File.join(profile_dir, 'source.cht')
    return unless File.exist?(src_path)

    require_relative "atomic_migration_suggester"
    candidates = AtomicMigrationSuggester.analyze(File.read(src_path))
    return if candidates.empty?

    puts ""
    puts "  Atomic fit detected. The lock profile shows write-heavy"
    puts "  contention; the source has counter-shape bindings whose"
    puts "  only WITH-EXCLUSIVE body shape is read / store / +=/-= on"
    puts "  a single primitive field. Replacing the wrapper struct +"
    puts "  mutex with `@shared:atomic` on the bare primitive turns"
    puts "  every increment into a single LOCK XADDQ — no allocation,"
    puts "  no parking, no critical section."
    puts ""
    puts "  Eligible bindings (run `clear fix` to apply once you're"
    puts "  ready; the rewrite touches the declaration AND every WITH"
    puts "  EXCLUSIVE body on this binding, so review before merging):"
    puts ""
    candidates.each do |c|
      sigil = c[:shared] ? "@shared:locked" : "@locked"
      loc   = c[:line] ? "line #{c[:line]}" : "(line unknown)"
      puts "    #{loc}: '#{c[:name]}: #{c[:struct_name]}' #{sigil}"
      puts "      single #{c[:field_type]} field '#{c[:field_name]}', #{c[:n_uses]} eligible WITH site(s)"
      puts "      → migrate to `#{c[:name]}: #{c[:field_type]} = ... @shared:atomic;`"
    end
  end

  # AtomicPtr M3.16: surface eligible @shared:locked / @shared:writeLocked
  # struct bindings whose WITH-EXCLUSIVE bodies match the whole-struct-
  # publish shape (read-mostly OR `alias = StructName{...}` only). The
  # M3.15 static suggester is the false-positive gate; the lock-profile
  # contention check upstream gates by "this lock matters at runtime."
  # Both must hold to surface.
  def emit_atomic_ptr_migration!(profile_dir)
    src_path = File.join(profile_dir, 'source.cht')
    return unless File.exist?(src_path)

    require_relative "atomic_ptr_migration_suggester"
    candidates = AtomicPtrMigrationSuggester.analyze(File.read(src_path))
    return if candidates.empty?

    puts ""
    puts "  AtomicPtr fit detected. The lock profile shows contended"
    puts "  acquires; the source has struct-shape bindings whose WITH-"
    puts "  EXCLUSIVE bodies are either read-only or whole-struct"
    puts "  replace (`alias = StructName{...}`). Switching to"
    puts "  `@indirect:atomic` removes the lock entirely: readers do an"
    puts "  acquire-load + EBR pin (lock-free, parallel-scaling); the"
    puts "  writer's whole-T publish becomes a CAS-loop (Rust arc-swap"
    puts "  rcu semantics — bounded internal retry, AtomicConflict on"
    puts "  cap exhaustion; usually defaulted via SYNC POLICY)."
    puts ""
    puts "  Eligible bindings (run `clear fix` to apply once you're"
    puts "  ready; the rewrite touches the declaration AND every WITH"
    puts "  EXCLUSIVE body, so review before merging):"
    puts ""
    candidates.each do |c|
      sigil = case c[:sync]
              when :write_locked then (c[:shared] ? "@shared:writeLocked" : "@writeLocked")
              when :locked       then (c[:shared] ? "@shared:locked"      : "@locked")
              end
      loc   = c[:line] ? "line #{c[:line]}" : "(line unknown)"
      puts "    #{loc}: '#{c[:name]}: #{c[:struct_name]}' #{sigil}"
      puts "      #{c[:n_uses]} eligible WITH site(s); whole-struct or read-only body"
      puts "      → migrate to `#{c[:name]} = #{c[:struct_name]}{...} @indirect:atomic;`"
      puts "         and rewrite WITH EXCLUSIVE -> WITH SNAPSHOT (read) /"
      puts "         WITH SNAPSHOT MUTABLE (whole-struct replace; AtomicConflict"
      puts "         is defaulted by SYNC POLICY -- no inline handler needed)"
    end
  end

  # ── MVCC Cells ──
  # Per-Versioned(T) cell stats from mvcc-profile.zig: reads, commits,
  # retries, struct size. Two diagnoses:
  #   - COW thrash: many commits + large struct -> @indirect heap-
  #     promotes the offending field so the CAS publishes a pointer
  #     swap (8 bytes) instead of a struct copy (256+ bytes).
  #   - MVCC misuse: more commits than reads -> not read-heavy ->
  #     @shared:writeLocked / @shared:locked is a better fit. MVCC's
  #     advantage is the lock-free read path; if writes dominate, the
  #     CAS-loop + EBR retire is just overhead.
  def section_mvcc(profile_dir)
    mvcc_prof = File.join(profile_dir, 'mvcc.txt')
    return unless File.exist?(mvcc_prof)

    rows = File.readlines(mvcc_prof).reject { |l| l.start_with?('#') || l.strip.empty? }
    # Columns (mvcc-profile v2): addr struct_size reads commits retries
    #   update_failures multi_commits [caller_trace]
    # caller_trace is `-` when --sync-callstacks is off, comma-separated
    # leaf-first when on. Pre-v2 files don't have the column; we treat
    # missing as empty.
    rows_parsed = rows.map do |l|
      f = l.split("\t").map(&:strip)
      f = l.strip.split if f.size < 6
      next nil if f.size < 6
      trace_field = f[7]
      trace = (trace_field.nil? || trace_field == '-') ? [] : trace_field.split(',')
      {
        addr: f[0], struct_size: f[1].to_i, reads: f[2].to_i,
        commits: f[3].to_i, retries: f[4].to_i,
        update_failures: f[5].to_i,
        multi_commits: (f[6] || 0).to_i,
        trace: trace,
      }
    end.compact

    # Aggregate (cell, trace) rows back to one row per cell so the
    # existing diagnoses (COW thrash, MVCC misuse) keep their meaning.
    cells = rows_parsed.group_by { |r| r[:addr] }.map do |addr, group|
      {
        addr: addr,
        struct_size: group.first[:struct_size],
        reads: group.sum { |r| r[:reads] },
        commits: group.sum { |r| r[:commits] },
        retries: group.sum { |r| r[:retries] },
        update_failures: group.sum { |r| r[:update_failures] },
        multi_commits: group.sum { |r| r[:multi_commits] },
        traces: group.map { |r| r[:trace] }.reject(&:empty?),
      }
    end.reject { |c| c[:reads] == 0 && c[:commits] == 0 }
       .sort_by { |c| -(c[:reads] + c[:commits]) }

    return if cells.empty?

    puts "=== MVCC Cells (Versioned(T)) ==="
    puts ""
    if (warn = saturation_warning(mvcc_prof))
      puts "  *** #{warn}"
      puts ""
    end
    printf "  %-12s %6s %10s %10s %8s  %10s  %s\n",
           "addr", "size", "reads", "commits", "retries", "cow_total", "diagnosis"
    cow_thrash = []
    misuse = []
    atomic_ptr_upgrade = []
    cells.first(10).each do |c|
      # COW total: every commit copies @sizeOf(T). Retries also copy
      # but get overwritten by the next attempt -- count both as
      # bytes "moved", since the CPU cycles spent are real.
      cow_bytes = c[:struct_size].to_i * (c[:commits] + c[:retries])
      cow_str = if cow_bytes >= 1_000_000_000 then "%.1fGB" % (cow_bytes / 1.0e9)
                elsif cow_bytes >= 1_000_000 then "%.1fMB" % (cow_bytes / 1.0e6)
                elsif cow_bytes >= 1_000     then "%.1fKB" % (cow_bytes / 1.0e3)
                else "#{cow_bytes}B" end
      retry_avg = c[:commits] > 0 ? (c[:retries].to_f / c[:commits]).round(1) : 0

      # COW thrash: commits >= 10K AND struct >= 256B AND total COW >= 100MB.
      # The 256B threshold matches the doctor advice in the lock section
      # ("the protected struct is small (<256 bytes)") — bigger == @indirect
      # candidate. The 100MB total guards against a hot small-struct cell
      # spuriously firing — at 256B+ the byte volume goes up fast.
      is_cow_thrash = c[:commits] >= 10_000 && c[:struct_size] >= 256 && cow_bytes >= 100_000_000

      # Misuse: write-heavy on a Versioned cell. MVCC's read path is
      # lock-free; the write path (CAS-loop + heap alloc + EBR retire)
      # is *more* expensive than a plain mutex. If commits >= reads,
      # the binding has the wrong shape.
      is_misuse = c[:commits] >= 1_000 && c[:reads] < c[:commits]

      # AtomicPtr M3.16 upgrade signal: when a cell does only single-
      # cell whole-struct commits (multi_commits == 0) AND has been
      # reasonably exercised (>=1K commits OR reads), it could skip
      # MVCC's bounded-retry + EBR-pin-on-update overhead by switching
      # to @indirect:atomic. The struct-shape check (M3.15 suggester:
      # whole-struct replace, no field-level mutation) is the false-
      # positive gate; this predicate just gates by "this cell
      # actually matters at runtime AND has no multi-cell ties."
      is_atomic_ptr_upgrade = c[:multi_commits] == 0 &&
                              (c[:commits] >= 1_000 || c[:reads] >= 1_000)

      diagnosis =
        if is_cow_thrash
          cow_thrash << c
          "COW thrash (#{cow_str} copied) → @indirect on large fields"
        elsif is_misuse
          misuse << c
          "write-heavy (#{c[:commits]} commits vs #{c[:reads]} reads) → " +
          "@shared:writeLocked / @shared:locked"
        elsif retry_avg >= 1.0
          "high retry (avg #{retry_avg}/commit; writers contending)"
        elsif c[:update_failures] > 0
          "#{c[:update_failures]} commits exhausted retries (-> error.UpdateRetriesExhausted)"
        elsif is_atomic_ptr_upgrade
          atomic_ptr_upgrade << c
          "single-cell only → check static eligibility for @indirect:atomic upgrade"
        else
          "ok"
        end

      printf "  %-12s %5dB %10d %10d %8d  %10s  %s\n",
             c[:addr], c[:struct_size], c[:reads], c[:commits], c[:retries],
             cow_str, diagnosis
    end

    if cow_thrash.any?
      puts ""
      puts "  COW thrash detected. Versioned(T)'s commit path copies the"
      puts "  whole struct on every update — for large structs that's"
      puts "  cache-line bouncing and allocator pressure. The fix:"
      puts ""
      puts "    STRUCT Big {"
      puts "      hot_field: Int64,           // small, copy is fine"
      puts "      cold_field: BigPayload @indirect,  // heap-pointed,"
      puts "                                  //   COW becomes a 1-word swap"
      puts "    }"
      puts ""
      puts "  Wrap any field where the bulk of the @sizeOf(T) lives. The"
      puts "  CAS payload becomes a pointer (8 bytes) instead of a struct"
      puts "  copy. Readers still see consistent snapshots — @indirect is"
      puts "  always read through the cell's pointer."
    end

    if misuse.any?
      puts ""
      puts "  MVCC misuse detected. `@shared:versioned` shines on read-heavy"
      puts "  workloads — lock-free reads, no reader-writer fairness. With"
      puts "  more commits than reads, you're paying MVCC's overhead (CAS"
      puts "  loop + heap alloc + EBR retire) without using its advantage."
      puts ""
      puts "  Migration: change `@shared:versioned` -> `@shared:writeLocked`"
      puts "  (or `@shared:locked` for simple mutex semantics). Read sites:"
      puts "  replace `WITH SNAPSHOT x AS v { ... }` with `WITH x AS v"
      puts "  { ... }`. Write sites: replace `WITH SNAPSHOT x AS MUTABLE v"
      puts "  { ... }` (the inline `ON MvccConflict` is optional under"
      puts "  the SYNC POLICY default) with `WITH EXCLUSIVE x AS v { ... }`."
      puts "  See docs/mvcc.md."
    end

    # AtomicPtr M3.16: when an MVCC cell only does single-cell
    # whole-struct commits (no multi-cell, no field-level mutation),
    # @indirect:atomic skips Versioned.update's bounded-retry +
    # EBR-pin-on-update overhead. The lock-profile path (above) is
    # the primary surface; this is the upgrade-from-MVCC follow-up.
    emit_atomic_ptr_upgrade_from_mvcc!(profile_dir) if atomic_ptr_upgrade.any?
    puts ""
  end

  # AtomicPtr M3.16 upgrade-from-MVCC: when one or more
  # @shared:versioned cells in the lock-profile flagged as
  # "single-cell only" (multi_commits == 0 + meaningful traffic),
  # cross-reference with the static suggester. Surfaces only when
  # both signals fire: the cell's runtime profile says
  # "atomic-ptr-fit" AND the source-side WITH SNAPSHOT MUTABLE
  # bodies are whole-struct replace (M3.15 eligibility).
  def emit_atomic_ptr_upgrade_from_mvcc!(profile_dir)
    src_path = File.join(profile_dir, 'source.cht')
    return unless File.exist?(src_path)

    require_relative "atomic_ptr_migration_suggester"
    candidates = AtomicPtrMigrationSuggester.analyze(File.read(src_path))
    versioned_candidates = candidates.select { |c| c[:sync] == :versioned }
    return if versioned_candidates.empty?

    puts ""
    puts "  AtomicPtr upgrade-from-MVCC detected. The mvcc profile shows"
    puts "  cells doing only single-cell whole-struct commits (no multi-"
    puts "  cell `Shared.updateMulti` traffic); the source has matching"
    puts "  WITH SNAPSHOT MUTABLE bodies that are whole-struct replace."
    puts "  Switching to `@indirect:atomic` skips MVCC's bounded-retry +"
    puts "  EBR-pin-on-update overhead: same lock-free read path, plus a"
    puts "  rcu-style retry update (bounded internally; AtomicConflict on"
    puts "  cap exhaustion, defaulted by SYNC POLICY)."
    puts ""
    puts "  Eligible bindings:"
    puts ""
    versioned_candidates.each do |c|
      sigil = c[:shared] ? "@shared:versioned" : "@versioned"
      loc   = c[:line] ? "line #{c[:line]}" : "(line unknown)"
      puts "    #{loc}: '#{c[:name]}: #{c[:struct_name]}' #{sigil}"
      puts "      #{c[:n_uses]} eligible WITH SNAPSHOT site(s); whole-struct or read-only"
      puts "      → migrate to `#{c[:name]} = #{c[:struct_name]}{...} @indirect:atomic;`"
      puts "         WITH SNAPSHOT (read) stays the same shape;"
      puts "         WITH SNAPSHOT MUTABLE drops the trailing `ON MvccConflict`"
      puts "         (AtomicConflict is defaulted by SYNC POLICY)"
    end
  end

  # ── Atomic Escape (Atomics M2.9) ──
  # Static analysis on `<profile-dir>/source.cht`. The compiler
  # rejects `@shared:atomic` bindings that escape their declaring
  # scope (M2.6 lifetime audit) -- this section translates the
  # "Lifetime Error: cannot store/RETURN ..." messages into a
  # plain-language explanation alongside the migration paths
  # (`@shared:locked` today, atomic struct fields in v0.3).
  # Skipped silently when source.cht is missing or no atomic-
  # escape sites are detected.
  def section_atomic_escape(profile_dir)
    src_path = File.join(profile_dir, 'source.cht')
    return unless File.exist?(src_path)

    require_relative "atomic_escape_suggester"
    findings = AtomicEscapeSuggester.analyze(File.read(src_path))
    return if findings.empty?

    puts "=== Atomic Escape ==="
    puts ""
    puts "  Compiler rejects #{findings.size} site(s) where an "
    puts "  `@shared:atomic` binding is captured into a destination"
    puts "  that outlives its declaring scope. M2 stores"
    puts "  `@shared:atomic` as a bare pointer to a scope-bounded"
    puts "  cell (no Arc, no refcount), so the binding can't"
    puts "  outlive the function it was declared in."
    puts ""
    puts "  Sites:"
    findings.each do |f|
      loc = f[:line] ? "line #{f[:line]}" : "(line unknown)"
      label =
        case f[:kind]
        when :return then "RETURN escapes atomic-tied value"
        when :store  then "store/append escapes atomic-tied value"
        else              "atomic-tied lifetime escape"
        end
      puts "    #{loc}: #{label}"
    end
    puts ""
    puts "  Migration options:"
    puts "    1. `@shared:atomic` -> `@shared:locked` at the binding's"
    puts "       declaration. Arc-refcounted, so the wrapped value can"
    puts "       outlive its declaring scope. Trade-off: every read /"
    puts "       write goes through `WITH EXCLUSIVE x AS a { ... }`,"
    puts "       and `@shared:locked` typically wants a STRUCT wrap"
    puts "       around the primitive. `clear fix` will surface the"
    puts "       sigil swap as an interactive edit."
    puts "    2. Wait for v0.3 atomic struct fields, which keep the"
    puts "       bare-pointer form and lift the escape restriction"
    puts "       (no Arc cost, no WITH-EXCLUSIVE wrapper)."
    puts ""
  end

  # ── Syscalls ──
  def section_syscalls(profile_dir)
    strace_file = File.join(profile_dir, 'syscalls.txt')
    return unless File.exist?(strace_file)

    puts "=== Syscalls ==="
    puts ""
    lines = File.readlines(strace_file).select { |l| l =~ /^\s+[\d.]+\s+[\d.]+/ }
    lines.first(10).each { |l| puts "  #{l.rstrip}" }
    total = File.readlines(strace_file).find { |l| l.include?('total') }
    puts "  #{total.rstrip}" if total
    puts ""
  end

  # ── Hardware Counters ──
  # Returns the LLC miss rate (or nil), so the FREEZE section can decide
  # whether to fire.
  def section_hardware(profile_dir)
    perf_stat_file = File.join(profile_dir, 'perf-stat.txt')
    return nil unless File.exist?(perf_stat_file)

    puts "=== Hardware Counters ==="
    puts ""
    hw = {}        # event_name -> integer count (unsupported events absent)
    File.readlines(perf_stat_file).each do |l|
      next if l.strip.empty? || l.start_with?('#') || l.start_with?('Performance')
      puts "  #{l.rstrip}" if l =~ /\d/
      next if l.include?('<not supported>')
      # Parse: "    1,234,567      event-name:u     # comment"
      m = l.match(/^\s*([\d,]+)\s+([\w:-]+)/)
      next unless m
      hw[m[2].sub(/:u?$/, '')] = m[1].gsub(',', '').to_i
    end

    # Derived metrics
    cycles       = hw['cycles']
    instructions = hw['instructions']
    branches     = hw['branches']
    branch_miss  = hw['branch-misses']
    # cache-references / cache-misses are the LLC-level events on x86
    # (LLC-loads / LLC-load-misses unsupported on most VMs/laptops)
    llc_loads    = hw['LLC-loads']    || hw['cache-references']
    llc_misses   = hw['LLC-load-misses'] || hw['cache-misses']

    ipc = (cycles && instructions && cycles > 0) ?
            (instructions.to_f / cycles).round(2) : nil
    llc_miss_rate = (llc_loads && llc_misses && llc_loads > 0) ?
                      (llc_misses.to_f / llc_loads * 100).round(1) : nil
    branch_miss_pct = (branches && branch_miss && branches > 0) ?
                        (branch_miss.to_f / branches * 100).round(1) : nil

    puts ""
    puts "  Analysis:"
    if ipc
      ipc_note = ipc < 1.0 ? " (low — memory or branch bound)" :
                 ipc >= 2.0 ? " (good — compute bound)" : ""
      puts "    IPC: #{ipc}#{ipc_note}"
    end
    if llc_miss_rate
      llc_note = llc_miss_rate > 20 ? " *** HIGH — working set exceeds cache" :
                 llc_miss_rate > 10 ? " (moderate)" : " (low)"
      puts "    LLC miss rate: #{llc_miss_rate}%#{llc_note}"
    end
    if branch_miss_pct
      branch_note = branch_miss_pct > 5 ? " *** HIGH — unpredictable control flow" : ""
      puts "    Branch miss rate: #{branch_miss_pct}%#{branch_note}"
    end
    puts ""

    llc_miss_rate
  end

  # ── FREEZE Recommendation ──
  # Fires when: high LLC miss rate + many small scattered heap allocations
  # (the signature of individually malloc'd tree/list nodes).
  def section_freeze(profile_dir, sites, resolved, llc_miss_rate)
    return unless llc_miss_rate && llc_miss_rate >= FREEZE_LLC_THRESHOLD && sites && sites.any?

    candidates = sites.select do |s|
      avg = s[:allocs] > 0 ? s[:bytes] / s[:allocs] : 0
      r   = resolved&.dig(s[:addr])
      fn  = r ? r[:func] : ''
      s[:allocs] >= FREEZE_MIN_ALLOCS &&
        avg >= FREEZE_MIN_AVG_BYTES && avg <= FREEZE_MAX_AVG_BYTES &&
        STRING_OPS.none? { |op| fn.include?(op) }
    end.sort_by { |s| -s[:bytes] }

    # For RC alloc sites that resolve to entryWrapper (inlined in ReleaseFast),
    # scan the transpiled.zig for rcCreate call sites to find CLEAR source lines.
    rc_clear_lines = []
    zig_source = File.join(profile_dir, 'transpiled.zig')
    if File.exist?(zig_source)
      zig_lines = File.readlines(zig_source)
      zig_lines.each_with_index do |line, li|
        next unless line.include?('rcCreate')
        (li - 1).downto(0) do |ci|
          break if ci < 0
          if zig_lines[ci] =~ %r{// CLR:(\d+)}
            rc_clear_lines << $1.to_i
            break
          end
        end
      end
      rc_clear_lines.uniq!
    end

    return if candidates.empty?

    puts "=== FREEZE Opportunity ==="
    puts ""
    puts "  LLC cache miss rate is #{llc_miss_rate}% (high). Detected scattered"
    puts "  node-level heap allocations — likely pointer-chasing through"
    puts "  individually malloc'd structs."
    puts ""
    puts "  Candidates (many small allocs from same site):"
    candidates.first(5).each do |s|
      r   = resolved&.dig(s[:addr])
      # In ReleaseFast builds, RC alloc sites inline into entryWrapper.
      # Fall back to transpiled.zig rcCreate line scan for CLEAR location.
      loc = if r&.dig(:clear_line)
              "line #{r[:clear_line]}"
            elsif r && r[:func] != 'entryWrapper' && !r[:func].empty?
              r[:func]
            elsif rc_clear_lines.any?
              "line #{rc_clear_lines.first}"
            else
              s[:addr]
            end
      avg  = s[:bytes] / s[:allocs]
      mb   = s[:bytes] / (1024.0 * 1024.0)
      puts "    %-32s  %s allocs × %d bytes avg  (%.1f MB)" % [
        loc,
        s[:allocs].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,'),
        avg, mb
      ]
    end
    puts ""
    puts "  If these nodes form a tree or acyclic graph, FREEZE can pack"
    puts "  them into a single contiguous allocation, eliminating pointer-"
    puts "  chasing cache misses. Measured speedup: 3-5x for working sets"
    puts "  larger than L3 cache."
    puts ""
    puts "  Zig:         const frozen = try freeze(T, alloc, root_ptr);"
    puts "  CLEAR:       frozen = FREEZE expr"
    puts ""
  end

  # ── --peek: callers and callees of one function ──
  # For sites whose leaf is `regex`, lists the unique callers (frames
  # immediately above the leaf in each trace) and aggregates bytes
  # per caller. For samples where `regex` matches a non-leaf frame,
  # also lists what's directly below — the callees this function
  # was on the path to. Mirrors `pprof -peek`'s shape.
  def run_peek(profile_dir, regex)
    unless profile_dir && Dir.exist?(profile_dir)
      $stderr.puts "\e[31merror:\e[0m --peek requires a profile directory"
      exit 1
    end
    binary = profile_dir.chomp('/').sub(/\.profile$/, '')
    binary = nil unless File.exist?(binary.to_s)

    sites, resolved = section_heap_silent(profile_dir, binary)
    return if sites.nil? || sites.empty?

    callers  = Hash.new { |h, k| h[k] = { bytes: 0, allocs: 0 } } # caller -> stats
    callees  = Hash.new { |h, k| h[k] = { bytes: 0, allocs: 0 } } # callee -> stats
    self_total = { bytes: 0, allocs: 0 }

    sites.each do |s|
      funcs = s[:trace].map { |a| resolved&.dig(a)&.dig(:func) || a }
      idx = funcs.index { |f| f =~ regex }
      next unless idx

      self_total[:bytes]  += s[:bytes]
      self_total[:allocs] += s[:allocs]

      # Caller: the frame above (deeper in the stack) — leaf-first
      # ordering means the caller is the next index. Stops at trace
      # root.
      if (caller_func = funcs[idx + 1])
        callers[caller_func][:bytes]  += s[:bytes]
        callers[caller_func][:allocs] += s[:allocs]
      else
        callers['<root>'][:bytes]  += s[:bytes]
        callers['<root>'][:allocs] += s[:allocs]
      end

      # Callee: only if the matched function is non-leaf (idx > 0).
      # The callee is the previous index (closer to leaf).
      if idx > 0 && (callee_func = funcs[idx - 1])
        callees[callee_func][:bytes]  += s[:bytes]
        callees[callee_func][:allocs] += s[:allocs]
      end
    end

    if self_total[:bytes].zero?
      puts "No samples matched /#{regex.source}/."
      return
    end

    puts "=== Peek /#{regex.source}/ ==="
    puts ""
    puts "  Self bytes:   %s (across %s allocations)" %
         [bytes_pretty(self_total[:bytes]), self_total[:allocs].to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')]
    puts ""

    puts "  Callers (frames above /#{regex.source}/):"
    callers.sort_by { |_f, v| -v[:bytes] }.first(10).each do |func, v|
      puts "    %-30s  %12s  (%d allocs)" % [func, bytes_pretty(v[:bytes]), v[:allocs]]
    end
    puts ""

    if callees.any?
      puts "  Callees (frames below /#{regex.source}/, when matched non-leaf):"
      callees.sort_by { |_f, v| -v[:bytes] }.first(10).each do |func, v|
        puts "    %-30s  %12s  (%d allocs)" % [func, bytes_pretty(v[:bytes]), v[:allocs]]
      end
      puts ""
    end
  end

  # Same parsing as section_heap but without the printout — used by
  # run_peek so we can build caller/callee tables from the parsed sites.
  def section_heap_silent(profile_dir, binary)
    out = StringIO.new
    real, $stdout = $stdout, out
    sites, resolved = section_heap(profile_dir, binary)
    [sites, resolved]
  ensure
    $stdout = real
  end

  # ── --diff: compare two profile runs ──
  # Loads both profile dirs, aggregates by leaf function, and reports
  # the largest deltas in alloc_space, lock contention, and MVCC
  # commits. Doctor's per-site advice is layered on top: a site that
  # newly trips "MVCC fit" gets called out, etc. Computes deltas
  # ourselves rather than shelling to `pprof -base` so doctor stays
  # self-contained and can attach commentary.
  def run_diff(before_dir, after_dir, focus: nil)
    before_dir = before_dir.to_s.chomp('/')
    after_dir  = after_dir.to_s.chomp('/')
    unless Dir.exist?(before_dir) && Dir.exist?(after_dir)
      $stderr.puts "\e[31merror:\e[0m diff requires two existing profile directories"
      $stderr.puts "  before: #{before_dir} (#{Dir.exist?(before_dir) ? 'ok' : 'MISSING'})"
      $stderr.puts "  after:  #{after_dir}  (#{Dir.exist?(after_dir)  ? 'ok' : 'MISSING'})"
      exit 1
    end

    @opts = T.let({ cumulative: false, focus: focus }, T::Hash[T.untyped, T.untyped])
    puts "=== Diff (before → after) ==="
    puts "  before: #{before_dir}"
    puts "  after:  #{after_dir}"
    puts "  focus:  /#{focus.source}/" if focus
    puts ""

    diff_heap(before_dir, after_dir, focus)
    diff_locks(before_dir, after_dir, focus)
    diff_mvcc(before_dir, after_dir, focus)
  end

  # Parse alloc.txt and aggregate by leaf-function name across all
  # rows that resolve to that function. Returns
  # { func_name => { allocs:, bytes:, frees:, free_bytes: } }.
  # `binary` is the path to use for addr2line resolution; pass the
  # after-profile's binary so before/after addresses resolve through
  # the same symbol table (ASLR / rebuild can shift addresses but the
  # function name should stay stable for the same source).
  def parse_alloc_for_diff(profile_dir, binary)
    alloc_file = File.join(profile_dir, 'alloc.txt')
    return {} unless File.exist?(alloc_file)

    rows = File.readlines(alloc_file).reject { |l| l.start_with?('#') || l.strip.empty? }
    leaves = []
    parsed = rows.map do |l|
      f = l.strip.split
      next nil if f.size < 6
      leaf = f[0].split(',').first
      leaves << leaf
      [leaf, { allocs: f[1].to_i, bytes: f[2].to_i,
               frees: f[3].to_i, free_bytes: f[4].to_i }]
    end.compact

    # Resolve leaf addrs to function names if a binary is available.
    # Otherwise fall back to keying by raw address — distinct leaves
    # still diff against each other; the table just shows hex addrs
    # in place of function names.
    addr_to_func = {}
    if binary && File.exist?(binary)
      raw = IO.popen(['addr2line', '-e', binary, '-f'] + leaves.uniq, err: '/dev/null', &:read)
      out_lines = raw.split("\n")
      leaves.uniq.each_with_index do |a, i|
        func = (out_lines[i * 2] || '?').strip.sub(/.*\./, '').sub(/__anon_\d+/, '')
        # addr2line returns "??" for addresses not in this binary;
        # fall back to the raw addr.
        func = a if func == '??' || func.empty?
        addr_to_func[a] = func
      end
    end

    by_func = Hash.new { |h, k| h[k] = { allocs: 0, bytes: 0, frees: 0, free_bytes: 0 } }
    parsed.each do |leaf, vals|
      f = addr_to_func[leaf] || leaf
      by_func[f][:allocs]      += vals[:allocs]
      by_func[f][:bytes]       += vals[:bytes]
      by_func[f][:frees]       += vals[:frees]
      by_func[f][:free_bytes]  += vals[:free_bytes]
    end
    by_func
  end

  def diff_heap(before_dir, after_dir, focus)
    # Use the after-dir's binary for both lookups — that's the user's
    # current build. Falls back to the before-dir's binary if the
    # after-dir doesn't have one.
    binary = locate_diff_binary(after_dir, before_dir)
    before = parse_alloc_for_diff(before_dir, binary)
    after  = parse_alloc_for_diff(after_dir, binary)
    return if before.empty? && after.empty?

    funcs = (before.keys + after.keys).uniq
    funcs.select! { |f| f =~ focus } if focus

    deltas = funcs.map do |f|
      b = before[f] || { bytes: 0, allocs: 0 }
      a = after[f]  || { bytes: 0, allocs: 0 }
      {
        func: f,
        before_bytes: b[:bytes], after_bytes: a[:bytes],
        delta_bytes: a[:bytes] - b[:bytes],
        before_allocs: b[:allocs], after_allocs: a[:allocs],
        delta_allocs: a[:allocs] - b[:allocs],
      }
    end.reject { |d| d[:delta_bytes].zero? && d[:delta_allocs].zero? }
       .sort_by { |d| -d[:delta_bytes].abs }

    return if deltas.empty?

    puts "=== Heap Δ (top by |Δ alloc_space|) ==="
    puts ""
    printf "  %-30s  %12s  %12s  %12s\n", "function", "before", "after", "Δ"
    deltas.first(10).each do |d|
      arrow = d[:delta_bytes].positive? ? "↑" : "↓"
      puts "  %-30s  %12s  %12s  %s %12s" % [
        d[:func],
        bytes_pretty(d[:before_bytes]),
        bytes_pretty(d[:after_bytes]),
        arrow,
        bytes_pretty(d[:delta_bytes].abs),
      ]
    end
    new_funcs = deltas.select { |d| d[:before_bytes].zero? && d[:after_bytes].positive? }
    if new_funcs.any?
      puts ""
      puts "  New allocation sites (cold → hot):"
      new_funcs.first(5).each { |d| puts "    + #{d[:func]} (#{bytes_pretty(d[:after_bytes])})" }
    end
    gone_funcs = deltas.select { |d| d[:after_bytes].zero? && d[:before_bytes].positive? }
    if gone_funcs.any?
      puts ""
      puts "  Eliminated allocation sites:"
      gone_funcs.first(5).each { |d| puts "    - #{d[:func]} (was #{bytes_pretty(d[:before_bytes])})" }
    end
    puts ""
  end

  def parse_locks_for_diff(profile_dir)
    lock_prof = File.join(profile_dir, 'locks.txt')
    return {} unless File.exist?(lock_prof)
    rows = File.readlines(lock_prof).reject { |l| l.start_with?('#') || l.strip.empty? }
    by_addr = Hash.new { |h, k| h[k] = { acquires: 0, contended: 0,
                                          total_wait_ns: 0, total_hold_ns: 0,
                                          read_acquires: 0, read_contended: 0,
                                          read_total_wait_ns: 0 } }
    rows.each do |l|
      f = l.split("\t").map(&:strip)
      f = l.strip.split if f.size < 11
      next if f.size < 11
      a = by_addr[f[0]]
      a[:acquires]            += f[1].to_i
      a[:contended]           += f[2].to_i
      a[:total_wait_ns]       += f[3].to_i
      a[:total_hold_ns]       += f[5].to_i
      a[:read_acquires]       += f[7].to_i
      a[:read_contended]      += f[8].to_i
      a[:read_total_wait_ns]  += f[9].to_i
    end
    by_addr
  end

  def diff_locks(before_dir, after_dir, _focus)
    before = parse_locks_for_diff(before_dir)
    after  = parse_locks_for_diff(after_dir)
    return if before.empty? && after.empty?

    addrs = (before.keys + after.keys).uniq
    deltas = addrs.map do |addr|
      b = before[addr] || { contended: 0, read_contended: 0, total_wait_ns: 0, read_total_wait_ns: 0 }
      a = after[addr]  || { contended: 0, read_contended: 0, total_wait_ns: 0, read_total_wait_ns: 0 }
      bcont = b[:contended] + b[:read_contended]
      acont = a[:contended] + a[:read_contended]
      bwait = b[:total_wait_ns] + b[:read_total_wait_ns]
      await = a[:total_wait_ns] + a[:read_total_wait_ns]
      {
        addr: addr,
        before_cont: bcont, after_cont: acont, delta_cont: acont - bcont,
        before_wait: bwait, after_wait: await, delta_wait: await - bwait,
      }
    end.reject { |d| d[:delta_cont].zero? && d[:delta_wait].zero? }
       .sort_by { |d| -d[:delta_wait].abs }

    return if deltas.empty?

    puts "=== Lock Δ (top by |Δ wait_ns|) ==="
    puts ""
    printf "  %-14s  %12s  %12s  %12s  %s\n", "lock", "Δ contend", "Δ wait_ns", "before/after", "diagnosis"
    deltas.first(10).each do |d|
      diag = if d[:before_wait].zero? && d[:after_wait].positive?
               "newly contended"
             elsif d[:after_wait].zero? && d[:before_wait].positive?
               "contention eliminated"
             elsif d[:delta_wait].positive?
               "regression"
             else
               "improved"
             end
      arrow = d[:delta_wait].positive? ? "↑" : "↓"
      puts "  %-14s  %s %5d  %s %10d  %d/%d  %s" % [
        d[:addr],
        d[:delta_cont].positive? ? "↑" : "↓",
        d[:delta_cont].abs,
        arrow,
        d[:delta_wait].abs,
        d[:before_wait], d[:after_wait], diag,
      ]
    end
    puts ""
  end

  def parse_mvcc_for_diff(profile_dir)
    mvcc_prof = File.join(profile_dir, 'mvcc.txt')
    return {} unless File.exist?(mvcc_prof)
    rows = File.readlines(mvcc_prof).reject { |l| l.start_with?('#') || l.strip.empty? }
    by_addr = Hash.new { |h, k| h[k] = { reads: 0, commits: 0, retries: 0 } }
    rows.each do |l|
      f = l.split("\t").map(&:strip)
      f = l.strip.split if f.size < 6
      next if f.size < 6
      a = by_addr[f[0]]
      a[:reads]   += f[2].to_i
      a[:commits] += f[3].to_i
      a[:retries] += f[4].to_i
    end
    by_addr
  end

  def diff_mvcc(before_dir, after_dir, _focus)
    before = parse_mvcc_for_diff(before_dir)
    after  = parse_mvcc_for_diff(after_dir)
    return if before.empty? && after.empty?

    addrs = (before.keys + after.keys).uniq
    deltas = addrs.map do |addr|
      b = before[addr] || { reads: 0, commits: 0, retries: 0 }
      a = after[addr]  || { reads: 0, commits: 0, retries: 0 }
      {
        addr: addr,
        delta_commits: a[:commits] - b[:commits],
        delta_retries: a[:retries] - b[:retries],
        before_retries: b[:retries], after_retries: a[:retries],
      }
    end.reject { |d| d[:delta_commits].zero? && d[:delta_retries].zero? }
       .sort_by { |d| -d[:delta_retries].abs }

    return if deltas.empty?

    puts "=== MVCC Δ (top by |Δ retries|) ==="
    puts ""
    printf "  %-14s  %12s  %12s  %s\n", "cell", "Δ commits", "Δ retries", "diagnosis"
    deltas.first(10).each do |d|
      diag = if d[:before_retries].zero? && d[:after_retries].positive?
               "new retry storm"
             elsif d[:after_retries].zero? && d[:before_retries].positive?
               "retries eliminated"
             elsif d[:delta_retries].positive?
               "more contention"
             else
               "less contention"
             end
      arrow_c = d[:delta_commits].positive? ? "↑" : "↓"
      arrow_r = d[:delta_retries].positive? ? "↑" : "↓"
      puts "  %-14s  %s %10d  %s %10d  %s" % [
        d[:addr],
        arrow_c, d[:delta_commits].abs,
        arrow_r, d[:delta_retries].abs,
        diag,
      ]
    end
    puts ""
  end

  # Find the binary to use for addr2line resolution in --diff mode.
  # Prefers the after-dir's binary (the user's current build); falls
  # back to the before-dir's binary if the after-dir is missing one
  # (e.g. binary was deleted after profiling).
  def locate_diff_binary(after_dir, before_dir)
    [after_dir, before_dir].each do |dir|
      bin = dir.to_s.chomp('/').sub(/\.profile$/, '')
      return bin if File.exist?(bin)
    end
    nil
  end

  def bytes_pretty(n)
    return "-" if n.zero?
    if n.abs >= 1024 * 1024
      "%.1f MB" % (n / (1024.0 * 1024.0))
    elsif n.abs >= 1024
      "%.1f KB" % (n / 1024.0)
    else
      "#{n} B"
    end
  end
end
