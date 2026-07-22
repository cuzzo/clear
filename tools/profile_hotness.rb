# frozen_string_literal: true

# Generate profile-hotness/v1 data for this repository's sub-projects and
# optionally ingest it into Lineage.
#
# Each target has a profiling recipe matched to its language:
#   compiler     Ruby: stackprof around real compiles of the benchmarks/ and
#                examples/ .clear corpus (the same corpus the
#                examples/benchmarks CI job builds), via tools/stackprof_compile.rb.
#   <ruby gem>   Ruby: stackprof around the gem's test files in one process
#                (espalier, slopcop, nil-kill, test-miser, auto-type,
#                ruby-to-clear). Test workloads are advisory - prefer real
#                workloads where one exists.
#   boobytrap    Go: go test -cpuprofile, read with go tool pprof -top -lines.
#   fact-mine    Rust: perf record around fact-mine-rust profiling the
#                compiler/ruby sources (a real workload), perf report --children.
#   zig          Zig: perf record around `zig build bench-locks` (built once
#                beforehand so compilation does not dominate the profile).
#
# Usage:
#   ruby tools/profile_hotness.rb --list
#   ruby tools/profile_hotness.rb --target compiler [--limit N]
#   ruby tools/profile_hotness.rb --all
#   ruby tools/profile_hotness.rb --target compiler --ingest --db lineage.db
#
# Outputs <out-dir>/<target>-hotness.json (default tmp/hotness/).

require "fileutils"
require "json"
require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
CONVERTER = File.join(ROOT, "gems/lineage/tools/pprof_to_hotness.rb")
LINEAGE_BIN = File.join(ROOT, "gems/lineage/target/release/lineage")

RUBY_GEM_TARGETS = {
  "espalier" => "gems/espalier/test/*_test.rb",
  "slopcop" => "gems/slopcop/test/*_test.rb",
  "nil-kill" => "gems/nil-kill/spec/*_spec.rb",
  "test-miser" => "gems/test-miser/test/*_test.rb",
  "auto-type" => "gems/auto-type/test/*_test.rb",
  "ruby-to-clear" => "gems/ruby-to-clear/test/*_test.rb"
}.freeze

