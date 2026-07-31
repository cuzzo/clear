#!/usr/bin/env ruby
# frozen_string_literal: true

# Prove two compiler implementations lower CLEAR to byte-identical Zig.
#
# The spec suite checks behaviour on the cases someone thought to write. This
# checks the actual product -- emitted Zig -- across every .clear in the repo,
# so any divergence shows up as a diff on a real program rather than as a
# missing assertion.
#
#   ruby tools/zig_equivalence.rb --candidate compiler/.ruby-rbs
#   ruby tools/zig_equivalence.rb --candidate compiler/.ruby-rbs --spinel tmp/spinel/bin/...
#
# The baseline is always compiler/ruby. Files the BASELINE cannot compile are
# skipped, not counted as differences: the point is agreement, not coverage.

require "digest"
require "fileutils"
require "optparse"
require "open3"
require "etc"
require "thread"

ROOT = File.expand_path("..", __dir__)

options = {
  candidate: "compiler/.ruby-rbs",
  roots: %w[examples transpile-tests benchmarks],
  limit: nil,
  out: "tmp/zig-equivalence",
}
options[:jobs] = [Etc.nprocessors - 2, 1].max

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/zig_equivalence.rb [--candidate DIR] [--roots a,b] [--limit N]"
  o.on("--candidate DIR", "Tree to compare against compiler/ruby") { |v| options[:candidate] = v }
  o.on("--roots LIST", "Comma-separated dirs to scan") { |v| options[:roots] = v.split(",") }
  o.on("--jobs N", Integer, "Parallel workers") { |v| options[:jobs] = v }
  o.on("--limit N", Integer, "Only the first N sources (smoke run)") { |v| options[:limit] = v }
  o.on("--out DIR", "Where to write diffs") { |v| options[:out] = v }
end.parse!(ARGV)

BASELINE = File.join(ROOT, "compiler", "ruby", "backends", "transpiler.rb")
CANDIDATE = File.join(ROOT, options[:candidate], "backends", "transpiler.rb")
abort("no candidate transpiler at #{CANDIDATE}") unless File.exist?(CANDIDATE)

sources = options[:roots].flat_map { |r| Dir[File.join(ROOT, r, "**", "*.clear")] }.sort
sources = sources.first(options[:limit]) if options[:limit]
abort("no .clear sources found") if sources.empty?

out_dir = File.join(ROOT, options[:out])
FileUtils.rm_rf(out_dir)
FileUtils.mkdir_p(out_dir)

# Emit Zig for one source with one transpiler. Returns [status, output].
# status: :ok, :baseline_failed, :candidate_failed
def emit(transpiler, source)
  stdout, stderr, status = Open3.capture3(
    { "CLEAR_DISABLE_BUILD_ZIG" => "1", "NO_COLOR" => "1" },
    RbConfig.ruby, transpiler, source,
    chdir: ROOT,
  )
  return [:fail, stderr] unless status.success?

  [:ok, stdout]
end

queue = Queue.new
sources.each { |s| queue << s }
results = Queue.new

workers = Array.new(options[:jobs]) do
  Thread.new do
    while (source = (queue.pop(true) rescue nil))
      rel = source.delete_prefix("#{ROOT}/")
      base_status, base_out = emit(BASELINE, source)
      if base_status != :ok
        results << [:skipped, rel, nil]
        next
      end

      cand_status, cand_out = emit(CANDIDATE, source)
      if cand_status != :ok
        results << [:candidate_error, rel, cand_out.to_s[0, 4000]]
      elsif base_out == cand_out
        results << [:same, rel, nil]
      else
        results << [:differs, rel, [base_out, cand_out]]
      end
    end
  end
end
workers.each(&:join)

counts = Hash.new(0)
divergent = []
until results.empty?
  kind, rel, payload = results.pop
  counts[kind] += 1
  next unless %i[differs candidate_error].include?(kind)

  divergent << [kind, rel]
  safe = rel.tr("/", "_")
  if kind == :differs
    File.write(File.join(out_dir, "#{safe}.baseline.zig"), payload[0])
    File.write(File.join(out_dir, "#{safe}.candidate.zig"), payload[1])
  else
    File.write(File.join(out_dir, "#{safe}.error.log"), payload)
  end
end

total = sources.length
puts "sources:          #{total}"
puts "identical Zig:    #{counts[:same]}"
puts "DIFFERENT Zig:    #{counts[:differs]}"
puts "candidate errors: #{counts[:candidate_error]}"
puts "skipped (baseline cannot compile): #{counts[:skipped]}"
unless divergent.empty?
  puts "\nfirst divergences (artifacts in #{options[:out]}):"
  divergent.sort_by { |_k, r| r }.first(25).each { |kind, rel| puts "  #{kind}: #{rel}" }
end

exit(counts[:differs] + counts[:candidate_error] > 0 ? 1 : 0)
