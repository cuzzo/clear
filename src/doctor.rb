require 'set'

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

  def run(profile_dir)
    unless profile_dir && Dir.exist?(profile_dir)
      $stderr.puts "\e[31merror:\e[0m Usage: clear doctor <profile-dir>"
      exit 1
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
    section_syscalls(profile_dir)
    llc_miss_rate = section_hardware(profile_dir)
    section_freeze(profile_dir, sites, resolved, llc_miss_rate)
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

    sites = lines.map do |line|
      parts = line.strip.split
      next nil if parts.size < 6
      addr = parts[0]
      { addr: addr, allocs: parts[1].to_i, bytes: parts[2].to_i,
        frees: parts[3].to_i, free_bytes: parts[4].to_i, live: parts[5].to_i }
    end.compact.sort_by { |s| -s[:bytes] }

    resolved = nil
    if binary
      resolved = {}
      addrs = sites.map { |s| s[:addr] }
      raw = IO.popen(['addr2line', '-e', binary, '-f'] + addrs, err: '/dev/null', &:read)
      lines_out = raw.split("\n")
      zig_source_path = File.join(profile_dir, 'transpiled.zig')
      zig_lines_cache = nil
      addrs.each_with_index do |addr, i|
        func = lines_out[i * 2]&.strip || "?"
        file = lines_out[i * 2 + 1]&.strip || "?"
        clear_line = nil
        if file =~ /:(\d+)/ && File.exist?(zig_source_path)
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
        resolved[addr] = { func: func, file: file, clear_line: clear_line }
      end
    end

    puts "=== Allocation Profile (#{total.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')} allocs) ==="
    puts ""
    if (warn = saturation_warning(alloc_file))
      puts "  *** #{warn}"
      puts ""
    end
    puts "Top sites by bytes:"
    sites.first(10).each_with_index do |s, i|
      r = resolved&.dig(s[:addr])
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
    # containing `s>`) are called out explicitly — they're the most
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
      # Detect `s>` as a standalone token. Avoid matching identifiers
      # that happen to contain the substring.
      pipeline = snippet =~ /(^|[\s(;])s>/ ? ' [pipeline stage]' : ''
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
    in_sched = false
    File.readlines(fiber_file).each do |l|
      s = l.strip
      next if s.empty? || s.start_with?('#') && !s.include?('per-scheduler')
      if s.include?('per-scheduler')
        in_sched = true
        next
      end
      if in_sched
        f = s.split
        next if f.size < 2
        sched_rows << { idx: f[0].to_i, runs: f[1].to_i } if f[0] =~ /\A\d+\z/
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
      end
      puts ""
    end
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
    locks = rows.map do |l|
      f = l.split
      # Columns: addr acquires contended total_wait max_wait total_hold max_hold
      #          read_acquires read_contended read_total_wait read_max_wait
      next nil if f.size < 11
      {
        addr: f[0], acquires: f[1].to_i, contended: f[2].to_i,
        total_wait_ns: f[3].to_i, max_wait_ns: f[4].to_i,
        total_hold_ns: f[5].to_i, max_hold_ns: f[6].to_i,
        read_acquires: f[7].to_i, read_contended: f[8].to_i,
        read_total_wait_ns: f[9].to_i, read_max_wait_ns: f[10].to_i,
      }
    end.compact.reject { |c| c[:acquires] == 0 && c[:read_acquires] == 0 }
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
      diagnosis =
        if is_mvcc_fit
          mvcc_candidates << l
          "read-heavy (#{read_pct}%) + contended → try @shared:versioned"
        elsif cont_pct >= 20 && avg_hold > 1_000_000
          "hot lock + long hold — break up the critical section"
        elsif cont_pct >= 20
          "contended — consider @shared:versioned (if read-heavy) or finer-grained locking"
        elsif avg_hold > 1_000_000
          "long critical section (#{(avg_hold / 1_000_000.0).round(1)}ms avg)"
        elsif total_acqs >= 100_000
          "hot lock (very frequent; low overhead but possible bottleneck)"
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
      puts "  `WITH SNAPSHOT x AS MUTABLE v { ... } ON Conflict RAISE` (or"
      puts "  RETRY(N) THEN ...). See docs/mvcc.md."
    end
    puts ""
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
    cells = rows.map do |l|
      f = l.split
      next nil if f.size < 6
      {
        addr: f[0], struct_size: f[1].to_i, reads: f[2].to_i,
        commits: f[3].to_i, retries: f[4].to_i,
        update_failures: f[5].to_i,
      }
    end.compact.reject { |c| c[:reads] == 0 && c[:commits] == 0 }
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
      puts "  { ... } ON Conflict RAISE` with `WITH EXCLUSIVE x AS v"
      puts "  { ... }`. See docs/mvcc.md."
    end

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
end
