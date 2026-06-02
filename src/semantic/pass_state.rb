# typed: strict

require "sorbet-runtime"
require "set"

class MIRPassOrderError < StandardError; end

# Monotonic record of the compiler facts available on an AST/MIR program.
# Passes consume earlier stamps and add exactly one new stamp when they finish.
class MIRPassState
  extend T::Sig

  class StageSpec < T::Struct
    const :name, Symbol
    const :producer, String
    const :requires, T.nilable(Symbol)
  end

  STAGES = T.let([
    StageSpec.new(name: :annotated, producer: "SemanticAnnotator", requires: nil),
    StageSpec.new(name: :pipeline_rewritten, producer: "PipelineRewriter", requires: :annotated),
    StageSpec.new(name: :string_concat_rewritten, producer: "StringConcatRewriter", requires: :pipeline_rewritten),
    StageSpec.new(name: :hoisted, producer: "Hoist", requires: :string_concat_rewritten),
    StageSpec.new(name: :premir_type_checked, producer: "PreMirTypeCheck", requires: :hoisted),
    StageSpec.new(name: :escape_analyzed, producer: "MIRPass/EscapeAnalysis", requires: :premir_type_checked),
    StageSpec.new(name: :cleanup_classified, producer: "MIRPass/CleanupClassifier", requires: :escape_analyzed),
    StageSpec.new(name: :loop_frame_analyzed, producer: "MIRPass/LoopFrameAnalysis", requires: :cleanup_classified),
    StageSpec.new(name: :needs_rt_finalized, producer: "MIRPass#finalize_needs_rt!", requires: :loop_frame_analyzed),
    StageSpec.new(name: :mir_pass_complete, producer: "MIRPass", requires: :needs_rt_finalized),
    StageSpec.new(name: :mir_lowered, producer: "MIRLowering", requires: :mir_pass_complete),
    StageSpec.new(name: :mir_checked, producer: "MIRChecker", requires: :mir_lowered),
  ].freeze, T::Array[StageSpec])

  ORDER = T.let(STAGES.map(&:name).freeze, T::Array[Symbol])
  STAGE_BY_NAME = T.let(STAGES.to_h { |spec| [spec.name, spec] }.freeze, T::Hash[Symbol, StageSpec])

  sig { returns(T::Set[Symbol]) }
  attr_reader :completed

  sig { void }
  def initialize
    @completed = T.let(Set.new, T::Set[Symbol])
  end

  sig { params(stage: Symbol).void }
  def mark!(stage)
    spec = stage_spec!(stage)
    if @completed.include?(stage)
      raise MIRPassOrderError, "#{spec.producer} attempted to mark #{stage} twice"
    end

    expected = next_unmarked_stage
    unless stage == expected
      raise MIRPassOrderError,
        "#{spec.producer} cannot mark #{stage}; next required stage is #{expected.inspect}; " \
        "completed stages: #{completed_stages.join(", ")}"
    end
    @completed.add(stage)
  end

  sig { params(stage: Symbol, consumer: String).void }
  def require!(stage, consumer:)
    stage_spec!(stage)
    return if @completed.include?(stage)

    raise MIRPassOrderError,
      "#{consumer} requires #{stage}; completed stages: #{completed_stages.join(", ")}"
  end

  sig { returns(T::Array[Symbol]) }
  def completed_stages
    ORDER.select { |stage| @completed.include?(stage) }
  end

  sig { returns(MIRPassState) }
  def copy
    state = MIRPassState.new
    @completed.each { |stage| state.completed.add(stage) }
    state
  end

  sig { params(program: Object).returns(MIRPassState) }
  def self.for!(program)
    state = program.respond_to?(:mir_pass_state) ? T.unsafe(program).mir_pass_state : nil
    unless state.is_a?(MIRPassState)
      state = MIRPassState.new
      T.unsafe(program).mir_pass_state = state if program.respond_to?(:mir_pass_state=)
    end
    state
  end

  sig { params(program: Object, stage: Symbol, consumer: String).void }
  def self.require!(program, stage, consumer:)
    state = program.respond_to?(:mir_pass_state) ? T.unsafe(program).mir_pass_state : nil
    unless state.is_a?(MIRPassState)
      raise MIRPassOrderError, "#{consumer} requires pass state; program was not produced by the MIR pipeline"
    end
    state.require!(stage, consumer: consumer)
  end

  sig { params(stage: Symbol).void }
  def validate_stage!(stage)
    return if STAGE_BY_NAME.key?(stage)

    raise MIRPassOrderError, "unknown MIR pass stage #{stage.inspect}"
  end

  sig { params(stage: Symbol).returns(StageSpec) }
  def stage_spec!(stage)
    spec = STAGE_BY_NAME[stage]
    return spec if spec

    raise MIRPassOrderError, "unknown MIR pass stage #{stage.inspect}"
  end

  sig { returns(T.nilable(Symbol)) }
  def next_unmarked_stage
    ORDER.find { |candidate| !@completed.include?(candidate) }
  end
end
