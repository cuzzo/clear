# typed: strict

require "sorbet-runtime"
require "set"

class MIRPassOrderError < StandardError; end

# Monotonic record of the compiler facts available on an AST/MIR program.
# Passes consume earlier stamps and add exactly one new stamp when they finish.
class MIRPassState
  extend T::Sig

  ORDER = T.let([
    :annotated,
    :pipeline_rewritten,
    :string_concat_rewritten,
    :hoisted,
    :premir_type_checked,
    :escape_analyzed,
    :cleanup_classified,
    :loop_frame_analyzed,
    :needs_rt_finalized,
    :mir_pass_complete,
    :mir_lowered,
    :mir_checked,
  ].freeze, T::Array[Symbol])

  sig { returns(T::Set[Symbol]) }
  attr_reader :completed

  sig { void }
  def initialize
    @completed = T.let(Set.new, T::Set[Symbol])
  end

  sig { params(stage: Symbol).void }
  def mark!(stage)
    validate_stage!(stage)
    idx = T.must(ORDER.index(stage))
    missing = T.must(ORDER[0...idx]).reject { |dep| @completed.include?(dep) }
    unless missing.empty?
      raise MIRPassOrderError, "cannot mark #{stage}; missing earlier stage(s): #{missing.join(", ")}"
    end
    @completed.add(stage)
  end

  sig { params(stage: Symbol, consumer: String).void }
  def require!(stage, consumer:)
    validate_stage!(stage)
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
    return if ORDER.include?(stage)

    raise MIRPassOrderError, "unknown MIR pass stage #{stage.inspect}"
  end
end
