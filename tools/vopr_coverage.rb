#!/usr/bin/env ruby
# frozen_string_literal: true

# VOPR coverage gap report.
#
# Cross-references VOPR-relevant sites in zig/runtime/ + zig/lib/
# against a kcov Cobertura XML produced by `zig build coverage-vopr
# -Dcoverage-vopr`. Reports VOPR-eligible sites that no VOPR test
# exercises.
#
# A site is "VOPR-relevant" if its behavior is non-deterministic
# under real OS execution but should become deterministic under a
# VOPR simulator: time reads, randomness, network IO, filesystem IO,
# or marked retry loops. Atomic-op interleavings are NOT VOPR-relevant
# -- those belong to Loom (see loom_atomic_coverage.rb).
#
# Categories:
#   time      -- monotonic/wall-clock reads (clock_gettime, milliTimestamp,
#                std.time.Instant.now, std.time.Timer)
#   random    -- PRNG / OS entropy reads (std.crypto.random, std.Random,
#                getrandom)
#   net_io    -- network syscalls (recv/send/connect/accept/bind/listen/
#                socket; both raw posix and direct IoUring)
#   fs_io     -- filesystem syscalls (open/read/write/close/fsync/unlink/
#                fstat; both raw posix and direct IoUring)
#   ring_io   -- io_uring submissions through the runtime's RingType seam
#                (self.ring.X(...)). Already shimmed by SimRing under VOPR.
#                Reported separately so leaks-vs-shimmed is visible.
#   retry     -- explicit `// VOPR-START-RETRY: ...` markers. Each marker
#                line is a single site whose hit count tells us the retry
#                path was entered.
#
# Usage:
#   ruby src/tools/vopr_coverage.rb [options]

require "optparse"
require "rexml/document"

