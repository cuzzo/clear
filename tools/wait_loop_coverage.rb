#!/usr/bin/env ruby
# frozen_string_literal: true

# Wait-loop hammer-test coverage gap report.
#
# Cross-references HAMMER-WAIT-LOOP-{BEGIN,END} markers in zig/runtime/
# and zig/lib/ against HAMMER-COVERS markers in *-hammer-test.zig files.
# Reports wait-loops that lack a hammer test exercising their stall path.
#
# A "wait-loop" is any retry loop that waits for an external condition
# (channel space, lock release, value publish). The risk: under
# pathological conditions (slow consumer, heavy contention, especially
# under TSan instrumentation) the loop can busy-spin instead of
# cooperatively yielding. A hammer test should drive the stall and
# verify the loop yields the OS thread (not just a fiber that's a no-op
# when no other local work exists).
#
# Usage:
#   ruby tools/wait_loop_coverage.rb [options]
#
# Options:
#   --scope DIRS       Comma-separated source dirs (default: zig/runtime,zig/lib)
#   --tests DIRS       Comma-separated hammer-test dirs (default: zig/,zig/runtime)
#   --all              Print covered loops too
#   --summary-only     Totals only, no per-loop list
#   --help
#
# Convention:
#   In source code:
#     // HAMMER-WAIT-LOOP-BEGIN: tag=<name>
#     // <description of what stalls>
#     // <yield contract>
#     while (...) {
#         ...
#     }
#     // HAMMER-WAIT-LOOP-END: tag=<name>
#
#   In *-hammer-test.zig files:
#     // HAMMER-COVERS: <name>
#     test "<test name>" { ... }
#
#   Tags are dot/dash-separated identifiers (e.g. "spsc-submit-resume",
#   "parking-lot.queue-spin", "streams.next-park"). One tag per loop;
#   one HAMMER-COVERS per test that exercises a tag (a single test may
#   cover multiple tags via repeated HAMMER-COVERS lines).
#
# Exit codes:
#   0  every wait-loop tag has at least one HAMMER-COVERS reference
#   1  one or more uncovered tags (or stale covers, or unbalanced markers)
#   2  argument / I/O error

require "optparse"

