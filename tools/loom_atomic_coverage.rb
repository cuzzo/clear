#!/usr/bin/env ruby
# frozen_string_literal: true

# Loom atomic-coverage gap report.
#
# Cross-references atomic operation sites in zig/runtime/ and zig/lib/
# against a kcov Cobertura XML produced by `zig build coverage-loom
# -Dcoverage-loom`. Reports atomic sites Loom never reached.
#
# Usage:
#   ruby src/tools/loom_atomic_coverage.rb [options]
#
# Options:
#   --coverage PATH   Cobertura XML (default: zig/zig-out/coverage-loom/merged/kcov-merged/cobertura.xml)
#   --scope DIRS      Comma-separated dirs to scan (default: zig/runtime,zig/lib)
#   --all             Print covered sites too, not just uncovered
#   --summary-only    Print totals only, no per-line list
#   --help

require "optparse"
require "rexml/document"

module LoomAtomicCoverage
  module_function

  # Atomic OPERATIONS only -- not type annotations, field declarations,
  # or continuation lines of multi-line atomic calls. The latter is
  # important: a multi-line cmpxchgWeak with `.release,` and `.monotonic`
  # on their own continuation lines must be attributed to the FIRST
  # line of the call (the line with the function name), because kcov
  # only assigns hit counts to that line in DWARF.
  #
  # Categories:
  #   1. Builtin intrinsics (always atomic ops).
  #   2. Method-call lines whose method name is on a known atomic
  #      method list. Single-line calls match `.method(...)`; multi-line
  #      calls match `.method(` at end of line. Continuation lines that
  #      contain only the ordering arg (e.g. `.monotonic,`) are NOT
  #      matched, so they don't show up as spurious 0-hit sites.
  ATOMIC_METHODS = %w[
    load store swap
    fetchAdd fetchSub fetchOr fetchAnd fetchXor fetchMin fetchMax
    cmpxchgStrong cmpxchgWeak compareExchange compareExchangeStrong compareExchangeWeak
    rmw
  ].freeze
  ATOMIC_METHOD_RE = /\.(?:#{ATOMIC_METHODS.join('|')})\s*\(/

  ATOMIC_PATTERNS = [
    /@atomic\w*\s*\(/,    # @atomicLoad, @atomicStore, @atomicRmw
    /@cmpxchg\w*\s*\(/,   # @cmpxchgStrong, @cmpxchgWeak
    /@fence\s*\(/,        # memory fences
    ATOMIC_METHOD_RE      # method-call line for atomic ops
  ].freeze

  # Comments shouldn't count as atomic sites. Strip line comments before
  # matching. Multi-line block comments don't exist in Zig.
  COMMENT_RE = %r{//.*\z}m

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

  # Test files use atomics to *exercise* the runtime; their own atomic
  # sites aren't candidates for Loom coverage. Excluded by default.
  # Also excluded: VOPR/Loom simulator + harness files themselves
  # (vopr*.zig, *-loom.zig) -- atomics there are test infrastructure,
  # not production runtime that Loom should be exercising.
  TEST_FILE_RE = /\A(?:.*-test|vopr[\w-]*|[\w-]+-loom)\.zig\z/

  # Source-comment markers for code regions that are by-design unreachable
  # under the loom harness (e.g. thread-only paths guarded by
  # `if (sched_opt == null)`, comptime-shadowed wrappers). Atomic ops
  # inside such a region are not gaps -- they belong to a different
  # testing regime. The line-state-machine is intentionally dumb: no
  # brace tracking, no Zig-syntax knowledge. Author owns marker accuracy.
  EXCLUDE_BEGIN_RE = %r{//\s*LOOM-EXCLUDE-BEGIN\b}
  EXCLUDE_END_RE   = %r{//\s*LOOM-EXCLUDE-END\b}

  def scan_atomic_sites(scope_dirs, repo_root, include_tests: false)
    sites = []
    scope_dirs.each do |dir|
      abs_dir = File.expand_path(dir, repo_root)
      Dir.glob(File.join(abs_dir, "**/*.zig")).sort.each do |abs_path|
        rel = abs_path.sub(/\A#{Regexp.escape(repo_root)}\/?/, "")
        next if !include_tests && File.basename(rel).match?(TEST_FILE_RE)

        in_exclude = false
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

          stripped = line.sub(COMMENT_RE, "")
          next unless ATOMIC_PATTERNS.any? { |re| stripped.match?(re) }

          sites << { file: rel, line: no, source: line.rstrip }
        end

        if in_exclude
          warn "warning: #{rel}: LOOM-EXCLUDE-BEGIN without matching LOOM-EXCLUDE-END"
        end
      end
    end
    sites
  end

  # kcov's --strip-path can leave paths in different forms across
  # versions ("zig/lib/atomic.zig" vs "lib/atomic.zig"). Look up a
  # scanned file in the hits map by trying progressively shorter
  # path-suffixes until one matches.
  def lookup_file_hits(hits, scanned_path)
    return hits[scanned_path] if hits.key?(scanned_path)

    parts = scanned_path.split("/")
    parts.length.times do |i|
      key = parts[i..].join("/")
      return hits[key] if hits.key?(key)
    end
    nil
  end

  # Zig's atomic ops live in `pub inline fn` wrappers (lib/atomic.zig)
  # and are mandatorily inlined. LLVM's debug-line attribution for the
  # inlined instructions points at the wrapper body, not the call site,
  # so kcov reports 0 hits at call lines whose surrounding block
  # actually executed. This produces false-positive "uncovered" rows.
  #
  # Elision rule (must be CONSERVATIVE -- a false elision masks a real
  # gap): only mark a 0-hit atomic line as elided when ALL of:
  #   1. The line's own kcov hit count is 0.
  #   2. The line is a non-control-flow statement -- a regular call
  #      with no `return`/`break`/`continue`/`if (`/`while (`/`for (`/
  #      `else`/`orelse`/`catch` keywords. Control-flow lines can be
  #      skipped while their surrounding block is still entered, so a
  #      hit successor proves nothing about them.
  #   3. BOTH neighbours: the closest preceding instrumented line AND
  #      the closest following instrumented line have hits > 0. A
  #      sandwich between two hit lines means the basic block executed,
  #      so the inlined atomic in between executed too. Single-side
  #      neighbour matches are not sufficient (a hit successor can sit
  #      after an unreached branch's exit, masking a real gap -- e.g.
  #      a fetchSub buried in an `if` body whose `if` line is also
  #      0-hit but a later unrelated line is hit).
  #
  # Lines that fail any clause stay classified as real 0-hit gaps.
  CONTROL_FLOW_RE = /\b(return|break|continue|if|while|for|else|switch|orelse|catch)\b/

  def control_flow_line?(source)
    stripped = source.sub(COMMENT_RE, "")
    stripped.match?(CONTROL_FLOW_RE)
  end

  def classify_artifact(file_hits, line_no, source)
    return false if control_flow_line?(source)

    keys = file_hits.keys.sort
    next_line = keys.bsearch { |k| k > line_no }
    prev_idx = keys.bsearch_index { |k| k >= line_no }
    prev_line = if prev_idx.nil?
                  keys.last
                elsif prev_idx > 0
                  keys[prev_idx - 1]
                end
    return false if next_line.nil? || prev_line.nil?

    file_hits[next_line] > 0 && file_hits[prev_line] > 0
  end

  def correlate(sites, hits)
    file_hits = {}
    sites.map do |s|
      file_hits[s[:file]] ||= lookup_file_hits(hits, s[:file]) || nil
      fh = file_hits[s[:file]]
      file_loaded = !fh.nil?
      fh ||= {}
      hit_count = fh[s[:line]]
      kcov_elided = !hit_count.nil? && hit_count.zero? && classify_artifact(fh, s[:line], s[:source])
      s.merge(hits: hit_count, kcov_elided: kcov_elided, file_loaded: file_loaded)
    end
  end

  def report(correlated, all:, summary_only:)
    total = correlated.size
    direct = correlated.count { |s| s[:hits] && s[:hits] > 0 }
    elided = correlated.count { |s| s[:kcov_elided] }
    covered = direct + elided
    instrumented = correlated.count { |s| !s[:hits].nil? }
    zero_hit_real = instrumented - direct - elided
    file_not_loaded = correlated.count { |s| s[:hits].nil? && !s[:file_loaded] }
    line_missing = correlated.count { |s| s[:hits].nil? && s[:file_loaded] }
    uncovered = total - covered

    unless summary_only
      to_show = all ? correlated : correlated.reject { |s| (s[:hits] && s[:hits] > 0) || s[:kcov_elided] }
      to_show.sort_by { |s| [s[:file], s[:line]] }.each do |s|
        tag = if s[:hits].nil? && !s[:file_loaded]
                "FILE NOT LOADED"
              elsif s[:hits].nil?
                "LINE MISSING (file loaded)"
              elsif s[:kcov_elided]
                "ELIDED (likely covered)"
              elsif s[:hits].zero?
                "0 hits"
              else
                "#{s[:hits]} hits"
              end
        puts "#{s[:file]}:#{s[:line]}: [#{tag}] #{s[:source].strip}"
      end
      puts unless to_show.empty?
    end

    pct = total.zero? ? 0.0 : (covered.to_f / total * 100)
    puts "Atomic sites: #{total}"
    puts "  covered (direct):         #{direct}"
    puts "  covered (kcov-elided):    #{elided}"
    puts "  covered total:            #{covered} (#{format('%.1f', pct)}%)"
    puts "  uncovered (0-hit):        #{zero_hit_real}    (instrumented, line never executed)"
    puts "  uncovered (file unloaded):#{file_not_loaded}   (file not loaded by any loom test)"
    puts "  uncovered (line missing): #{line_missing}    (file loaded; line may be inline-elided OR unreached)"
    puts "  uncovered total:          #{uncovered}"
  end

  def run(argv)
    opts = {
      coverage: "zig/zig-out/coverage-loom/merged/kcov-merged/cobertura.xml",
      scope: "zig/runtime,zig/lib",
      all: false,
      summary_only: false,
      include_tests: false
    }

    OptionParser.new do |o|
      o.banner = "Usage: ruby src/tools/loom_atomic_coverage.rb [options]"
      o.on("--coverage PATH", "Cobertura XML path") { |v| opts[:coverage] = v }
      o.on("--scope DIRS", "Comma-separated dirs to scan") { |v| opts[:scope] = v }
      o.on("--all", "Print covered sites too") { opts[:all] = true }
      o.on("--summary-only", "Print totals only") { opts[:summary_only] = true }
      o.on("--include-tests", "Include atomic sites in *-test.zig files") { opts[:include_tests] = true }
      o.on("--audit-elisions", "Print elision-classified lines and exit (for verifying the heuristic)") { opts[:audit] = true }
      o.on("-h", "--help") do
        puts o
        exit 0
      end
    end.parse!(argv)

    repo_root = File.expand_path("..", __dir__)
    coverage_path = File.expand_path(opts[:coverage], repo_root)
    scope_dirs = opts[:scope].split(",").map(&:strip).reject(&:empty?)

    unless File.exist?(coverage_path)
      warn "Cobertura XML not found: #{coverage_path}"
      warn "Generate it with: zig build coverage-loom -Dcoverage-loom"
      exit 2
    end

    hits = parse_cobertura(coverage_path)
    sites = scan_atomic_sites(scope_dirs, repo_root, include_tests: opts[:include_tests])
    correlated = correlate(sites, hits)

    if opts[:audit]
      elided = correlated.select { |s| s[:kcov_elided] }
      puts "#{elided.size} lines classified as kcov-elided (artifact, treated as covered):"
      elided.sort_by { |s| [s[:file], s[:line]] }.each do |s|
        puts "  #{s[:file]}:#{s[:line]}: #{s[:source].strip}"
      end
      puts
      puts "Heuristic: 0-hit AND non-control-flow AND both nearest instrumented neighbours are hit."
      exit 0
    end

    report(correlated, all: opts[:all], summary_only: opts[:summary_only])

    uncovered = correlated.count { |s| s[:hits].nil? || s[:hits].zero? }
    exit(uncovered.zero? ? 0 : 1)
  end
end

LoomAtomicCoverage.run(ARGV) if __FILE__ == $PROGRAM_NAME
