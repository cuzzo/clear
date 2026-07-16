# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/source_error"
require_relative "../../ast/type"

module PrefixedIntRange
  extend T::Helpers
  extend T::Sig
  abstract!
  include ErrorHelper

  # Called after coercion context is known for integer literals and constant-foldable
  # unary negations (e.g. -200). Errors if the value does not fit in the effective
  # target type. No-op for non-integer or non-literal nodes.
  sig { params(node: AST::Node, effective_type: T.nilable(Type::TypeInput)).returns(NilClass) }
  def check_prefixed_int_range!(node, effective_type)
    return if effective_type.nil?

    val = integer_literal_range_value(node)
    return if val.nil?
    literal_value = val

    checked_type = effective_type
    t = integer_range_target_type(checked_type)
    return if t.nil?
    type_sym = t

    max = Type.integer_type_max(type_sym)
    return if max.nil?  # Not a known integer type; let type checker handle the mismatch
    max_value = max
    min = Type.integer_type_min(type_sym) || 0

    if literal_value < min || literal_value > max_value
      if node.is_a?(AST::Literal)
        handle_prefixed_int_overflow!(node, literal_value, type_sym, min, max_value)
      else
        error!(node, :INT_LITERAL_OVERFLOW,
          val: literal_value, type: type_sym, min: min, max: max_value)
      end
    end
  end

  sig { params(node: AST::Literal, val: Integer, target_type: Symbol, min: Integer, max: Integer).returns(NilClass) }
  def handle_prefixed_int_overflow!(node, val, target_type, min, max)
    error!(node, :INT_LITERAL_OVERFLOW,
      val: val, type: target_type, min: min, max: max)
  end

  sig { params(node: AST::Node).returns(T.nilable(Integer)) }
  def integer_literal_range_value(node)
    if node.is_a?(AST::Literal)
      return node.value if node.type == :PREFIXED_INT || node.type == :INT64
    end

    negative_integer_literal_range_value(node)
  end

  sig { params(node: AST::Node).returns(T.nilable(Integer)) }
  def negative_integer_literal_range_value(node)
    return nil unless node.is_a?(AST::UnaryOp)
    return nil unless node.op == :SUB

    lit = node.right
    return nil unless lit.is_a?(AST::Literal)
    return nil unless lit.type == :INT64 || lit.type == :PREFIXED_INT

    -lit.value
  end

  sig { params(effective_type: Type::TypeInput).returns(T.nilable(Symbol)) }
  def integer_range_target_type(effective_type)
    # Unwrap error unions so fallible integer returns range-check against the
    # underlying payload type.
    current_type = effective_type
    if current_type.is_a?(Type) && current_type.error_union?
      payload_type = current_type.payload_type
      return nil unless payload_type
      current_type = payload_type
    end

    case current_type
    when Type
      current_type.resolved
    when Symbol
      current_type
    when String
      current_type.to_sym
    end
  end

  private :integer_literal_range_value, :integer_range_target_type
end
