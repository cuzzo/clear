# frozen_string_literal: true

# Convert profiler output into profile-hotness/v1 for `lineage ingest-hotness`.
#
# Reference converter for the workflow documented in the Espalier and Lineage
# READMEs. Two inputs are supported:
#
#   --pprof-top FILE     output of: go tool pprof -top -lines <profile>
#                        (also produced by `pprof` for Rust/C++ protobuf profiles)
#   --stackprof FILE     stackprof JSON dump (Ruby): stackprof --json > FILE
#   --perf-script FILE   output of: perf script -F comm,ip,sym,srcline
#                        (Rust/Zig/C/C++ binaries; carries file:line when the
#                        binary has DWARF - build Rust with
#                        `cargo build --profile profiling` and do not strip
#                        Zig/C binaries, otherwise entries are symbol-only)
#
# Tiers are assigned from cumulative share of total samples:
#   critical >= 5%, warm >= 0.5%, cold otherwise.
# Profiles are workload-specific: merge multiple runs by converting each and
# passing all of them to ingest-hotness, which keeps the maximum tier per
# function - hot in any real workload means hot.
#
# Usage:
#   ruby pprof_to_hotness.rb (--pprof-top FILE | --stackprof FILE)
#     [--source LABEL] [--commit SHA] [--strip-prefix PATH] > hotness.json

require "json"
require "optparse"

CRITICAL_SHARE = 0.05
WARM_SHARE = 0.005

options = { source: nil, commit: nil, strip: nil, pprof_top: nil, stackprof: nil, perf_script: nil, path_prefixes: [] }
OptionParser.new do |opts|
  opts.on("--pprof-top=FILE") { |v| options[:pprof_top] = v }
  opts.on("--stackprof=FILE") { |v| options[:stackprof] = v }
  opts.on("--perf-script=FILE") { |v| options[:perf_script] = v }
  opts.on("--source=LABEL") { |v| options[:source] = v }
  opts.on("--commit=SHA") { |v| options[:commit] = v }
  opts.on("--strip-prefix=PATH", "Strip this prefix from paths (e.g. absolute build dir)") { |v| options[:strip] = v }
  opts.on("--path-prefix=PREFIX", "Keep only entries under this path prefix; drops harness/vendor frames. May be repeated") { |v| options[:path_prefixes] << v }
end.parse!

def tier_for(share)
  return "critical" if share >= CRITICAL_SHARE
  return "warm" if share >= WARM_SHARE

  "cold"
end

def relative_path(path, strip)
  return path unless path
  path = path.delete_prefix(strip).delete_prefix("/") if strip && path.start_with?(strip)
  path
end

entries = []
total = 0

if options[:pprof_top]
  # pprof -top -lines rows:
  #       flat  flat%   sum%        cum   cum%   symbol path:line
  #      120ms 12.00% 12.00%      300ms 30.00%  pkg.(*T).run /src/t.go:42
  unit_scale = { "ns" => 1, "us" => 1_000, "ms" => 1_000_000, "s" => 1_000_000_000 }
  File.foreach(options[:pprof_top]) do |line|
    match = line.match(/^\s*([\d.]+)(\w*)\s+([\d.]+)%\s+[\d.]+%\s+([\d.]+)(\w*)\s+([\d.]+)%\s+(\S+)(?:\s+(\S+):(\d+))?\s*$/)
    next unless match

    flat_raw, flat_unit, flat_pct, cum_raw, cum_unit, cum_pct, symbol, path, line_no = match.captures
    flat = (flat_raw.to_f * (unit_scale[flat_unit] || 1)).round
    cum = (cum_raw.to_f * (unit_scale[cum_unit] || 1)).round
    entries << {
      "function" => symbol,
      "path" => relative_path(path, options[:strip]),
      "line" => line_no&.to_i,
      "flat" => flat,
      "cum" => cum,
      "flat_share" => flat_pct.to_f / 100.0,
      "cum_share" => cum_pct.to_f / 100.0
    }
  end
  abort "no pprof -top rows recognized in #{options[:pprof_top]}" if entries.empty?
  options[:source] ||= "pprof"
  total = entries.sum { |entry| entry["flat"] }
elsif options[:stackprof]
  dump = JSON.parse(File.read(options[:stackprof]))
  total = dump.fetch("samples").to_f
  abort "stackprof dump has no samples" if total.zero?
  dump.fetch("frames").each_value do |frame|
    samples = frame["samples"].to_i
    total_samples = frame["total_samples"].to_i
    next if total_samples.zero?

    entries << {
      "function" => frame.fetch("name"),
      "path" => relative_path(frame["file"], options[:strip]),
      "line" => frame["line"],
      "flat" => samples,
      "cum" => total_samples,
      "flat_share" => samples / total,
      "cum_share" => total_samples / total
    }
  end
  options[:source] ||= "stackprof"
elsif options[:perf_script]
  # perf script -F comm,ip,sym,srcline emits one sample as a comm line, then
  # frame pairs: "\t<addr> <symbol>" followed by "  <file>:<line>" (or ":0"
  # without DWARF), blank line between samples. Leaf frame first. Flat = leaf
  # occurrences, cum = samples containing the frame anywhere.
  flat_counts = Hash.new(0)
  cum_counts = Hash.new(0)
  frame_info = {}
  total_samples = 0
  stack = []
  pending_symbol = nil

  finish_sample = lambda do
    next if stack.empty?
    total_samples += 1
    flat_counts[stack.first] += 1
    stack.uniq.each { |frame| cum_counts[frame] += 1 }
    stack = []
  end

  File.foreach(options[:perf_script]) do |line|
    if line.strip.empty?
      stack << pending_symbol if pending_symbol
      pending_symbol = nil
      finish_sample.call
    elsif (match = line.match(/^\t\s*[0-9a-f]+\s+(.+?)(?:\+0x[0-9a-f]+)?\s*(?:\(.*\))?$/))
      stack << pending_symbol if pending_symbol
      pending_symbol = match[1].strip
    elsif pending_symbol && (match = line.match(/^\s+(\S+):(\d+)\s*$/))
      file, line_no = match.captures
      if line_no.to_i.positive? && file != "?"
        frame_info[pending_symbol] ||= [relative_path(file, options[:strip]), line_no.to_i]
      end
      stack << pending_symbol
      pending_symbol = nil
    end
  end
  stack << pending_symbol if pending_symbol
  finish_sample.call
  abort "no perf script samples recognized in #{options[:perf_script]}" if total_samples.zero?

  cum_counts.each do |symbol, cum|
    path, line_no = frame_info[symbol]
    entries << {
      "function" => symbol,
      "path" => path,
      "line" => line_no,
      "flat" => flat_counts[symbol],
      "cum" => cum,
      "flat_share" => flat_counts[symbol].to_f / total_samples,
      "cum_share" => cum.to_f / total_samples
    }
  end
  options[:source] ||= "perf"
  total = total_samples
else
  abort "one of --pprof-top, --stackprof, or --perf-script is required"
end

unless options[:path_prefixes].empty?
  entries.select! do |entry|
    options[:path_prefixes].any? { |prefix| entry["path"].to_s.start_with?(prefix) }
  end
  abort "no entries under #{options[:path_prefixes].join(", ")}" if entries.empty?
end
entries.each { |entry| entry["tier"] = tier_for(entry["cum_share"]) }
entries.sort_by! { |entry| [-entry["cum_share"], entry["function"]] }

puts JSON.pretty_generate(
  "schema" => "profile-hotness/v1",
  "source" => options[:source],
  "commit" => options[:commit],
  "total" => total.to_i,
  "entries" => entries
)
