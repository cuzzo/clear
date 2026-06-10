# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "set"
require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../../semantic/capability_plan"

PipelinePlaceholderMap = T.type_alias { T::Hash[String, String] }
PipelineSoaFieldSet = T.type_alias { T::Set[T.any(Symbol, String)] }

class PipelineContextState < T::Struct
  extend T::Sig

  const :placeholder_name, T.nilable(String)
  const :acc_placeholder, T.nilable(String)
  const :join_param_map, T.nilable(PipelinePlaceholderMap)
  const :named_bindings, PipelinePlaceholderMap
  const :soa_each_mode, T::Boolean
  const :soa_rewrite_active, T::Boolean
  const :soa_needed_fields, PipelineSoaFieldSet

  sig { returns(PipelineContextState) }
  def self.empty
    new(
      placeholder_name: nil,
      acc_placeholder: nil,
      join_param_map: nil,
      named_bindings: {},
      soa_each_mode: false,
      soa_rewrite_active: false,
      soa_needed_fields: Set.new,
    )
  end

  sig { params(placeholder: T.nilable(String), acc: T.nilable(String)).returns(PipelineContextState) }
  def with_pipeline_values(placeholder, acc)
    PipelineContextState.new(
      placeholder_name: placeholder,
      acc_placeholder: acc,
      join_param_map: join_param_map,
      named_bindings: named_bindings,
      soa_each_mode: soa_each_mode,
      soa_rewrite_active: soa_rewrite_active,
      soa_needed_fields: soa_needed_fields,
    )
  end

  sig { params(clear_name: String, zig_var: String).returns(PipelineContextState) }
  def with_named_binding(clear_name, zig_var)
    PipelineContextState.new(
      placeholder_name: placeholder_name,
      acc_placeholder: acc_placeholder,
      join_param_map: join_param_map,
      named_bindings: named_bindings.merge(clear_name => zig_var),
      soa_each_mode: soa_each_mode,
      soa_rewrite_active: soa_rewrite_active,
      soa_needed_fields: soa_needed_fields,
    )
  end

  sig { params(join_params: T.nilable(PipelinePlaceholderMap)).returns(PipelineContextState) }
  def with_join_params(join_params)
    PipelineContextState.new(
      placeholder_name: placeholder_name,
      acc_placeholder: acc_placeholder,
      join_param_map: join_params,
      named_bindings: named_bindings,
      soa_each_mode: soa_each_mode,
      soa_rewrite_active: soa_rewrite_active,
      soa_needed_fields: soa_needed_fields,
    )
  end

  sig { params(each_mode: T::Boolean, fields: PipelineSoaFieldSet).returns(PipelineContextState) }
  def with_soa_rewrite(each_mode, fields)
    PipelineContextState.new(
      placeholder_name: placeholder_name,
      acc_placeholder: acc_placeholder,
      join_param_map: join_param_map,
      named_bindings: named_bindings,
      soa_each_mode: each_mode,
      soa_rewrite_active: true,
      soa_needed_fields: fields,
    )
  end

  sig { returns(T::Boolean) }
  def active?
    !!(placeholder_name || acc_placeholder || join_param_map ||
       soa_each_mode || soa_rewrite_active || !named_bindings.empty?)
  end

  sig { params(name: String).returns(T.nilable(String)) }
  def replacement_for_identifier(name)
    return placeholder_name if name == "_" && placeholder_name
    return acc_placeholder if name == "acc" && acc_placeholder

    joined = join_param_map&.[](name)
    return joined if joined

    named_bindings[name]
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def soa_each_field_node?(node)
    soa_each_mode && node.is_a?(AST::GetField) &&
      node.target.is_a?(AST::Identifier) && node.target.name == "_"
  end

  sig { params(node: AST::GetField).returns(T::Boolean) }
  def soa_rewrite_field_node?(node)
    soa_rewrite_active && node.target.is_a?(AST::Identifier) && node.target.name == "_"
  end

  sig { params(field: T.any(Symbol, String)).void }
  def record_soa_field(field)
    soa_needed_fields << field
  end
end

