# typed: true
# frozen_string_literal: true
#
# AUTO-GENERATED. Do not edit by hand. Regenerate with:
#   bundle exec ruby tools/gen_attr_rbi.rb > sorbet/rbi/clear-attr-accessors.rbi
#
# Sorbet's automatic Struct.new typing only surfaces the positional
# Struct fields, not `attr_accessor`/`attr_reader`/`attr_writer`
# declarations inside the do-block. Without this shim, every file
# that flips to `# typed: true` and reads such an attribute trips a
# `Method does not exist` error.
#
# Where a matching T.let declaration exists in initialize, the sig is
# typed. Otherwise it falls back to T.untyped.

class AST::Assignment
  sig { returns(T.untyped) }
  def auto_atomic_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_atomic_op=(value); end
  sig { returns(T.untyped) }
  def auto_lock; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_lock=(value); end
  sig { returns(T.untyped) }
  def compound_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def compound_op=(value); end
  sig { returns(T.untyped) }
  def container_promote_zig_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def container_promote_zig_type=(value); end
  sig { returns(T.untyped) }
  def field_pre_cleanup; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def field_pre_cleanup=(value); end
end

class AST::BgBlock
  sig { returns(T.untyped) }
  def can_smash_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def can_smash_token=(value); end
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def capture_string_dupes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_string_dupes=(value); end
  sig { returns(T.untyped) }
  def captures_resource; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def captures_resource=(value); end
  sig { returns(T.untyped) }
  def computed_stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def computed_stack_tier=(value); end
  sig { returns(T.untyped) }
  def exit_promote; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def exit_promote=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def open_brace_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def open_brace_token=(value); end
  sig { returns(T.untyped) }
  def prefix_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def prefix_token=(value); end
  sig { returns(T.untyped) }
  def return_provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_provenance=(value); end
  sig { returns(T.untyped) }
  def spawn_form; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def spawn_form=(value); end
end

class AST::BgStreamBlock
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def capture_string_dupes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_string_dupes=(value); end
  sig { returns(T.untyped) }
  def computed_stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def computed_stack_tier=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def spawn_form; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def spawn_form=(value); end
  sig { returns(T.untyped) }
  def yields_frame_strings; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def yields_frame_strings=(value); end
end

class AST::BinaryOp
  sig { returns(T.untyped) }
  def observable_dest; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_dest=(value); end
  sig { returns(T.untyped) }
  def observable_terminal; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_terminal=(value); end
  sig { returns(T.untyped) }
  def or_fallback_dupe; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def or_fallback_dupe=(value); end
  sig { returns(T.untyped) }
  def paren_bind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def paren_bind=(value); end
  sig { returns(T.untyped) }
  def storage; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def storage=(value); end
  sig { returns(T.untyped) }
  def string_concat; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def string_concat=(value); end
end

class AST::BindExpr
  sig { returns(T.untyped) }
  def auto_atomic_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_atomic_op=(value); end
  sig { returns(T.untyped) }
  def compound_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def compound_op=(value); end
  sig { returns(T.untyped) }
  def mir_binding_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mir_binding_entry=(value); end
  sig { returns(T.untyped) }
  def mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mode=(value); end
  sig { returns(T.untyped) }
  def reassign_cleanup; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reassign_cleanup=(value); end
end

class AST::CapabilityWrap
  sig { returns(T.untyped) }
  def lock_rank; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lock_rank=(value); end
end

class AST::ConcurrentOp
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def shard_context; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def shard_context=(value); end
end

class AST::CopyNode
  sig { returns(T.untyped) }
  def deep_copy; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deep_copy=(value); end
end

class AST::ExternFnDecl
  sig { returns(T.untyped) }
  def fn_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_type_params=(value); end
  sig { returns(T.untyped) }
  def owner_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type=(value); end
  sig { returns(T.untyped) }
  def owner_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type_params=(value); end
end

class AST::ExternStructDecl
  sig { returns(T.untyped) }
  def as_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def as_type=(value); end
  sig { returns(T.untyped) }
  def close_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def close_method=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
end

class AST::ForEach
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class AST::ForRange
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class AST::FuncCall
  sig { returns(T.untyped) }
  def arg_families; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arg_families=(value); end
  sig { returns(T.untyped) }
  def collapsed_errors; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def collapsed_errors=(value); end
  sig { returns(T.untyped) }
  def error_union_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def error_union_type=(value); end
  sig { returns(T.untyped) }
  def extern_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_call=(value); end
  sig { returns(T.untyped) }
  def extern_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_effects=(value); end
  sig { returns(T.untyped) }
  def fn_var_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_var_call=(value); end
  sig { returns(T.untyped) }
  def generic_type_args; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def generic_type_args=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
  sig { returns(T.untyped) }
  def module_alias; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def module_alias=(value); end
  sig { returns(T.untyped) }
  def pipe_lhs; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pipe_lhs=(value); end
end

