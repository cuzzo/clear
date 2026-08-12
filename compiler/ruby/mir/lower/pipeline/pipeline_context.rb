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
    return true unless placeholder_name.nil?
    return true unless acc_placeholder.nil?
    return true unless join_param_map.nil?
    return true if soa_each_mode
    return true if soa_rewrite_active

    !named_bindings.empty?
  end

  sig { params(name: String).returns(T.nilable(String)) }
  def replacement_for_identifier(name)
    return placeholder_name if name == "_" && placeholder_name
    return acc_placeholder if name == "acc" && acc_placeholder

    map = join_param_map
    if map
      joined = map[name]
      return joined if joined
    end

    named_bindings[name]
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def soa_each_field_node?(node)
    return false unless soa_each_mode

    case node
    when AST::GetField
      placeholder_identifier?(node.target)
    else
      false
    end
  end

  sig { params(node: AST::GetField).returns(T::Boolean) }
  def soa_rewrite_field_node?(node)
    soa_rewrite_active && placeholder_identifier?(node.target)
  end

  sig { params(node: AST::Locatable).returns(T::Boolean) }
  def placeholder_identifier?(node)
    case node
    when AST::Identifier
      node.name == "_"
    else
      false
    end
  end
  private :placeholder_identifier?

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
    when AST::VarDecl then substitute_var_decl(node)
    when AST::BindExpr then substitute_bind_expr(node)
    when AST::Assignment then substitute_assignment(node)
    when AST::UnaryOp then substitute_unary_op(node)
    when AST::OptionalUnwrap then substitute_optional_unwrap(node)
    when AST::IsA then substitute_is_a(node)
    when AST::CopyNode, AST::MoveNode, AST::KeepNode, AST::ShareNode
      substitute_value_wrapper(node)
    when AST::WithBlock then substitute_with_block(node)
    when AST::StructLit then substitute_struct_lit(node)
    when AST::HashLit then substitute_hash_lit(node)
    when AST::ListLit then substitute_list_lit(node)
    when AST::TupleLit then substitute_tuple_lit(node)
    when AST::Cast then substitute_cast(node)
    when AST::BlockExpr then substitute_block_expr(node)
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
    new_bin.string_concat = true if node.string_concat == true
    new_bin
  end

  sig { params(node: AST::GetField).returns(AST::Node) }
  def substitute_get_field(node)
    if @context.soa_rewrite_field_node?(node)
      @context.record_soa_field(node.field)
      soa_field = AST::Identifier.new(node.token, "__soa_#{node.field}")
      soa_field.type_object = soa_field_slice_type(node)
      soa_idx = AST::Identifier.new(node.token, "__soa_i")
      soa_idx.type_object = Type.new(:Int64)
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

  # A VarDecl carries the declaration's symbol, storage and cleanup stamps, so
  # it is rewritten in place: rebuilding it would drop them. The initializer is
  # the only place a placeholder can appear.
  # An IS_A test rewrites in place: the node carries the annotator's runtime
  # payload stamps, and only its subject can hold a placeholder.
  sig { params(node: AST::IsA).returns(AST::Node) }
  def substitute_is_a(node)
    new_left = substitute(node.left)
    node.left = new_left unless new_left.equal?(node.left)
    node
  end

  sig { params(node: AST::OptionalUnwrap).returns(AST::Node) }
  def substitute_optional_unwrap(node)
    new_target = substitute(node.target)
    return node if new_target.equal?(node.target)

    new_unwrap = AST::OptionalUnwrap.new(node.token, new_target)
    copy_type_info(node, new_unwrap)
    new_unwrap
  end

  sig { params(node: AST::VarDecl).returns(AST::Node) }
  def substitute_var_decl(node)
    new_value = substitute(node.value)
    node.value = new_value unless new_value.equal?(node.value)
    node
  end

  sig { params(node: AST::BindExpr).returns(AST::Node) }
  def substitute_bind_expr(node)
    new_name = substitute_assignment_target(node.name)
    new_value = substitute(node.value)
    return node if new_name == node.name && new_value == node.value

    new_bind = AST::BindExpr.new(node.token, new_name, node.type, new_value)
    new_bind.mode = node.mode
    new_bind.reassign_cleanup = node.reassign_cleanup
    new_bind.symbol = node.symbol if new_bind.respond_to?(:symbol=) && node.respond_to?(:symbol)
    new_bind.mir_binding_entry = node.mir_binding_entry if new_bind.respond_to?(:mir_binding_entry=) && node.respond_to?(:mir_binding_entry)
    new_bind.compound_op = node.compound_op if new_bind.respond_to?(:compound_op=) && node.respond_to?(:compound_op)
    new_bind.auto_atomic_op = node.auto_atomic_op if new_bind.respond_to?(:auto_atomic_op=) && node.respond_to?(:auto_atomic_op)
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

  sig { params(node: AST::AssignmentName).returns(AST::AssignmentName) }
  def substitute_assignment_target(node)
    if node.is_a?(AST::GetField)
      rewritten = substitute(T.cast(node, AST::GetField))
      return T.cast(rewritten, AST::AssignmentName)
    end
    if node.is_a?(AST::GetIndex)
      rewritten = substitute(T.cast(node, AST::GetIndex))
      return T.cast(rewritten, AST::AssignmentName)
    end

    node
  end

  # COPY/GIVE/CLONE/SHARE wrappers: substitute inside the wrapped value.
  sig { params(node: T.any(AST::CopyNode, AST::MoveNode, AST::KeepNode, AST::ShareNode)).returns(AST::Node) }
  def substitute_value_wrapper(node)
    value = T.let(nil, T.nilable(AST::Locatable))
    case node
    when AST::CopyNode
      value = node.value
    when AST::MoveNode
      value = node.value
    when AST::KeepNode
      value = node.value
    when AST::ShareNode
      value = node.value
    end
    value = T.must(value)
    new_value = substitute(value)
    return node if new_value == value

    new_node = T.let(nil, T.nilable(AST::PipelineRewriteNode))
    case node
    when AST::CopyNode
      new_node = AST::CopyNode.new(node.token, new_value)
    when AST::MoveNode
      new_node = AST::MoveNode.new(node.token, new_value)
    when AST::KeepNode
      new_node = AST::KeepNode.new(node.token, new_value)
    when AST::ShareNode
      new_node = AST::ShareNode.new(node.token, new_value)
    end
    new_node = T.must(new_node)
    copy_type_info(node, new_node)
    new_node
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
    new_body = substitute_body(node.body)
    arms = node.arms
    new_arms = T.let(nil, T.nilable(T::Array[AST::WithMatchArm]))
    if arms
      rewritten_arms = T.let([], T::Array[AST::WithMatchArm])
      arm_index = 0
      while arm_index < arms.length
        arm = arms.fetch(arm_index)
        arm_body = T.let(arm.body_nodes, T::Array[AST::Node])
        new_arm_body = substitute_body(arm_body)
        rewritten_arm =
          if new_arm_body == arm_body
            arm
          else
            AST::WithMatchArm.new(
              family: arm.family_value,
              body: new_arm_body,
              lock_error_clauses: arm.lock_error_clauses_value,
              token: arm.token_value,
            )
          end
        rewritten_arms << rewritten_arm
        arm_index += 1
      end
      new_arms = rewritten_arms
    end
    return node if new_body == node.body && new_arms == node.arms

    new_with = AST::WithBlock.new(node.token, node.capabilities, new_body, node.deferred_drops)
    new_with.lock_error_clause = node.lock_error_clause
    new_with.deadlock_escape = node.deadlock_escape
    new_with.arms = new_arms
    new_with.view_kind = node.view_kind
    new_with.snapshot_mode = node.snapshot_mode
    new_with.polymorphic = node.polymorphic
    new_with.universal_poly = node.universal_poly
    new_with.capability_plan = CapabilityPlan.require_for(node) if node.capability_plan
    copy_type_info(node, new_with)
    new_with
  end

  sig { params(body: T::Array[AST::Node]).returns(T::Array[AST::Node]) }
  def substitute_body(body)
    result = T.let([], T::Array[AST::Node])
    index = 0
    while index < body.length
      result << substitute(body.fetch(index))
      index += 1
    end
    result
  end

  sig { params(node: AST::StructLit).returns(AST::Node) }
  def substitute_struct_lit(node)
    fields = T.let(node.fields, T::Hash[String, AST::Node])
    new_fields = T.let({}, T::Hash[String, AST::Node])
    keys = fields.keys
    index = 0
    while index < keys.length
      key = keys.fetch(index)
      new_fields[key] = substitute(fields.fetch(key))
      index += 1
    end
    return node if new_fields == fields

    new_sl = AST::StructLit.new(node.token, node.name, new_fields, node.storage, node.type_args)
    copy_type_info(node, new_sl)
    new_sl
  end

  sig { params(node: AST::ListLit).returns(AST::Node) }
  def substitute_list_lit(node)
    new_items = node.items.map { |item| substitute(item) }
    return node if new_items == node.items

    new_ll = AST::ListLit.new(node.token, new_items, node.storage, node.constructor_options)
    copy_type_info(node, new_ll)
    new_ll
  end

  sig { params(node: AST::TupleLit).returns(AST::Node) }
  def substitute_tuple_lit(node)
    new_items = node.items.map { |item| substitute(item) }
    return node if new_items == node.items

    new_tl = AST::TupleLit.new(node.token, new_items, node.storage)
    copy_type_info(node, new_tl)
    new_tl
  end

  sig { params(node: AST::Cast).returns(AST::Node) }
  def substitute_cast(node)
    new_value = substitute(node.value)
    return node if new_value.equal?(node.value)

    new_cast = AST::Cast.new(node.token, new_value, node.target)
    copy_type_info(node, new_cast)
    new_cast
  end

  sig { params(node: AST::HashLit).returns(AST::Node) }
  def substitute_hash_lit(node)
    pairs = T.let(node.pairs, T::Hash[AST::Node, AST::Node])
    new_pairs = T.let({}, T::Hash[AST::Node, AST::Node])
    # Iterate the pairs rather than looking each key back up: the keys are AST
    # nodes whose stamps are mutated after insertion, which leaves their hash
    # buckets stale and makes `fetch` miss a key that `keys` just handed us.
    pairs.each { |key, value| new_pairs[key] = substitute(value) }
    return node if new_pairs == pairs

    new_hl = AST::HashLit.new(node.token, new_pairs, node.storage)
    copy_type_info(node, new_hl)
    new_hl
  end

  sig { params(node: AST::BlockExpr).returns(AST::Node) }
  def substitute_block_expr(node)
    body = T.let(node.body, T::Array[AST::Node])
    new_body = T.let([], T::Array[AST::Node])
    index = 0
    while index < body.length
      new_body << substitute(body.fetch(index))
      index += 1
    end
    result = T.let(node.result, T.nilable(AST::Node))
    new_result = result ? substitute(result) : nil
    return node if new_body == node.body && new_result == node.result

    new_block = AST::BlockExpr.new(node.token, new_body, new_result)
    copy_type_info(node, new_block)
    new_block
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

  sig { params(src: AST::PipelineRewriteNode, dst: AST::PipelineRewriteNode).void }
  def copy_type_info(src, dst)
    AST.copy_pipeline_rewrite_metadata!(dst, src)
  end

  sig { params(src: AST::PipelineRewriteNode, dst: AST::PipelineRewriteNode).void }
  def copy_call_metadata(src, dst)
    AST.copy_pipeline_rewrite_metadata!(dst, src, include_call_metadata: true)
  end

  sig { params(field_node: AST::GetField).returns(Type) }
  def soa_field_slice_type(field_node)
    field_type = field_node.type_object
    raise "SOA field slice: missing annotated type" unless field_type
    concrete_type = T.cast(field_type, Type)
    raise "SOA field slice: unresolved annotated type" if concrete_type.untyped?
    Type.new(:"#{concrete_type.resolved}[]")
  end
end
