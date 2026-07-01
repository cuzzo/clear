#!/usr/bin/env ruby

require 'benchmark'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
EXAMPLE_DIR = File.expand_path(__dir__)
SOURCE = File.join(EXAMPLE_DIR, 'du.clear')
BINARY = File.join(EXAMPLE_DIR, 'pdu')
DISKUS = ENV['DISKUS'] || File.join(Dir.home, '.cargo', 'bin', 'diskus')

def usage!
  warn "usage: ruby examples/parallel_du/bench.rb [path] [runs]"
  exit 1
end

def run_checked(env, argv, chdir:, timeout:)
  out, err, status = Open3.capture3(env, 'timeout', "#{timeout}s", *argv, chdir: chdir)
  return out.empty? ? err : out if status.success?

  warn "command failed: #{argv.join(' ')}"
  warn "timed out after #{timeout}s" if status.exitstatus == 124
  warn err unless err.empty?
  warn out unless out.empty?
  exit status.exitstatus || 1
end

def run_measured(env, argv, chdir:, timeout:)
  out, err, status = Open3.capture3(
    env,
    '/usr/bin/time',
    '-f',
    '__MAX_RSS_KB=%M',
    'timeout',
    "#{timeout}s",
    *argv,
    chdir: chdir
  )
  rss_line = err.lines.find { |line| line.start_with?('__MAX_RSS_KB=') }
  rss_kb = rss_line&.split('=', 2)&.last&.to_i
  clean_err = err.lines.reject { |line| line.start_with?('__MAX_RSS_KB=') }.join

  if status.success?
    return [out.empty? ? clean_err : out, rss_kb]
  end

  warn "command failed: #{argv.join(' ')}"
  warn "timed out after #{timeout}s" if status.exitstatus == 124
  warn clean_err unless clean_err.empty?
  warn out unless out.empty?
  exit status.exitstatus || 1
end

def command_available?(path)
  return File.executable?(path) if path.include?(File::SEPARATOR)

  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
    File.executable?(File.join(dir, path))
  end
end

def best_and_median(samples)
  sorted = samples.sort
  [sorted.first, sorted[sorted.length / 2]]
end

def parse_size(output)
  first_line = output.lines.first&.strip || ''
  match = first_line.match(/\A([0-9]+)/)
  abort "could not parse byte count from output: #{first_line.inspect}" unless match
  match[1].to_i
end

target = File.expand_path(ARGV[0] || File.join(ROOT, 'src'))
runs = (ARGV[1] || ENV['RUNS'] || '5').to_i
timeout = (ENV['BENCH_TIMEOUT'] || '30').to_i
usage! if runs <= 0
abort "BENCH_TIMEOUT must be positive" if timeout <= 0
abort "target does not exist: #{target}" unless File.exist?(target)

nproc = `nproc 2>/dev/null`.strip.to_i
nproc = 1 if nproc <= 0
default_threads = nproc.to_s
threads = ENV['CLEAR_THREADS'] || ENV['BENCH_CORES'] || default_threads

puts "Building pdu..."
run_checked(
  { 'BUNDLE_WITHOUT' => 'development' },
  ['./clear', 'build', '--optimized', SOURCE, '-o', BINARY],
  chdir: ROOT,
  timeout: timeout
)

unless command_available?(DISKUS)
  warn "diskus not found at #{DISKUS}"
  warn "Install with: cargo install diskus --version 0.7.0 --locked"
  exit 1
end

tools = [
  ['pdu', { 'CLEAR_THREADS' => threads }, [BINARY]],
  ['diskus', {}, [DISKUS, '--threads', threads, '--apparent-size', '.']]
]

puts "Target: #{target}"
puts "Runs: #{runs}"
puts "Timeout: #{timeout}s"
puts "Threads: #{threads}"
puts

expected_size = nil
tools.each do |name, env, argv|
  times = []
  rss_samples = []
  last_output = nil
  last_size = nil

  runs.times do
    elapsed = Benchmark.realtime do
      last_output, rss_kb = run_measured(env, argv, chdir: target, timeout: timeout)
      rss_samples << rss_kb if rss_kb
    end
    last_size = parse_size(last_output)
    times << elapsed
  end

  expected_size ||= last_size
  abort "size mismatch: #{name} returned #{last_size}, expected #{expected_size}" if last_size != expected_size

  best, median = best_and_median(times)
  rss_best, rss_median = best_and_median(rss_samples)
  first_line = last_output.lines.first&.strip || ''
  puts "%-8s best %.4fs  median %.4fs  rss_best %dKB  rss_median %dKB  %s" %
    [name, best, median, rss_best, rss_median, first_line]
end