module VoprCoverage
  module_function

  COMMENT_RE = %r{//.*\z}m

  # Source-comment exclusion markers, mirroring the loom convention.
  # Use sparingly: a region inside VOPR-EXCLUDE means "by design not
  # driven by VOPR" (e.g. panic handlers reading time, build-time
  # config dumps).
  EXCLUDE_BEGIN_RE = %r{//\s*VOPR-EXCLUDE-BEGIN\b}
  EXCLUDE_END_RE   = %r{//\s*VOPR-EXCLUDE-END\b}

  RETRY_BEGIN_RE = %r{//\s*VOPR-START-RETRY\b}
  RETRY_END_RE   = %r{//\s*VOPR-END-RETRY\b}
  # Single-line marker for compact one-statement retry loops (e.g.
  # `while (lock.swap(1) == 1) yield(); // VOPR-RETRY`). Treated as a
  # retry site on its own line.
  RETRY_SINGLE_RE = %r{//\s*VOPR-RETRY\b}

  # Files out of scope by default:
  #   *-test.zig        — unit tests
  #   vopr*.zig         — VOPR shim infrastructure
  #   loom*.zig         — Loom shim infrastructure
  #   *-loom.zig        — loom test impl side
  #   *-vopr.zig        — VOPR test impl side
  #   *-bench.zig       — benchmarks
  #   size_check.zig    — standalone build-time size-print exe
  #   runtime-header.zig — transpiler-emitted runtime, not unit-testable
  TEST_FILE_RE = /\A(?:.*-test|vopr[\w-]*|loom[\w-]*|[\w-]+-loom|[\w-]+-vopr|[\w-]+-bench|size_check|runtime-header)\.zig\z/

  # Pattern definitions per category.  Each entry is a literal substring
  # OR_ELSE a Regexp.  All matched against the line WITH comments stripped
  # (so commented-out usages don't count) but BEFORE retry-marker
  # stripping (so a marker on the same line as a call still counts as
  # both a marker and a call).
  PATTERNS = {
    time: [
      /\bstd\.time\.milliTimestamp\s*\(/,
      /\bstd\.time\.nanoTimestamp\s*\(/,
      /\bstd\.time\.microTimestamp\s*\(/,
      /\bstd\.time\.Instant\.now\s*\(/,
      /\bstd\.time\.Timer\b/,
      /\bclock_gettime\s*\(/,
      /\bmilliTimestamp\s*\(/, # bare alias used in scheduler.zig
      /\bnanoTimestamp\s*\(/
    ].freeze,
    random: [
      /\bstd\.crypto\.random\b/,
      /\bstd\.Random\b/,
      /\bstd\.rand\b/,
      /\bgetrandom\s*\(/,
      /\bRandom\.DefaultPrng\b/
    ].freeze,
    net_io: [
      # Raw posix net syscalls -- a leak: bypasses any simulator.
      /\bposix\.(?:recv|send|connect|accept|bind|listen|socket|recvfrom|sendto|recvmsg|sendmsg|getsockopt|setsockopt|shutdown)\s*\(/,
      /\bstd\.posix\.(?:recv|send|connect|accept|bind|listen|socket|recvfrom|sendto|recvmsg|sendmsg|getsockopt|setsockopt|shutdown)\s*\(/,
      /\bstd\.net\.\w+/,
      # Direct IoUring net ops (not via RingType seam).
      /\blinux\.IoUring\.(?:recv|send|accept|connect)\s*\(/
    ].freeze,
    fs_io: [
      /\bposix\.(?:open|openat|read|write|pread|pwrite|close|fsync|fdatasync|unlink|unlinkat|rename|renameat|stat|fstat|lstat|lseek|mkdir|rmdir|readlink|symlink|chdir|truncate|ftruncate)\s*\(/,
      /\bstd\.posix\.(?:open|openat|read|write|pread|pwrite|close|fsync|fdatasync|unlink|unlinkat|rename|renameat|stat|fstat|lstat|lseek|mkdir|rmdir|readlink|symlink|chdir|truncate|ftruncate)\s*\(/,
      /\bstd\.fs\.\w+/,
      /\blinux\.IoUring\.(?:read|write|fsync|openat|close)\s*\(/
    ].freeze,
    ring_io: [
      # The runtime's RingType seam.  SimRing-shimmed under VOPR.  A site
      # here is GOOD (it's already simulator-friendly); we report it to
      # show the simulator's reach.
      /\bself\.ring\.(?:read|write|recv|send|accept|connect|fsync|poll_add|poll_remove|cancel)\s*\(/,
      /\bring\.(?:read|write|recv|send|accept|connect|fsync|poll_add|poll_remove|cancel)\s*\(/
    ].freeze
  }.freeze

  # Compute the category for a stripped source line, if any.  Returns
  # nil for lines that match no pattern.  A line that matches multiple
  # categories is rare in practice; we pick the first match in the
  # order time / random / net_io / fs_io / ring_io.
  def categorize(stripped)
    PATTERNS.each do |cat, patterns|
      patterns.each do |re|
        return cat if stripped.match?(re)
      end
    end
    nil
  end

  # Retry ranges are intentionally wider than a single loop because the
  # interesting outcome is often handled immediately after the retry.  Do
  # not turn punctuation-only scope boundaries into hazards: Zig/LLVM emits
  # no line-table entry for them, so they can never acquire a kcov hit.
  def executable_retry_line?(stripped)
    code = stripped.strip
    return false if code.empty?
    return false if code.match?(/\A[{};,]+\z/)
    return false if code.match?(/\A}\s*else\s*{\z/)

    true
  end

  def parse_cobertura(path)
    doc = REXML::Document.new(File.read(path))
    hits = Hash.new { |h, k| h[k] = {} }
    doc.elements.each("//class") do |cls|
      filename = cls.attribute("filename")&.value
      next unless filename
      cls.elements.each("lines/line") do |ln|
        no = ln.attribute("number")&.value&.to_i
        ct = ln.attribute("hits")&.value&.to_i
        next unless no && ct
        hits[filename][no] = ct
      end
    end
    hits
  end

  def lookup_file_hits(hits, scanned_path)
    return hits[scanned_path] if hits.key?(scanned_path)
    parts = scanned_path.split("/")
    parts.length.times do |i|
      key = parts[i..].join("/")
      return hits[key] if hits.key?(key)
    end
    nil
  end

  def scan_sites(scope_dirs, repo_root, include_tests: false)
    sites = []
    scope_dirs.each do |dir|
      abs_dir = File.expand_path(dir, repo_root)
      Dir.glob(File.join(abs_dir, "**/*.zig")).sort.each do |abs_path|
        rel = abs_path.sub(/\A#{Regexp.escape(repo_root)}\/?/, "")
        next if !include_tests && File.basename(rel).match?(TEST_FILE_RE)

        in_exclude = false
        retry_depth = 0
        File.foreach(abs_path).with_index(1) do |line, no|
          if line.match?(EXCLUDE_BEGIN_RE)
            in_exclude = true
            next
          end
          if line.match?(EXCLUDE_END_RE)
            in_exclude = false
            next
          end
          next if in_exclude

          # Retry markers: the START line itself is a retry site (one
          # per pair). The END line just resets state. Ranges may
          # contain other VOPR-relevant calls; those still register
          # under their own categories.
          if line.match?(RETRY_BEGIN_RE)
            sites << { file: rel, line: no, source: line.rstrip, category: :retry }
            retry_depth += 1
            next
          end
          if line.match?(RETRY_END_RE)
            if retry_depth.zero?
              warn "warning: #{rel}:#{no}: VOPR-END-RETRY without matching VOPR-START-RETRY"
            else
              retry_depth -= 1
            end
            next
          end
          # Single-line marker -- retry site is the line itself.
          if line.match?(RETRY_SINGLE_RE)
            sites << { file: rel, line: no, source: line.rstrip, category: :retry }
            next
          end

          stripped = line.sub(COMMENT_RE, "")
          cat = categorize(stripped)
          if cat
            sites << { file: rel, line: no, source: line.rstrip, category: cat }
          elsif retry_depth.positive? && executable_retry_line?(stripped)
            # Inside a VOPR-START-RETRY block: every executable line is
            # a retry-body site. Tracks whether the loop body ran (vs
            # just the loop header). Blank and punctuation-only lines are
            # filtered here; executable sites absent from kcov's line table
            # are reported separately as DWARF-hidden.
            sites << { file: rel, line: no, source: line.rstrip, category: :retry_body }
          end
        end

        if in_exclude
          warn "warning: #{rel}: VOPR-EXCLUDE-BEGIN without matching VOPR-EXCLUDE-END"
        end
        if retry_depth.positive?
          warn "warning: #{rel}: #{retry_depth} VOPR-START-RETRY marker(s) without matching VOPR-END-RETRY"
        end
      end
    end
    sites
  end

  def correlate(sites, hits)
    file_hits = {}
    sites.map do |s|
      file_hits[s[:file]] ||= lookup_file_hits(hits, s[:file]) || nil
      fh = file_hits[s[:file]]
      file_loaded = !fh.nil?
      fh ||= {}
      hit_count = fh[s[:line]]
      # kcov only emits hit counts for instrumented (executable) lines.
      # A standalone `// VOPR-START-RETRY` comment has no hit count, so
      # attribute the marker to the FIRST instrumented line at-or-after
      # it. The next code line is the loop header (`while (...) {`),
      # which is what we actually want to know was reached.
      if hit_count.nil? && file_loaded && s[:category] == :retry
        keys = fh.keys
        following = keys.select { |k| k >= s[:line] }.min
        hit_count = fh[following] if following
      end
      dwarf_hidden = hit_count.nil? && file_loaded
      s.merge(hits: hit_count, dwarf_hidden: dwarf_hidden, file_loaded: file_loaded)
    end
  end

  def actionable_gap?(site)
    return false if site[:dwarf_hidden]

    site[:hits].nil? || site[:hits].zero?
  end

  CATEGORY_ORDER = %i[time random net_io fs_io ring_io retry retry_body].freeze

  CATEGORY_LABEL = {
    time:       "Time",
    random:     "Random",
    net_io:     "Network IO (raw)",
    fs_io:      "Filesystem IO (raw)",
    ring_io:    "io_uring (RingType seam)",
    retry:      "Retry markers",
    retry_body: "Retry body (lines inside marker blocks)"
  }.freeze

  def report(correlated, all:, summary_only:, only_category:)
    by_cat = correlated.group_by { |s| s[:category] }

    total_all = correlated.size
    covered_all = correlated.count { |s| s[:hits] && s[:hits] > 0 }
    hidden_all = correlated.count { |s| s[:dwarf_hidden] }
    observable_all = total_all - hidden_all

    unless summary_only
      CATEGORY_ORDER.each do |cat|
        next if only_category && cat != only_category
        rows = by_cat[cat] || []
        next if rows.empty?

        covered = rows.count { |s| s[:hits] && s[:hits] > 0 }
        hidden = rows.count { |s| s[:dwarf_hidden] }
        observable = rows.size - hidden
        puts "## #{CATEGORY_LABEL[cat]} (#{covered}/#{observable} observable, #{hidden} DWARF-hidden)"
        to_show = all ? rows : rows.reject { |s| s[:hits] && s[:hits] > 0 }
        to_show.sort_by { |s| [s[:file], s[:line]] }.each do |s|
          tag = if s[:hits].nil? && !s[:file_loaded]
                  "FILE NOT LOADED"
                elsif s[:hits].nil?
                  "DWARF-HIDDEN (ignored)"
                elsif s[:hits].zero?
                  "0 hits"
                else
                  "#{s[:hits]} hits"
                end
          puts "  #{s[:file]}:#{s[:line]}: [#{tag}] #{s[:source].strip}"
        end
        puts
      end
    end

    puts "Summary"
    puts "-------"
    CATEGORY_ORDER.each do |cat|
      rows = by_cat[cat] || []
      next if rows.empty?
      covered = rows.count { |s| s[:hits] && s[:hits] > 0 }
      hidden = rows.count { |s| s[:dwarf_hidden] }
      observable = rows.size - hidden
      pct = observable.zero? ? 100.0 : (covered.to_f / observable * 100)
      puts format("  %-26s %3d/%-3d (%5.1f%%), %3d DWARF-hidden", CATEGORY_LABEL[cat], covered, observable, pct, hidden)
    end
    pct_all = observable_all.zero? ? 100.0 : (covered_all.to_f / observable_all * 100)
    puts format("  %-26s %3d/%-3d (%5.1f%%), %3d DWARF-hidden", "TOTAL", covered_all, observable_all, pct_all, hidden_all)
  end

  def run(argv)
    opts = {
      coverage: "zig/zig-out/coverage-vopr/merged/kcov-merged/cobertura.xml",
      scope: "zig/runtime,zig/lib",
      all: false,
      summary_only: false,
      include_tests: false,
      only_category: nil
    }

    OptionParser.new do |o|
      o.banner = "Usage: ruby src/tools/vopr_coverage.rb [options]"
      o.on("--coverage PATH", "Cobertura XML path") { |v| opts[:coverage] = v }
      o.on("--scope DIRS", "Comma-separated dirs to scan") { |v| opts[:scope] = v }
      o.on("--all", "Print covered sites too") { opts[:all] = true }
      o.on("--summary-only", "Print totals only") { opts[:summary_only] = true }
      o.on("--include-tests", "Include sites in *-test.zig files") { opts[:include_tests] = true }
      o.on("--category CAT", "Only show one category (time|random|net_io|fs_io|ring_io|retry)") do |v|
        opts[:only_category] = v.to_sym
      end
      o.on("-h", "--help") do
        puts o
        exit 0
      end
    end.parse!(argv)

    repo_root = File.expand_path("..", __dir__)
    coverage_path = File.expand_path(opts[:coverage], repo_root)
    scope_dirs = opts[:scope].split(",").map(&:strip).reject(&:empty?)

    hits = if File.exist?(coverage_path)
             parse_cobertura(coverage_path)
           else
             warn "Cobertura XML not found: #{coverage_path}"
             warn "Generate it with: zig build coverage-vopr -Dcoverage-vopr"
             warn "Reporting site-scan only (all sites will show as LINE MISSING)."
             {}
           end
    sites = scan_sites(scope_dirs, repo_root, include_tests: opts[:include_tests])
    correlated = correlate(sites, hits)

    report(
      correlated,
      all: opts[:all],
      summary_only: opts[:summary_only],
      only_category: opts[:only_category]
    )

    uncovered = correlated.count { |s| actionable_gap?(s) }
    exit(uncovered.zero? ? 0 : 1)
  end
end

VoprCoverage.run(ARGV) if __FILE__ == $PROGRAM_NAME
