#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "open3"
require_relative "zig_coverage_support"

ROOT = File.expand_path("..", __dir__)

opts = {
  examples: true,
  benchmarks: true,
  strict: false,
  shard: nil,
  limit: nil,
  timeout: Integer(ENV.fetch("CORPUS_RUNTIME_TIMEOUT", "120")),
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/corpus_runtime_coverage.rb [options]"
  o.on("--examples-only") { opts[:benchmarks] = false }
  o.on("--benchmarks-only") { opts[:examples] = false }
  o.on("--strict") { opts[:strict] = true }
  o.on("--limit N", Integer) { |v| opts[:limit] = v }
  o.on("--timeout N", Integer) { |v| opts[:timeout] = v }
  o.on("--shard I/N") do |v|
    idx, total = v.split("/", 2).map(&:to_i)
    abort "--shard expects I/N with N > 0 and 0 <= I < N" unless total && total.positive? && idx && idx >= 0 && idx < total
    opts[:shard] = [idx, total]
  end
end.parse!

ENV["ZIG_COVERAGE"] = "1"
ENV["ZIG_COVERAGE_SUITE"] ||= "examples-benchmarks"

def runnable_example?(path)
  src = File.read(path)
  src.match?(/\bFN\s+main\s*\(/) ||
    src.match?(/\bTEST\b/) ||
    src.match?(/\bTEST\s+THAT\b/) ||
    src.match?(/\bWHEN\b/)
end

def skipped_example?(path)
  rel = path.delete_prefix("#{ROOT}/")
  return true if rel.include?("/bench.profile/")
  return true if rel.start_with?("examples/footguns/")

  case rel
  when "examples/minivm/_bc_runner.cht",
       "examples/minivm/_scheme_runner.cht",
       "examples/minivm/debugger.cht",
       "examples/minivm/parser.cht",
       "examples/minivm/register_debugger.cht",
       "examples/minivm/sus-int.cht",
       "examples/minivm/types.cht",
       "examples/minivm/vm.cht",
       "examples/minivm/vtest.cht"
    true
  else
    false
  end
end

def apply_shard(items, shard)
  return items unless shard

  idx, total = shard
  items.each_with_index.select { |_item, i| (i % total) == idx }.map(&:first)
end

def timeout_bin
  [
    "/usr/bin/timeout",
    "/bin/timeout",
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "timeout") },
  ].flatten.find { |path| File.file?(path) && File.executable?(path) }
end

def run_cmd(label, argv, timeout:)
  command = if timeout.positive? && (bin = timeout_bin)
              [bin, "#{timeout}s", *argv]
            else
              argv
            end
  output, status = Open3.capture2e(
    {
      "ZIG_COVERAGE" => "1",
      "ZIG_COVERAGE_SUITE" => ENV.fetch("ZIG_COVERAGE_SUITE", "examples-benchmarks"),
    },
    *command,
    chdir: ROOT
  )
  if status.success?
    puts "  OK #{label}"
    true
  else
    puts "  FAIL #{label}"
    puts output.lines.last(30).map { |line| "    #{line}" }.join
    false
  end
end

passed = 0
failed = 0
skipped = 0

if opts[:examples]
  examples = Dir.glob(File.join(ROOT, "examples", "**", "*.cht")).sort
                .reject { |path| skipped_example?(path) }
  runnable, non_runnable = examples.partition { |path| runnable_example?(path) }
  skipped += non_runnable.size
  runnable = apply_shard(runnable, opts[:shard])
  runnable = runnable.first(opts[:limit]) if opts[:limit]

  puts "Runtime example coverage: #{runnable.size} runnable, #{non_runnable.size} skipped"
  runnable.each do |path|
    rel = path.delete_prefix("#{ROOT}/")
    if run_cmd(rel, ["./clear", "test", "--coverage", path], timeout: opts[:timeout])
      passed += 1
    else
      failed += 1
    end
  end
end

if opts[:benchmarks]
  bench_args = ["ruby", "benchmarks/runner.rb", "--coverage", "--all"]
  bench_args << "--shard=#{opts[:shard].join("/")}" if opts[:shard]
  puts "Runtime benchmark coverage: #{bench_args.join(' ')}"
  if run_cmd("benchmarks", bench_args, timeout: opts[:timeout])
    passed += 1
  else
    failed += 1
  end
end

merged = ZigCoverageSupport.merge!("examples-benchmarks")
puts "Merged Zig coverage: #{merged}" if merged

puts "Corpus runtime coverage summary: #{passed} ok, #{failed} failed, #{skipped} skipped"
exit 1 if opts[:strict] && failed.positive?
exit 1 if passed.zero?
