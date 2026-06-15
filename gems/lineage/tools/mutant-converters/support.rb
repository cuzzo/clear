# typed: strict
# Shared helpers for mutation-test runners.

require 'fileutils'
require 'open3'
require 'sorbet-runtime'

module MutationTesting
  extend T::Sig

  ROOT = T.let(File.expand_path('../../../..', __dir__), String)

  class CommandResult < T::Struct
    const :output, String
    const :exitstatus, Integer
  end

  class MutantSummary < T::Struct
    const :mutations, Integer
    const :kills, Integer
    const :alive, Integer
    const :timeouts, Integer
    const :selected_tests, Integer
    const :coverage, Float
  end

  class Shard < T::Struct
    const :index, Integer
    const :count, Integer
  end

  FuzzSummary = T.type_alias { T::Hash[Symbol, Integer] }

  sig { params(argv: T::Array[String], cwd: String, allow_failure: T::Boolean, log_path: T.nilable(String)).returns(CommandResult) }
  def self.run_cmd(argv, cwd: ROOT, allow_failure: false, log_path: nil)
    output, status = T.unsafe(Open3).capture2e(*argv, chdir: cwd)
    if log_path
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(log_path, output)
    end
    unless status.success? || allow_failure
      raise "command failed: #{argv.join(' ')}\n#{output}"
    end
    CommandResult.new(output: output, exitstatus: status.exitstatus || 1)
  end

  sig { params(output: String).returns(T.nilable(MutantSummary)) }
  def self.parse_mutant_summary(output)
    mutations = parse_int_metric(output, 'Mutations')
    kills = parse_int_metric(output, 'Kills')
    alive = parse_int_metric(output, 'Alive')
    timeouts = parse_int_metric(output, 'Timeouts')
    selected_tests = parse_int_metric(output, 'Selected-Tests')
    coverage = parse_float_metric(output, 'Coverage')
    return nil unless mutations && kills && alive && timeouts && selected_tests && coverage

    MutantSummary.new(
      mutations: mutations,
      kills: kills,
      alive: alive,
      timeouts: timeouts,
      selected_tests: selected_tests,
      coverage: coverage
    )
  end

  sig { params(output: String).returns(T.nilable(FuzzSummary)) }
  def self.parse_fuzz_summary(output)
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

  sig { params(value: String).returns(Shard) }
  def self.parse_shard(value)
    parts = value.split('/', 2)
    raise "invalid shard #{value.inspect}; expected INDEX/COUNT" unless parts.length == 2

    shard(Integer(parts.fetch(0)), Integer(parts.fetch(1)))
  rescue ArgumentError
    raise "invalid shard #{value.inspect}; expected integer INDEX/COUNT"
  end

  sig { params(index: Integer, count: Integer).returns(Shard) }
  def self.shard(index, count)
    raise "shard count must be positive, got #{count}" unless count.positive?
    raise "shard index must be between 0 and #{count - 1}, got #{index}" unless index >= 0 && index < count

    Shard.new(index: index, count: count)
  end

  sig do
    type_parameters(:Elem)
      .params(items: T::Array[T.type_parameter(:Elem)], shard: T.nilable(Shard))
      .returns(T::Array[T.type_parameter(:Elem)])
  end
  def self.shard_items(items, shard)
    return items unless shard

    items.each_with_index.filter_map do |item, index|
      item if (index % shard.count) == shard.index
    end
  end

  sig { params(shard: T.nilable(Shard)).returns(String) }
  def self.shard_label(shard)
    shard ? "#{shard.index}/#{shard.count}" : "all"
  end

  sig { params(output: String, label: String).returns(T.nilable(Integer)) }
  def self.parse_int_metric(output, label)
    match = output.match(/^#{Regexp.escape(label)}:\s+(\d+)/)
    match&.[](1)&.to_i
  end
  private_class_method :parse_int_metric

  sig { params(output: String, label: String).returns(T.nilable(Float)) }
  def self.parse_float_metric(output, label)
    match = output.match(/^#{Regexp.escape(label)}:\s+([0-9]+(?:\.[0-9]+)?)%/)
    match&.[](1)&.to_f
  end
  private_class_method :parse_float_metric
end
