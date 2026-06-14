#!/usr/bin/env ruby
# Targeted mutant runner for tools/fuzz.
#
# Runs the relevant fuzz templates before and after applying a deliberate
# safety-rule-breaking patch, then reports whether the mutant produced new
# failures relative to baseline.

require 'fileutils'
require 'open3'
require 'optparse'
require_relative '../../mutants/support'
require_relative 'registry'

opts = {
  mutant: nil,
  all: false,
  out: File.expand_path('/tmp/clear-fuzz-mutants'),
  keep: false,
  list: false,
  dry_run: false,
  allow_dirty: false,
  shard: nil,
}

OptionParser.new do |o|
  o.banner = 'Usage: ruby tools/fuzz/mutants/run.rb [--mutant NAME | --all] [--shard INDEX/COUNT] [--out DIR] [--keep] [--dry-run] [--allow-dirty]'
  o.on('--mutant NAME') { |v| opts[:mutant] = v.to_sym }
  o.on('--all') { opts[:all] = true }
  o.on('--shard INDEX/COUNT') { |v| opts[:shard] = MutationTesting.parse_shard(v) }
  o.on('--out DIR') { |v| opts[:out] = File.expand_path(v) }
  o.on('--keep') { opts[:keep] = true }
  o.on('--dry-run') { opts[:dry_run] = true }
  o.on('--allow-dirty') { opts[:allow_dirty] = true }
  o.on('--list') { opts[:list] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

def step(label)
  puts "[mutants] #{label}"
end

def run_cmd(argv, cwd:, allow_failure: false, log_path: nil)
  out, status = Open3.capture2e(*argv, chdir: cwd)
  File.write(log_path, out) if log_path
  unless status.success? || allow_failure
    warn out
    raise "command failed: #{argv.join(' ')}"
  end
  [out, status.exitstatus]
end

def patch_targets(mutant)
  File.readlines(mutant.patch).filter_map do |line|
    match = line.match(/^diff --git a\/(.+?) b\/(.+)$/)
    match && match[2]
  end.uniq
end

def dirty_paths(paths)
  return [] if paths.empty?

  out, = run_cmd(['git', 'status', '--porcelain', '--', *paths], cwd: FuzzMutants::ROOT)
  out.lines.map(&:chomp).reject(&:empty?)
end

def ensure_clean_targets!(mutant, allow_dirty:)
  paths = patch_targets(mutant)
  dirty = dirty_paths(paths)
  return if dirty.empty? || allow_dirty

  abort <<~MSG
    Refusing to run #{mutant.name}: mutant target files have local changes.
    #{dirty.map { |line| "  #{line}" }.join("\n")}

    Commit/stash those edits, or rerun with --allow-dirty if you intentionally
    want to test this mutant on WIP.
  MSG
end

def parse_summary(output)
  line = output.lines.find { |l| l.start_with?('Summary: ') }
  return nil unless line

  match = line.match(/Summary: (?<run>\d+) run, (?<ok>\d+) ok, (?<fail>\d+) fail, (?<leak>\d+) leak, (?<mir>\d+) mir-error, (?<unexpected>\d+) unexpected-pass/)
  return nil unless match

  {
    run: match[:run].to_i,
    ok: match[:ok].to_i,
    fail: match[:fail].to_i,
    leak: match[:leak].to_i,
    mir_error: match[:mir].to_i,
    unexpected_pass: match[:unexpected].to_i,
  }
end

def fuzz_run(mutant, out_dir, log_path:)
  args = [
    'ruby', 'tools/fuzz/run.rb',
    '--matrix',
    '--templates', mutant.templates.join(','),
    '--out', out_dir,
    '--clean',
  ]
  output, = run_cmd(args, cwd: FuzzMutants::ROOT, allow_failure: true, log_path: log_path)
  summary = parse_summary(output)
  raise "could not parse fuzz summary for #{mutant.name}" unless summary
  [summary, output]
end

def check_patch(mutant)
  run_cmd(['git', 'apply', '--check', mutant.patch], cwd: FuzzMutants::ROOT)
  run_cmd(['git', 'apply', '--reverse', '--check', mutant.patch], cwd: FuzzMutants::ROOT, allow_failure: true)
end

def apply_patch(mutant)
  run_cmd(['git', 'apply', '--check', mutant.patch], cwd: FuzzMutants::ROOT)
  run_cmd(['git', 'apply', mutant.patch], cwd: FuzzMutants::ROOT)
end

def revert_patch(mutant)
  run_cmd(['git', 'apply', '--reverse', '--check', mutant.patch], cwd: FuzzMutants::ROOT)
  run_cmd(['git', 'apply', '-R', mutant.patch], cwd: FuzzMutants::ROOT)
end

def killed?(mutant, baseline, mutated)
  kill = mutant.kill || { bucket: :unexpected_pass, min_delta: 1 }
  bucket = kill.fetch(:bucket)
  min_delta = kill.fetch(:min_delta, 1)
  delta = mutated.fetch(bucket) - baseline.fetch(bucket)
  [delta >= min_delta, bucket, delta, min_delta]
end

def run_mutant(mutant, root_out)
  base_dir = File.join(root_out, mutant.name.to_s, 'baseline')
  mutant_dir = File.join(root_out, mutant.name.to_s, 'mutated')
  log_dir = File.join(root_out, mutant.name.to_s, 'logs')
  FileUtils.mkdir_p(base_dir)
  FileUtils.mkdir_p(mutant_dir)
  FileUtils.mkdir_p(log_dir)

  puts "== #{mutant.name}"
  puts mutant.description
  puts "invariant: #{mutant.invariant}"
  puts "templates: #{mutant.templates.join(', ')}"
  puts "patch: #{mutant.patch}"
  puts

  step "1/6 checking patch targets"
  ensure_clean_targets!(mutant, allow_dirty: $allow_dirty)

  step "2/6 verifying patch applies"
  check_patch(mutant)

  if $dry_run
    puts "dry-run: patch checks passed; no fuzz run performed"
    puts
    return true
  end

  step "3/6 running baseline fuzz matrix"
  baseline, = fuzz_run(mutant, base_dir, log_path: File.join(log_dir, 'baseline.log'))
  puts "baseline: #{baseline}"

  applied = false
  begin
    step "4/6 applying mutant patch"
    apply_patch(mutant)
    applied = true
    step "5/6 running mutated fuzz matrix"
    mutated, = fuzz_run(mutant, mutant_dir, log_path: File.join(log_dir, 'mutated.log'))
  ensure
    if applied
      step "6/6 reverting mutant patch"
      begin
        revert_patch(mutant)
      rescue StandardError => e
        warn "FAILED TO REVERT MUTANT #{mutant.name}: #{e.message}"
        warn "Manual restore command: git apply -R #{mutant.patch}"
        raise
      end
    end
  end

  puts "mutated:  #{mutated}"

  killed, bucket, delta, min_delta = killed?(mutant, baseline, mutated)
  puts "signal: #{bucket} delta=#{delta} required>=#{min_delta}"
  puts "logs: #{log_dir}"
  puts(killed ? 'result: KILLED' : 'result: SURVIVED')
  puts

  killed
end

def selected_mutants(opts)
  mutants =
    if opts[:all]
      FuzzMutants::REGISTRY
    elsif opts[:mutant]
      found = FuzzMutants.find(opts[:mutant])
      abort "unknown mutant: #{opts[:mutant]}" unless found
      [found]
    else
      abort 'pass --mutant NAME, --all, or --list'
    end

  MutationTesting.shard_items(mutants, opts[:shard])
end

if opts[:list]
  mutants = opts[:shard] ? MutationTesting.shard_items(FuzzMutants::REGISTRY, opts[:shard]) : FuzzMutants::REGISTRY
  mutants.each do |m|
    kill = m.kill || { bucket: :unexpected_pass, min_delta: 1 }
    puts "#{m.name} - #{m.description} [#{kill.fetch(:bucket)} +#{kill.fetch(:min_delta, 1)}]"
  end
  exit 0
end

mutants = selected_mutants(opts)

FileUtils.rm_rf(opts[:out]) unless opts[:keep]
FileUtils.mkdir_p(opts[:out])

$dry_run = opts[:dry_run]
$allow_dirty = opts[:allow_dirty]

if mutants.empty?
  puts "no fuzz mutants selected for shard #{MutationTesting.shard_label(opts[:shard])}"
  exit 0
end

puts "fuzz mutant shard #{MutationTesting.shard_label(opts[:shard])}: #{mutants.length} mutant(s)"
results = mutants.map { |m| run_mutant(m, opts[:out]) }
exit(results.all? ? 0 : 1)
