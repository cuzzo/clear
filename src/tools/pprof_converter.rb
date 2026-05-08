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
    if (path = convert_perf(profile_dir, binary))
      out[:cpu] = path
    end
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

    sites = parse_columns(src, 6).map do |f|
      {
        addr: f[0],
        allocs: f[1].to_i,
        bytes: f[2].to_i,
        frees: f[3].to_i,
        free_bytes: f[4].to_i,
        live: f[5].to_i,
      }
    end
    return nil if sites.empty?

    resolved = resolve_addrs(sites.map { |s| s[:addr] }, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_sample_type('alloc_objects', 'count')
    pb.add_sample_type('alloc_space',   'bytes')
    pb.add_sample_type('inuse_objects', 'count')
    pb.add_sample_type('inuse_space',   'bytes')
    pb.set_period_type('space', 'bytes', 1)
    pb.default_sample_type = 'alloc_space'

    sites.each do |s|
      r = resolved[s[:addr]] || {}
      func = r[:func] || s[:addr]
      file = r[:file] || ''
      line = r[:clear_line] || 0
      func_id = pb.add_function(name: func, filename: clear_source_path(profile_dir, file), system_name: r[:func] || func)
      loc_id  = pb.add_location(
        function_id: func_id,
        line: line,
        address: parse_addr(s[:addr]),
      )
      pb.add_sample(
        [loc_id],
        [
          s[:allocs],
          s[:bytes],
          [s[:allocs] - s[:frees], 0].max,
          [s[:bytes] - s[:free_bytes], 0].max,
        ],
        addr: s[:addr]
      )
    end

    out = File.join(profile_dir, 'heap.pb.gz')
    pb.write_gzip(out)
    out
  end

  # ── locks.txt → lock.pb.gz ────────────────────────────────────────
  # Mirrors Go's mutex profile shape (contention count + delay ns).
  # We add hold-time columns since the runtime tracks both, and the
  # split read/write columns so the pprof user can drill into either.
  def convert_locks(profile_dir, binary)
    src = File.join(profile_dir, 'locks.txt')
    return nil unless File.exist?(src)

    locks = parse_columns(src, 11).map do |f|
      {
        addr: f[0], acquires: f[1].to_i, contended: f[2].to_i,
        total_wait_ns: f[3].to_i, max_wait_ns: f[4].to_i,
        total_hold_ns: f[5].to_i, max_hold_ns: f[6].to_i,
        read_acquires: f[7].to_i, read_contended: f[8].to_i,
        read_total_wait_ns: f[9].to_i, read_max_wait_ns: f[10].to_i,
      }
    end.reject { |l| l[:acquires].zero? && l[:read_acquires].zero? }
    return nil if locks.empty?

    resolved = resolve_addrs(locks.map { |l| l[:addr] }, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_sample_type('contentions',  'count')
    pb.add_sample_type('delay',        'nanoseconds')
    pb.add_sample_type('hold',         'nanoseconds')
    pb.add_sample_type('acquisitions', 'count')
    pb.set_period_type('contentions', 'count', 1)
    pb.default_sample_type = 'delay'

    locks.each do |l|
      r = resolved[l[:addr]] || {}
      func = r[:func] || l[:addr]
      func_id = pb.add_function(name: func, filename: clear_source_path(profile_dir, r[:file]))
      loc_id  = pb.add_location(
        function_id: func_id,
        line: r[:clear_line] || 0,
        address: parse_addr(l[:addr]),
      )
      pb.add_sample(
        [loc_id],
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

    cells = parse_columns(src, 6).map do |f|
      {
        addr: f[0], struct_size: f[1].to_i, reads: f[2].to_i,
        commits: f[3].to_i, retries: f[4].to_i,
        update_failures: f[5].to_i,
        multi_commits: (f[6] || 0).to_i,
      }
    end.reject { |c| c[:reads].zero? && c[:commits].zero? }
    return nil if cells.empty?

    resolved = resolve_addrs(cells.map { |c| c[:addr] }, binary, profile_dir)

    pb = Pprof::Profile.new
    pb.add_sample_type('reads',     'count')
    pb.add_sample_type('commits',   'count')
    pb.add_sample_type('retries',   'count')
    pb.add_sample_type('cow_bytes', 'bytes')
    pb.set_period_type('operations', 'count', 1)
    pb.default_sample_type = 'commits'

    cells.each do |c|
      r = resolved[c[:addr]] || {}
      func = r[:func] || c[:addr]
      func_id = pb.add_function(name: func, filename: clear_source_path(profile_dir, r[:file]))
      loc_id  = pb.add_location(
        function_id: func_id,
        line: r[:clear_line] || 0,
        address: parse_addr(c[:addr]),
      )
      cow_bytes = c[:struct_size] * (c[:commits] + c[:retries])
      pb.add_sample(
        [loc_id],
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

  # Resolve a batch of hex addresses to {func, file, clear_line}.
  # Mirrors `Doctor.section_heap`'s resolver: addr2line gives us the
  # Zig source line; we walk back to the nearest `// CLR:N` marker
  # the transpiler emits to recover the user-facing CLEAR source line.
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
      if zig_lines && file =~ /:(\d+)/
        zig_line = $1.to_i
        (zig_line - 1).downto(0) do |li|
          break if li.negative? || li >= zig_lines.size
          if zig_lines[li] =~ %r{// CLR:(\d+)}
            clear_line = $1.to_i
            break
          end
        end
      end
      out[addr] = { func: func, file: file, clear_line: clear_line }
    end
    out
  end

  def parse_addr(s)
    s.start_with?('0x') ? s.to_i(16) : s.to_i
  end

  # Prefer the original `.cht` source path so pprof's `list` view
  # shows CLEAR code, falling back to whatever addr2line returned.
  def clear_source_path(profile_dir, addr2line_file)
    cht = File.join(profile_dir, 'source.cht')
    return cht if File.exist?(cht)
    addr2line_file.to_s
  end
end