class AST::FunctionDef
  sig { returns(T.untyped) }
  def alloc_fault; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def alloc_fault=(value); end
  sig { returns(T.untyped) }
  def arrow_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arrow_token=(value); end
  sig { returns(T.untyped) }
  def can_fail; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def can_fail=(value); end
  sig { returns(T.untyped) }
  def cleanup_bindings; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def cleanup_bindings=(value); end
  sig { returns(T.untyped) }
  def effect_set; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effect_set=(value); end
  sig { returns(T.untyped) }
  def effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects=(value); end
  sig { returns(T.untyped) }
  def effects_decl; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects_decl=(value); end
  sig { returns(T.untyped) }
  def effects_span; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects_span=(value); end
  sig { returns(T.untyped) }
  def error_fallible; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def error_fallible=(value); end
  sig { returns(T.untyped) }
  def explicit_return_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def explicit_return_type=(value); end
  sig { returns(T.untyped) }
  def fsm_eligible; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_eligible=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def has_promotion; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def has_promotion=(value); end
  sig { returns(T.untyped) }
  def heap_carry_return; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_carry_return=(value); end
  sig { returns(T.untyped) }
  def heap_carry_return_vars; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_carry_return_vars=(value); end
  sig { returns(T.untyped) }
  def inferred_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def inferred_effects=(value); end
  sig { returns(T.untyped) }
  def is_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def is_method=(value); end
  sig { returns(T.untyped) }
  def max_depth_n; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def max_depth_n=(value); end
  sig { returns(T.untyped) }
  def moved_guard_info; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def moved_guard_info=(value); end
  sig { returns(T.untyped) }
  def mutual_thunk_plan; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mutual_thunk_plan=(value); end
  sig { returns(T.untyped) }
  def name_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def name_token=(value); end
  sig { returns(T.untyped) }
  def needs_rt; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def needs_rt=(value); end
  sig { returns(T.untyped) }
  def post_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def post_clauses=(value); end
  sig { returns(T.untyped) }
  def pre_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pre_clauses=(value); end
  sig { returns(T.untyped) }
  def reentrance_kind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrance_kind=(value); end
  sig { returns(T.untyped) }
  def reentrant; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrant=(value); end
  sig { returns(T.untyped) }
  def reentrant_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrant_token=(value); end
  sig { returns(T.untyped) }
  def requires; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def requires=(value); end
  sig { returns(T.untyped) }
  def requires_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def requires_clauses=(value); end
  sig { returns(T.untyped) }
  def return_provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_provenance=(value); end
  sig { returns(T.untyped) }
  def return_type_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_type_token=(value); end
  sig { returns(T.untyped) }
  def snapshot_types; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def snapshot_types=(value); end
  sig { returns(T.untyped) }
  def stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def stack_tier=(value); end
  sig { returns(T.untyped) }
  def stack_vars_bytes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def stack_vars_bytes=(value); end
  sig { returns(T.untyped) }
  def tail_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tail_call=(value); end
  sig { returns(T.untyped) }
  def thunk_plan; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def thunk_plan=(value); end
  sig { returns(T.untyped) }
  def tight_reentrance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight_reentrance=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
  sig { returns(T.untyped) }
  def uses_alloc; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_alloc=(value); end
  sig { returns(T.untyped) }
  def uses_heap; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_heap=(value); end
  sig { returns(T.untyped) }
  def uses_rt; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_rt=(value); end
end

class AST::GetField
  sig { returns(T.untyped) }
  def indirect_field; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def indirect_field=(value); end
  sig { returns(T.untyped) }
  def is_assignment_lhs; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def is_assignment_lhs=(value); end
end

class AST::Identifier
  sig { returns(T.untyped) }
  def atomic_borrow; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def atomic_borrow=(value); end
  sig { returns(T.untyped) }
  def fn_ref; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_ref=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
end

class AST::IfStatement
  sig { returns(T.untyped) }
  def else_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def else_result_type=(value); end
  sig { returns(T.untyped) }
  def expr_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def expr_mode=(value); end
  sig { returns(T.untyped) }
  def then_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def then_result_type=(value); end
end

class AST::MatchStatement
  sig { returns(T.untyped) }
  def case_result_types; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def case_result_types=(value); end
  sig { returns(T.untyped) }
  def default_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def default_result_type=(value); end
  sig { returns(T.untyped) }
  def expr_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def expr_mode=(value); end
  sig { returns(T.untyped) }
  def string_match; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def string_match=(value); end
end

class AST::MethodCall
  sig { returns(T.untyped) }
  def extern_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_call=(value); end
  sig { returns(T.untyped) }
  def extern_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_effects=(value); end
  sig { returns(T.untyped) }
  def generic_type_args; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def generic_type_args=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
  sig { returns(T.untyped) }
  def map_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def map_method=(value); end
  sig { returns(T.untyped) }
  def pool_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pool_method=(value); end
  sig { returns(T.untyped) }
  def set_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def set_method=(value); end
end

class AST::Program
  sig { returns(T.untyped) }
  def sync_policy; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def sync_policy=(value); end
end

class AST::ReturnNode
  sig { returns(T.untyped) }
  def catch_string_dupe_ret; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def catch_string_dupe_ret=(value); end
  sig { returns(T.untyped) }
  def promote_ret_wrap; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def promote_ret_wrap=(value); end
  sig { returns(T.untyped) }
  def ret_field_promote_data; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def ret_field_promote_data=(value); end
end

class AST::StringConcat
  sig { returns(T.untyped) }
  def storage; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def storage=(value); end
end

