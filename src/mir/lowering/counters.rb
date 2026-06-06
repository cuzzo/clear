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

  sig { returns(Integer) }
  def next_tmp_id
    next_one_based(MIRLoweringCounterKind::Tmp)
  end

  sig { returns(Integer) }
  def next_block_expr_id
    next_one_based(MIRLoweringCounterKind::BlockExpr)
  end

  sig { returns(Integer) }
  def next_safe_nav_id
    next_one_based(MIRLoweringCounterKind::SafeNav)
  end

  sig { returns(Integer) }
  def next_extern_id
    next_one_based(MIRLoweringCounterKind::Extern)
  end

  sig { returns(Integer) }
  def next_lambda_id
    next_one_based(MIRLoweringCounterKind::Lambda)
  end

  sig { returns(Integer) }
  def next_stream_literal_id
    next_zero_based(MIRLoweringCounterKind::StreamLiteral)
  end

  sig { returns(Integer) }
  def next_do_block_id
    next_zero_based(MIRLoweringCounterKind::DoBlock)
  end

  sig { returns(Integer) }
  def next_background_block_id
    next_zero_based(MIRLoweringCounterKind::BackgroundBlock)
  end

  sig { returns(Integer) }
  def next_stream_generator_id
    next_zero_based(MIRLoweringCounterKind::StreamGenerator)
  end

  sig { returns(Integer) }
  def next_loop_mark_id
    next_one_based(MIRLoweringCounterKind::LoopMark)
  end

  sig { returns(Integer) }
  def next_for_loop_id
    next_one_based(MIRLoweringCounterKind::ForLoop)
  end

  private

  sig { params(kind: MIRLoweringCounterKind).returns(Integer) }
  def next_one_based(kind)
    next_zero_based(kind) + 1
  end

  sig { params(kind: MIRLoweringCounterKind).returns(Integer) }
  def next_zero_based(kind)
    value = @values.fetch(kind)
    @values[kind] = value + 1
    value
  end
end
