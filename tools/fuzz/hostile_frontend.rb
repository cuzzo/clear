#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "rbconfig"
require "timeout"

ROOT = File.expand_path("../..", __dir__)
FAILURE_DIR = File.join(ROOT, "compiler/spec/integration/fixtures/hostile_frontend")

class HostileFrontend
  Result = Struct.new(:ok, :reason, :status, keyword_init: true)

  def initialize(timeout:, memory_mb:)
    @timeout = timeout
    @memory_bytes = memory_mb * 1024 * 1024
  end

  def run(source)
    reader, writer = IO.pipe
    pid = Process.spawn(
      RbConfig.ruby, __FILE__, "--worker",
      in: reader, out: File::NULL, err: File::NULL,
      rlimit_as: @memory_bytes,
      rlimit_cpu: [2, 2],
    )
    reader.close
    writer.binmode
    writer.write(source)
    writer.close

    status = nil
    Timeout.timeout(@timeout) { _, status = Process.wait2(pid) }
    return Result.new(ok: false, reason: "signal #{status.termsig}", status: status) if status.signaled?
    return Result.new(ok: false, reason: "internal exception (exit #{status.exitstatus})", status: status) unless status.success?

    Result.new(ok: true, reason: "diagnostic or successful parse", status: status)
  rescue Timeout::Error
    Process.kill("KILL", pid)
    Process.wait(pid)
    Result.new(ok: false, reason: "wall timeout", status: nil)
  rescue Errno::EPIPE
    _, status = Process.wait2(pid)
    Result.new(ok: false, reason: "worker exited while reading input", status: status)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end

def worker!
  require File.join(ROOT, "compiler/ruby/ast/parser")

  source = STDIN.binmode.read
  budget = FrontendResourceBudget.new(
    max_nesting: 192,
    max_tokens: 200_000,
    max_source_bytes: 2 * 1024 * 1024,
  )
  tokens = Lexer.new(source, file: "<hostile>", budget: budget).tokenize
  ClearParser.new(tokens, source, budget: budget).parse
  exit 0
rescue Lexer::Error, ParserError
  exit 0
rescue StandardError => error
  warn "#{error.class}: #{error.message}"
  warn error.backtrace&.first(8)
  exit 70
end

def mutate(source, random)
  bytes = source.b
  return bytes if bytes.empty?

  case random.rand(5)
  when 0
    bytes.byteslice(0, random.rand(bytes.bytesize + 1)).to_s
  when 1
    at = random.rand(bytes.bytesize + 1)
    bytes.byteslice(0, at).to_s + random.bytes(random.rand(1..8)) + bytes.byteslice(at..).to_s
  when 2
    at = random.rand(bytes.bytesize)
    bytes.byteslice(0, at).to_s + bytes.byteslice((at + 1)..).to_s
  when 3
    at = random.rand(bytes.bytesize)
    replacement = "()[]{}\"#;$".bytes.sample(random: random).chr
    bytes.byteslice(0, at).to_s + replacement + bytes.byteslice((at + 1)..).to_s
  else
    left = random.rand(bytes.bytesize)
    right = random.rand(left...bytes.bytesize)
    bytes + bytes.byteslice(left..right).to_s
  end
end

def minimize(source, harness)
  current = source.b
  chunk = [current.bytesize / 2, 1].max
  while chunk >= 1
    changed = false
    offset = 0
    while offset < current.bytesize
      candidate = current.byteslice(0, offset).to_s + current.byteslice((offset + chunk)..).to_s
      unless harness.run(candidate).ok
        current = candidate
        changed = true
        break
      end
      offset += chunk
    end
    chunk /= 2 unless changed
  end
  current
end

if ARGV.delete("--worker")
  worker!
end

options = { cases: 100, seed: 1, timeout: 1.0, memory_mb: 1024 }
OptionParser.new do |parser|
  parser.on("--cases N", Integer) { |value| options[:cases] = value }
  parser.on("--seed N", Integer) { |value| options[:seed] = value }
  parser.on("--timeout N", Float) { |value| options[:timeout] = value }
  parser.on("--memory-mb N", Integer) { |value| options[:memory_mb] = value }
end.parse!

random = Random.new(options[:seed])
seeds = [
  "value = 1_i64;",
  "IF value EXISTS AS item AND item > 0_i64 THEN PASS; END",
  "FN main(x: {Symbol}[List]?Tuple<Int64, String>) RETURNS Void -> PASS; END",
  "STRUCT Cache<M: SHARED Map, K: Hashable & Equality> { values: M }",
  "IMPLEMENTATION Cache<M> { METHOD get<N>(self: Cache<M>, key: N) RETURNS ?N -> RETURN NIL; END }",
  'message = "before ${call("nested")}";',
]
harness = HostileFrontend.new(timeout: options[:timeout], memory_mb: options[:memory_mb])

options[:cases].times do |index|
  source = if index.even?
    random.bytes(random.rand(0..512))
  else
    mutate(seeds.sample(random: random), random)
  end
  result = harness.run(source)
  next if result.ok

  minimized = minimize(source, harness)
  FileUtils.mkdir_p(FAILURE_DIR)
  path = File.join(FAILURE_DIR, "seed_#{options[:seed]}_case_#{index}.clear.bin")
  File.binwrite(path, minimized)
  warn "hostile frontend failure: #{result.reason}; minimized #{source.bytesize} -> #{minimized.bytesize} bytes; saved #{path}"
  exit 1
end

puts "hostile frontend: #{options[:cases]} cases passed (seed #{options[:seed]})"