options = {
  targets: [],
  all: false,
  list: false,
  limit: 12,
  out_dir: File.join(ROOT, "tmp/hotness"),
  ingest: false,
  db: nil,
  repo: ROOT
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/profile_hotness.rb [options]"
  opts.on("--target=NAME", "Profile one target. May be repeated") { |v| options[:targets] << v }
  opts.on("--all", "Profile every target") { options[:all] = true }
  opts.on("--list", "List targets") { options[:list] = true }
  opts.on("--limit=N", Integer, "Corpus/test file cap per target (default 12)") { |v| options[:limit] = v }
  opts.on("--out-dir=PATH", "Output directory (default tmp/hotness)") { |v| options[:out_dir] = v }
  opts.on("--ingest", "Ingest each result via lineage ingest-hotness") { options[:ingest] = true }
  opts.on("--db=PATH", "Lineage DB for --ingest") { |v| options[:db] = v }
  opts.on("--repo=PATH", "Repository root for --ingest (default repo root)") { |v| options[:repo] = v }
end.parse!

def run!(command, env: {}, chdir: ROOT, allow_failure: false)
  stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
  unless status.success? || allow_failure
    abort "command failed (#{status.exitstatus}): #{command.join(" ")}\n#{stderr[0, 2000]}\n#{stdout[0, 500]}"
  end
  [stdout, stderr, status]
end

def tool_available?(name)
  system("which #{name} >/dev/null 2>&1")
end

def convert!(input_flag, input_path, source, out_path, strip: nil, path_prefix: nil)
  command = ["ruby", CONVERTER, "#{input_flag}=#{input_path}", "--source=#{source}"]
  command << "--strip-prefix=#{strip}" if strip
  command << "--path-prefix=#{path_prefix}" if path_prefix
  stdout, = run!(command)
  File.write(out_path, stdout)
  entries = JSON.parse(stdout).fetch("entries")
  critical = entries.count { |entry| entry["tier"] == "critical" }
  puts "  #{File.basename(out_path)}: #{entries.size} entries, #{critical} critical"
end

def profile_compiler(work_dir, out_path, limit)
  corpus = (Dir[File.join(ROOT, "benchmarks/**/*.clear")] +
            Dir[File.join(ROOT, "examples/**/*.clear")])
           .reject { |path| File.basename(path).start_with?("_") }
           .sort
  sample = corpus.each_slice([corpus.size / limit, 1].max).map(&:first).first(limit)
  dumps = []
  sample.each_with_index do |clear_file, index|
    dump = File.join(work_dir, "compile-#{index}.dump")
    _out, _err, status = run!(
      ["bundle", "exec", "ruby", "tools/stackprof_compile.rb", "--mode", "cpu", "-o", dump, clear_file],
      allow_failure: true
    )
    dumps << dump if status.success? && File.file?(dump)
  end
  abort "no benchmark/example compiles succeeded under stackprof" if dumps.empty?
  puts "  profiled #{dumps.size}/#{sample.size} corpus compiles"

  aggregated = File.join(work_dir, "compiler-stackprof.json")
  stdout, = run!(["bundle", "exec", "stackprof", "--json", *dumps])
  File.write(aggregated, stdout)
  convert!("--stackprof", aggregated, "stackprof:compiler", out_path, strip: "#{ROOT}/", path_prefix: "compiler/")
end

def profile_ruby_gem(target, glob, work_dir, out_path, limit)
  files = Dir[File.join(ROOT, glob)].sort.first(limit)
  abort "no test files match #{glob}" if files.empty?
  dump = File.join(work_dir, "#{target}.dump")
  loader = files.map { |file| "require #{File.expand_path(file).inspect}" }.join("; ")
  run!(
    ["bundle", "exec", "ruby", "-e", loader],
    env: { "STACKPROF_OUT" => dump, "RUBYOPT" => "-r#{File.join(ROOT, "tools/stackprof_shim.rb")}" },
    allow_failure: true
  )
  abort "stackprof produced no dump for #{target}" unless File.file?(dump)
  json = File.join(work_dir, "#{target}-stackprof.json")
  stdout, = run!(["bundle", "exec", "stackprof", "--json", dump])
  File.write(json, stdout)
  convert!("--stackprof", json, "stackprof:#{target}", out_path, strip: "#{ROOT}/", path_prefix: "gems/#{target}/")
end

def profile_boobytrap(work_dir, out_path)
  abort "go toolchain unavailable" unless tool_available?("go")
  src = File.join(ROOT, "gems/boobytrap/src")
  profile = File.join(work_dir, "boobytrap-cpu.out")
  binary = File.join(work_dir, "boobytrap-test.bin")
  # Some tests exercise environment-dependent subcommands; the CPU profile is
  # written even when individual tests fail, so only the artifacts are required.
  run!(["go", "test", "-run", ".", "-cpuprofile", profile, "-o", binary, "."],
       chdir: src, allow_failure: true)
  abort "go test produced no CPU profile" unless File.file?(profile) && File.file?(binary)
  top = File.join(work_dir, "boobytrap-top.txt")
  stdout, = run!(["go", "tool", "pprof", "-top", "-lines", binary, profile], chdir: src)
  File.write(top, stdout)
  convert!("--pprof-top", top, "pprof:boobytrap", out_path, strip: "#{src}/")
end

def perf_record!(command, work_dir, label, chdir: ROOT, env: {})
  abort "perf unavailable" unless tool_available?("perf")
  data = File.join(work_dir, "#{label}.perf.data")
  # 297Hz keeps captures small enough that perf script srcline resolution
  # (addr2line per unique address) stays fast.
  run!(["perf", "record", "-g", "-F", "297", "-o", data, "--", *command], chdir: chdir, env: env)
  script = File.join(work_dir, "#{label}-script.txt")
  # binutils addr2line re-parses DWARF per query and can take unbounded time
  # on large binaries (Zig especially). --no-inline avoids the worst cost;
  # if srcline still exceeds the budget, fall back to symbols only - the
  # ingest-time resolver attributes those against the unit inventory.
  stdout, _err, status = run!(
    ["timeout", "180", "perf", "script", "--no-inline", "-F", "comm,ip,sym,srcline", "-i", data],
    chdir: chdir, allow_failure: true
  )
  if status.success?
    File.write(script, stdout)
  else
    warn "  srcline symbolization exceeded 180s; falling back to symbols only"
    stdout, = run!(["perf", "script", "-F", "comm,ip,sym", "-i", data], chdir: chdir)
    File.write(script, stdout)
  end
  script
end

def profile_fact_mine(work_dir, out_path, limit)
  # The profiling cargo profile keeps DWARF so perf script yields file:line.
  binary = File.join(ROOT, "gems/fact-mine/target/profiling/fact-mine-rust")
  unless File.executable?(binary)
    puts "  building fact-mine with the profiling cargo profile (keeps DWARF)"
    run!(["cargo", "build", "--profile", "profiling"], chdir: File.join(ROOT, "gems/fact-mine"))
  end
  workload = Dir[File.join(ROOT, "compiler/ruby/**/*.rb")].sort.first([limit * 4, 24].max)
  script = perf_record!([binary, "profile", "nil-kill", *workload], work_dir, "fact-mine")
  convert!("--perf-script", script, "perf:fact-mine", out_path, strip: "#{ROOT}/")
end

def profile_zig(work_dir, out_path)
  abort "zig toolchain unavailable" unless tool_available?("zig")
  zig_dir = File.join(ROOT, "zig")
  # Warm the build cache so the profile measures the benchmark, not compilation.
  run!(["zig", "build", "bench-locks"], chdir: zig_dir)
  script = perf_record!(["zig", "build", "bench-locks"], work_dir, "zig", chdir: zig_dir)
  convert!("--perf-script", script, "perf:zig", out_path, strip: "#{ROOT}/")
end

targets = {
  "compiler" => ->(work, out, limit) { profile_compiler(work, out, limit) },
  "boobytrap" => ->(work, out, _limit) { profile_boobytrap(work, out) },
  "fact-mine" => ->(work, out, limit) { profile_fact_mine(work, out, limit) },
  "zig" => ->(work, out, _limit) { profile_zig(work, out) }
}
RUBY_GEM_TARGETS.each do |gem_name, glob|
  targets[gem_name] = ->(work, out, limit) { profile_ruby_gem(gem_name, glob, work, out, limit) }
end

if options[:list]
  targets.keys.sort.each { |name| puts name }
  exit 0
end

selected = options[:all] ? targets.keys : options[:targets]
abort "pass --target NAME, --all, or --list" if selected.empty?
unknown = selected - targets.keys
abort "unknown target(s): #{unknown.join(", ")} (see --list)" unless unknown.empty?

FileUtils.mkdir_p(options[:out_dir])

selected.each do |target|
  puts "== #{target}"
  work_dir = File.join(options[:out_dir], "work", target)
  FileUtils.mkdir_p(work_dir)
  out_path = File.join(options[:out_dir], "#{target}-hotness.json")
  targets.fetch(target).call(work_dir, out_path, options[:limit])

  next unless options[:ingest]
  abort "--ingest requires --db" unless options[:db]
  abort "lineage binary missing: #{LINEAGE_BIN}" unless File.executable?(LINEAGE_BIN)
  stdout, = run!([LINEAGE_BIN, "ingest-hotness", "--db", options[:db], "--repo", options[:repo],
                  "--input", out_path])
  puts "  #{stdout.strip}"
end