class AST::StructLit
  sig { returns(T.untyped) }
  def borrowed_field_names; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def borrowed_field_names=(value); end
  sig { returns(T.untyped) }
  def field_tokens; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def field_tokens=(value); end
end

class AST::TestBlock
  sig { returns(T.untyped) }
  def after_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_all=(value); end
  sig { returns(T.untyped) }
  def after_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_each=(value); end
  sig { returns(T.untyped) }
  def before_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_all=(value); end
  sig { returns(T.untyped) }
  def before_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_each=(value); end
  sig { returns(T.untyped) }
  def lets; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lets=(value); end
end

class AST::TestThat
  sig { returns(T.untyped) }
  def pending; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pending=(value); end
  sig { returns(T.untyped) }
  def synthetic_fn; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def synthetic_fn=(value); end
end

class AST::UnionDef
  sig { returns(T.untyped) }
  def methods; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def methods=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
end

class AST::VarDecl
  sig { returns(T.untyped) }
  def mir_binding_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mir_binding_entry=(value); end
end

class AST::WhenBlock
  sig { returns(T.untyped) }
  def after_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_all=(value); end
  sig { returns(T.untyped) }
  def after_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_each=(value); end
  sig { returns(T.untyped) }
  def before_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_all=(value); end
  sig { returns(T.untyped) }
  def before_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_each=(value); end
  sig { returns(T.untyped) }
  def lets; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lets=(value); end
  sig { returns(T.untyped) }
  def tags; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tags=(value); end
end

class AST::WhileBindLoop
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class AST::WhileLoop
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class AST::WithBlock
  sig { returns(T.untyped) }
  def arms; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arms=(value); end
  sig { returns(T.untyped) }
  def deadlock_escape; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deadlock_escape=(value); end
  sig { returns(T.untyped) }
  def lock_error_clause; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lock_error_clause=(value); end
  sig { returns(T.untyped) }
  def polymorphic; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def polymorphic=(value); end
  sig { returns(T.untyped) }
  def snapshot_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def snapshot_mode=(value); end
  sig { returns(T.untyped) }
  def universal_poly; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def universal_poly=(value); end
  sig { returns(T.untyped) }
  def view_kind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def view_kind=(value); end
end

class AST::YieldExpr
  sig { returns(T.untyped) }
  def yield_dupe; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def yield_dupe=(value); end
end

class Assignment
  sig { returns(T.untyped) }
  def auto_atomic_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_atomic_op=(value); end
  sig { returns(T.untyped) }
  def auto_lock; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_lock=(value); end
  sig { returns(T.untyped) }
  def compound_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def compound_op=(value); end
  sig { returns(T.untyped) }
  def container_promote_zig_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def container_promote_zig_type=(value); end
  sig { returns(T.untyped) }
  def field_pre_cleanup; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def field_pre_cleanup=(value); end
end