module WaitLoopCoverage
  module_function

  BEGIN_RE = /\/\/\s*HAMMER-WAIT-LOOP-BEGIN:\s*tag=([\w\.\-]+)/
  END_RE   = /\/\/\s*HAMMER-WAIT-LOOP-END:\s*tag=([\w\.\-]+)/
  COVER_RE = /\/\/\s*HAMMER-COVERS:\s*([\w\.\-]+)/

  Loop = Struct.new(:tag, :file, :begin_line, :end_line, keyword_init: true)
  Cover = Struct.new(:tag, :file, :line, keyword_init: true)

  def scan_source_files(dirs, repo_root)
    files = []
    dirs.each do |dir|
      abs = File.expand_path(dir, repo_root)
      next unless Dir.exist?(abs)
      Dir.glob(File.join(abs, "**", "*.zig")).each do |path|
        # Source files only; tests live in *-test.zig which we scan separately.
        next if path.include?("-test.zig")
        next if path.include?("-loom.zig")
        files << path
      end
    end
    files.sort
  end

  def scan_hammer_test_files(dirs, repo_root)
    files = []
    dirs.each do |dir|
      abs = File.expand_path(dir, repo_root)
      next unless Dir.exist?(abs)
      # Top-level (non-recursive) for zig/, recursive for nested test dirs.
      pattern = File.join(abs, dir.end_with?("/") ? "**" : "", "*-hammer-test.zig")
      Dir.glob(pattern).each { |p| files << p }
      # Also scan zig/runtime/*-hammer-test.zig if dir was zig/.
      Dir.glob(File.join(abs, "*-hammer-test.zig")).each { |p| files << p }
    end
    files.uniq.sort
  end

  def parse_loops(source_files, repo_root)
    loops = []
    open_begins = {} # tag => [file, line]
    issues = []

    source_files.each do |path|
      rel = path.sub("#{repo_root}/", "")
      File.foreach(path).with_index(1) do |line, lineno|
        if (m = BEGIN_RE.match(line))
          tag = m[1]
          if open_begins.key?(tag)
            issues << "#{rel}:#{lineno}: nested HAMMER-WAIT-LOOP-BEGIN with tag=#{tag} (already open at #{open_begins[tag][0]}:#{open_begins[tag][1]})"
          end
          open_begins[tag] = [rel, lineno]
        elsif (m = END_RE.match(line))
          tag = m[1]
          if (entry = open_begins.delete(tag))
            loops << Loop.new(tag: tag, file: entry[0], begin_line: entry[1], end_line: lineno)
          else
            issues << "#{rel}:#{lineno}: HAMMER-WAIT-LOOP-END without matching BEGIN (tag=#{tag})"
          end
        end
      end

      open_begins.each do |tag, (f, l)|
        next unless f == rel
        issues << "#{f}:#{l}: HAMMER-WAIT-LOOP-BEGIN without END (tag=#{tag})"
      end
      open_begins.delete_if { |_t, (f, _l)| f == rel }
    end

    [loops, issues]
  end

  def parse_covers(test_files, repo_root)
    covers = []
    test_files.each do |path|
      rel = path.sub("#{repo_root}/", "")
      File.foreach(path).with_index(1) do |line, lineno|
        next unless (m = COVER_RE.match(line))
        covers << Cover.new(tag: m[1], file: rel, line: lineno)
      end
    end
    covers
  end

  def correlate(loops, covers)
    by_tag = covers.group_by(&:tag)
    loops.map do |l|
      { loop: l, covers: by_tag[l.tag] || [] }
    end
  end

  def report(correlated, covers, all:, summary_only:)
    uncovered = correlated.select { |c| c[:covers].empty? }
    covered = correlated - uncovered

    cover_tags = covers.map(&:tag).uniq
    loop_tags = correlated.map { |c| c[:loop].tag }.uniq
    stale = cover_tags - loop_tags

    unless summary_only
      if uncovered.any?
        puts "UNCOVERED wait-loops (no HAMMER-COVERS in any *-hammer-test.zig):"
        uncovered.each do |c|
          l = c[:loop]
          puts "  #{l.file}:#{l.begin_line}-#{l.end_line}: tag=#{l.tag}"
        end
        puts
      end

      if stale.any?
        puts "STALE HAMMER-COVERS (no matching HAMMER-WAIT-LOOP source markers):"
        stale.each do |t|
          covers.select { |c| c.tag == t }.each do |c|
            puts "  #{c.file}:#{c.line}: covers=#{t}"
          end
        end
        puts
      end

      if all
        puts "Covered wait-loops:"
        covered.each do |c|
          l = c[:loop]
          tests = c[:covers].map { |t| "#{t.file}:#{t.line}" }.join(", ")
          puts "  #{l.file}:#{l.begin_line}-#{l.end_line}: tag=#{l.tag} <- #{tests}"
        end
        puts
      end
    end

    puts "Wait-loop coverage:"
    puts "  total wait-loops:    #{correlated.size}"
    puts "  covered:             #{covered.size}"
    puts "  uncovered:           #{uncovered.size}"
    puts "  stale HAMMER-COVERS: #{stale.size}"

    [uncovered.size, stale.size]
  end

  def run(argv)
    opts = {
      scope: "zig/runtime,zig/lib",
      tests: "zig,zig/runtime",
      all: false,
      summary_only: false
    }

    OptionParser.new do |o|
      o.banner = "Usage: ruby tools/wait_loop_coverage.rb [options]"
      o.on("--scope DIRS", "Source dirs (comma-separated)") { |v| opts[:scope] = v }
      o.on("--tests DIRS", "Hammer test dirs (comma-separated)") { |v| opts[:tests] = v }
      o.on("--all", "Print covered loops too") { opts[:all] = true }
      o.on("--summary-only", "Totals only") { opts[:summary_only] = true }
      o.on("-h", "--help") do
        puts o
        exit 0
      end
    end.parse!(argv)

    repo_root = File.expand_path("..", __dir__)
    scope_dirs = opts[:scope].split(",").map(&:strip).reject(&:empty?)
    test_dirs  = opts[:tests].split(",").map(&:strip).reject(&:empty?)

    source_files = scan_source_files(scope_dirs, repo_root)
    test_files   = scan_hammer_test_files(test_dirs, repo_root)

    loops, issues = parse_loops(source_files, repo_root)
    covers = parse_covers(test_files, repo_root)

    if issues.any?
      warn "Marker syntax issues:"
      issues.each { |i| warn "  #{i}" }
      exit 1
    end

    correlated = correlate(loops, covers)
    uncovered_count, stale_count = report(correlated, covers, all: opts[:all], summary_only: opts[:summary_only])

    exit(uncovered_count.zero? && stale_count.zero? ? 0 : 1)
  end
end

WaitLoopCoverage.run(ARGV) if $PROGRAM_NAME == __FILE__