class PipelinePlaceholderRewriter
  extend T::Sig

  sig { params(context: PipelineContextState).void }
  def initialize(context)
    @context = T.let(context, PipelineContextState)
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def substitute(node)
    return node unless @context.active?
    return soa_each_field(T.cast(node, AST::GetField)) if soa_each_field?(node)

    case node
    when AST::Identifier then substitute_identifier(node)
    when AST::FuncCall then substitute_func_call(node)
    when AST::MethodCall then substitute_method_call(node)
    when AST::BinaryOp then substitute_binary_op(node)
    when AST::GetField then substitute_get_field(node)
    when AST::GetIndex then substitute_get_index(node)
    when AST::BindExpr then substitute_bind_expr(node)
    when AST::Assignment then substitute_assignment(node)
    when AST::UnaryOp then substitute_unary_op(node)
    when AST::WithBlock then substitute_with_block(node)
    when AST::StructLit then substitute_struct_lit(node)
    when AST::HashLit then substitute_hash_lit(node)
    when AST::Assert then substitute_assert(node)
    when AST::IfStatement then substitute_if_statement(node)
    else node
    end
  end

  private

  sig { params(node: AST::Node).returns(T::Boolean) }
  def soa_each_field?(node)
    @context.soa_each_field_node?(node)
  end

  sig { params(node: AST::GetField).returns(AST::Identifier) }
  def soa_each_field(node)
    @context.record_soa_field(node.field)
    new_id = AST::Identifier.new(node.token, "__soa_#{node.field}[__soa_i]")
    copy_type_info(node, new_id)
    new_id
  end

  sig { params(node: AST::Identifier).returns(AST::Node) }
  def substitute_identifier(node)
    replacement = @context.replacement_for_identifier(node.name)
    return node unless replacement

    new_id = AST::Identifier.new(node.token, replacement)
    copy_type_info(node, new_id)
    new_id
  end

  sig { params(node: AST::FuncCall).returns(AST::Node) }
  def substitute_func_call(node)
    new_args = node.args.map { |arg| substitute(arg) }
    return node if new_args == node.args

    new_call = AST::FuncCall.new(node.token, node.name, new_args)
    copy_type_info(node, new_call)
    copy_call_metadata(node, new_call)
    new_call
  end

  sig { params(node: AST::MethodCall).returns(AST::Node) }
  def substitute_method_call(node)
    new_target = substitute(node.object)
    new_args = node.args.map { |arg| substitute(arg) }
    return node if new_target == node.object && new_args == node.args

    new_mc = AST::MethodCall.new(node.token, new_target, node.name, new_args)
    copy_type_info(node, new_mc)
    copy_call_metadata(node, new_mc)
    new_mc
  end

  sig { params(node: AST::BinaryOp).returns(AST::Node) }
  def substitute_binary_op(node)
    new_left = substitute(node.left)
    new_right = substitute(node.right)
    return node if new_left == node.left && new_right == node.right

    new_bin = AST::BinaryOp.new(node.token, new_left, node.op, new_right)
    copy_type_info(node, new_bin)
    new_bin.string_concat = node.string_concat if node.respond_to?(:string_concat) && node.string_concat
    new_bin
  end

  sig { params(node: AST::GetField).returns(AST::Node) }
  def substitute_get_field(node)
    if @context.soa_rewrite_field_node?(node)
      @context.record_soa_field(node.field)
      soa_field = AST::Identifier.new(node.token, "__soa_#{node.field}")
      AST.stamp_synthetic_type!(soa_field, soa_field_slice_type(node), context: "synthetic AST type")
      soa_idx = AST::Identifier.new(node.token, "__soa_i")
      AST.stamp_synthetic_type!(soa_idx, :Int64, context: "synthetic AST type")
      new_gi = AST::GetIndex.new(node.token, soa_field, soa_idx)
      copy_type_info(node, new_gi)
      return new_gi
    end

    new_target = substitute(node.target)
    return node if new_target == node.target

    new_gf = AST::GetField.new(node.token, new_target, node.field)
    copy_type_info(node, new_gf)
    new_gf
  end

  sig { params(node: AST::GetIndex).returns(AST::Node) }
  def substitute_get_index(node)
    new_target = substitute(node.target)
    new_index = substitute(node.index)
    return node if new_target == node.target && new_index == node.index

    new_ia = AST::GetIndex.new(node.token, new_target, new_index)
    copy_type_info(node, new_ia)
    new_ia
  end

  sig { params(node: AST::BindExpr).returns(AST::Node) }
  def substitute_bind_expr(node)
    new_name = substitute_assignment_target(node.name)
    new_value = substitute(node.value)
    return node if new_name == node.name && new_value == node.value

    new_bind = AST::BindExpr.new(node.token, new_name, node.type, new_value)
    new_bind.mode = node.mode
    new_bind.reassign_cleanup = node.reassign_cleanup
    copy_type_info(node, new_bind)
    new_bind
  end

  sig { params(node: AST::Assignment).returns(AST::Node) }
  def substitute_assignment(node)
    new_name = substitute_assignment_target(node.name)
    new_value = substitute(node.value)
    return node if new_name == node.name && new_value == node.value

    new_assign = AST::Assignment.new(node.token, new_name, new_value)
    new_assign.auto_lock = node.auto_lock
    new_assign.field_pre_cleanup = node.field_pre_cleanup
    copy_type_info(node, new_assign)
    new_assign
  end

  sig { params(node: T.any(AST::Node, String)).returns(T.any(AST::Node, String)) }
  def substitute_assignment_target(node)
    node.is_a?(AST::GetField) || node.is_a?(AST::GetIndex) ? substitute(node) : node
  end

  sig { params(node: AST::UnaryOp).returns(AST::Node) }
  def substitute_unary_op(node)
    new_operand = substitute(node.right)
    return node if new_operand == node.right

    new_uo = AST::UnaryOp.new(node.token, node.op, new_operand)
    copy_type_info(node, new_uo)
    new_uo
  end

  sig { params(node: AST::WithBlock).returns(AST::Node) }
  def substitute_with_block(node)
    new_body = node.body.map { |stmt| substitute(stmt) }
    return node if new_body == node.body

    new_with = AST::WithBlock.new(node.token, node.capabilities, new_body, node.deferred_drops)
    new_with.lock_error_clause = node.lock_error_clause
    new_with.deadlock_escape = node.deadlock_escape
    new_with.arms = node.arms
    new_with.view_kind = node.view_kind
    new_with.snapshot_mode = node.snapshot_mode
    new_with.polymorphic = node.polymorphic
    new_with.universal_poly = node.universal_poly
    new_with.capability_plan = CapabilityPlan.require_for(node) if node.capability_plan
    copy_type_info(node, new_with)
    new_with
  end

  sig { params(node: AST::StructLit).returns(AST::Node) }
  def substitute_struct_lit(node)
    new_fields = node.fields.transform_values { |value| substitute(value) }
    return node if new_fields == node.fields

    new_sl = AST::StructLit.new(node.token, node.name, new_fields, node.storage, node.type_args)
    copy_type_info(node, new_sl)
    new_sl
  end

  sig { params(node: AST::HashLit).returns(AST::Node) }
  def substitute_hash_lit(node)
    new_pairs = node.pairs.transform_values { |value| substitute(value) }
    return node if new_pairs == node.pairs

    new_hl = AST::HashLit.new(node.token, new_pairs, node.storage)
    copy_type_info(node, new_hl)
    new_hl
  end

  sig { params(node: AST::Assert).returns(AST::Node) }
  def substitute_assert(node)
    new_cond = substitute(node.condition)
    return node if new_cond == node.condition

    new_assert = AST::Assert.new(node.token, new_cond, node.message)
    copy_type_info(node, new_assert)
    new_assert
  end

  sig { params(node: AST::IfStatement).returns(AST::Node) }
  def substitute_if_statement(node)
    new_cond = substitute(node.condition)
    new_then = node.then_branch.map { |stmt| substitute(stmt) }
    new_else = node.else_branch&.map { |stmt| substitute(stmt) }
    return node if new_cond == node.condition && new_then == node.then_branch && new_else == node.else_branch

    new_if = AST::IfStatement.new(node.token, new_cond, new_then, new_else, node.then_drops, node.else_drops)
    new_if.expr_mode = node.expr_mode if node.respond_to?(:expr_mode)
    new_if.then_result_type = node.then_result_type if node.respond_to?(:then_result_type)
    new_if.else_result_type = node.else_result_type if node.respond_to?(:else_result_type)
    copy_type_info(node, new_if)
    new_if
  end

  sig { params(src: AST::Locatable, dst: AST::Locatable).void }
  def copy_type_info(src, dst)
    AST.copy_pipeline_rewrite_metadata!(src, dst)
  end

  sig { params(src: AST::Locatable, dst: AST::Locatable).void }
  def copy_call_metadata(src, dst)
    AST.copy_pipeline_rewrite_metadata!(src, dst, include_call_metadata: true)
  end

  sig { params(field_node: AST::GetField).returns(Type) }
  def soa_field_slice_type(field_node)
    field_type = field_node.full_type!(context: "SOA field slice")
    Type.new(:"#{field_type.resolved}[]")
  end
end
