# typed: strict

require "sorbet-runtime"

class MIRLoweringCounterKind < T::Enum
  enums do
    Tmp = new("tmp")
    BlockExpr = new("block_expr")
    SafeNav = new("safe_nav")
    Extern = new("extern")
    Lambda = new("lambda")
    StreamLiteral = new("stream_literal")
    DoBlock = new("do_block")
    BackgroundBlock = new("background_block")
    StreamGenerator = new("stream_generator")
    LoopMark = new("loop_mark")
    ForLoop = new("for_loop")
  end
end

class MIRLoweringGeneratedId < T::Struct
  extend T::Sig

  const :kind, MIRLoweringCounterKind
  const :value, Integer

  sig { params(other: T.untyped).returns(T::Boolean) }
  def ==(other)
    return false unless other.is_a?(MIRLoweringGeneratedId)

    other.kind == kind && other.value == value
  end

  sig { params(other: T.untyped).returns(T::Boolean) }
  def eql?(other)
    self == other
  end

  sig { returns(Integer) }
  def hash
    [kind, value].hash
  end

  sig { returns(String) }
  def to_s
    value.to_s
  end
end

class MIRLoweringCounters
  extend T::Sig

  COUNTER_KINDS = T.let([
    MIRLoweringCounterKind::Tmp,
    MIRLoweringCounterKind::BlockExpr,
    MIRLoweringCounterKind::SafeNav,
    MIRLoweringCounterKind::Extern,
    MIRLoweringCounterKind::Lambda,
    MIRLoweringCounterKind::StreamLiteral,
    MIRLoweringCounterKind::DoBlock,
    MIRLoweringCounterKind::BackgroundBlock,
    MIRLoweringCounterKind::StreamGenerator,
    MIRLoweringCounterKind::LoopMark,
    MIRLoweringCounterKind::ForLoop,
  ].freeze, T::Array[MIRLoweringCounterKind])

  sig { void }
  def initialize
    @values = T.let({}, T::Hash[MIRLoweringCounterKind, Integer])
    COUNTER_KINDS.each { |kind| @values[kind] = 0 }
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_tmp_id
    next_one_based(MIRLoweringCounterKind::Tmp)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_block_expr_id
    next_one_based(MIRLoweringCounterKind::BlockExpr)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_safe_nav_id
    next_one_based(MIRLoweringCounterKind::SafeNav)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_extern_id
    next_one_based(MIRLoweringCounterKind::Extern)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_lambda_id
    next_one_based(MIRLoweringCounterKind::Lambda)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_stream_literal_id
    next_zero_based(MIRLoweringCounterKind::StreamLiteral)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_do_block_id
    next_zero_based(MIRLoweringCounterKind::DoBlock)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_background_block_id
    next_zero_based(MIRLoweringCounterKind::BackgroundBlock)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_stream_generator_id
    next_zero_based(MIRLoweringCounterKind::StreamGenerator)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_loop_mark_id
    next_one_based(MIRLoweringCounterKind::LoopMark)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_for_loop_id
    next_one_based(MIRLoweringCounterKind::ForLoop)
  end

  private

  sig { params(kind: MIRLoweringCounterKind).returns(MIRLoweringGeneratedId) }
  def next_one_based(kind)
    next_id(kind, offset: 1)
  end

  sig { params(kind: MIRLoweringCounterKind).returns(MIRLoweringGeneratedId) }
  def next_zero_based(kind)
    next_id(kind, offset: 0)
  end

  sig { params(kind: MIRLoweringCounterKind, offset: Integer).returns(MIRLoweringGeneratedId) }
  def next_id(kind, offset:)
    value = @values.fetch(kind)
    @values[kind] = value + 1
    MIRLoweringGeneratedId.new(kind: kind, value: value + offset)
  end
end
