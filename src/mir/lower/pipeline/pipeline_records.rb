# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../mir"

PipelineTypeInput = T.type_alias { T.any(Type, Symbol, String) }
PipelineLoweringResult = T.type_alias { T.nilable(T.any(MIR::BlockExpr, MIR::ForStmt, MIR::ScopeBlock)) }

class PipelineSite < T::Struct
  const :list, AST::Node
  const :options, AST::BinaryOp
end

class PipelineSourceShape < T::Struct
  extend T::Sig

  const :type, Type
  const :bc_target, T::Boolean
  const :named_source, T::Boolean

  sig { returns(Type) }
  def element_type
    elem_type = type.runtime_stream_storage_element_type || type.element_type
    raise "pipeline source shape: #{type} has no element type" unless elem_type

    elem_type
  end

  private

  sig { returns(T::Boolean) }
  def infinite_stream?
    type.inf_stream?
  end

  public

  sig { returns(T::Boolean) }
  def bc_infinite_stream?
    bc_target && infinite_stream?
  end

  sig { returns(T::Boolean) }
  def bc_named_infinite_stream?
    bc_infinite_stream? && named_source
  end
end

class PipelineNamedBinding < T::Struct
  const :name, String
  const :zig, String
end

class PipelineLabelState
  extend T::Sig

  sig { void }
  def initialize
    @counter = T.let(0, Integer)
    @current_label = T.let(nil, T.nilable(String))
  end

  sig { returns(String) }
  def next_label
    @counter += 1
    "__pblk#{@counter}"
  end

  sig { params(label: String).void }
  def current_label=(label)
    @current_label = label
  end

  sig { returns(T.nilable(String)) }
  def current_label
    @current_label
  end
end
