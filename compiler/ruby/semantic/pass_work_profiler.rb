# typed: strict
# frozen_string_literal: true

require "csv"
require "sorbet-runtime"
require_relative "../ast/ast"
require_relative "../mir/mir"

module PassWorkProfiler
  extend T::Sig

  ProfileScalar = T.type_alias { T.nilable(T.any(Symbol, String, Numeric, T::Boolean, Type, Lexer::Token)) }
  ProfileStructNode = T.type_alias { T.any(AST::Locatable, MIR::Emittable, Struct) }
  ProfileWalkValue = T.type_alias do
    T.nilable(T.any(
      ProfileScalar,
      ProfileStructNode,
      T::Array[ProfileScalar],
      T::Array[ProfileStructNode],
      T::Hash[Symbol, ProfileScalar],
      T::Hash[Symbol, ProfileStructNode],
    ))
  end

  class WorkSummary < T::Struct
    const :stage, String
    const :kind, String
    const :calls, Integer
    const :units, Integer
    const :seconds, Float
    const :exclusive_seconds, Float
  end

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
    prop :work_calls, T::Hash[String, Integer], default: {}
    prop :work_units, T::Hash[String, Integer], default: {}
    prop :work_seconds, T::Hash[String, Float], default: {}
    prop :work_exclusive_seconds, T::Hash[String, Float], default: {}

    sig { params(kind: String, yields: Integer, seconds: Float).void }
    def add_walk(kind, yields, seconds)
      walk_calls[kind] = walk_calls.fetch(kind, 0) + 1
      walk_yields[kind] = walk_yields.fetch(kind, 0) + yields
      walk_seconds[kind] = walk_seconds.fetch(kind, 0.0) + seconds
    end

    sig { params(kind: String, units: Integer, seconds: Float, exclusive_seconds: Float).void }
    def add_work(kind, units, seconds, exclusive_seconds)
      work_calls[kind] = work_calls.fetch(kind, 0) + 1
      work_units[kind] = work_units.fetch(kind, 0) + units
      work_seconds[kind] = work_seconds.fetch(kind, 0.0) + seconds
      work_exclusive_seconds[kind] = work_exclusive_seconds.fetch(kind, 0.0) + exclusive_seconds
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

    sig { returns(Integer) }
    def total_work_calls
      work_calls.values.sum
    end

    sig { returns(Integer) }
    def total_work_units
      work_units.values.sum
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

    sig { returns(String) }
    def top_walk_times
      walk_seconds
        .sort_by { |kind, seconds| [-seconds, kind] }
        .first(3)
        .map { |kind, seconds| "#{kind}:#{format("%.3fs", seconds)}" }
        .join(";")
    end

    sig { returns(String) }
    def top_work
      work_units
        .sort_by { |kind, units| [-units, kind] }
        .first(3)
        .map { |kind, units| "#{kind}:#{PassWorkProfiler.format_count(units)}" }
        .join(";")
    end

    sig { returns(String) }
    def top_work_times
      work_seconds
        .sort_by { |kind, seconds| [-seconds, kind] }
        .first(3)
        .map { |kind, seconds| "#{kind}:#{format("%.3fs", seconds)}" }
        .join(";")
    end

    sig { returns(String) }
    def top_work_exclusive_times
      work_exclusive_seconds
        .sort_by { |kind, seconds| [-seconds, kind] }
        .first(3)
        .map { |kind, seconds| "#{kind}:#{format("%.3fs", seconds)}" }
        .join(";")
    end

    sig { returns(T::Array[WorkSummary]) }
    def work_summaries
      work_calls.keys.sort.map do |kind|
        WorkSummary.new(
          stage: label,
          kind: kind,
          calls: work_calls.fetch(kind),
          units: work_units.fetch(kind, 0),
          seconds: work_seconds.fetch(kind, 0.0),
          exclusive_seconds: work_exclusive_seconds.fetch(kind, 0.0),
        )
      end
    end
  end

  class WorkFrame < T::Struct
    const :stage_label, String
    const :started_at, Float
    prop :child_seconds, Float, default: 0.0
  end

  class RecordStore
    extend T::Sig

    sig { void }
    def initialize
      @records = T.let({}, T::Hash[String, StageRecord])
      @next_sequence = T.let(0, Integer)
    end

    sig { params(label: String).returns(StageRecord) }
    def fetch(label)
      existing = @records[label]
      return existing if existing

      record = StageRecord.new(label: label, sequence: @next_sequence)
      @next_sequence += 1
      @records[label] = record
      record
    end

    sig { returns(T::Array[StageRecord]) }
    def records
      @records.values.sort_by(&:sequence)
    end
  end

  class StageStack
    extend T::Sig

    sig { void }
    def initialize
      @labels = T.let([], T::Array[String])
    end

    sig { params(label: String).void }
    def push(label)
      @labels << label
    end

    sig { void }
    def pop
      @labels.pop
    end

    sig { returns(String) }
    def current_label
      @labels.last || "(outside)"
    end
  end

  class WorkFrameStack
    extend T::Sig

    sig { void }
    def initialize
      @frames = T.let([], T::Array[WorkFrame])
    end

    sig { params(frame: WorkFrame).void }
    def push(frame)
      @frames << frame
    end

    sig { returns(T.nilable(WorkFrame)) }
    def pop
      @frames.pop
    end

    sig { returns(T.nilable(WorkFrame)) }
    def current
      @frames.last
    end
  end

  class Profiler
    extend T::Sig

    sig { void }
    def initialize
      @record_store = T.let(RecordStore.new, RecordStore)
      @stage_stack = T.let(StageStack.new, StageStack)
      @work_stack = T.let(WorkFrameStack.new, WorkFrameStack)
    end

    sig do
      params(
        label: String,
        ast_root: T.nilable(ProfileWalkValue),
        mir_root: T.nilable(ProfileWalkValue),
        token_count: T.nilable(Integer),
        block: T.proc.returns(T.any(Float, Symbol))
      ).returns(T.any(Float, Symbol))
    end
    def measure(label, ast_root: nil, mir_root: nil, token_count: nil, &block)
      record = T.let(nil, T.nilable(StageRecord))
      started = T.let(nil, T.nilable(Float))
      record = record_for(label)
      record.calls += 1
      record.input_tokens += token_count if token_count
      record.input_ast_nodes += PassWorkProfiler.count_ast_nodes(ast_root) if ast_root
      record.input_mir_nodes += PassWorkProfiler.count_mir_nodes(mir_root) if mir_root

      @stage_stack.push(label)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      block.call
    ensure
      if record && started
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - started
        record.seconds += elapsed
        @stage_stack.pop
      end
    end

    sig { params(kind: String, yields: Integer, seconds: Float).void }
    def record_walk(kind, yields, seconds)
      record_for(current_label).add_walk(kind, yields, seconds)
    end

    sig { params(kind: String, units: Integer, seconds: Float, exclusive_seconds: Float).void }
    def record_work(kind, units, seconds, exclusive_seconds)
      record_for(current_label).add_work(kind, units, seconds, exclusive_seconds)
    end

    sig { params(kind: String, units: Integer, block: T.proc.returns(Symbol)).returns(Symbol) }
    def measure_work(kind, units: 0, &block)
      frame = T.let(nil, T.nilable(WorkFrame))
      frame = WorkFrame.new(
        stage_label: current_label,
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      )
      @work_stack.push(frame)
      block.call
    ensure
      if frame
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - frame.started_at
        exclusive_seconds = elapsed - frame.child_seconds
        exclusive_seconds = 0.0 if exclusive_seconds.negative?
        @work_stack.pop
        parent = @work_stack.current
        parent.child_seconds += elapsed if parent
        record_for(frame.stage_label).add_work(kind, units, elapsed, exclusive_seconds)
      end
    end

    sig { returns(T::Array[StageRecord]) }
    def records
      @record_store.records
    end

    sig { returns(T::Array[WorkSummary]) }
    def work_summaries
      records.flat_map(&:work_summaries)
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
          "top_walk_times",
          "work_calls",
          "work_units",
          "top_work",
          "top_work_times",
          "top_work_exclusive_times",
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
            record.top_walk_times,
            record.total_work_calls,
            record.total_work_units,
            record.top_work,
            record.top_work_times,
            record.top_work_exclusive_times,
          ]
        end
      end
    end

    sig { returns(String) }
    def work_details_to_csv
      CSV.generate do |csv|
        csv << ["stage", "kind", "calls", "units", "seconds", "exclusive_seconds"]
        work_summaries.each do |summary|
          csv << [
            summary.stage,
            summary.kind,
            summary.calls,
            summary.units,
            format("%.6f", summary.seconds),
            format("%.6f", summary.exclusive_seconds),
          ]
        end
      end
    end

    sig { returns(String) }
    def to_table
      lines = T.let([], T::Array[String])
      lines << format(
        "%-48s %5s %10s %10s %9s %12s %12s %9s %12s %12s %9s %12s %12s %9s %12s %12s %s %s %s %s %s",
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
        "top_walkers",
        "top_walk_times",
        "work_calls",
        "work_units",
        "top_work",
        "top_work_times",
        "top_work_excl"
      )
      records.each do |record|
        lines << format(
          "%-48s %5d %10s %10s %9.3f %12s %12s %9.1f %12s %12s %9.1f %12s %12s %9.1f %12s %12s %s %s %s %s %s",
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
          record.top_walkers,
          record.top_walk_times,
          PassWorkProfiler.format_count(record.total_work_calls),
          PassWorkProfiler.format_count(record.total_work_units),
          record.top_work,
          record.top_work_times,
          record.top_work_exclusive_times
        )
      end
      lines.join("\n")
    end

    sig { returns(String) }
    def work_details_to_table
      lines = T.let([], T::Array[String])
      lines << format(
        "%-48s %-56s %8s %10s %10s %10s",
        "stage",
        "kind",
        "calls",
        "units",
        "seconds",
        "exclusive"
      )
      work_summaries
        .sort_by { |summary| [-summary.seconds, summary.stage, summary.kind] }
        .each do |summary|
          lines << format(
            "%-48s %-56s %8d %10s %10.3f %10.3f",
            summary.stage,
            summary.kind,
            summary.calls,
            PassWorkProfiler.format_count(summary.units),
            summary.seconds,
            summary.exclusive_seconds
          )
        end
      lines.join("\n")
    end

    private

    sig { returns(String) }
    def current_label
      @stage_stack.current_label
    end

    sig { params(label: String).returns(StageRecord) }
    def record_for(label)
      @record_store.fetch(label)
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

  sig { params(root: ProfileWalkValue).returns(Integer) }
  def self.count_ast_nodes(root)
    count_nodes(root, "AST::", {})
  end

  sig { params(root: ProfileWalkValue).returns(Integer) }
  def self.count_mir_nodes(root)
    count_nodes(root, "MIR::", {})
  end

  sig { params(value: Integer).returns(String) }
  def self.format_count(value)
    return value.to_s if value.abs < 1_000
    return format("%.1fk", value / 1_000.0) if value.abs < 1_000_000

    format("%.1fm", value / 1_000_000.0)
  end

  sig { params(root: ProfileWalkValue, namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
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
      next unless value.nil? || value.is_a?(Array) || value.is_a?(Hash) ||
                  value.is_a?(Struct) || value.is_a?(Symbol) ||
                  value.is_a?(String) || value.is_a?(Numeric) ||
                  value == true || value == false || value.is_a?(Type) ||
                  value.is_a?(Lexer::Token)

      count += count_nodes(value, namespace, seen)
    end
    count
  end
  private_class_method :count_nodes

  sig { params(root: T::Array[ProfileWalkValue], namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
  def self.count_array_nodes(root, namespace, seen)
    root.sum { |value| count_nodes(value, namespace, seen) }
  end
  private_class_method :count_array_nodes

  sig { params(root: T::Hash[ProfileWalkValue, ProfileWalkValue], namespace: String, seen: T::Hash[Integer, TrueClass]).returns(Integer) }
  def self.count_hash_nodes(root, namespace, seen)
    root.each_value.sum do |value|
      next 0 unless value.nil? || value.is_a?(Array) || value.is_a?(Hash) ||
                    value.is_a?(Struct) || value.is_a?(Symbol) ||
                    value.is_a?(String) || value.is_a?(Numeric) ||
                    value == true || value == false || value.is_a?(Type) ||
                    value.is_a?(Lexer::Token)

      count_nodes(value, namespace, seen)
    end
  end
  private_class_method :count_hash_nodes

  sig { params(root: ProfileWalkValue, namespace: String).returns(T::Boolean) }
  def self.profiler_node?(root, namespace)
    class_name = root.class.name
    return false unless class_name
    return false unless root
    return false unless class_name.start_with?(namespace)

    root.respond_to?(:each_pair) == true
  end
  private_class_method :profiler_node?

  sig { params(root: ProfileWalkValue).returns(T::Boolean) }
  def self.scalar?(root)
    root.nil? || root.is_a?(Symbol) || root.is_a?(String) ||
      root.is_a?(Numeric) || root == true || root == false ||
      root.is_a?(Type) || root.is_a?(Lexer::Token)
  end
  private_class_method :scalar?
end
