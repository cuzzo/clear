require "sorbet-runtime"

require_relative 'pprof'

# Converts the text-format profile data emitted by `clear profile`
# into pprof's gzipped protobuf format. Each runtime profile becomes
# one `.pb.gz` file in the same `.profile/` dir, viewable via:
#
#   pprof -http=:8080 ./<binary> <profile_dir>/heap.pb.gz
#   pprof -top -alloc_space <profile_dir>/heap.pb.gz
#   pprof -base before/heap.pb.gz after/heap.pb.gz
#
# The converters share an `addr2line` resolver so call-site addresses
# show up in pprof as proper function names + CLEAR source lines (via
# the `// CLR:N` markers the transpiler emits into transpiled.zig).
module PprofConverter
  extend T::Sig

  module_function

  # Run all available converters for a `.profile/` directory. Returns
  # a hash of {name => path} for files actually written. Missing input
  # files are silently skipped.
  def convert_all(profile_dir)
    return {} unless profile_dir && Dir.exist?(profile_dir)

    binary = profile_dir.chomp('/').sub(/\.profile$/, '')
    binary = nil unless File.exist?(binary.to_s)

    out = {}
    if (path = convert_alloc(profile_dir, binary))
      out[:heap] = path
    end
    if (path = convert_locks(profile_dir, binary))
      out[:lock] = path
    end
    if (path = convert_mvcc(profile_dir, binary))
      out[:mvcc] = path
    end
    if (path = convert_channels(profile_dir, binary))
      out[:channels] = path
    end
    if (path = convert_perf(profile_dir, binary))
      out[:cpu] = path
    end
    out
  end

  # ── channels.txt → channels.pb.gz ─────────────────────────────────
  # Channel telemetry has no call site — channels are identified by a
  # registry id, not an address. We emit one Sample per registered
  # channel, with synthetic Function names like `channel#7` so pprof's
  # views show the per-channel breakdown with stable identifiers.
  # Sample columns: pushes / pops / push_blocked / pop_blocked /
  # max_depth (capacity travels as a label).
  def convert_channels(profile_dir, binary)
    src = File.join(profile_dir, 'channels.txt')
    return nil unless File.exist?(src)

    rows = parse_tabbed_columns(src, 7).map do |f|
      f = f.first(7)  # ignore any future trailing columns
      {
        id: f[0].to_i,
        pushes: f[1].to_i, pops: f[2].to_i,
        push_blocked: f[3].to_i, pop_blocked: f[4].to_i,
        max_depth: f[5].to_i, capacity: f[6].to_i,
      }
    end.reject { |c| c[:pushes].zero? && c[:pops].zero? }
    return nil if rows.empty?

    pb = Pprof::Profile.new
    pb.add_mapping(binary: binary.to_s) if binary
    pb.add_sample_type('pushes',       'count')
    pb.add_sample_type('pops',         'count')
    pb.add_sample_type('push_blocked', 'count')
    pb.add_sample_type('pop_blocked',  'count')
    pb.add_sample_type('max_depth',    'count')
    pb.set_period_type('operations', 'count', 1)
    pb.default_sample_type = 'pushes'

    rows.each do |r|
      name = "channel##{r[:id]}"
      fid = pb.add_function(name: name, filename: '', system_name: name)
      lid = pb.add_location(function_id: fid, line: 0, address: r[:id])
      pb.add_sample(
        [lid],
        [r[:pushes], r[:pops], r[:push_blocked], r[:pop_blocked], r[:max_depth]],
        capacity: r[:capacity], id: r[:id]
      )
    end

    out = File.join(profile_dir, 'channels.pb.gz')
    pb.write_gzip(out)
    out
  end

  # ── alloc.txt → heap.pb.gz ────────────────────────────────────────
  # Emits four sample-type columns matching Go's heap profile so the
  # standard pprof flags (-alloc_space / -alloc_objects /
  # -inuse_space / -inuse_objects) all work out of the box.
  #
  #   alloc_objects (count)  = total allocations at this site
  #   alloc_space   (bytes)  = total bytes allocated at this site
  #   inuse_objects (count)  = currently-live objects (allocs - frees)
  #   inuse_space   (bytes)  = currently-live bytes  (bytes - free_bytes)
  def convert_alloc(profile_dir, binary)
    src = File.join(profile_dir, 'alloc.txt')
    return nil unless File.exist?(src)

    # Each site's first column is now a comma-separated leaf-first
    # stack trace (alloc-profile v2). v1 single-addr files still parse
    # because `split(',')` on a no-comma string returns a one-element
    # array.
    sites = parse_columns(src, 6).map do |f|
      addrs = f[0].split(',')
      {
        addrs: addrs,
        allocs: f[1].to_i,
        bytes: f[2].to_i,
        frees: f[3].to_i,
        free_bytes: f[4].to_i,
        live: f[5].to_i,
      }
    end
    return nil if sites.empty?

    all_addrs = sites.flat_map { |s| s[:addrs] }.uniq
    resolved = resolve_addrs(all_addrs, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_mapping(binary: binary.to_s) if binary
    pb.add_sample_type('alloc_objects', 'count')
    pb.add_sample_type('alloc_space',   'bytes')
    pb.add_sample_type('inuse_objects', 'count')
    pb.add_sample_type('inuse_space',   'bytes')
    pb.set_period_type('space', 'bytes', 1)
    pb.default_sample_type = 'alloc_space'

    # One Location per unique address, reused across samples whose
    # traces share that frame. Saves a lot of bytes on hot leaves
    # like `entryWrapper` that appear in every trace.
    location_ids = build_location_index(pb, all_addrs, resolved, profile_dir)

    sites.each do |s|
      stack = s[:addrs].map { |a| location_ids[a] }
      pb.add_sample(
        stack,
        [
          s[:allocs],
          s[:bytes],
          [s[:allocs] - s[:frees], 0].max,
          [s[:bytes] - s[:free_bytes], 0].max,
        ],
        addr: s[:addrs].first
      )
    end

    out = File.join(profile_dir, 'heap.pb.gz')
    pb.write_gzip(out)
    out
  end

  # Pre-build one Location per unique address so multi-frame samples
  # can share frames. Returns { hex_addr => location_id }.
  def build_location_index(pb, addrs, resolved, profile_dir)
    addrs.each_with_object({}) do |addr, idx|
      r = resolved[addr] || {}
      func = r[:func] || addr
      file = r[:file] || ''
      # User-zig frames get clear_line into source.cht; runtime/stdlib
      # frames get the Zig line itself, with their own filename so
      # pprof -list resolves to the right file.
      line = r[:is_user_zig] ? (r[:clear_line] || 0) : extract_zig_line(file)
      filename = clear_source_path(profile_dir, file, is_user_zig: r[:is_user_zig])
      fid = pb.add_function(name: func, filename: filename, system_name: r[:func] || func)
      idx[addr] = pb.add_location(function_id: fid, line: line, address: parse_addr(addr))
    end
  end

  # addr2line emits `path:line` for each address. Pull the trailing
  # line number; returns 0 if absent.
  sig { params(addr2line_file: String).returns(Integer) }
  def extract_zig_line(addr2line_file)
    return 0 unless addr2line_file
    addr2line_file =~ /:(\d+)\b/ ? Regexp.last_match(1).to_i : 0
  end

  # ── locks.txt → lock.pb.gz ────────────────────────────────────────
  # Mirrors Go's mutex profile shape (contention count + delay ns).
  # We add hold-time columns since the runtime tracks both, and the
  # split read/write columns so the pprof user can drill into either.
  def convert_locks(profile_dir, binary)
    src = File.join(profile_dir, 'locks.txt')
    return nil unless File.exist?(src)

    # lock-profile v3 adds an optional 12th column for the caller
    # trace ('-' = empty; comma-separated leaf-first when present).
    # We tab-split because the trace field can contain commas; older
    # whitespace-only files still parse via the fallback split.
    locks = parse_tabbed_columns(src, 11).map do |f|
      trace_field = f[11]
      caller_trace = (trace_field.nil? || trace_field == '-') ? [] : trace_field.split(',')
      {
        addr: f[0], acquires: f[1].to_i, contended: f[2].to_i,
        total_wait_ns: f[3].to_i, max_wait_ns: f[4].to_i,
        total_hold_ns: f[5].to_i, max_hold_ns: f[6].to_i,
        read_acquires: f[7].to_i, read_contended: f[8].to_i,
        read_total_wait_ns: f[9].to_i, read_max_wait_ns: f[10].to_i,
        caller_trace: caller_trace,
      }
    end.reject { |l| l[:acquires].zero? && l[:read_acquires].zero? }
    return nil if locks.empty?

    # Each row already carries its own (lock, caller-trace) identity;
    # we keep them as-is so pprof renders one Sample per row. The
    # leaf of every trace is the lock pointer, then the caller frames.
    all_addrs = locks.flat_map { |l| [l[:addr]] + l[:caller_trace] }.uniq
    resolved = resolve_addrs(all_addrs, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_mapping(binary: binary.to_s) if binary
    pb.add_sample_type('contentions',  'count')
    pb.add_sample_type('delay',        'nanoseconds')
    pb.add_sample_type('hold',         'nanoseconds')
    pb.add_sample_type('acquisitions', 'count')
    pb.set_period_type('contentions', 'count', 1)
    pb.default_sample_type = 'delay'

    location_ids = build_location_index(pb, all_addrs, resolved, profile_dir)

    locks.each do |l|
      stack = [location_ids[l[:addr]]] +
              l[:caller_trace].map { |a| location_ids[a] }.compact
      pb.add_sample(
        stack,
        [
          l[:contended] + l[:read_contended],
          l[:total_wait_ns] + l[:read_total_wait_ns],
          l[:total_hold_ns],
          l[:acquires] + l[:read_acquires],
        ],
        kind: l[:read_acquires] > l[:acquires] ? 'read' : 'write',
        addr: l[:addr]
      )
    end

    out = File.join(profile_dir, 'lock.pb.gz')
    pb.write_gzip(out)
    out
  end

  # ── mvcc.txt → mvcc.pb.gz ─────────────────────────────────────────
  # MVCC cells track read/commit/retry counts and per-cell struct size.
  # Reported columns let the pprof user spot COW-thrash (high commits
  # x large struct), retry storms, and read-heavy cells worth keeping.
  def convert_mvcc(profile_dir, binary)
    src = File.join(profile_dir, 'mvcc.txt')
    return nil unless File.exist?(src)

    # mvcc-profile v2 adds an optional 8th column for the caller
    # trace; same shape as lock-profile v3.
    cells = parse_tabbed_columns(src, 6).map do |f|
      trace_field = f[7]
      caller_trace = (trace_field.nil? || trace_field == '-') ? [] : trace_field.split(',')
      {
        addr: f[0], struct_size: f[1].to_i, reads: f[2].to_i,
        commits: f[3].to_i, retries: f[4].to_i,
        update_failures: f[5].to_i,
        multi_commits: (f[6] || 0).to_i,
        caller_trace: caller_trace,
      }
    end.reject { |c| c[:reads].zero? && c[:commits].zero? }
    return nil if cells.empty?

    all_addrs = cells.flat_map { |c| [c[:addr]] + c[:caller_trace] }.uniq
    resolved = resolve_addrs(all_addrs, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_mapping(binary: binary.to_s) if binary
    pb.add_sample_type('reads',     'count')
    pb.add_sample_type('commits',   'count')
    pb.add_sample_type('retries',   'count')
    pb.add_sample_type('cow_bytes', 'bytes')
    pb.set_period_type('operations', 'count', 1)
    pb.default_sample_type = 'commits'

    location_ids = build_location_index(pb, all_addrs, resolved, profile_dir)

    cells.each do |c|
      stack = [location_ids[c[:addr]]] +
              c[:caller_trace].map { |a| location_ids[a] }.compact
      cow_bytes = c[:struct_size] * (c[:commits] + c[:retries])
      pb.add_sample(
        stack,
        [c[:reads], c[:commits], c[:retries], cow_bytes],
        struct_size: c[:struct_size],
        addr: c[:addr]
      )
    end

    out = File.join(profile_dir, 'mvcc.pb.gz')
    pb.write_gzip(out)
    out
  end

  # ── perf.data → cpu.pb.gz ─────────────────────────────────────────
  # Defers to Google's `perf_to_profile` (the canonical converter,
  # `go install github.com/google/perf_data_converter/src/cmd/perf_to_profile`).
  # If the tool is not on PATH we leave perf.data in place and return
  # nil; the caller surfaces a one-line install hint.
  def convert_perf(profile_dir, _binary)
    src = File.join(profile_dir, 'perf.data')
    return nil unless File.exist?(src)
    return nil unless system('which perf_to_profile > /dev/null 2>&1')

    out = File.join(profile_dir, 'cpu.pb.gz')
    ok = system('perf_to_profile', '-i', src, '-o', out, %i[out err] => '/dev/null')
    return nil unless ok && File.exist?(out)
    out
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Read whitespace-separated columns from a profile text file,
  # skipping `#` comment lines and blank lines. Filters rows that are
  # shorter than `min_cols` (header lines, partial dumps).
  def parse_columns(path, min_cols)
    File.readlines(path).each_with_object([]) do |line, acc|
      next if line.start_with?('#') || line.strip.empty?
      f = line.strip.split
      acc << f if f.size >= min_cols
    end
  end

  # lock-profile and mvcc-profile use TAB separators so the optional
  # caller_trace field can carry commas without a column-count
  # ambiguity. Older single-tab-or-whitespace files still parse via
  # the fallback. Filters rows shorter than `min_cols`.
  def parse_tabbed_columns(path, min_cols)
    File.readlines(path).each_with_object([]) do |line, acc|
      next if line.start_with?('#') || line.strip.empty?
      f = line.split("\t").map(&:strip)
      f = line.strip.split if f.size < min_cols
      acc << f if f.size >= min_cols
    end
  end

  # Resolve a batch of hex addresses to {func, file, clear_line}.
  # Mirrors `Doctor.section_heap`'s resolver: addr2line gives us the
  # Zig source line; we walk back to the nearest `// CLR:N` marker
  # the transpiler emits to recover the user-facing CLEAR source line.
  #
  # Only assign `clear_line` when the resolved Zig file is the user's
  # transpiled.zig — otherwise the address was in runtime/stdlib Zig
  # code where CLR markers don't exist, and we'd misattribute by
  # walking back through transpiled.zig anyway. (Repro: `pprof -list
  # entryWrapper` showed it pointing at random source.cht lines.)
  def resolve_addrs(addrs, binary, profile_dir)
    return {} if addrs.empty? || binary.nil?
    raw = IO.popen(['addr2line', '-e', binary, '-f'] + addrs, err: '/dev/null', &:read)
    lines_out = raw.split("\n")
    zig_path = File.join(profile_dir, 'transpiled.zig')
    zig_lines = File.exist?(zig_path) ? File.readlines(zig_path) : nil

    out = {}
    addrs.each_with_index do |addr, i|
      func = lines_out[i * 2]&.strip || '?'
      file = lines_out[i * 2 + 1]&.strip || '?'
      func = func.sub(/.*\./, '').sub(/__anon_\d+/, '')
      clear_line = nil
      is_user_zig = zig_lines && file_is_transpiled_zig?(file, zig_path)
      if is_user_zig && file =~ /:(\d+)\b/
        zig_line = $1.to_i
        (zig_line - 1).downto(0) do |li|
          break if li.negative? || li >= zig_lines.size
          if zig_lines[li] =~ %r{// CLR:(\d+)}
            clear_line = $1.to_i
            break
          end
        end
      end
      out[addr] = { func: func, file: file, clear_line: clear_line, is_user_zig: !!is_user_zig }
    end
    out
  end

  # True if addr2line's `<file>:<line>` came from the user's
  # transpiled CLEAR file (where CLR markers exist), not from
  # runtime/stdlib. The build target's actual compile-time filename
  # is `._clear_tmp_<name>.zig`, copied to `<profile_dir>/
  # transpiled.zig` for inspection. addr2line emits the build-time
  # path, so we match the basename pattern that signals user code.
  # addr2line may append "(discriminator N)" or other metadata after
  # the line number; strip that before extracting the basename.
  def file_is_transpiled_zig?(addr2line_file, _zig_path)
    return false unless addr2line_file
    bare = addr2line_file.sub(/:\d+\b.*\z/, '')
    File.basename(bare).match?(/\A\._clear_tmp_.*\.zig\z/)
  end

  sig { params(s: String).returns(Integer) }
  def parse_addr(s)
    s.start_with?('0x') ? s.to_i(16) : s.to_i
  end

  # Pick the source file pprof's `list` view should show for this
  # function. User-code (transpiled.zig with CLR markers) -> the
  # original .cht source. Runtime/stdlib code -> the addr2line file
  # path (which is a real .zig file pprof can read). Without this
  # split, runtime functions like `entryWrapper` rendered against
  # arbitrary .cht line numbers, badly misleading the user.
  def clear_source_path(profile_dir, addr2line_file, is_user_zig: nil)
    if is_user_zig.nil?
      cht = File.join(profile_dir, 'source.cht')
      return cht if File.exist?(cht)
      return addr2line_file.to_s.sub(/:\d+\z/, '')
    end
    if is_user_zig
      cht = File.join(profile_dir, 'source.cht')
      return cht if File.exist?(cht)
    end
    addr2line_file.to_s.sub(/:\d+\z/, '')
  end
end
