# typed: strict
# Shared helpers for mutation-test runners.

require 'fileutils'
require 'json'
require 'open3'
require 'sorbet-runtime'
require 'time'

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

  sig { params(path: String).returns(String) }
  def self.relative_repo_path(path)
    expanded = File.expand_path(path)
    root = "#{ROOT}/"
    expanded.start_with?(root) ? expanded.delete_prefix(root) : path
  end

  sig { params(patch: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.patch_changed_line_records(patch)
    hunks = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
    current_path = T.let(nil, T.nilable(String))
    current_hunk = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))

    File.foreach(patch, chomp: true) do |line|
      if (match = line.match(/^diff --git a\/(.+?) b\/(.+)$/))
        current_path = T.must(match[2])
        current_hunk = nil
        next
      end

      if (match = line.match(/^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@/))
        next unless current_path

        current_hunk = {
          file: T.must(current_path),
          old_start: T.must(match[1]).to_i,
          entries: [],
        }
        hunks << T.must(current_hunk)
        next
      end

      next unless current_hunk
      next if line.start_with?("\\")
      next unless [" ", "-", "+"].include?(line[0])

      T.cast(T.must(current_hunk)[:entries], T::Array[T::Array[String]]) << [T.must(line[0]), line[1..].to_s]
    end

    hunks.flat_map do |hunk|
      hunk_changed_line_records(
        T.cast(hunk[:file], String),
        T.cast(hunk[:old_start], Integer),
        T.cast(hunk[:entries], T::Array[T::Array[String]])
      )
    end
  end

  sig do
    params(
      path: String,
      old_start: Integer,
      entries: T::Array[T::Array[String]]
    ).returns(T::Array[T::Hash[Symbol, T.untyped]])
  end
  def self.hunk_changed_line_records(path, old_start, entries)
    records = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
    source_lines = source_lines(path)
    actual_start = best_hunk_start(source_lines, entries, old_start) || old_start
    groups = T.let([], T::Array[[T::Array[Integer], T::Boolean, Integer]])
    old_cursor = T.let(actual_start, Integer)
    changed_lines = T.let([], T::Array[Integer])
    has_added = false

    entries.each do |tag, _text|
      case tag
      when " "
        groups << [changed_lines.dup, has_added, old_cursor] if changed_lines.any? || has_added
        changed_lines.clear
        has_added = false
        old_cursor += 1
      when "-"
        changed_lines << old_cursor
        old_cursor += 1
      when "+"
        has_added = true
      end
    end
    groups << [changed_lines.dup, has_added, old_cursor] if changed_lines.any? || has_added

    groups.each do |line_numbers, added, insertion_line|
      lines = line_numbers.dup
      if lines.empty? && added
        lines << insertion_anchor_line(path, insertion_line)
      end
      lines.uniq.each do |line_number|
        context = source_lines[line_number - 1]
        next unless context

        records << { file: path, line: line_number, context_line: context }
      end
    end
    records
  end

  sig do
    params(
      source_lines: T::Array[String],
      entries: T::Array[T::Array[String]],
      old_start: Integer
    ).returns(T.nilable(Integer))
  end
  def self.best_hunk_start(source_lines, entries, old_start)
    old_side = entries.filter_map do |tag, text|
      text unless tag == "+"
    end
    return nil if old_side.empty? || source_lines.length < old_side.length

    candidates = T.let([], T::Array[Integer])
    limit = source_lines.length - old_side.length
    (0..limit).each do |index|
      candidates << index + 1 if source_lines[index, old_side.length] == old_side
    end
    candidates.min_by { |line| (line - old_start).abs }
  end

  sig { params(path: String, fallback_line: Integer).returns(Integer) }
  def self.insertion_anchor_line(path, fallback_line)
    absolute = File.join(ROOT, path)
    line_count = File.file?(absolute) ? File.foreach(absolute).count : 0
    return 1 if line_count.zero?
    return line_count if fallback_line > line_count

    [fallback_line, 1].max
  end

  sig { params(path: String, line_number: Integer).returns(T.nilable(String)) }
  def self.source_line(path, line_number)
    return nil unless line_number.positive?

    source_lines(path)[line_number - 1]
  rescue Errno::ENOENT
    nil
  end

  sig { params(path: String).returns(T::Array[String]) }
  def self.source_lines(path)
    File.readlines(File.join(ROOT, path), chomp: true)
  rescue Errno::ENOENT
    []
  end

  sig do
    params(
      path: String,
      source: String,
      hits: T::Array[T::Hash[Symbol, T.untyped]]
    ).void
  end
  def self.write_test_exposure(path, source:, hits:)
    body = {
      schema: 'test-exposure/v1',
      generated_at: Time.now.utc.iso8601,
      source: source,
      hits: hits,
    }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(body))
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