class BasicBlock
  sig { returns(T.untyped) }
  def id; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def id=(value); end
  sig { returns(T::Array[T.untyped]) }
  def predecessors; end
  sig { params(value: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def predecessors=(value); end
  sig { returns(T::Array[T.untyped]) }
  def stmts; end
  sig { params(value: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def stmts=(value); end
  sig { returns(T::Array[T.untyped]) }
  def successors; end
  sig { params(value: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def successors=(value); end
end

class BgBlock
  sig { returns(T.untyped) }
  def can_smash_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def can_smash_token=(value); end
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def capture_string_dupes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_string_dupes=(value); end
  sig { returns(T.untyped) }
  def captures_resource; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def captures_resource=(value); end
  sig { returns(T.untyped) }
  def computed_stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def computed_stack_tier=(value); end
  sig { returns(T.untyped) }
  def exit_promote; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def exit_promote=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def open_brace_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def open_brace_token=(value); end
  sig { returns(T.untyped) }
  def prefix_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def prefix_token=(value); end
  sig { returns(T.untyped) }
  def return_provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_provenance=(value); end
  sig { returns(T.untyped) }
  def spawn_form; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def spawn_form=(value); end
end

class BgStreamBlock
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def capture_string_dupes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_string_dupes=(value); end
  sig { returns(T.untyped) }
  def computed_stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def computed_stack_tier=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def spawn_form; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def spawn_form=(value); end
  sig { returns(T.untyped) }
  def yields_frame_strings; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def yields_frame_strings=(value); end
end

class BinaryOp
  sig { returns(T.untyped) }
  def observable_dest; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_dest=(value); end
  sig { returns(T.untyped) }
  def observable_terminal; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_terminal=(value); end
  sig { returns(T.untyped) }
  def or_fallback_dupe; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def or_fallback_dupe=(value); end
  sig { returns(T.untyped) }
  def paren_bind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def paren_bind=(value); end
  sig { returns(T.untyped) }
  def storage; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def storage=(value); end
  sig { returns(T.untyped) }
  def string_concat; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def string_concat=(value); end
end

class BindExpr
  sig { returns(T.untyped) }
  def auto_atomic_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_atomic_op=(value); end
  sig { returns(T.untyped) }
  def compound_op; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def compound_op=(value); end
  sig { returns(T.untyped) }
  def mir_binding_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mir_binding_entry=(value); end
  sig { returns(T.untyped) }
  def mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mode=(value); end
  sig { returns(T.untyped) }
  def reassign_cleanup; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reassign_cleanup=(value); end
end

class BorrowChecker
  sig { returns(T::Array[T.untyped]) }
  def errors; end
end

class Builder
  sig { returns(T::Array[T.untyped]) }
  def segments; end
  sig { returns(T::Array[T.untyped]) }
  def synthetic_fields; end
end

class CapabilityWrap
  sig { returns(T.untyped) }
  def lock_rank; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lock_rank=(value); end
end

class ConcurrentOp
  sig { returns(T.untyped) }
  def capture_analysis; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capture_analysis=(value); end
  sig { returns(T.untyped) }
  def shard_context; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def shard_context=(value); end
end

class CopyNode
  sig { returns(T.untyped) }
  def deep_copy; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deep_copy=(value); end
end

class Drop
  sig { returns(T.untyped) }
  def cleanup_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def cleanup_entry=(value); end
end

class Edit
  sig { returns(T.untyped) }
  def replacement; end
  sig { returns(T.untyped) }
  def span; end
end

class EffectSet
  sig { returns(T::Set[Symbol]) }
  def effects; end
end

class EnumSchema
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class ExternFnDecl
  sig { returns(T.untyped) }
  def fn_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_type_params=(value); end
  sig { returns(T.untyped) }
  def owner_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type=(value); end
  sig { returns(T.untyped) }
  def owner_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type_params=(value); end
end

class ExternStructDecl
  sig { returns(T.untyped) }
  def as_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def as_type=(value); end
  sig { returns(T.untyped) }
  def close_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def close_method=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
end

class FieldDef
  sig { returns(T.untyped) }
  def boxed_capture; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def boxed_capture=(value); end
end

class Fix
  sig { returns(Symbol) }
  def confidence; end
  sig { returns(T.untyped) }
  def description; end
  sig { returns(T::Array[Edit]) }
  def edits; end
end

class FixableFinding
  sig { returns(T.untyped) }
  def category; end
  sig { returns(T::Array[Fix]) }
  def fixes; end
  sig { returns(T.untyped) }
  def level; end
  sig { returns(T.untyped) }
  def message; end
  sig { returns(T.untyped) }
  def token; end
end

class ForEach
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class ForRange
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class FsmTransform::Builder
  sig { returns(T::Array[T.untyped]) }
  def segments; end
  sig { returns(T::Array[T.untyped]) }
  def synthetic_fields; end
end

class FsmTransform::RecursiveSplitter::Builder
  sig { returns(T::Array[T.untyped]) }
  def segments; end
  sig { returns(T::Array[T.untyped]) }
  def synthetic_fields; end
end

class FuncCall
  sig { returns(T.untyped) }
  def arg_families; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arg_families=(value); end
  sig { returns(T.untyped) }
  def collapsed_errors; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def collapsed_errors=(value); end
  sig { returns(T.untyped) }
  def error_union_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def error_union_type=(value); end
  sig { returns(T.untyped) }
  def extern_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_call=(value); end
  sig { returns(T.untyped) }
  def extern_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_effects=(value); end
  sig { returns(T.untyped) }
  def fn_var_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_var_call=(value); end
  sig { returns(T.untyped) }
  def generic_type_args; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def generic_type_args=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
  sig { returns(T.untyped) }
  def module_alias; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def module_alias=(value); end
  sig { returns(T.untyped) }
  def pipe_lhs; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pipe_lhs=(value); end
end

class FunctionCFG
  sig { returns(T::Array[T.untyped]) }
  def blocks; end
  sig { returns(BasicBlock) }
  def entry; end
  sig { returns(BasicBlock) }
  def exit_block; end
  sig { returns(T.untyped) }
  def fn_name; end
end

class FunctionContext
  sig { returns(Integer) }
  def alloc_count; end
  sig { params(value: Integer).returns(Integer) }
  def alloc_count=(value); end
  sig { returns(Integer) }
  def conditional_depth; end
  sig { params(value: Integer).returns(Integer) }
  def conditional_depth=(value); end
  sig { returns(Integer) }
  def frame_count; end
  sig { params(value: Integer).returns(Integer) }
  def frame_count=(value); end
  sig { returns(Integer) }
  def heap_count; end
  sig { params(value: Integer).returns(Integer) }
  def heap_count=(value); end
  sig { returns(T.untyped) }
  def lifetime; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lifetime=(value); end
  sig { returns(Integer) }
  def loop_depth; end
  sig { params(value: Integer).returns(Integer) }
  def loop_depth=(value); end
  sig { returns(T.untyped) }
  def name; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def name=(value); end
  sig { returns(T::Boolean) }
  def needs_rt; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def needs_rt=(value); end
  sig { returns(Type) }
  def return_type; end
  sig { returns(T::Array[T.untyped]) }
  def returns; end
  sig { params(value: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def returns=(value); end
  sig { returns(Integer) }
  def stack_vars_bytes; end
  sig { params(value: Integer).returns(Integer) }
  def stack_vars_bytes=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
end

class FunctionDef
  sig { returns(T.untyped) }
  def alloc_fault; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def alloc_fault=(value); end
  sig { returns(T.untyped) }
  def arrow_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arrow_token=(value); end
  sig { returns(T.untyped) }
  def can_fail; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def can_fail=(value); end
  sig { returns(T.untyped) }
  def cleanup_bindings; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def cleanup_bindings=(value); end
  sig { returns(T.untyped) }
  def effect_set; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effect_set=(value); end
  sig { returns(T.untyped) }
  def effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects=(value); end
  sig { returns(T.untyped) }
  def effects_decl; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects_decl=(value); end
  sig { returns(T.untyped) }
  def effects_span; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects_span=(value); end
  sig { returns(T.untyped) }
  def error_fallible; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def error_fallible=(value); end
  sig { returns(T.untyped) }
  def explicit_return_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def explicit_return_type=(value); end
  sig { returns(T.untyped) }
  def fsm_eligible; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_eligible=(value); end
  sig { returns(T.untyped) }
  def fsm_ineligible_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_ineligible_reason=(value); end
  sig { returns(T.untyped) }
  def fsm_suspend_points; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fsm_suspend_points=(value); end
  sig { returns(T.untyped) }
  def has_promotion; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def has_promotion=(value); end
  sig { returns(T.untyped) }
  def heap_carry_return; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_carry_return=(value); end
  sig { returns(T.untyped) }
  def heap_carry_return_vars; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_carry_return_vars=(value); end
  sig { returns(T.untyped) }
  def inferred_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def inferred_effects=(value); end
  sig { returns(T.untyped) }
  def is_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def is_method=(value); end
  sig { returns(T.untyped) }
  def max_depth_n; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def max_depth_n=(value); end
  sig { returns(T.untyped) }
  def moved_guard_info; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def moved_guard_info=(value); end
  sig { returns(T.untyped) }
  def mutual_thunk_plan; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mutual_thunk_plan=(value); end
  sig { returns(T.untyped) }
  def name_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def name_token=(value); end
  sig { returns(T.untyped) }
  def needs_rt; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def needs_rt=(value); end
  sig { returns(T.untyped) }
  def post_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def post_clauses=(value); end
  sig { returns(T.untyped) }
  def pre_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pre_clauses=(value); end
  sig { returns(T.untyped) }
  def reentrance_kind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrance_kind=(value); end
  sig { returns(T.untyped) }
  def reentrant; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrant=(value); end
  sig { returns(T.untyped) }
  def reentrant_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reentrant_token=(value); end
  sig { returns(T.untyped) }
  def requires; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def requires=(value); end
  sig { returns(T.untyped) }
  def requires_clauses; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def requires_clauses=(value); end
  sig { returns(T.untyped) }
  def return_provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_provenance=(value); end
  sig { returns(T.untyped) }
  def return_type_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_type_token=(value); end
  sig { returns(T.untyped) }
  def snapshot_types; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def snapshot_types=(value); end
  sig { returns(T.untyped) }
  def stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def stack_tier=(value); end
  sig { returns(T.untyped) }
  def stack_vars_bytes; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def stack_vars_bytes=(value); end
  sig { returns(T.untyped) }
  def tail_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tail_call=(value); end
  sig { returns(T.untyped) }
  def thunk_plan; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def thunk_plan=(value); end
  sig { returns(T.untyped) }
  def tight_reentrance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight_reentrance=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
  sig { returns(T.untyped) }
  def uses_alloc; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_alloc=(value); end
  sig { returns(T.untyped) }
  def uses_heap; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_heap=(value); end
  sig { returns(T.untyped) }
  def uses_rt; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def uses_rt=(value); end
end

class FunctionSignature
  sig { returns(T.untyped) }
  def alloc_fault; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def alloc_fault=(value); end
  sig { returns(T.untyped) }
  def arg_spec; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arg_spec=(value); end
  sig { returns(T.nilable(Proc)) }
  def arg_validator; end
  sig { params(value: T.nilable(Proc)).returns(T.nilable(Proc)) }
  def arg_validator=(value); end
  sig { returns(T.nilable(Integer)) }
  def arity; end
  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def arity=(value); end
  sig { returns(T.untyped) }
  def can_fail; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def can_fail=(value); end
  sig { returns(T.untyped) }
  def effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def effects=(value); end
  sig { returns(T.nilable(IntrinsicEmit)) }
  def emit; end
  sig { params(value: T.nilable(IntrinsicEmit)).returns(T.nilable(IntrinsicEmit)) }
  def emit=(value); end
  sig { returns(T.untyped) }
  def error_fallible; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def error_fallible=(value); end
  sig { returns(T.untyped) }
  def extern; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern=(value); end
  sig { returns(T.untyped) }
  def extern_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_effects=(value); end
  sig { returns(T.untyped) }
  def fn_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_type_params=(value); end
  sig { returns(T.untyped) }
  def intrinsic; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def intrinsic=(value); end
  sig { returns(T.untyped) }
  def module_alias; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def module_alias=(value); end
  sig { returns(T.untyped) }
  def needs_rt; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def needs_rt=(value); end
  sig { returns(T.untyped) }
  def owner_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type=(value); end
  sig { returns(T.untyped) }
  def owner_type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def owner_type_params=(value); end
  sig { returns(T.untyped) }
  def params; end
  sig { returns(T.untyped) }
  def reentrant; end
  sig { returns(T.untyped) }
  def requires; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def requires=(value); end
  sig { returns(FunctionReturn) }
  def return_def; end
  sig { params(value: FunctionReturn).returns(FunctionReturn) }
  def return_def=(value); end
  sig { returns(T.untyped) }
  def return_lifetime; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_lifetime=(value); end
  sig { returns(T.untyped) }
  def return_provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_provenance=(value); end
  sig { returns(T.untyped) }
  def return_strategy; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def return_strategy=(value); end
  sig { returns(Type) }
  def return_type; end
  sig { returns(T.untyped) }
  def stack_tier; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def stack_tier=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(T.untyped) }
  def visibility; end
  sig { returns(T.untyped) }
  def zig_pattern; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def zig_pattern=(value); end
end

class GetField
  sig { returns(T.untyped) }
  def indirect_field; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def indirect_field=(value); end
  sig { returns(T.untyped) }
  def is_assignment_lhs; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def is_assignment_lhs=(value); end
end

class Identifier
  sig { returns(T.untyped) }
  def atomic_borrow; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def atomic_borrow=(value); end
  sig { returns(T.untyped) }
  def fn_ref; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def fn_ref=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
end

class IfStatement
  sig { returns(T.untyped) }
  def else_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def else_result_type=(value); end
  sig { returns(T.untyped) }
  def expr_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def expr_mode=(value); end
  sig { returns(T.untyped) }
  def then_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def then_result_type=(value); end
end

class InlineStructVariant
  sig { returns(T.untyped) }
  def deinit_entries; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deinit_entries=(value); end
  sig { returns(T.untyped) }
  def fields; end
end

class MIR::Drop
  sig { returns(T.untyped) }
  def cleanup_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def cleanup_entry=(value); end
end

class MIR::FieldDef
  sig { returns(T.untyped) }
  def boxed_capture; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def boxed_capture=(value); end
end

class MIRChecker
  sig { returns(T::Array[T.untyped]) }
  def errors; end
end

class MIREmitter
  sig { returns(String) }
  def rt_name; end
  sig { params(value: String).returns(String) }
  def rt_name=(value); end
end

class MIRLowering
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def fn_sigs; end
  sig { returns(T.untyped) }
  def shard_context; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def shard_context=(value); end
end

class MIRPass
  sig { returns(T::Hash[String, T::Hash[String, CleanupEntry]]) }
  def cleanup_bindings; end
end

class MatchStatement
  sig { returns(T.untyped) }
  def case_result_types; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def case_result_types=(value); end
  sig { returns(T.untyped) }
  def default_result_type; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def default_result_type=(value); end
  sig { returns(T.untyped) }
  def expr_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def expr_mode=(value); end
  sig { returns(T.untyped) }
  def string_match; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def string_match=(value); end
end

class MethodCall
  sig { returns(T.untyped) }
  def extern_call; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_call=(value); end
  sig { returns(T.untyped) }
  def extern_effects; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def extern_effects=(value); end
  sig { returns(T.untyped) }
  def generic_type_args; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def generic_type_args=(value); end
  sig { returns(T.untyped) }
  def heap_dupe_result; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def heap_dupe_result=(value); end
  sig { returns(T.untyped) }
  def map_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def map_method=(value); end
  sig { returns(T.untyped) }
  def pool_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pool_method=(value); end
  sig { returns(T.untyped) }
  def set_method; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def set_method=(value); end
end

class ModuleImporter
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def module_cache; end
end

class OwnershipDataflow
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def block_in; end
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def block_out; end
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def point_states; end
end

class OwnershipGraph
  sig { returns(T::Array[T.untyped]) }
  def edges; end
end

class PipelineHost
  sig { returns(T.untyped) }
  def fn_sigs; end
end

class Pprof::Profile
  sig { params(value: Integer).returns(Integer) }
  def duration_nanos=(value); end
  sig { params(value: Integer).returns(Integer) }
  def period=(value); end
  sig { params(value: T.untyped).returns(T.untyped) }
  def time_nanos=(value); end
end

class Profile
  sig { params(value: Integer).returns(Integer) }
  def duration_nanos=(value); end
  sig { params(value: Integer).returns(Integer) }
  def period=(value); end
  sig { params(value: T.untyped).returns(T.untyped) }
  def time_nanos=(value); end
end

class Program
  sig { returns(T.untyped) }
  def sync_policy; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def sync_policy=(value); end
end

class RecursiveSplitter::Builder
  sig { returns(T::Array[T.untyped]) }
  def segments; end
  sig { returns(T::Array[T.untyped]) }
  def synthetic_fields; end
end

class ResourceSchema
  sig { returns(T.untyped) }
  def as_type; end
  sig { returns(T.untyped) }
  def close_zig; end
  sig { returns(T.untyped) }
  def extern_module; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def methods; end
  sig { returns(T.untyped) }
  def static_methods; end
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(Symbol) }
  def visibility; end
end

class ReturnNode
  sig { returns(T.untyped) }
  def catch_string_dupe_ret; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def catch_string_dupe_ret=(value); end
  sig { returns(T.untyped) }
  def promote_ret_wrap; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def promote_ret_wrap=(value); end
  sig { returns(T.untyped) }
  def ret_field_promote_data; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def ret_field_promote_data=(value); end
end

class Schemas::EnumSchema
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class Schemas::InlineStructVariant
  sig { returns(T.untyped) }
  def deinit_entries; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deinit_entries=(value); end
  sig { returns(T.untyped) }
  def fields; end
end

class Schemas::ResourceSchema
  sig { returns(T.untyped) }
  def as_type; end
  sig { returns(T.untyped) }
  def close_zig; end
  sig { returns(T.untyped) }
  def extern_module; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def methods; end
  sig { returns(T.untyped) }
  def static_methods; end
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(Symbol) }
  def visibility; end
end

class Schemas::StructSchema
  sig { returns(T.untyped) }
  def as_type; end
  sig { returns(T.untyped) }
  def extern_module; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def methods; end
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(T.untyped) }
  def visibility; end
end

class Schemas::UnionSchema
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class Scope
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def dependencies; end
  sig { params(value: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
  def dependencies=(value); end
  sig { returns(Integer) }
  def depth; end
  sig { params(value: Integer).returns(Integer) }
  def depth=(value); end
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def locals; end
  sig { params(value: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
  def locals=(value); end
  sig { returns(T::Set[T.untyped]) }
  def owned_names; end
  sig { params(value: T::Set[T.untyped]).returns(T::Set[T.untyped]) }
  def owned_names=(value); end
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def types; end
end

class SemanticAnnotator
  sig { returns(T::Array[T.untyped]) }
  def scope_stack; end
  sig { returns(T.untyped) }
  def source_code; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def source_code=(value); end
end

class SourceError
  sig { returns(T.untyped) }
  def original_message; end
  sig { returns(T.untyped) }
  def source_code; end
  sig { returns(T.untyped) }
  def token; end
end

class Span
  sig { returns(T.untyped) }
  def col; end
  sig { returns(T.untyped) }
  def file; end
  sig { returns(T.untyped) }
  def length; end
  sig { returns(T.untyped) }
  def line; end
end

class StackVerifier
  sig { returns(T.untyped) }
  def binary_path; end
  sig { returns(T.untyped) }
  def module_prefix; end
end

class StringConcat
  sig { returns(T.untyped) }
  def storage; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def storage=(value); end
end

class StructLit
  sig { returns(T.untyped) }
  def borrowed_field_names; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def borrowed_field_names=(value); end
  sig { returns(T.untyped) }
  def field_tokens; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def field_tokens=(value); end
end

class StructSchema
  sig { returns(T.untyped) }
  def as_type; end
  sig { returns(T.untyped) }
  def extern_module; end
  sig { returns(T.untyped) }
  def fields; end
  sig { returns(T.untyped) }
  def methods; end
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(T.untyped) }
  def visibility; end
end

class SymbolEntry
  sig { returns(T::Boolean) }
  def borrowed_alias; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def borrowed_alias=(value); end
  sig { returns(T.untyped) }
  def capabilities; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def capabilities=(value); end
  sig { returns(T.untyped) }
  def close_zig; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def close_zig=(value); end
  sig { returns(T.untyped) }
  def invalid_reason; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def invalid_reason=(value); end
  sig { returns(T::Boolean) }
  def is_param; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def is_param=(value); end
  sig { returns(T.untyped) }
  def layout; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def layout=(value); end
  sig { returns(T.untyped) }
  def lifetime; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lifetime=(value); end
  sig { returns(T.nilable(Symbol)) }
  def link_source; end
  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def link_source=(value); end
  sig { returns(T.untyped) }
  def mutable; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mutable=(value); end
  sig { returns(T::Boolean) }
  def mutable_ref_target; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def mutable_ref_target=(value); end
  sig { returns(T::Boolean) }
  def mutated; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def mutated=(value); end
  sig { returns(T.nilable(Symbol)) }
  def ownership_kind; end
  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def ownership_kind=(value); end
  sig { returns(T.untyped) }
  def param_decl_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def param_decl_token=(value); end
  sig { returns(T::Boolean) }
  def poly_borrow_target; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def poly_borrow_target=(value); end
  sig { returns(T::Boolean) }
  def read; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def read=(value); end
  sig { returns(T.untyped) }
  def rebindable; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def rebindable=(value); end
  sig { returns(T.untyped) }
  def reg; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def reg=(value); end
  sig { returns(T.untyped) }
  def resource; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def resource=(value); end
  sig { returns(T.nilable(Scope)) }
  def scope; end
  sig { params(value: T.nilable(Scope)).returns(T.nilable(Scope)) }
  def scope=(value); end
  sig { returns(T.nilable(Integer)) }
  def scope_depth; end
  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def scope_depth=(value); end
  sig { returns(T.untyped) }
  def size; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def size=(value); end
  sig { returns(T.untyped) }
  def storage; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def storage=(value); end
  sig { returns(T.untyped) }
  def sync; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def sync=(value); end
  sig { returns(T.untyped) }
  def sync_families; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def sync_families=(value); end
  sig { returns(T::Boolean) }
  def takes; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def takes=(value); end
  sig { returns(Type) }
  def type; end
  sig { returns(T.untyped) }
  def valid; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def valid=(value); end
end

class TestBlock
  sig { returns(T.untyped) }
  def after_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_all=(value); end
  sig { returns(T.untyped) }
  def after_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_each=(value); end
  sig { returns(T.untyped) }
  def before_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_all=(value); end
  sig { returns(T.untyped) }
  def before_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_each=(value); end
  sig { returns(T.untyped) }
  def lets; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lets=(value); end
end

class TestBlockCtx
  sig { returns(T.nilable(T::Array[T.untyped])) }
  def setup_mir; end
  sig { returns(T::Array[T.untyped]) }
  def test_after_each_mir; end
  sig { returns(T::Array[T.untyped]) }
  def test_before_each_mir; end
  sig { returns(AST::TestBlock) }
  def test_block; end
  sig { returns(String) }
  def test_name; end
end

class TestLowering::TestBlockCtx
  sig { returns(T.nilable(T::Array[T.untyped])) }
  def setup_mir; end
  sig { returns(T::Array[T.untyped]) }
  def test_after_each_mir; end
  sig { returns(T::Array[T.untyped]) }
  def test_before_each_mir; end
  sig { returns(AST::TestBlock) }
  def test_block; end
  sig { returns(String) }
  def test_name; end
end

class TestThat
  sig { returns(T.untyped) }
  def pending; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def pending=(value); end
  sig { returns(T.untyped) }
  def synthetic_fn; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def synthetic_fn=(value); end
end

class Type
  sig { returns(T.untyped) }
  def auto_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def auto_token=(value); end
  sig { returns(T.untyped) }
  def capacity; end
  sig { returns(T.untyped) }
  def collection; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def collection=(value); end
  sig { returns(T.untyped) }
  def elem_ownership; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def elem_ownership=(value); end
  sig { returns(T.untyped) }
  def elem_sync; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def elem_sync=(value); end
  sig { returns(T.untyped) }
  def generic_args; end
  sig { returns(T::Boolean) }
  def is_observable; end
  sig { params(value: T::Boolean).returns(T::Boolean) }
  def is_observable=(value); end
  sig { params(value: T.untyped).returns(T.untyped) }
  def is_resource=(value); end
  sig { returns(T.untyped) }
  def layout; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def layout=(value); end
  sig { returns(T.untyped) }
  def link_source; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def link_source=(value); end
  sig { returns(T.untyped) }
  def lock_rank; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lock_rank=(value); end
  sig { returns(T.untyped) }
  def name; end
  sig { returns(T.untyped) }
  def observable_terminal; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_terminal=(value); end
  sig { returns(T.untyped) }
  def observable_token; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def observable_token=(value); end
  sig { returns(T.untyped) }
  def ownership; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def ownership=(value); end
  sig { returns(T.untyped) }
  def polymorphic_shared; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def polymorphic_shared=(value); end
  sig { returns(T.untyped) }
  def provenance; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def provenance=(value); end
  sig { returns(T.untyped) }
  def raw; end
  sig { returns(T.untyped) }
  def shard_count; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def shard_count=(value); end
  sig { returns(T.untyped) }
  def soa; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def soa=(value); end
  sig { returns(T.untyped) }
  def sync; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def sync=(value); end
end

class UnionDef
  sig { returns(T.untyped) }
  def methods; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def methods=(value); end
  sig { returns(T.untyped) }
  def type_params; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def type_params=(value); end
end

class UnionSchema
  sig { returns(T.untyped) }
  def type_params; end
  sig { returns(T.untyped) }
  def variants; end
  sig { returns(T.untyped) }
  def visibility; end
end

class UseAfterMoveChecker
  sig { returns(T::Array[T.untyped]) }
  def errors; end
end

class VarDecl
  sig { returns(T.untyped) }
  def mir_binding_entry; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mir_binding_entry=(value); end
end

class WhenBlock
  sig { returns(T.untyped) }
  def after_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_all=(value); end
  sig { returns(T.untyped) }
  def after_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def after_each=(value); end
  sig { returns(T.untyped) }
  def before_all; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_all=(value); end
  sig { returns(T.untyped) }
  def before_each; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def before_each=(value); end
  sig { returns(T.untyped) }
  def lets; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lets=(value); end
  sig { returns(T.untyped) }
  def tags; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tags=(value); end
end

class WhileBindLoop
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class WhileLoop
  sig { returns(T.untyped) }
  def mark_per_iter; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def mark_per_iter=(value); end
  sig { returns(T.untyped) }
  def tight; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def tight=(value); end
end

class WithBlock
  sig { returns(T.untyped) }
  def arms; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def arms=(value); end
  sig { returns(T.untyped) }
  def deadlock_escape; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def deadlock_escape=(value); end
  sig { returns(T.untyped) }
  def lock_error_clause; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def lock_error_clause=(value); end
  sig { returns(T.untyped) }
  def polymorphic; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def polymorphic=(value); end
  sig { returns(T.untyped) }
  def snapshot_mode; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def snapshot_mode=(value); end
  sig { returns(T.untyped) }
  def universal_poly; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def universal_poly=(value); end
  sig { returns(T.untyped) }
  def view_kind; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def view_kind=(value); end
end

class YieldExpr
  sig { returns(T.untyped) }
  def yield_dupe; end
  sig { params(value: T.untyped).returns(T.untyped) }
  def yield_dupe=(value); end
end

class ZigTranspiler
  sig { returns(T.untyped) }
  def enum_schemas; end
  sig { returns(T.untyped) }
  def module_type_defs; end
  sig { returns(T.untyped) }
  def struct_schemas; end
  sig { returns(T.untyped) }
  def union_schemas; end
end

