# typed: strict
# frozen_string_literal: true

require "csv"
require "sorbet-runtime"

module PassWorkProfiler
  extend T::Sig

  class StageRecord < T::Struct
    extend T::Sig

    const :label, String
    const :sequence, Integer
    prop :calls, Integer, default: 0
    prop :seconds, Float, default: 0.0
    prop :input_tokens, Integer, default: 0
    prop :input_ast_nodes, Integer, default: 0
    prop :input_mir_nodes, Integer, default: 0
    prop :walk_calls, T::Hash[String, Integer], default: {}
    prop :walk_yields, T::Hash[String, Integer], default: {}
    prop :walk_seconds, T::Hash[String, Float], default: {}

    sig { params(kind: String, yields: Integer, seconds: Float).void }
    def add_walk(kind, yields, seconds)
      walk_calls[kind] = walk_calls.fetch(kind, 0) + 1
      walk_yields[kind] = walk_yields.fetch(kind, 0) + yields
      walk_seconds[kind] = walk_seconds.fetch(kind, 0.0) + seconds
    end

    sig { returns(Integer) }
    def ast_walk_calls
      walk_calls.select { |kind, _count| kind.start_with?("AST.") }.values.sum
    end

    sig { returns(Integer) }
    def ast_walk_yields
      walk_yields.select { |kind, _count| kind.start_with?("AST.") }.values.sum
    end

    sig { returns(Integer) }
    def mir_walk_calls
      walk_calls.select { |kind, _count| kind.start_with?("MIR.") }.values.sum
    end

    sig { returns(Integer) }
    def mir_walk_yields
      walk_yields.select { |kind, _count| kind.start_with?("MIR.") }.values.sum
    end

    sig { returns(Integer) }
    def total_walk_calls
      walk_calls.values.sum
    end

    sig { returns(Integer) }
    def total_walk_yields
      walk_yields.values.sum
    end

    sig { params(numerator: Integer, denominator: Integer).returns(Float) }
    def self.ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      numerator.to_f / denominator
    end

    sig { returns(Float) }
    def ast_yields_per_input_node
      StageRecord.ratio(ast_walk_yields, input_ast_nodes)
    end

    sig { returns(Float) }
    def mir_yields_per_input_node
      StageRecord.ratio(mir_walk_yields, input_mir_nodes)
    end

    sig { returns(Float) }
    def walk_yields_per_input
      input = input_ast_nodes + input_mir_nodes
      input = input_tokens if input.zero?
      StageRecord.ratio(total_walk_yields, input)
    end

    sig { returns(String) }
    def top_walkers
      walk_yields
        .sort_by { |kind, yields| [-yields, kind] }
        .first(3)
        .map { |kind, yields| "#{kind}:#{PassWorkProfiler.format_count(yields)}" }
        .join(";")
    end
  end

  class Profiler
    extend T::Sig

    sig { void }
    def initialize
      @records = T.let({}, T::Hash[String, StageRecord])
      @stack = T.let([], T::Array[String])
      @next_sequence = T.let(0, Integer)
    end

    sig do
      params(
        label: String,
        ast_root: T.untyped,
        mir_root: T.untyped,
        token_count: T.nilable(Integer),
        block: T.proc.returns(T.untyped)
      ).returns(T.untyped)
    end
    def measure(label, ast_root: nil, mir_root: nil, token_count: nil, &block)
      record = T.let(nil, T.nilable(StageRecord))
      started = T.let(nil, T.nilable(Float))
      record = record_for(label)
      record.calls += 1
      record.input_tokens += token_count if token_count
      record.input_ast_nodes += PassWorkProfiler.count_ast_nodes(ast_root) if ast_root
      record.input_mir_nodes += PassWorkProfiler.count_mir_nodes(mir_root) if mir_root

      @stack << label
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      block.call
    ensure
      if record && started
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - started
        record.seconds += elapsed
        @stack.pop
      end
    end

    sig { params(kind: String, yields: Integer, seconds: Float).void }
    def record_walk(kind, yields, seconds)
      record_for(current_label).add_walk(kind, yields, seconds)
    end

    sig { returns(T::Array[StageRecord]) }
    def records
      @records.values.sort_by(&:sequence)
    end

    sig { returns(String) }
    def to_csv
      CSV.generate do |csv|
        csv << [
          "stage",
          "calls",
          "input_tokens",
          "input_ast_nodes",
          "input_mir_nodes",
          "seconds",
          "walk_calls",
          "walk_yields",
          "walk_yields_per_input",
          "ast_walk_calls",
          "ast_walk_yields",
          "ast_yields_per_input_ast_node",
          "mir_walk_calls",
          "mir_walk_yields",
          "mir_yields_per_input_mir_node",
          "top_walkers",
        ]
        records.each do |record|
          csv << [
            record.label,
            record.calls,
            record.input_tokens,
            record.input_ast_nodes,
            record.input_mir_nodes,
            format("%.6f", record.seconds),
            record.total_walk_calls,
            record.total_walk_yields,
            format("%.2f", record.walk_yields_per_input),
            record.ast_walk_calls,
            record.ast_walk_yields,
            format("%.2f", record.ast_yields_per_input_node),
            record.mir_walk_calls,
            record.mir_walk_yields,
            format("%.2f", record.mir_yields_per_input_node),
            record.top_walkers,
          ]
        end
      end
    end

    sig { returns(String) }
    def to_table
      lines = T.let([], T::Array[String])
      lines << format(
        "%-48s %5s %10s %10s %9s %12s %12s %9s %12s %12s %9s %12s %12s %9s %s",
        "stage",
        "calls",
        "tokens",
        "ast_in",
        "seconds",
        "walk_calls",
        "walk_yields",
        "work_x",
        "ast_calls",
        "ast_yields",
        "ast_x",
        "mir_calls",
        "mir_yields",
        "mir_x",
        "top_walkers"
      )
      records.each do |record|
        lines << format(
          "%-48s %5d %10s %10s %9.3f %12s %12s %9.1f %12s %12s %9.1f %12s %12s %9.1f %s",
          record.label,
          record.calls,
          PassWorkProfiler.format_count(record.input_tokens),
          PassWorkProfiler.format_count(record.input_ast_nodes),
          record.seconds,
          PassWorkProfiler.format_count(record.total_walk_calls),
          PassWorkProfiler.format_count(record.total_walk_yields),
          record.walk_yields_per_input,
          PassWorkProfiler.format_count(record.ast_walk_calls),
          PassWorkProfiler.format_count(record.ast_walk_yields),
          record.ast_yields_per_input_node,
          PassWorkProfiler.format_count(record.mir_walk_calls),
          PassWorkProfiler.format_count(record.mir_walk_yields),
          record.mir_yields_per_input_node,
          record.top_walkers
        )
      end
      lines.join("\n")
    end

    private

    sig { returns(String) }
    def current_label
      @stack.last || "(outside)"
    end

    sig { params(label: String).returns(StageRecord) }
    def record_for(label)
      existing = @records[label]
      return existing if existing

      record = StageRecord.new(label: label, sequence: @next_sequence)
      @next_sequence += 1
      @records[label] = record
      record
    end
  end

  class << self
    extend T::Sig

    sig { returns(T.nilable(Profiler)) }
    def current
      Thread.current[:pass_work_profiler]
    end

    sig { params(profiler: T.nilable(Profiler)).void }
    def current=(profiler)
      Thread.current[:pass_work_profiler] = profiler
    end
  end

  SCALAR_CLASSES = T.let(
    [Symbol, String, Numeric, TrueClass, FalseClass, NilClass].freeze,
    T::Array[T.class_of(Object)]
  )

  sig { params(root: T.untyped).returns(Integer) }
  def self.count_ast_nodes(root)
    count_nodes(root, "AST::", {})
  end

  sig { params(root: T.untyped).returns(Integer) }
  def self.count_mir_nodes(root)
    count_nodes(root, "MIR::", {})
  end

  sig { params(value: Integer).returns(String) }
  def self.format_count(value)
    return value.to_s if value.abs < 1_000
    return format("%.1fk", value / 1_000.0) if value.abs < 1_000_000

    format("%.1fm", value / 1_000_000.0)
  end

  sig { params(root: T.untyped, namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
  def self.count_nodes(root, namespace, seen)
    return 0 if scalar?(root)
    return count_array_nodes(root, namespace, seen) if root.is_a?(Array)
    return count_hash_nodes(root, namespace, seen) if root.is_a?(Hash)
    return 0 unless profiler_node?(root, namespace)

    object_id = root.object_id
    return 0 if seen[object_id]

    seen[object_id] = true
    count = T.let(1, Integer)
    T.unsafe(root).each_pair do |_member, value|
      count += count_nodes(value, namespace, seen)
    end
    count
  end
  private_class_method :count_nodes

  sig { params(root: T::Array[T.untyped], namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
  def self.count_array_nodes(root, namespace, seen)
    root.sum { |value| count_nodes(value, namespace, seen) }
  end
  private_class_method :count_array_nodes

  sig { params(root: T::Hash[T.untyped, T.untyped], namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
  def self.count_hash_nodes(root, namespace, seen)
    root.each_value.sum { |value| count_nodes(value, namespace, seen) }
  end
  private_class_method :count_hash_nodes

  sig { params(root: T.untyped, namespace: String).returns(T::Boolean) }
  def self.profiler_node?(root, namespace)
    class_name = root.class.name
    !!class_name&.start_with?(namespace) && root.respond_to?(:each_pair)
  end
  private_class_method :profiler_node?

  sig { params(root: T.untyped).returns(T::Boolean) }
  def self.scalar?(root)
    SCALAR_CLASSES.any? { |klass| root.is_a?(klass) }
  end
  private_class_method :scalar?
end
