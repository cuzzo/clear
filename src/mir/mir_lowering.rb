# typed: strict
# src/mir_lowering.rb - Lowers annotated AST (post-MIRPass) into MIR tree
#
# Pipeline: Parse -> Annotate -> MIRPass -> Lower -> Emit
#
# The lowering reads the annotated AST with old MIR nodes (Drop, Promote,
# SuppressCleanup, etc.) already inserted by MIRPass, and produces a
# complete MIR tree that the MIREmitter can emit to Zig.
#
# This pass subsumes the transpiler's visit_node dispatch. All type
# introspection and allocator resolution happens HERE, not in the emitter.

require "sorbet-runtime"
require "set"

require_relative "mir"
require_relative "cleanup_entry"
require_relative "pass_state"
require_relative "placement"
require_relative "capture_strategy"
require_relative "fiber_ctx_builder"
require_relative "../ast/ast"
require_relative "../ast/type"
require_relative "../ast/error_registry"
require_relative "../backends/zig_type_mapper"
require_relative "../backends/pipeline_host"
require_relative "fsm_lowering"
require_relative "fsm_transform"
require_relative "thunk_transform"
require_relative "test_lowering"
require_relative "hoist"
require_relative "lowering/functions"
require_relative "lowering/capabilities"
require_relative "lowering/concurrency"
require_relative "lowering/expressions"
require_relative "lowering/literals"
require_relative "lowering/variables"
require_relative "lowering/control_flow"

class MIRLowering
    extend T::Sig

  class OwnershipTransferPlan < T::Struct
    extend T::Sig

    const :name, String
    const :target, Symbol
    const :move_guarded, T::Boolean

    sig { returns(T::Array[T.untyped]) }
    def marks
      out = T.let([MIR::TransferMark.new(name, target)], T::Array[T.untyped])
      out << MIR::MoveMark.new(name) if move_guarded
      out
    end
  end

  class AllocatingResultFact < T::Struct
    extend T::Sig

    const :name, String
    const :ownership_effect, MIR::OwnershipEffect
    const :type_info, Type
    const :scope, Symbol

    sig { returns(Symbol) }
    def alloc
      ownership_effect.alloc || :heap
    end

    sig { returns(MIR::AllocMark) }
    def alloc_mark
      mark = MIR::AllocMark.new(name, alloc, type_info)
      mark.scope = scope
      mark
    end
  end

  include ZigTypeMapper
  include FsmLowering
  include TestLowering
  include MIRHoistLowering
  include MIRLoweringFunctions
  include MIRLoweringCapabilities
  include MIRLoweringConcurrency
  include MIRLoweringExpressions
  include MIRLoweringLiterals
  include MIRLoweringVariables
  include MIRLoweringControlFlow

  ZIG_PRIMITIVE_RE = /\A[uif]\d+\z/

  attr_reader :fn_sigs
  attr_accessor :shard_context

  sig { params(type_info: T.untyped).returns(T::Boolean) }
  def ast_void_type?(type_info)
    return true if type_info.nil? || type_info == :Void
    ti = Type.from_node(type_info)
    ti ? ti.void? : false
  end

  sig { params(struct_schemas: T::Hash[Symbol, Schemas::StructSchema], enum_schemas: T::Hash[Symbol, T::Array[String]], union_schemas: T::Hash[Symbol, Schemas::UnionSchema], fn_sigs: T::Hash[String, FunctionSignature], moved_guard_info: T::Hash[String, T::Hash[String, TrueClass]], importer: T.nilable(ModuleImporter), source_dir: T.nilable(String), debug_mode: T::Boolean, target: Symbol).void }
  def initialize(struct_schemas: {}, enum_schemas: {}, union_schemas: {},
                 fn_sigs: {}, moved_guard_info: {},
                 importer: nil, source_dir: nil,
                 debug_mode: false, target: :zig)
    @struct_schemas = T.let(struct_schemas || {}, T::Hash[Symbol, T.untyped])
    @enum_schemas = T.let(enum_schemas || {}, T::Hash[Symbol, T::Array[T.untyped]])
    @union_schemas = T.let(union_schemas || {}, T::Hash[Symbol, T.untyped])
    # Single source for struct/union schema resolution. Was rebuilt as an
    # identical inline `->(name){ @struct_schemas&.dig(name) ||
    # @union_schemas&.dig(name) }` lambda at 5 sites (decomplex
    # Missing-Abstraction / Reification-Miss).
    @schema_lookup = T.let(
      ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) || @enum_schemas&.dig(name) },
      T.proc.params(name: T.untyped).returns(T.untyped),
    )
    @fn_sigs = T.let(fn_sigs || {}, T::Hash[T.untyped, T.untyped])
    @moved_guard_info = T.let(moved_guard_info || {}, T::Hash[String, T::Hash[T.untyped, T.untyped]])
    @rt_name = T.let("rt", String)
    @shard_context = T.let(nil, T.untyped)  # { map: "varname", idx: "__sh0_sh.shard", key: "__sh0_key" }
    @emitted_extern_modules = T.let(Set.new, T::Set[T.untyped])
    @block_expr_counter = T.let(0, Integer)
    @pipeline_host = T.let(nil, T.nilable(PipelineHost))
    @importer = T.let(importer, T.nilable(ModuleImporter))
    @source_dir = T.let(source_dir, T.nilable(String))
    @emitted_types = T.let(Set.new, T::Set[T.untyped])
    @debug_mode = debug_mode
    @pending_stmts = T.let([], T::Array[T.untyped])
    @tmp_counter = T.let(0, Integer)
    @current_decl_alloc = T.let(nil, T.nilable(Symbol))
    # Allocator of the binding whose value is currently being lowered;
    # an anonymous allocating sub-expression inherits it (with_decl_alloc).
    @current_bindings = T.let({}, T::Hash[String, CleanupEntry])  # set per-function by lower_function_def from fn.cleanup_bindings
    @target = target
    @fn_alloc_marked_names = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @lowered_alloc_names = T.let(Set.new, T.nilable(T::Set[T.untyped]))
    @lowered_guarded_cleanup_names = T.let(Set.new, T.nilable(T::Set[T.untyped]))
    @decl_zig_name_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @guarded_cleanup_names = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @fn_name_rename_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @current_fn_snapshot_types = T.let(nil, T.nilable(T::Set[T.untyped]))
    @atomic_emit_raw = T.let(false, T::Boolean)
    @used_sharded_map = T.let(false, T::Boolean)
    @current_fn_has_rt = T.let(false, T::Boolean)
    @current_fn_tail_call = T.let(false, T::Boolean)
    @current_fn_zig_name = T.let(nil, T.nilable(String))
    @current_fn_return_payload_zig = T.let(nil, T.nilable(String))
    @current_fn_returned_names = T.let(Set.new, T::Set[String])
    @current_fn_heap_carry_return = T.let(false, T::Boolean)
    @current_fn_heap_carry_return_vars = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_has_catch = T.let(false, T::Boolean)
    @current_fn_collection_params = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_param_names = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_takes_param_names = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_mutable_scalar_params = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_bg_pointer_captures = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fiber_capture_symbols = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @do_capture_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @locked_unwrap_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @rc_unwrap_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @with_alias_alloc_map = T.let(nil, T.nilable(T::Hash[String, Symbol]))
    @safe_nav_counter = T.let(0, Integer)
    @extern_counter = T.let(0, Integer)
    @lambda_counter = T.let(0, Integer)
    @stream_lit_counter = T.let(0, Integer)
    @do_block_counter = T.let(0, Integer)
    @bg_block_counter = T.let(0, Integer)
    @stream_gen_counter = T.let(0, Integer)
    @current_stream_is_inf = T.let(nil, T.nilable(T::Boolean))
    @current_stream_local = T.let(nil, T.nilable(String))
    @loop_mark_counter = T.let(0, Integer)
    @for_counter = T.let(0, Integer)
    @_emitter = T.let(nil, T.nilable(MIREmitter))
  end

  sig { returns(T.proc.params(name: T.untyped).returns(T.untyped)) }
  def mir_schema_lookup
    @schema_lookup
  end

  sig { returns(Symbol) }
  def lowering_target
    @target
  end

  sig { returns(String) }
  def runtime_binding_name
    @rt_name
  end

  sig { returns(Integer) }
  def next_stream_literal_id
    id = @stream_lit_counter
    @stream_lit_counter += 1
    id
  end

  sig { params(mir: T.untyped, ast_node: T.untyped, dest_alloc: T.nilable(Symbol), dest_type: T.untyped).returns(T.untyped) }
  def place_value_for_destination(mir, ast_node, dest_alloc, dest_type = nil)
    return mir unless dest_alloc == :heap

    ti = dest_type || Type.from_node(ast_node)
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    if ti.is_a?(Type) && ti.indirect? && !ti.any_sync? && ti.ownership == :affine
      return mir if mir.is_a?(MIR::HeapCreate)
      source_t = Type.from_node(ast_node)
      source_t = Type.new(source_t) if source_t && !source_t.is_a?(Type)
      return mir if source_t.is_a?(Type) && source_t.indirect?
      return MIR::HeapCreate.new(transpile_type(ti.resolved.to_s), mir, :heap, "blk")
    end

    return mir unless ti.is_a?(Type) && ti.string?
    if mir.is_a?(MIR::Cast) && ast_node.is_a?(AST::BinaryOp) && (ast_node.op == :OR_RESCUE || ast_node.op == :OR)
      placed = place_value_for_destination(mir.expr, ast_node, dest_alloc, dest_type)
      return MIR::Cast.new(placed, mir.target_type, mir.method)
    end
    if ast_node.is_a?(AST::BinaryOp) && (ast_node.op == :OR_RESCUE || ast_node.op == :OR)
      left_t = Type.from_node(ast_node.left)
      return place_string_value_for_heap_destination(mir, ast_node) if left_t&.optional?

      if mir.is_a?(MIR::TryCatch)
        return place_string_value_for_heap_destination(mir, ast_node) unless heap_owned_result?(mir.expr, ast_node.left)

        left = place_or_branch_value_for_destination(mir.expr, ast_node.left)
        right = place_or_branch_value_for_destination(mir.catch_body, ast_node.right)
        return MIR::TryCatch.new(left, right, mir.capture)
      elsif mir.is_a?(MIR::Orelse)
        left = place_or_branch_value_for_destination(mir.expr, ast_node.left)
        right = place_or_branch_value_for_destination(mir.fallback, ast_node.right)
        return MIR::Orelse.new(left, right)
      end
    end

    place_string_value_for_heap_destination(mir, ast_node)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T.untyped) }
  def place_or_branch_value_for_destination(mir, ast_node)
    placed = place_string_value_for_heap_destination(mir, ast_node)
    return placed unless mir_allocates?(placed)

    scoped_owning_branch_value(placed, ast_node)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T.untyped) }
  def place_string_value_for_heap_destination(mir, ast_node)
    return mir if heap_owned_result?(mir, ast_node)

    mir = MIR::TryExpr.new(mir) if Type.from_node!(ast_node, context: "heap destination placement").error_union?
    MIR::DupeSlice.new(mir, :heap)
  end

  sig { params(type_info: T.untyped).returns(T.nilable(Symbol)) }
  def escaping_value_alloc(type_info)
    ti = Type.from_node(type_info)
    ti = ti.payload_type if ti&.error_union?
    return :heap if ti&.heap_ptr? || ti&.recursive_cleanup_shape?(@schema_lookup)
    nil
  end

  sig { params(node: AST::ReturnNode).returns(T.nilable(Symbol)) }
  def return_destination_alloc(node)
    return nil unless @current_fn_heap_carry_return
    return nil unless node.value

    escaping_value_alloc(Type.from_node(node.value))
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(MIR::BlockExpr) }
  def scoped_owning_branch_value(mir, ast_node)
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @tmp_counter = T.let(@tmp_counter, T.untyped)
    @block_expr_counter += 1
    @tmp_counter += 1
    label = "__own_branch_#{@block_expr_counter}"
    name = "__tmp_#{@tmp_counter}"
    type_info = Type.from_node!(ast_node, context: "branch ownership placement")
    mark = MIR::AllocMark.new(name, :heap, type_info)
    mark.scope = :heap
    body = T.let([mark, MIR::Let.new(name, mir, false, nil, nil)], T::Array[MIR::Stmt])
    entry = hoist_cleanup_entry(mir, ast_node)
    if entry
      entry[:has_moved_guard] = true
      body << MIR::ErrCleanup.new(name, entry)
      body << MIR::TransferMark.new(name, :block_result)
      body << MIR::MoveMark.new(name)
    end
    body << MIR::BreakStmt.new(label, MIR::Ident.new(name))
    MIR::BlockExpr.new(label, body)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T::Boolean) }
  def heap_owned_result?(mir, ast_node)
    effect = mir.respond_to?(:ownership_effect) ? mir.ownership_effect : MIR::OwnershipEffect.none
    return true if effect.produces_owned && effect.alloc == :heap

    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    if node.is_a?(AST::Identifier) && ast_node.respond_to?(:was_moved) && ast_node.was_moved == true
      return placement_for_node(node) == :heap
    end
    node.is_a?(AST::Identifier) && node.symbol&.heap_storage? == true
  end

  # Lower an AST node (or old MIR node) into a new MIR node.
  sig { params(node: T.untyped).returns(T.untyped) }
  def lower(node)
    case node

    # --- Top-level ---
    when AST::Program           then lower_program(node)

    # --- Old MIR nodes (from MIRPass) -> new MIR nodes ---
    when MIR::Drop              then lower_drop(node)
    when MIR::SuppressCleanup
      safe = zig_safe_name(node.name)
      if @guarded_cleanup_names&.[](safe)
        [MIR::TransferMark.new(safe, :owned_sink), MIR::MoveMark.new(safe)]
      else
        []
      end
    when MIR::Alloc
      mark = MIR::AllocMark.new(node.name, node.alloc, nil)
      mark.scope = node.alloc == :heap ? :heap : :iteration
      mark
    when MIR::Return            then MIR::ReturnMark.new(node.escaped_vars)
    when MIR::ReassignCleanup   then MIR::ReassignMark.new(node.name, node.alloc)
    when MIR::FieldCleanup      then MIR::FieldCleanupMark.new(node.target_name, node.field, node.alloc)

    # --- Type definitions ---
    when AST::EnumDef           then lower_enum_def(node)
    when AST::UnionDef          then lower_union_def(node)
    when AST::StructDef         then lower_struct_def(node)
    when AST::ExternFnDecl      then lower_extern_fn(node)
    when AST::ExternStructDecl  then lower_extern_struct(node)

    # --- Declarations & assignments ---
    when AST::VarDecl           then lower_var_decl(node)
    when AST::BindExpr          then lower_bind_expr(node)
    when AST::Assignment        then lower_assignment(node)

    # --- Control flow ---
    when AST::IfStatement       then lower_if(node)
    when AST::IfBind            then lower_if_bind(node)
    when AST::WhileLoop         then lower_while(node)
    when AST::WhileBindLoop     then lower_while_bind(node)
    when AST::ForEach           then lower_for_each(node)
    when AST::ForRange          then lower_for_range(node)
    when AST::MatchStatement    then lower_match(node)
    when AST::ReturnNode        then lower_return(node)
    when AST::BreakNode         then MIR::BreakStmt.new(nil, nil)
    when AST::ContinueNode      then MIR::ContinueStmt.new(nil)
    when AST::PassStmt          then MIR::Noop.new("pass")

    # --- Functions & calls ---
    when AST::FunctionDef       then lower_function_def(node)
    when AST::FuncCall          then lower_func_call(node)
    when AST::MethodCall        then lower_method_call(node)
    when AST::LambdaLit         then lower_lambda(node)

    # --- Collections ---
    when AST::ListLit           then lower_list_lit(node)
    when AST::HashLit           then lower_hash_lit(node)

    # --- Expressions ---
    when AST::Literal           then lower_literal(node)
    when AST::DefaultLit        then MIR::Lit.new(".{}")
    when AST::Identifier        then lower_identifier(node)
    when AST::BinaryOp          then lower_binary_op(node)
    when AST::UnaryOp           then lower_unary_op(node)
    when AST::GetField          then lower_get_field(node)
    when AST::GetIndex          then lower_get_index(node)
    when AST::StructLit         then lower_struct_lit(node)
    when AST::UnionVariantLit   then lower_union_variant_lit(node)
    when AST::StringConcat      then lower_string_concat(node)
    when AST::BlockExpr         then lower_block_expr(node)
    when AST::RangeLit          then lower_range_lit(node)
    when AST::OptionalUnwrap    then MIR::OptionalUnwrap.new(lower(node.target))
    when AST::Assert            then lower_assert(node)
    when AST::Raise             then lower_raise(node)
    when AST::Cast              then lower_cast(node)
    when AST::ThrowNode         then MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
    when AST::DieNode           then MIR::ExprStmt.new(MIR::Call.new("std.process.exit", [MIR::Lit.new((node.status || 1).to_s)], false), false)

    # --- Memory / capability expressions ---
    when AST::CopyNode          then lower_copy(node)
    when AST::CloneNode         then lower_clone(node)
    when AST::MoveNode          then lower_move(node)
    when AST::ShareNode         then lower_share(node)
    when AST::CapabilityWrap    then lower_cap_wrap(node)
    when AST::LinkNode          then lower_link(node)
    when AST::ResolveNode       then lower_resolve(node)
    when AST::FreezeNode        then lower_freeze(node)
    when AST::Copy              then lower(node.value) # Zig copies structs by value

    # --- Slice ---
    when AST::Slice             then lower_slice(node)

    # --- Concurrent / capability blocks ---
    when AST::BgBlock          then lower_bg_block(node)
    when AST::BgStreamBlock    then lower_bg_stream_block(node)
    when AST::WithBlock        then lower_with_block(node)
    when AST::DoBlock          then lower_do_block(node)
    when AST::TestBlock        then lower_test_block(node)
    when AST::RequireNode      then lower_require(node)
    when AST::YieldExpr        then lower_yield(node)
    when AST::NextExpr         then lower_next_expr(node)
    when AST::StaticCall       then lower_static_call(node)
    when AST::OrRaise          then MIR::Ident.new("error.OrRaise")
    when AST::OrBreak          then MIR::BreakStmt.new(nil, nil)
    when AST::OrPass           then MIR::Ident.new("undefined")
    when AST::OrPrune          then MIR::Ident.new("undefined")
    when AST::OrExit           then lower_or_exit(node)
    when AST::ThenChain        then raise "Internal: ThenChain should be flattened by BgBlock lowering"
    when AST::AssertRaises     then lower_assert_raises(node)
    when AST::StubDecl         then lower_stub_decl(node)
    when AST::BenchmarkStmt    then lower_benchmark(node)
    when AST::SmashStmt        then lower_smash(node)
    when AST::ProfileStmt      then lower_profile(node)

    else
      raise "MIRLowering: unhandled node type #{node.class} at #{node.token ? "line #{node.token.line}" : 'unknown'}"
    end.tap { |mir|
      # Apply type coercion (int->float, float->int, etc.) when AST node has coerced_type
      if mir && node.respond_to?(:coerced_type) && node.coerced_type &&
         node.typed? &&
         node.coerced_type != node.full_type
        # Skip coercion for stack-allocated fixed-size arrays (SROA)
        skip = node.is_a?(AST::ListLit) && node.storage == :stack &&
               (node.respond_to?(:coerced_type_info) ? node.coerced_type_info : node.full_type)&.fixed?
        unless skip
          cast_node = mir_cast(mir, node.full_type, node.coerced_type)
          return cast_node if cast_node
        end
      end
    }
  end

  # Lower a body (array of statements) into an array of MIR nodes.
  # Flushes @pending_stmts before each statement so hoisted Lets (from
  # hoist_alloc calls inside lower()) precede the statement that uses them.
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def lower_body(stmts)
    return [] unless stmts
    result = []
    stmts.each { |s|
      mir = lower(s)
      next unless mir
      # Non-void function-like expressions used as statements need explicit discard (_ =)
      needs_discard = (AST.call?(s)) ||
                      (s.is_a?(AST::BinaryOp) && (s.op == :OR_RESCUE || s.op == :PIPE_ERR))
      hoisted_discard = false
      if needs_discard &&
         s.respond_to?(:resolved_type) && s.resolved_type && s.resolved_type != :Void &&
        mir_allocates?(mir) && !mutating_receiver_allocator_op?(mir)
        entry = hoist_cleanup_entry(mir, s)
        if entry
          @tmp_counter += 1
          discard_name = "__discard_#{@tmp_counter}"
          alloc = entry.alloc || mir_owned_alloc(mir) || :heap
          mark = MIR::AllocMark.new(discard_name, alloc, Type.from_node(s))
          mark.scope = alloc == :heap ? :heap : :iteration
          stamp_allocating_result_target!(mir, discard_name, alloc: alloc)
          mir = MIR::ScopeBlock.new([
            mark,
            MIR::Let.new(discard_name, mir, true, discard_owned_zig_type(s, entry), "_ = &#{discard_name};"),
            MIR::Cleanup.new(discard_name, entry),
          ])
          hoisted_discard = true
        end
      end
      pending = flush_pending
      if needs_discard &&
         s.respond_to?(:resolved_type) && s.resolved_type && s.resolved_type != :Void &&
         !hoisted_discard
        mir = MIR::ExprStmt.new(mir, true)
      end
      pending.compact.each do |p|
        result << p
        register_visible_alloc_names!(p)
        visible_alloc_names = visible_alloc_names_for_transfer(result, p)
        visible_guarded_names = visible_guarded_cleanup_names_for_transfer(result, p)
        ownership_transfers_for_mir(p, visible_alloc_names, visible_guarded_names).each do |mark|
          result << mark
        end
      end
      if s.is_a?(AST::MoveNode)
        ownership_marks_for_transferred_temp(mir).each { |mark| result << mark }
        next
      end
      mir_nodes = normalize_allocating_mir_body(mir.is_a?(Array) ? mir.compact : [mir])
      mir_nodes.each { |m| finalize_nested_mir_bodies!(m) }

      # Inject source map comment for this user-visible statement.
      # Placed after pending (hoisted synthetic temps have no user source line).
      line = s.token&.line
      col  = s.token&.column
      result << MIR::Comment.new("CLR:#{line}") if line
      mir_nodes.each do |m|
        stamp_source_line!(m, line, col)
        pre_terminator_transfer_marks(m, result, mir_nodes).each do |mark|
          stamp_source_line!(mark, line, col)
          result << mark
        end
        result << m
      end
      register_visible_alloc_names!(mir_nodes)
      visible_alloc_names = visible_alloc_names_for_transfer(result, mir_nodes)
      visible_guarded_names = visible_guarded_cleanup_names_for_transfer(result, mir_nodes)
      (ownership_transfers_for_stmt(s, visible_alloc_names, visible_guarded_names) + ownership_transfers_for_mir(mir_nodes, visible_alloc_names, visible_guarded_names)).uniq { |m| [m.class, m.name, m.respond_to?(:target) ? m.target : nil] }.each do |m|
        stamp_source_line!(m, line, col)
        result << m
      end
    }
    result
  end

  sig { params(result: T::Array[T.untyped], mir: T.untyped).returns(T::Set[String]) }
  def visible_alloc_names_for_transfer(result, mir)
    names = T.let(T.must(@lowered_alloc_names).dup, T::Set[String])
    walk_mir_node(result) { |node| names << node.name.to_s if node.is_a?(MIR::AllocMark) }
    walk_mir_node(mir) { |node| names << node.name.to_s if node.is_a?(MIR::AllocMark) }
    names
  end

  sig { params(root: T.untyped).void }
  def register_visible_alloc_names!(root)
    lowered_alloc_names = T.must(@lowered_alloc_names)
    lowered_guarded_cleanup_names = T.must(@lowered_guarded_cleanup_names)
    walk_mir_node(root) do |node|
      lowered_alloc_names << node.name.to_s if node.is_a?(MIR::AllocMark)
      next unless node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)

      entry = node.cleanup_entry
      guarded = entry.respond_to?(:has_moved_guard?) ? entry.has_moved_guard? : !!(entry.respond_to?(:[]) && entry[:has_moved_guard])
      lowered_guarded_cleanup_names << node.name.to_s if guarded
    end
    nil
  end

  sig { params(result: T::Array[T.untyped], mir: T.untyped).returns(T::Set[String]) }
  def visible_guarded_cleanup_names_for_transfer(result, mir)
    names = T.let(T.must(@lowered_guarded_cleanup_names).dup, T::Set[String])
    [result, mir].each do |root|
      walk_mir_node(root) do |node|
        next unless node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
        entry = node.cleanup_entry
        guarded = entry.respond_to?(:has_moved_guard?) ? entry.has_moved_guard? : !!(entry.respond_to?(:[]) && entry[:has_moved_guard])
        names << node.name.to_s if guarded
      end
    end
    names
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def append_ownership_transfers_for_mir_body(body)
    body = normalize_allocating_mir_body(body)
    out = T.let([], T::Array[T.untyped])
    body.each do |node|
      finalize_nested_mir_bodies!(node)
      alloc_mark = implicit_alloc_mark_for_mir_node(node, out)
      if alloc_mark
        out << alloc_mark
        register_visible_alloc_names!(alloc_mark)
      end
      visible_alloc_names = visible_alloc_names_for_transfer(out, node)
      visible_guarded_names = visible_guarded_cleanup_names_for_transfer(out, node)
      if node.is_a?(MIR::BreakStmt) && node.value
        mir_ident_names(node.value).each do |name|
          next unless visible_alloc_names.include?(name.to_s)
          next if transfer_mark_present?(out, name.to_s) || transfer_mark_present?(body, name.to_s)
          out << MIR::TransferMark.new(name.to_s, :block_result)
        end
      end
      pre_terminator_transfer_marks(node, out, body).each do |mark|
        out << mark
      end
      out << node
      register_visible_alloc_names!(node)
      ownership_transfers_for_mir(node, visible_alloc_names, visible_guarded_names, out + body).each do |mark|
        out << mark
      end
    end
    out
  end

  sig { params(nodes: T::Array[T.untyped], name: String).returns(T::Boolean) }
  def transfer_mark_present?(nodes, name)
    nodes.any? { |node| node.is_a?(MIR::TransferMark) && node.name.to_s == name.to_s }
  end

  sig { params(node: MIR::Node, emitted: T::Array[T.untyped], remaining: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def pre_terminator_transfer_marks(node, emitted, remaining)
    return [] unless (node.is_a?(MIR::ReturnStmt) || node.is_a?(MIR::BreakStmt)) && node.value

    visible_alloc_names = visible_alloc_names_for_transfer(emitted, node)
    visible_guarded_names = visible_guarded_cleanup_names_for_transfer(emitted, node)
    consumed = T.let(collect_mir_consumed_roots(node.value), T::Array[String])
    if node.is_a?(MIR::ReturnStmt)
      mir_ident_names(node.value).each { |name| consumed << name.to_s }
    end
    consumed.uniq.filter_map do |name|
      safe = name.to_s
      next unless visible_alloc_names.include?(safe)
      next if transfer_mark_present?(emitted, safe) || transfer_mark_present?(remaining, safe)

      target = node.is_a?(MIR::ReturnStmt) && mir_ident_names(node.value).map(&:to_s).include?(safe) ? :return : :owned_sink
      ownership_transfer_plan(safe, target, visible_guarded_names).marks
    end.flatten
  end

  sig { params(node: MIR::Node).void }
  def finalize_nested_mir_bodies!(node)
    case node
    when MIR::Let
      finalize_nested_mir_expr_bodies!(node.init)
    when MIR::Set
      finalize_nested_mir_expr_bodies!(node.target)
      finalize_nested_mir_expr_bodies!(node.value)
    when MIR::ReassignWithCleanup
      finalize_nested_mir_expr_bodies!(node.value)
    when MIR::ExprStmt
      finalize_nested_mir_expr_bodies!(node.expr)
    when MIR::ReturnStmt, MIR::BreakStmt
      finalize_nested_mir_expr_bodies!(node.value)
    when MIR::WhileStmt, MIR::ForStmt
      node.body = append_ownership_transfers_for_mir_body(node.body ? node.body : [])
    when MIR::ScopeBlock, MIR::BlockExpr
      node.body = append_ownership_transfers_for_mir_body(node.body ? node.body : [])
    when MIR::IfStmt, MIR::IfBindStmt
      node.then_body = append_ownership_transfers_for_mir_body(node.then_body ? node.then_body : [])
      node.else_body = append_ownership_transfers_for_mir_body(node.else_body ? node.else_body : []) if node.else_body
    when MIR::IfChain
      node.branches&.each do |branch|
        branch[:body] = append_ownership_transfers_for_mir_body(branch[:body] ? branch[:body] : [])
      end
      node.default_body = append_ownership_transfers_for_mir_body(node.default_body ? node.default_body : []) if node.default_body
    when MIR::SwitchStmt
      node.arms&.each do |arm|
        arm[:body] = append_ownership_transfers_for_mir_body(arm[:body] ? arm[:body] : [])
      end
      node.default_body = append_ownership_transfers_for_mir_body(node.default_body ? node.default_body : []) if node.default_body
    end
    nil
  end

  sig { params(expr: T.nilable(MIR::Node)).void }
  def finalize_nested_mir_expr_bodies!(expr)
    return unless expr
    return unless expr.expr?
    if expr.is_a?(MIR::BlockExpr)
      expr.body = append_ownership_transfers_for_mir_body(expr.body ? expr.body : [])
      return
    end
    each_mir_expr_child(expr) { |child| finalize_nested_mir_expr_bodies!(child) }
    nil
  end

  sig { params(node: MIR::Node, out: T::Array[T.untyped]).returns(T.nilable(MIR::AllocMark)) }
  def implicit_alloc_mark_for_mir_node(node, out)
    fact = implicit_allocating_result_fact(node, out)
    fact&.alloc_mark
  end

  sig { params(node: MIR::Node, out: T::Array[T.untyped]).returns(T.nilable(AllocatingResultFact)) }
  def implicit_allocating_result_fact(node, out)
    return nil unless node.is_a?(MIR::Let)
    init = node.init
    return nil unless mir_allocates?(init)
    return nil if mutating_receiver_allocator_op?(init)

    name = node.name.to_s
    existing_mark = T.let(nil, T.nilable(MIR::AllocMark))
    walk_mir_node(out) do |child|
      existing_mark = child if child.is_a?(MIR::AllocMark) && child.name.to_s == name
    end
    if existing_mark
      stamp_allocating_result_target!(init, name, alloc: existing_mark.alloc)
      return nil
    end

    effect = init.respond_to?(:ownership_effect) ? init.ownership_effect : MIR::OwnershipEffect.none
    alloc = effect.alloc || mir_owned_alloc(init) || :heap
    stamp_allocating_result_target!(init, name, alloc: alloc)
    AllocatingResultFact.new(
      name: name,
      ownership_effect: effect.produces_owned ? effect.with_target(name) : MIR::OwnershipEffect.owned(alloc: alloc, target_var: name),
      type_info: Type.new(:Untyped),
      scope: alloc == :heap ? :heap : :iteration,
    )
  end

  sig { params(stmt: T.untyped, visible_alloc_names: T::Set[String], visible_guarded_names: T::Set[String]).returns(T::Array[T.untyped]) }
  def ownership_transfers_for_stmt(stmt, visible_alloc_names, visible_guarded_names)
    return [] if stmt.is_a?(AST::ReturnNode)
    return [] if stmt.is_a?(AST::WhileLoop) || stmt.is_a?(AST::WhileBindLoop) ||
                 stmt.is_a?(AST::ForRange) || stmt.is_a?(AST::ForEach) ||
                 stmt.is_a?(AST::IfStatement) || stmt.is_a?(AST::MatchStatement) ||
                 stmt.is_a?(AST::WithBlock) || stmt.is_a?(AST::DoBlock)
    marks = T.let([], T::Array[T.untyped])
    collect_bg_capture_transfer_roots(stmt).uniq.each do |name|
      safe = zig_safe_name(name)
      safe = @fn_name_rename_map[safe] if @fn_name_rename_map&.key?(safe)
      next unless visible_alloc_names.include?(safe.to_s)
      entry = @current_bindings[name] || CleanupEntry::NONE
      next unless entry.present?
      marks.concat(ownership_transfer_plan(safe.to_s, :owned_sink, visible_guarded_names).marks)
    end
    marks
  end

  sig { params(mir: T.untyped, visible_alloc_names: T::Set[String], visible_guarded_names: T::Set[String], existing: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def ownership_transfers_for_mir(mir, visible_alloc_names, visible_guarded_names, existing = [])
    return [] if mir.is_a?(MIR::BreakStmt) || mir.is_a?(MIR::ReturnStmt)

    names = T.let([], T::Array[String])
    nodes = mir.is_a?(Array) ? mir : [mir]
    nodes.compact.each do |node|
      collect_mir_consumed_roots(node).each { |name| names << name.to_s }
    end
    marks = T.let([], T::Array[T.untyped])
    names.uniq.each do |name|
      next unless visible_alloc_names.include?(name.to_s)
      next if transfer_mark_present?(existing + marks, name.to_s)
      marks.concat(ownership_transfer_plan(name.to_s, :owned_sink, visible_guarded_names).marks)
    end
    marks
  end

  sig { params(name: String, target: Symbol, visible_guarded_names: T::Set[String]).returns(OwnershipTransferPlan) }
  def ownership_transfer_plan(name, target, visible_guarded_names)
    OwnershipTransferPlan.new(
      name: name,
      target: target,
      move_guarded: visible_guarded_names.include?(name),
    )
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def collect_mir_consumed_roots(node)
    names = T.let([], T::Array[String])
    if node.is_a?(MIR::Pipeline)
      collect_mir_consumed_roots(node.inner).each { |name| names << name.to_s }
      return names.uniq
    end
    walk_mir_node(node) do |child|
      ownership_contract_consumes(child).each { |name| names << name.to_s }
      structural_ownership_consumes(child).each { |name| names << name.to_s }
    end
    names.uniq
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: MIR::Node).void).void }
  def walk_mir_node(node, &blk)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |child| walk_mir_node(child, &blk) }
      return
    end
    if node.is_a?(Hash)
      node.each_value { |child| walk_mir_node(child, &blk) }
      return
    end
    return unless node.respond_to?(:mir?) && node.mir?

    yield node
    return if node.is_a?(MIR::BlockExpr) || node.is_a?(MIR::Pipeline) ||
              node.is_a?(MIR::WhileStmt) || node.is_a?(MIR::ForStmt) ||
              node.is_a?(MIR::IfStmt) || node.is_a?(MIR::IfBindStmt) ||
              node.is_a?(MIR::IfChain) || node.is_a?(MIR::SwitchStmt) ||
              node.is_a?(MIR::ScopeBlock) || node.is_a?(MIR::FnDef)
    return unless node.class.respond_to?(:members)
    node.class.members.each do |member|
      value = node[member]
      if value.is_a?(Array)
        value.each { |child| walk_mir_node(child, &blk) }
      elsif value.is_a?(Hash)
        value.each_value { |child| walk_mir_node(child, &blk) }
      else
        walk_mir_node(value, &blk) if value.respond_to?(:mir?)
      end
    end
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def ownership_contract_consumes(node)
    contract = case node
    when MIR::InlineZig, MIR::RawZig
      node.ownership_contract
    when MIR::Call, MIR::TailCall, MIR::MethodCall
      node.callable_contract&.ownership_contract
    else
      nil
    end
    return [] unless contract
    contract.consumes.map(&:to_s)
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def structural_ownership_consumes(node)
    case node
    when MIR::Let
      return [] if node.init.is_a?(MIR::BlockExpr)
      mir_ident_names(node.init)
    when MIR::Set
      mir_ident_names(node.value)
    when MIR::ReassignWithCleanup
      mir_ident_names(node.value)
    when MIR::ShardedMapPut
      return [] unless node.stdlib_def&.takes_ownership?
      mir_ident_names(node.value)
    when MIR::StructInit
      node.fields.flat_map { |field| mir_ident_names(field[:value]) }
    else
      []
    end
  end

  sig { params(stmt: T.untyped).returns(T::Array[String]) }
  def collect_bg_capture_transfer_roots(stmt)
    names = T.let([], T::Array[String])
    AST.each_bg_block_in_stmt(stmt) do |bg|
      (bg.capture_analysis&.move_mark_names || Set.new).each do |name|
        entry = @current_bindings[name.to_s] || CleanupEntry::NONE
        names << name.to_s if entry.present?
      end
    end
    names.uniq
  end

  sig { params(stmt: T.untyped).returns(T::Array[String]) }
  def collect_stdlib_consumed_roots(stmt)
    names = T.let([], T::Array[String])
    walk_ast_calls(stmt) do |call|
      stdlib_call_ownership_facts(call).consumed_names.each { |name| names << name }
    end
    names.uniq
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: AST::Node).void).void }
  def walk_ast_calls(node, &blk)
    return unless node.is_a?(AST::Locatable)
    yield node if AST.call?(node)
    AST.each_child_node(node) { |child| walk_ast_calls(child, &blk) }
  end

  sig { params(stmt: T.untyped).returns(T::Array[String]) }
  def collect_moved_arg_roots(stmt)
    names = T.let([], T::Array[String])
    if (stmt.is_a?(AST::VarDecl) || (stmt.is_a?(AST::BindExpr) && stmt.mode == :decl)) &&
       stmt.respond_to?(:value) && stmt.value.is_a?(AST::Identifier)
      ti = Type.from_node!(stmt.value, context: "moved declaration root")
      entry = @current_bindings[stmt.value.name.to_s] || CleanupEntry::NONE
      names << stmt.value.name.to_s if ownership_tracked_transfer_type?(ti) && entry.present?
    end
    walk_ast_for_moved_args(stmt) do |arg|
      next if arg_is_call_argument?(stmt, arg)
      ti = Type.from_node!(arg, context: "moved argument root")
      next unless ownership_tracked_transfer_type?(ti)
      root = moved_arg_root(arg)
      next unless root
      ident = AST.root_identifier(arg) rescue nil
      entry = @current_bindings[root] || CleanupEntry::NONE
      next unless ident&.symbol&.heap_storage? || (entry.present? && entry.alloc == :heap)
      names << root if root
    end
    names.uniq
  end

  sig { params(stmt: T.untyped, arg: T.untyped).returns(T::Boolean) }
  def arg_is_call_argument?(stmt, arg)
    return false unless AST.call?(stmt) && stmt.respond_to?(:args)
    T.unsafe(stmt).args.include?(arg)
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def ownership_tracked_transfer_type?(ti)
    return false if ti.primitive? || ti.void? || ti.any? || ti.id_handle?
    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(@schema_lookup)
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: AST::Node).void).void }
  def walk_ast_for_moved_args(node, &blk)
    return unless node.is_a?(AST::Locatable)
    yield node if node.is_a?(AST::Identifier) && node.respond_to?(:was_moved) && node.was_moved == true
    return if nested_ownership_scope?(node)

    AST.each_child_node(node) { |child| walk_ast_for_moved_args(child, &blk) }
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def nested_ownership_scope?(node)
    case node
    when AST::WithBlock, AST::DoBlock, AST::BgBlock, AST::BgStreamBlock,
         AST::FunctionDef, AST::LambdaLit
      true
    else
      false
    end
  end

  sig { params(arg: T.untyped).returns(T.nilable(String)) }
  def moved_arg_root(arg)
    node = arg
    node = node.value if node.is_a?(AST::MoveNode)
    return node.name.to_s if node.is_a?(AST::Identifier)
    nil
  end

  sig { params(name: String).returns(String) }
  def transfer_binding_name(name)
    safe = zig_safe_name(name)
    @fn_name_rename_map&.key?(safe) ? @fn_name_rename_map.fetch(safe) : safe
  end

  sig { params(call: T.untyped).returns(MIRLoweringFunctions::CallOwnershipFacts) }
  def stdlib_call_ownership_facts(call)
    stdlib_call_facts(call).ownership
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def ownership_bearing_type?(type_info)
    ti = type_info
    ti = ti.payload_type if ti.respond_to?(:error_union?) && ti.error_union?
    return false unless ti
    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(@schema_lookup)
  end

  sig { params(arg: T.untyped).returns(T.nilable(String)) }
  def consumed_binding_root(arg)
    return nil if arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode)
    node = arg.is_a?(AST::MoveNode) ? arg.value : arg
    return node.name.to_s if node.is_a?(AST::Identifier)
    root = AST.root_identifier(node) rescue nil
    root&.name&.to_s
  end

  sig { params(node: T.untyped, entry: CleanupEntry).returns(String) }
  def discard_owned_zig_type(node, entry)
    return entry[:zig_type] if entry[:zig_type]
    ti = Type.from_node!(node, context: "discard owned type")
    ti = ti.payload_type || ti if ti.error_union?
    return "[]const u8" if ti.string?
    ti.zig_type || Type.new(ti.resolved).zig_type
  end

  # Stamps `MIR::Stmt#source_line` (and `source_column`) from the
  # originating AST node's token. Used by the register VM emitter for
  # per-statement crash-message attribution and per-instruction
  # debugger position lookup. Lifting this from the per-stmt comment
  # injection in lower_body keeps it as the single source of truth so
  # cleanup defers, hoist temps, and other synthesized statements all
  # inherit their parent statement's position. No-op when `line` is
  # nil (synthesized fragments may have no AST origin).
  sig { params(node: T.untyped, line: T.nilable(Integer), column: T.nilable(Integer)).void }
  def stamp_source_line!(node, line, column = nil)
    return unless line
    return unless node.respond_to?(:source_line=)
    node.source_line ||= line
    node.source_column ||= column if node.respond_to?(:source_column=) && column
  end

  # Like lower_body, but the last user-visible statement becomes break :label expr
  # instead of a regular statement. Used for IF/MATCH expression branches.
  sig { params(stmts: T::Array[T.untyped], label: String).returns(T::Array[T.untyped]) }
  def lower_body_with_break(stmts, label)
    return [] unless stmts && !stmts.empty?

    # Find the last non-old-MIR-verification node (the result expression)
    last_user_idx = stmts.rindex { |s|
      !s.is_a?(MIR::Drop) && !s.is_a?(MIR::Alloc) &&
      !s.is_a?(MIR::Return) && !s.is_a?(MIR::SuppressCleanup) &&
      !s.is_a?(MIR::ReassignCleanup) && !s.is_a?(MIR::FieldCleanup)
    }
    return T.must(lower_body(stmts)) unless last_user_idx

    prefix_lowered = lower_body(stmts[0...last_user_idx])
    result_mir = lower(stmts[last_user_idx])
    pending = flush_pending
    suffix_lowered = T.must(stmts[(last_user_idx + 1)..]).empty? ? [] : lower_body(stmts[(last_user_idx + 1)..])

    tail = pending + T.must(suffix_lowered) + [MIR::BreakStmt.new(label, result_mir)]
    T.must(prefix_lowered) + normalize_allocating_mir_body(tail)
  end

  # Lower a full program into MIR::Program with standard imports + footer.
  sig { params(node: AST::Program, use_c_allocator: T::Boolean, needs_safety: T::Boolean, use_debug_allocator: T::Boolean).returns(T.nilable(MIR::Program)) }
  def lower_program(node, use_c_allocator: false, needs_safety: false, use_debug_allocator: false)
    MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering")
    @use_debug_allocator = T.let(use_debug_allocator, T.nilable(T::Boolean))
    items = []

    # Auto-detect needs_safety from @nonReentrant functions
    needs_safety ||= node.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.reentrant == :non_reentrant }

    # Standard imports
    items << MIR::Import.new("std", "std", nil)
    items << MIR::Import.new("CheatHeader", "runtime/runtime-header.zig", nil)
    items << MIR::TypeAlias.new("CheatLib", "CheatHeader.CheatLib")
    items << MIR::TypeAlias.new("Runtime", "CheatHeader.Runtime")
    items << MIR::TypeAlias.new("EbrContext", "CheatHeader.EbrContext")
    items << MIR::Import.new("safety", "runtime/../lib/safety.zig", nil) if needs_safety

    if use_c_allocator || @used_sharded_map
      items << MIR::PubConst.new("USE_C_ALLOCATOR", "true")
    end
    if @use_debug_allocator
      items << MIR::PubConst.new("USE_DEBUG_ALLOCATOR", "true")
    end

    # Lower each statement, adding source line comments
    node.statements.each do |stmt|
      lowered = lower(stmt)
      next unless lowered
      line = stmt.token&.line
      # Some lowerings (e.g. union with helpers) return arrays of nodes
      nodes = lowered.is_a?(::Array) ? lowered : [lowered]
      nodes.each_with_index do |n, i|
        items << MIR::Comment.new("CLR:#{line}") if i == 0
        items << n
      end
    end

    state = MIRPassState.for!(node).copy
    state.mark!(:mir_lowered)
    MIR::Program.new(items, state)
  end

  # Lower a module AST into MIR items for inlining via REQUIRE.
  # Emits only public declarations (types + functions + re-exports).
  # No standard imports or runtime footer -- the importing file provides those.
  #
  # Returns { items: [MIR nodes], type_items: [MIR type nodes] }
  sig { params(node: AST::Program).returns(T::Hash[Symbol, T::Array[T.untyped]]) }
  def lower_module(node)
    MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering.lower_module")
    type_items = []
    fn_items = []

    node.statements.each do |stmt|
      case stmt
      when AST::FunctionDef
        next if stmt.visibility == :private
        lowered = lower(stmt)
        next unless lowered
        line = stmt.token.line
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          fn_items << MIR::Comment.new("CLR:#{line}") if i == 0
          fn_items << n
        end
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        next if stmt.visibility == :private
        lowered = lower(stmt)
        next unless lowered
        line = stmt.token.line
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          type_items << MIR::Comment.new("CLR:#{line}") if i == 0
          type_items << n
        end
      when AST::RequireNode
        lowered = lower(stmt)
        next unless lowered
        (lowered.is_a?(::Array) ? lowered : [lowered]).each { |n| fn_items << n }
      when AST::ExternFnDecl, AST::ExternStructDecl
        lowered = lower(stmt)
        next unless lowered
        line = stmt.token.line
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          fn_items << MIR::Comment.new("CLR:#{line}") if i == 0
          fn_items << n
        end
      end
    end

    { items: fn_items, type_items: type_items }
  end

  private

  # ================================================================
  # Name and type helpers
  # ================================================================

  sig { params(name: String).returns(T.nilable(String)) }
  def zig_safe_name(name)
    cleaned = (name.end_with?('!') || name.end_with?('?')) ? name[0..-2] : name
    cleaned = "clearMain" if cleaned == "main"
    cleaned =~ ZIG_PRIMITIVE_RE ? "@\"#{cleaned}\"" : cleaned
  end

  sig { params(node: T.untyped).returns(Symbol) }
  def alloc_for_node(node)
    placement_for_node(node)
  end

  sig { params(alloc: T.nilable(Symbol), blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_decl_alloc(alloc, &blk)
    prev = @current_decl_alloc
    @current_decl_alloc = alloc
    blk.call
  ensure
    @current_decl_alloc = prev
  end

  sig { params(callee_param: T.untyped).returns(Symbol) }
  def allocator_for_takes_param!(callee_param)
    Kernel.raise "TAKES argument allocator requested without a callee parameter" unless callee_param
    :heap
  end

  sig { params(arg: T.untyped, callee_param: T.untyped).returns(T::Boolean) }
  def call_arg_consumes_ownership?(arg, callee_param)
    !!(callee_param && callee_param.respond_to?(:takes) && callee_param.takes)
  end

  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  def symbol_storage_for_node(node)
    return nil unless node
    sym = node.respond_to?(:symbol) ? node.symbol : nil
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    auth = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
    storage = auth.storage
    auth.heap_storage? ? :heap : :frame
  end

  sig { params(node: T.untyped).returns(Symbol) }
  def placement_for_node(node)
    node = node.value if node.is_a?(AST::MoveNode)
    root = root_receiver_node(node) || node
    if root.is_a?(AST::Identifier)
      alias_alloc = @with_alias_alloc_map&.[](root.name.to_s)
      return alias_alloc if alias_alloc
      return :heap if @current_fn_collection_params&.include?(root.name)
      entry = @current_bindings[root.name.to_s] if @current_bindings
      return entry.alloc if entry&.alloc
    end
    if root.is_a?(AST::Identifier)
      sym = root.symbol
      lifetime_sources = sym&.lifetime_sources || []
      if !lifetime_sources.empty?
        return :heap if lifetime_sources.any?(&:heap_storage?)
        return :frame
      end
    end
    symbol_storage_for_node(root) || @current_decl_alloc || :frame
  end


  sig { params(kind: Symbol, _rt_name: T.untyped).returns(Symbol) }
  def alloc_expr(kind, _rt_name = nil)
    MIR::Placement.alloc(kind, :frame)
  end

  sig { params(sym: Symbol).returns(Symbol) }
  def alloc_from_sym(sym)
    MIR::Placement.alloc(sym, :heap)
  end

  # Resolve a registry alloc symbol (:heap, :frame, :receiver_storage, :node_storage)
  # to a concrete :heap/:frame symbol. Used by InlineZig allocs field.
  sig { params(alloc_sym: Symbol, target_node: T.untyped, node: T.untyped).returns(Symbol) }
  def resolve_alloc_sym(alloc_sym, target_node = nil, node = nil)
    case alloc_sym
    when :heap  then :heap
    when :frame then :frame
    when :receiver_storage
      receiver = target_node
      receiver ||= node.object if node.is_a?(AST::MethodCall)
      receiver ||= node.args&.first if node.respond_to?(:mutates_receiver) && node.mutates_receiver
      root = root_receiver_node(receiver)
      placement_for_node(root || receiver || node)
    when :node_storage
      @current_decl_alloc || placement_for_node(target_node || node)
    else :heap
    end
  end

  # Shared root resolution for checker attribution and receiver allocator lookup.
  sig { params(node: T.untyped).returns(T.untyped) }
  def root_receiver_node(node)
    root = AST.root_identifier(node)
    return root if root
    node.respond_to?(:target) ? root_receiver_node(node.target) : nil
  end

  # Extract root variable name from a potentially nested AST node (e.g., pool[id]?.vars).
  sig { params(node: T.untyped).returns(T.nilable(String)) }
  def extract_root_var_name(node)
    root = root_receiver_node(node)
    return nil unless root.is_a?(AST::Identifier)
    decl = root.symbol&.reg
    (@decl_zig_name_map && decl && @decl_zig_name_map[decl.object_id]) || root.name.to_s
  end

  # Resolve allocator symbol to Zig string (for InlineZig/RawZig patterns only).
  sig { params(kind: Symbol).returns(String) }
  def alloc_zig_str(kind)
    MIR::Placement.zig_allocator(kind, @rt_name)
  end

  # Produce a MIR::Cast node for type coercion, or nil if no cast needed.
  # Mirrors transpile_cast logic but returns MIR nodes instead of strings.
  sig { params(mir_node: T.untyped, from_type: Type, to_type: T.untyped).returns(T.nilable(MIR::Cast)) }
  def mir_cast(mir_node, from_type, to_type)
    from = from_type.respond_to?(:resolved) ? from_type.resolved : from_type
    to   = to_type.respond_to?(:resolved) ? to_type.resolved : to_type
    return nil if from == to

    from_t = from_type.is_a?(Type) ? from_type : Type.new(from)
    to_t   = to_type.is_a?(Type)   ? to_type   : Type.new(to)

    zig_to = transpile_type(to)

    # fn_type: generic @as cast
    return MIR::Cast.new(mir_node, zig_to, :as) if from_t.fn_type? || to_t.fn_type?

    # Int -> Float
    if from_t.integer? && to_t.float?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :floatFromInt), zig_to, :as)
    end

    # Float -> Int
    if from_t.float? && to_t.integer?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :intFromFloat), zig_to, :as)
    end

    # Int -> Int
    if from_t.integer? && to_t.integer?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :intCast), zig_to, :as)
    end

    # Float -> Float
    if from_t.float? && to_t.float?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :floatCast), zig_to, :as)
    end

    # Array coercions, HashMap coercions, error union coercions -- no cast needed
    from_str = from.to_s
    to_str = to.to_s
    return nil if from_str.end_with?("[]") && to_str.end_with?("[]")
    return nil if from_str =~ /\[\d+\]$/ && to_str == "Any[]"
    # Fixed-size array (`T[N]`) -> typed slice (`T[]`): no cast needed.
    # The downstream argument-position `MIR::ItemsAccess` handles the
    # slice coercion via `<expr>[0..]`. Without this skip, the
    # `mir_cast` fallback below wraps the identifier with
    # `@as(std.ArrayListUnmanaged(T), <fixed>)`, which Zig rejects
    # because a `[N]T` does not coerce to an ArrayList.
    if from_str =~ /\A(.+)\[\d+\]\z/
      from_elem = Regexp.last_match(1)
      return nil if to_str == "#{from_elem}[]"
    end
    return nil if from_str.start_with?("HashMap<") && to_str.start_with?("HashMap<")
    if to_str.start_with?("!")
      payload_type = to_str[1..]
      from_matches = from_str == payload_type || from == to.to_s[1..].to_sym
      from_matches ||= from_str.start_with?("Byte[") && payload_type == "String"
      return nil if from_matches
    end

    # Fallback: @as cast
    MIR::Cast.new(mir_node, zig_to, :as)
  end

  # ================================================================
  # Cleanup entry helpers (moved from MIRPass/control_flow.rb)
  # ================================================================

  # No-op: cleanup emit now uses @TypeOf(name) at the call site, so the
  # entry needs no precomputed zig_type / elem_zig_type. Kept as a hook
  # in case future per-kind metadata needs to be stamped at lowering time.
  sig { params(entry: CleanupEntry, ti: Type, source_node: T.nilable(AST::VarDecl)).returns(T.nilable(T::Boolean)) }
  def build_drop_entry!(entry, ti, source_node)
    nil
  end

  # ================================================================
  # Old MIR translation (MATCH AS bindings still use Drop/Alloc)
  # ================================================================

  sig { params(node: MIR::Drop).returns(MIR::Cleanup) }
  def lower_drop(node)
    safe = zig_safe_name(node.name)
    entry = node.cleanup_entry
    has_guard = entry.respond_to?(:has_moved_guard?) ? entry.has_moved_guard? : !!(entry.respond_to?(:[]) && entry[:has_moved_guard])
    (@guarded_cleanup_names ||= {})[safe] = true if has_guard
    MIR::Cleanup.new(safe, node.cleanup_entry)
  end

  # ================================================================
  # Type definitions
  # ================================================================

  sig { params(node: AST::EnumDef).returns(MIR::EnumDef) }
  def lower_enum_def(node)
    @enum_schemas[node.name.to_sym] = node.variants
    MIR::EnumDef.new(node.name, node.variants.map(&:to_s), nil)
  end

  sig { params(node: T.untyped).returns(MIR::Lit) }
  def lower_field_default(node)
    case node
    when AST::DefaultLit then MIR::Lit.new(".{}")
    else lower(node)
    end
  end

  sig { params(node: AST::StructDef).returns(T.untyped) }
  def lower_struct_def(node)
    @struct_schemas[node.name.to_sym] = Schemas::StructSchema.new(fields: node.field_decls)

    if node.type_params&.any?
      # Generic struct: fn Name(comptime T: type) type { return struct { ... }; }
      comptime_params = node.type_params.map { |p| "comptime #{p}: type" }
      fields_mir = node.field_decls.map { |name, fd|
        zig_t = transpile_type(fd.type, is_field: true)
        default_mir = fd.default ? lower_field_default(fd.default) : nil
        MIR::FieldDef.new(name.to_s, zig_t, default_mir)
      }
      inner_struct = MIR::StructDef.new(nil, fields_mir, nil, nil)
      body = [MIR::ReturnStmt.new(inner_struct)]
      MIR::FnDef.new(node.name, [], "type", body, nil, false, comptime_params)
    else
      fields = node.field_decls.map { |name, fd|
        zig_t = transpile_type(fd.type, is_field: true)
        default_mir = fd.default ? lower_field_default(fd.default) : nil
        MIR::FieldDef.new(name.to_s, zig_t, default_mir)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  sig { params(node: AST::UnionDef).returns(T.untyped) }
  def lower_union_def(node)
    @union_schemas[node.name.to_sym] = Schemas::UnionSchema.new(variants: node.variants)

    # Emit helper structs for inline struct variants
    helper_structs = node.variants.filter_map do |var_name, var_data|
      next unless Schemas.inline_struct?(var_data)
      fields = var_data.fields.map { |fname, ftype|
        zig_t = transpile_type(ftype, is_field: true)
        MIR::FieldDef.new(fname.to_s, zig_t, nil)
      }

      alloc_ref = MIR::Ident.new("alloc")
      self_ref  = MIR::Ident.new("self")
      deinit_stmts = (var_data.deinit_entries || []).flat_map { |de|
        self_field = MIR::FieldGet.new(self_ref, de[:field])
        case de[:kind]
        when :indirect
          [
            MIR::ExprStmt.new(
              emit_builtin(:cleanup, [MIR::Ident.new(de[:zig_type]), alloc_ref, self_field]),
              false
            ),
            MIR::ExprStmt.new(MIR::DestroyPtr.new(self_field, alloc_ref), false),
          ]
        when :array
          elem_zig = MIR::Ident.new(de[:elem_zig_type])
          loop_body = [
            MIR::ExprStmt.new(
              emit_builtin(:cleanup, [elem_zig, alloc_ref, MIR::Ident.new("__e")]),
              false
            ),
          ]
          for_loop = MIR::ForStmt.new(self_field, "*__e", loop_body, nil, false, false)
          cleanup_guard = MIR::IfStmt.new(
            MIR::Comptime.new(emit_builtin(:needsCleanup, [elem_zig])),
            [for_loop],
            nil
          )
          len_guard = MIR::IfStmt.new(
            MIR::BinOp.new(">", MIR::ListLength.new(self_field), MIR::Lit.new("0")),
            [MIR::ExprStmt.new(MIR::FreeSlice.new(self_field, alloc_ref), false)],
            nil
          )
          [cleanup_guard, len_guard]
        else []
        end
      }

      methods = if deinit_stmts.any?
        deinit_fn = MIR::FnDef.new(
          "deinit",
          [MIR::Param.new("self", "*@This()", false), MIR::Param.new("alloc", "std.mem.Allocator", false)],
          "void",
          deinit_stmts,
          :pub
        )
        [deinit_fn]
      end

      MIR::StructDef.new("#{node.name}_#{var_name}", fields, methods, nil)
    end

    # Build variant list
    variants = node.variants.map { |var_name, var_data|
      zig_t = if var_data.nil?
        "void"
      elsif Schemas.inline_struct?(var_data)
        "#{node.name}_#{var_name}"
      else
        transpile_type(var_data, is_field: true)
      end
      { name: var_name.to_s, zig_type: zig_t }
    }

    if node.type_params&.any?
      # Generic union: fn Name(comptime T: type) type { return union(enum) { ... }; }
      comptime_params = node.type_params.map { |p| "comptime #{p}: type" }
      inner_union = MIR::UnionTypeDef.new(nil, variants, nil)
      body = [MIR::ReturnStmt.new(inner_union)]
      generic_fn = MIR::FnDef.new(node.name, [], "type", body, nil, false, comptime_params)
      if helper_structs.any?
        helper_structs + [generic_fn]
      else
        generic_fn
      end
    else
      union_node = MIR::UnionTypeDef.new(node.name, variants, nil)
      if helper_structs.any?
        helper_structs + [union_node]
      else
        union_node
      end
    end
  end

  # Module roots that resolve as Zig MODULES (not relative .zig files):
  # - std, builtin: Zig stdlib
  # - cheat_runtime: CLEAR runtime, wired via build.zig as a module
  EXTERN_MODULE_ROOTS = T.let(%w[std builtin cheat_runtime].to_set.freeze, T::Set[String])

  sig { params(node: AST::Cast).returns(MIR::Cast) }
  def lower_cast(node)
    inner = lower(node.value)
    target_type = transpile_type(node.target)

    # Int -> enum: emit `@enumFromInt(value)` instead of `@as(EnumT, value)`.
    # Modern Zig rejects `@as(EnumT, intExpr)` (type coercion is enum-from-
    # int, which is its own builtin). Detected by checking whether the
    # target's underlying type matches a registered enum schema.
    #
    # Strip the optional `?` and error-union `!` prefixes from the resolved
    # name before lookup so `CAST(x AS ?MyEnum)` and `CAST(x AS !MyEnum)`
    # also route through the builtin -- otherwise the schema lookup misses
    # and we emit `@as(?MyEnum, intExpr)` which Zig also rejects.
    target_resolved = node.target.is_a?(Type) ? node.target.resolved : node.target
    target_base = target_resolved.to_s.sub(/\A[?!]+/, '').to_sym
    if @enum_schemas&.key?(target_base)
      return MIR::Cast.new(inner, target_type, :enumFromInt)
    end

    MIR::Cast.new(inner, target_type, :as)
  end

  # ================================================================
  # Concurrent / capability blocks
  # ================================================================

  # WITH-capture helpers. Group 1 (sync/ownership) on a binding can apply
  # to either the whole binding (Identifier capture) or to a specific
  # field of it (GetField capture, e.g. `WITH EXCLUSIVE env.vars AS v`).
  # These helpers paper over the difference for the lowering loop.

  # User-visible name of the bound entity — used for naming guard vars.
  sig { params(node: AST::StaticCall).returns(T.untyped) }
  def lower_static_call(node)
    # Structural MIR::InlineBc when the matched stdlib_def opts in via
    # bc:true. Both backends consume the same node: Zig emits via
    # emit_inline_bc_as_zig (substituting {0}, {1}, ... from stdlib_def[:zig]),
    # BC dispatches by op symbol in compile_inline_bc.
    if node.matched_stdlib_def&.emit&.bc
      mir_args = node.args.map { |a| hoist_alloc(lower(a), a) }
      return MIR::InlineBc.new(node.matched_stdlib_def.emit&.bc_op,
                                mir_args, node.matched_stdlib_def)
    end

    pattern = node.zig_pattern.dup
    # Hoist any heap-allocating args to named Lets via hoist_alloc so the
    # checker can verify their cleanup. Non-allocating args (and frame allocs)
    # are left inline -- the pending Lets are emitted by lower_body's
    # flush_pending before the enclosing statement.
    arg_strs = node.args.map { |a| emit_expr(hoist_alloc(lower(a), a)) }
    arg_strs.each_with_index { |arg, i| pattern = pattern.gsub("{#{i}}") { arg } }
    iz = MIR::InlineZig.new(pattern, "static_call")
    iz.stdlib_def = node.matched_stdlib_def
    iz
  end

  sig { params(node: AST::OrExit).returns(MIR::ScopeBlock) }
  def lower_or_exit(node)
    # Unified OR EXIT: any combination of (kind, error_name, message).
    # Unspecified fields inherit from the pre-existing rt.__error set
    # by the failing call. If a Kind is specified but no Type, the
    # type is explicitly cleared (set to 0 / None) to avoid carrying
    # a stale type that no longer matches the new kind.
    stmts = []
    rt_name = @rt_name
    line = node.token.line.to_s

    # Register VM: structured sibling of the InlineZig sequence below.
    # The bc emitter cannot parse Zig (CLAUDE.md), so carry the
    # reassignment as one InlineBc with structured fields. The Zig
    # backend path (target != :bc) is byte-for-byte unchanged.
    if @target == :bc
      bc_kind = nil
      bc_name_id = nil
      bc_clear_type = false
      if node.kind
        bc_kind = node.kind.to_s
        if node.error_name
          bc_name_id = AST.id_of_type(node.error_name.to_sym)
        else
          bc_clear_type = true
        end
      elsif node.error_name && AST.error_type?(node.error_name.to_sym)
        bc_kind = AST.kind_of_type(node.error_name.to_sym).to_s
        bc_name_id = AST.id_of_type(node.error_name.to_sym)
      end
      msg_mir = node.message ? lower(node.message) : nil
      reassign = MIR::InlineBc.new(:or_exit, [msg_mir].compact, {
        kind: bc_kind, name_id: bc_name_id,
        clear_type: bc_clear_type, has_message: !node.message.nil?,
        line: node.token.line.to_i
      })
      return MIR::ScopeBlock.new([
        MIR::ExprStmt.new(reassign, false),
        MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
      ])
    end

    if node.kind
      stmts << MIR::ExprStmt.new(MIR::InlineZig.new("#{rt_name}.__error.kind = .#{node.kind}", "or_exit_kind"), false)
      if node.error_name
        stmts << MIR::ExprStmt.new(MIR::InlineZig.new("#{rt_name}.__error.error_name = @intFromEnum(ErrorName.#{node.error_name})", "or_exit_type"), false)
      else
        # Kind without type -> clear any stale type from the prior context.
        stmts << MIR::ExprStmt.new(MIR::InlineZig.new("#{rt_name}.__error.error_name = 0", "or_exit_clear_type"), false)
      end
    end

    if node.message
      msg_zig = emit_expr(lower(node.message))
      stmts << MIR::ExprStmt.new(MIR::InlineZig.new("#{rt_name}.__error.message = #{msg_zig}", "or_exit_msg"), false)
    end

    # Always update clear_line so diagnostics point at this OR EXIT.
    stmts << MIR::ExprStmt.new(MIR::InlineZig.new("#{rt_name}.__error.clear_line = #{line}", "or_exit_line"), false)

    stmts << MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
    MIR::ScopeBlock.new(stmts)
  end

  # Test-framework MIR lowering (lower_test_block, lower_assert_raises,
  # lower_stub_decl, lower_benchmark, lower_smash, lower_profile,
  # stub_intercept_for, stub_local_idents, TEST_PREAMBLE) is mixed in
  # from src/mir/test_lowering.rb (TestLowering module).

  sig { params(node: AST::RequireNode).returns(T.untyped) }
  def lower_require(node)
    # Stdlib packages auto-resolve to <repo>/stdlib/<name>/src/lib.cht
    # and are inlined into single-binary builds (no separate .zig is
    # produced for them). User-registered packages (--pkg name=...)
    # keep the @import emission so an outer build.zig can orchestrate
    # per-package compilation.
    pkg_inline = node.kind == :package && @importer && @importer.stdlib_package?(node.path)

    if node.kind == :package && !pkg_inline
      MIR::Import.new(node.namespace || node.path, "#{node.namespace || node.path}.zig", nil)
    else
      # Local require / stdlib package: compile the module and inline
      # the Zig body. Local uses compile_file (path); stdlib uses
      # compile_package (name → resolved path).
      raise "MIRLowering: REQUIRE \"#{node.path}\" but no importer available" unless @importer

      mod = if pkg_inline
        @importer.compile_package(node.path, caller_dir: T.must(@source_dir))
      else
        @importer.compile_file(node.path, caller_dir: T.must(@source_dir))
      end

      # Merge schemas so downstream code can resolve imported types
      merge_module_schemas!(T.must(mod))

      # Propagate fn_sigs from imported functions. When `full_type` is
      # not a FunctionSignature (some annotator paths leave it as a
      # `Type`), reconstruct from the FunctionDef's own param list so
      # call-site routing decisions that consult `callee_sig.params[idx]`
      # (MUTABLE @list detection, takes/borrow, etc.) work for cross-file
      # callees too. Without this, the lowering silently sees an empty
      # param list and emits the wrong arg shape (e.g. `.items` instead
      # of `&xs` for a MUTABLE @list parameter).
      if T.must(mod).ast
        T.must(mod).ast.statements.each do |stmt|
          next unless stmt.is_a?(AST::FunctionDef)
          @fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt)
        end
      end

      # Emit type definitions at file scope, then function body in struct wrapper
      same_dir = T.must(mod).source_dir == @source_dir
      file_scope_types = visible_type_defs(T.must(mod), same_dir: same_dir)
      body = T.must(mod).transpiled_body.strip
      fn_body = strip_all_type_defs(body)
      indented = fn_body.lines.map { |l| l.rstrip.empty? ? "" : "    #{l.rstrip}" }.join("\n")

      lines = []
      lines << file_scope_types if file_scope_types && !file_scope_types.strip.empty?
      lines << "const #{node.namespace} = struct {\n#{indented}\n};"
      # Opaque: body comes from a completed separate transpile pass (mod.transpiled_body).
      # Decomposition requires threading MIR through the module-importer pipeline.
      raw = MIR::RawZig.new(lines.join("\n"), "require_local_module_opaque",
        MIR::OwnershipContract.empty)

      # VM target also needs the imported function bodies as MIR FnDefs so the
      # bytecode emitter can lay out helpers and resolve namespaced calls
      # (e.g. `require_helper.addPub`). Lower each public function from the
      # module AST and tag its name with the importer namespace; the call-site
      # lookup in bc_emitter treats `<ns>.<fn>` as a synonym for the bare name.
      if @target == :bc && T.must(mod).ast
        helper_fns = []
        T.must(mod).ast.statements.each do |stmt|
          next unless stmt.is_a?(AST::FunctionDef)
          fn_mir = lower_function_def(stmt)
          if fn_mir
            # Stash the AST on the MIR FnDef so bc_emitter's parallel walk can
            # find it without going through CompilerFrontend's fn_nodes (which
            # only sees the top-level AST, not imported modules).
            fn_mir.instance_variable_set(:@ast_fn, stmt) if fn_mir.respond_to?(:instance_variable_set)
            helper_fns << fn_mir
          end
        end
        return [raw, *helper_fns] if helper_fns.any?
      end

      raw
    end
  end

  sig { params(mod: ModuleImporter::CompiledModule).returns(T.untyped) }
  def merge_module_schemas!(mod)
    if mod.struct_schemas
      @struct_schemas.merge!(mod.struct_schemas)
    end
    if mod.union_schemas
      @union_schemas.merge!(mod.union_schemas)
    end
    if mod.enum_schemas
      @enum_schemas.merge!(mod.enum_schemas)
    end
  end

  sig { params(mod: ModuleImporter::CompiledModule, same_dir: T::Boolean).returns(T.nilable(String)) }
  def visible_type_defs(mod, same_dir: false)
    return nil unless mod.type_defs && !mod.type_defs.strip.empty?
    return nil unless mod.ast

    visible_names = Set.new
    mod.ast.statements.each do |stmt|
      case stmt
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        vis = stmt.visibility || :package
        next if vis == :private
        next unless (vis == :pub) || same_dir
        name = stmt.name.to_s
        next if @emitted_types.include?(name)
        visible_names.add(name)
        @emitted_types.add(name)
        if stmt.is_a?(AST::UnionDef)
          stmt.variants.each do |var_name, var_data|
            next unless Schemas.inline_struct?(var_data)
            syn = "#{stmt.name}_#{var_name}"
            visible_names.add(syn)
            @emitted_types.add(syn)
          end
        end
      end
    end

    return nil if visible_names.empty?
    filter_zig_blocks(mod.type_defs, visible_names)
  end

  sig { params(body: String).returns(String) }
  def strip_all_type_defs(body)
    lines = body.lines
    result = []
    i = 0
    while i < lines.length
      line = lines[i]
      if line =~ /\Aconst (\w+)\s*=\s*(struct|union\(enum\)|enum)\s*[\{(]/
        depth = T.must(line).count('{') - T.must(line).count('}')
        i += 1
        while i < lines.length && depth > 0
          depth += T.must(lines[i]).count('{') - T.must(lines[i]).count('}')
          i += 1
        end
        i += 1 if i < lines.length && lines[i]&.strip == '};'
      else
        result << line
        i += 1
      end
    end
    result.join
  end

  sig { params(source: String, names: T::Set[String]).returns(String) }
  def filter_zig_blocks(source, names)
    lines = source.lines
    result = []
    i = 0
    while i < lines.length
      line = lines[i]
      if line =~ /\Aconst (\w+)\s*=/
        name = $1
        is_target = names.include?(name)
        block_lines = [line]
        depth = T.must(line).count('{') - T.must(line).count('}')
        i += 1
        while i < lines.length && depth > 0
          block_lines << lines[i]
          depth += T.must(lines[i]).count('{') - T.must(lines[i]).count('}')
          i += 1
        end
        if i < lines.length && lines[i]&.strip == '};'
          block_lines << lines[i]
          i += 1
        end
        result.concat(block_lines) if is_target
      else
        i += 1
      end
    end
    result.join
  end

  # ================================================================
  # Helpers for concurrent blocks
  # ================================================================

  STACK_SIZE_ZIG_VARIANT = T.let({
    nil       => "Standard",
    :micro    => "Micro", :standard => "Standard", :large => "Large", :xl => "Xl",
    "micro"   => "Micro", "standard" => "Standard", "large" => "Large", "xl" => "Xl",
    :service  => "Huge",
  }.freeze, T::Hash[T.untyped, T.untyped])

  TIER_RANK = T.let({ "Micro" => 0, "Standard" => 1, "Large" => 2, "Xl" => 3, "Huge" => 4 }.freeze, T::Hash[T.untyped, T.untyped])

  sig { params(stack_size: T.nilable(Symbol), computed_tier: T.nilable(Symbol)).returns(String) }
  def task_config_zig(stack_size, computed_tier)
    default = @debug_mode ? "Large" : "Standard"
    variant = if stack_size
      if stack_size == :stack
        STACK_SIZE_ZIG_VARIANT.fetch(computed_tier || :standard, default)
      else
        STACK_SIZE_ZIG_VARIANT.fetch(stack_size, default)
      end
    elsif computed_tier
      computed = STACK_SIZE_ZIG_VARIANT.fetch(computed_tier, default)
      TIER_RANK.fetch(computed, 0) >= TIER_RANK.fetch(default, 0) ? computed : default
    else
      default
    end
    ".{ .stack_size = .#{variant} }"
  end

  sig { params(rt_name: String, ctx_type: String, ctx_var: String, task_cfg: String, pin_mode: T.untyped).returns(String) }
  def fiber_spawn_call_zig(rt_name, ctx_type, ctx_var, task_cfg, pin_mode)
    spawn_args = "@intFromPtr(&Runtime.entryWrapper),\n" \
      "    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n" \
      "    #{ctx_var},\n" \
      "    #{task_cfg}"
    case pin_mode
    when :local, true
      "try #{rt_name}.getSched().submitSpawn(\n    #{spawn_args}\n);"
    when :shared
      "try CheatHeader.spawnPinned(\n    #{spawn_args}\n);"
    when :parallel
      "try CheatHeader.spawnBest(\n    #{spawn_args}\n);"
    else
      "try CheatHeader.spawnBest(\n    #{spawn_args}\n);"
    end
  end

  sig { params(task_cfg: String, site_id: Integer, dispatch: T.untyped).returns(String) }
  def task_config_with_profile(task_cfg, site_id, dispatch)
    fields = ".profile_site_id = #{site_id}, .profile_dispatch = #{profile_dispatch_id(dispatch)}"
    stripped = task_cfg.strip
    return ".{ #{fields} }" if stripped == ".{}"
    stripped.sub(/\}\s*\z/, ", #{fields} }")
  end

  sig { params(dispatch: T.untyped).returns(Integer) }
  def profile_dispatch_id(dispatch)
    case dispatch
    when :local, true then 1
    when :parallel then 2
    when :shared then 3
    else 1
    end
  end

  sig { params(site_id: Integer, line: Integer, col: Integer, dispatch: T.untyped, form: Symbol).returns(String) }
  def bg_profile_site_comment(site_id, line, col, dispatch, form)
    "// CLEAR_PROFILE_TASK_SITE id=#{site_id} kind=BG line=#{line} column=#{col} dispatch=#{dispatch} form=#{form}"
  end

  # ================================================================
  # Expressions
  # ================================================================

  sig { params(subject: MIR::Ident, pat: AST::StructPattern).returns(T::Array[T.untyped]) }
  def lower_struct_pattern(subject, pat)
    conditions = []
    bindings = []

    pat.fields.each do |f|
      next if f.wildcard?
      if f.bind?
        field_access = MIR::FieldGet.new(subject, f.name.to_s)
        bindings << MIR::Let.new(f.name.to_s, field_access, false, nil, "_ = &#{f.name};")
      else
        val = lower(f.expr)
        field_access = MIR::FieldGet.new(subject, f.name.to_s)
        conditions << MIR::BinOp.new("==", field_access, val)
      end
    end

    [conditions, bindings]
  end

  sig { params(node: AST::FuncCall).returns(MIR::Call) }
  def lower_macro_print(node)
    formats = node.args.map { |arg| zig_format_for_type(arg.full_type) }.join(" ")
    args_mir = node.args.map { |a| hoist_alloc(lower(a), a) }
    format_lit = MIR::Lit.new("\"#{formats}\\n\"")
    tuple_inner = args_mir.map { |a| emit_expr(a) }.join(", ")
    tuple = MIR::Ident.new(".{#{tuple_inner}}")
    MIR::Call.new("std.debug.print", [format_lit, tuple], false, false, MIR::CallableContract.no_ownership(2))
  end

  sig { params(flux_type: Type).returns(String) }
  def zig_format_for_type(flux_type)
    t = flux_type.to_s
    return "{s}" if t.include?("String") || t.match?(/^Byte\[/)
    case t
    when "Number", "Int64", "Byte" then "{d}"
    when "Bool" then "{}"
    when "Void" then "{}"
    else "{any}"
    end
  end

  sig { params(name: String).returns(T::Boolean) }
  def callee_can_fail?(name)
    return true if false || name.to_s.empty?
    sig = @fn_sigs&.dig(name) || @fn_sigs&.dig(name.to_sym) || @fn_sigs&.dig(name.to_s)
    sig ? (sig.can_fail.nil? ? true : sig.can_fail) : true
  end

  sig { params(nodes: T::Array[T.untyped]).returns(T::Set[String]) }
  def collect_identifier_names(nodes)
    names = Set.new
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array then n.each { |item| traverse.call(item) }
      when Hash then n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef then nil # Don't descend into nested defs
      when AST::Identifier then names.add(n.name)
      else n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(nodes)
    names
  end

  # Quick emit for an MIR expression (used when embedding in InlineZig).
  # This is a temporary bridge -- ideally all expressions stay as MIR nodes.
  # Emit a builtin operation from BUILTIN_OPS registry as MIR::InlineZig
  # with stdlib_def attached so the MIR checker can verify ownership.
  sig { params(name: Symbol, args: T::Array[T.untyped]).returns(T.any(MIR::InlineBc, MIR::InlineZig)) }
  def emit_builtin(name, args)
    entry = IntrinsicRegistry.sig(BUILTIN_OPS, name)
    raise "emit_builtin: unknown builtin :#{name}" unless entry
    if @target == :bc && entry.emit&.bc
      return MIR::InlineBc.new(name, args, entry)
    end
    pattern = entry.emit&.zig.to_s.dup
    # Use block form of gsub so backslashes in Zig code (e.g. "\\" for a literal
    # backslash) are not interpreted as replacement specials by String#gsub.
    args.each_with_index { |a, i| code = emit_expr(a); pattern = pattern.gsub("{#{i}}") { code } }
    iz = MIR::InlineZig.new(pattern, "builtin_#{name}")
    iz.stdlib_def = entry
    consumes = T.let([], T::Array[String])
    args.each do |arg|
      next unless arg.respond_to?(:mir?) && arg.mir?
      collect_mir_consumed_roots(arg).each { |root| consumes << root }
    end
    iz.ownership_contract = MIR::OwnershipContract.consumes(consumes.uniq) unless consumes.empty?
    iz
  end

  # Returns the bare Zig type name for a type_info value, stripping any
  # leading pointer qualifier that transpile_type may add (e.g. *Value -> Value).
  def bare_zig_type(ti)
    transpile_type(ti.is_a?(Type) ? ti.resolved.to_s : ti.to_s)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def direct_indexable_collection_type?(type_info)
    ti = Type.new(type_info)
    ti.direct_indexable_collection?
  end

  sig { params(ast_node: T.untyped, type_info: Type).returns(T::Boolean) }
  def direct_slice_backed_expr?(ast_node, type_info)
    ti = Type.new(type_info)
    return true if ti.fixed?
    return true if ast_node.is_a?(AST::GetField)
    ast_node.is_a?(AST::Identifier) ? !!@current_fn_param_names&.include?(ast_node.name) : false
  end

  sig { params(target: T.untyped, index: T.untyped, ast_node: T.untyped, type_info: Type).returns(T.nilable(MIR::IndexGet)) }
  def direct_index_get(target, index, ast_node, type_info)
    ti = Type.new(type_info)
    # @list types defer to CheatLib.getAt (the registry fallback). The runtime
    # helper dispatches ArrayList vs slice via comptime @hasField, so we don't
    # re-derive container shape from "is this a param?" here. Keep direct
    # IndexGet only for true slice-backed exprs (string@raw, fixed slices).
    return nil if ti.list_collection?
    return nil unless direct_slice_backed_expr?(ast_node, ti)
    cast_idx = MIR::Cast.new(index, "usize", :intCast)
    MIR::IndexGet.new(target, cast_idx)
  end

  sig { params(node: T.untyped).returns(T.nilable(MIR::Cast)) }
  def lower_direct_length(node)
    recv_ast = node.is_a?(AST::MethodCall) ? node.object : node.args.first
    return nil unless recv_ast

    recv_ti = Type.from_node!(recv_ast, context: "direct length")

    ti = Type.new(recv_ti)
    # Containers (list/array/slice) all defer to CheatLib.len, which dispatches
    # ArrayList vs slice via comptime @hasField. Returning nil here falls back
    # to the regular stdlib-registry path that emits CheatLib.len({0}). The
    # runtime is the single source of truth for container shape — the lowering
    # MUST NOT re-derive shape from "is this a param?" or similar shortcuts
    # (TAKES @list params receive ArrayList; borrow @list params receive a
    # slice via .items; the runtime helper handles both).
    return nil if ti.direct_indexable_collection?

    recv = lower(recv_ast)
    len_expr =
      if ti.string?
        MIR::ListLength.new(recv)
      else
        nil
      end

    return nil unless len_expr
    MIR::Cast.new(len_expr, "i64", :intCast)
  end

  sig { params(node: T.untyped).returns(T.nilable(String)) }
  def emit_expr(node)
    @_emitter ||= begin
      require_relative "mir_emitter"
      MIREmitter.new
    end
    @_emitter.rt_name = @rt_name
    @_emitter.emit(node)
  end

  # Strip try-wrapping from a MIR node so it can be used inside catch/orelse.
  # Returns a new node without try, or the original node if not try-wrapped.
  sig { params(left: T.untyped, catch_body: T.untyped, capture: T.nilable(String), fallback: T.untyped).returns(MIR::TryCatch) }
  def try_catch_with_provenance(left, catch_body, capture, fallback: nil)
    MIR::TryCatch.new(strip_try(left), catch_body, capture)
  end

  sig { params(mir_node: T.untyped).returns(T.untyped) }
  def strip_try(mir_node)
    case mir_node
    when MIR::Call
      MIR::Call.new(mir_node.callee, mir_node.args, false, mir_node.owned_return, mir_node.callable_contract)
    when MIR::MethodCall
      MIR::MethodCall.new(mir_node.receiver, mir_node.method, mir_node.args, false,
        mir_node.callable_contract, mir_node.owned_result_alloc)
    when MIR::TryExpr
      mir_node.expr
    when MIR::InlineZig
      code = mir_node.code.sub(/\Atry /, '')
      iz = MIR::InlineZig.new(code, mir_node.reason)
      iz.stdlib_def = mir_node.stdlib_def
      iz.allocs = mir_node.allocs
      iz.target_var = mir_node.target_var
      iz
    when MIR::RawZig
      code = mir_node.code.sub(/\Atry /, '')
      MIR::RawZig.new(code, mir_node.reason)
    else
      mir_node
    end
  end

  # Emit a list of MIR statements as Zig body text, adding semicolons
  # to expression nodes used as statements. Mirrors MIREmitter#emit_body.
  sig { params(mir_nodes: T::Array[T.untyped], indent: String).returns(String) }
  def emit_stmts_zig(mir_nodes, indent: "")
    mir_nodes.filter_map { |s|
      code = emit_expr(s)
      next nil unless code
      stripped = code.strip
      if s.respond_to?(:expr?) && s.expr? &&
         !stripped.end_with?(";") && !stripped.end_with?("}") && !stripped.end_with?("{")
        "#{indent}#{code};"
      else
        "#{indent}#{code}"
      end
    }.join("\n")
  end

  public

  # Temporarily installs a fiber capture map and rt alias, runs the block, then restores.
  # Used by DoBlock, BgBlock, and PipelineHost (for concurrent pipeline operators).
  #
  # `capture_symbols` (optional Hash<name => SymbolEntry>) carries the LIVE
  # SymbolEntry for each captured name so body-lowering passes that need
  # current sync/storage (e.g. WITH EXCLUSIVE's Arc-vs-bare dispatch in
  # with_cap_sync_storage) read post-`propagate_caller_sync!` state, not
  # the AST-snapshot state that var_node.symbol may carry. Without this,
  # a `WITH EXCLUSIVE c` inside a CONCURRENT/BG/DO callback that captures
  # c (received via REQUIRES LOCKED) emits the polymorphic `c.*` deref
  # path instead of the direct `c.ctrl.data.*` Arc-unwrap, and the Zig
  # compile fails with "cannot dereference non-pointer type Arc(...)".
  # See transpile-tests/257_concurrent_capture_locked_param.cht.
  sig { params(new_entries: T::Hash[String, String], capture_symbols: T.nilable(T::Hash[String, SymbolEntry]), rt_override: String, blk: T.untyped).returns(T.untyped) }
  def with_fiber_capture_map(new_entries, capture_symbols: nil, rt_override: "__rt", &blk)
    prev_map = @do_capture_map || {}
    prev_syms = @current_fiber_capture_symbols || {}
    prev_rt  = @rt_name
    @do_capture_map = prev_map.merge(new_entries)
    @current_fiber_capture_symbols = prev_syms.merge(capture_symbols || {})
    @rt_name = rt_override
    result = blk.call
    @do_capture_map = prev_map
    @current_fiber_capture_symbols = prev_syms
    @rt_name = prev_rt
    result
  end

  private

  # Should we inject `rt.checkYield()` at the entry of this fn?
  # Returns true for non-TIGHT recursive fns (plain :reentrant,
  # :TAIL_CALL, :MAX_DEPTH(N) when N > BUDGET). Skipped for :THUNK
  # (the trampoline body emits its own yield) and :NOT_LOGICAL
  # (depth=1 by assertion -- yield is meaningless).
  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def needs_recursion_yield?(node)
    return false if node.tight_reentrance
    case node.reentrance_kind
    when :reentrant, :reentrant_tail_call, :reentrant_max_depth
      true
    else
      # :reentrant_thunk handled in ThunkTransform::Emit (its
      # trampoline always yields per iteration unless TIGHT).
      # :reentrant_not_logical never yields.
      false
    end
  end

  # Strip pointer prefix from zig type - dupeUnionValue needs bare type (Value not *Value).
  sig { params(ti: Type).returns(T.untyped) }
  def bare_zig_type(ti)
    t = transpile_type(ti.is_a?(Type) ? ti : ti)
    t.start_with?("*") ? t[1..] : t
  end

  sig { params(value: T.untyped, ast_node: T.untyped, sink_alloc: Symbol, sink_type: T.untyped).returns(T.untyped) }
  def materialize_owned_sink_value(value, ast_node, sink_alloc, sink_type = nil)
    return value unless ast_node
    ti = Type.from_node!(ast_node, context: "owned sink materialization")
    dst_ti = Type.from_node(sink_type) || ti

    if ti.string?
      value_alloc = mir_owned_alloc(value) || placement_for_node(ast_node)
      return value if ast_node.respond_to?(:was_moved) && ast_node.was_moved == true &&
                      value_alloc == sink_alloc &&
                      !ti.rodata? &&
                      !ast_node.is_a?(AST::CopyNode) && !ast_node.is_a?(AST::CloneNode)
      return value if value_alloc == sink_alloc && verifiable_owned_source?(ast_node)
      return value if value_alloc == sink_alloc && existing_owned_source?(ast_node) &&
                      !verifiable_owned_source?(ast_node)
      return value if owned_sink_value?(value, ast_node)
      return MIR::DupeSlice.new(value, sink_alloc)
    end

    if ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(@schema_lookup)
      value_alloc = mir_owned_alloc(value) || placement_for_node(ast_node)
      return value if ast_node.respond_to?(:was_moved) && ast_node.was_moved == true &&
                      value_alloc == sink_alloc &&
                      !ast_node.is_a?(AST::CopyNode) && !ast_node.is_a?(AST::CloneNode)
      return value if owned_parameter_source?(ast_node)
      return value if ast_node.respond_to?(:needs_heap_create) && ast_node.needs_heap_create
      return value if value_alloc == sink_alloc && ownership_transfer_source?(ast_node)
      return value if ownership_transfer_source_without_local_cleanup?(ast_node)
      return value unless existing_owned_source?(ast_node)
      return MIR::DeepCopy.new(value, dst_ti.zig_type(is_field: true), nil, :full_value, sink_alloc)
    end

    return value unless borrowed_union_sink_value?(ast_node, ti)
    zig_t = bare_zig_type(ti)
    emit_builtin(:dupeUnionValue, [MIR::Ident.new(zig_t), value, MIR::Ident.new(alloc_zig_str(sink_alloc))])
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def owned_parameter_source?(ast_node)
    return false unless ast_node.is_a?(AST::Identifier)
    symbol = ast_node.symbol
    !!(symbol&.is_param && symbol&.takes)
  end

  sig { params(value: T.untyped, ast_node: T.untyped).returns(T::Boolean) }
  def owned_sink_value?(value, ast_node)
    return owned_sink_value?(value.expr, ast_node) if value.is_a?(MIR::Cast)
    return owned_sink_value?(value.expr, ast_node) if value.is_a?(MIR::TryExpr)
    return true if ast_node.is_a?(AST::MoveNode) || ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return true if mir_allocates?(value)
    return true if value.is_a?(MIR::Call) && value.owned_return?
    false
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def existing_owned_source?(ast_node)
    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    node.is_a?(AST::Identifier) || node.is_a?(AST::GetField) ||
      node.is_a?(AST::GetIndex) || node.is_a?(AST::OptionalUnwrap)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def verifiable_owned_source?(ast_node)
    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    return false unless node.is_a?(AST::Identifier)
    entry = @current_bindings[node.name.to_s] if @current_bindings
    !!entry&.needs_cleanup?
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def ownership_transfer_source?(ast_node)
    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    return false unless node.is_a?(AST::Identifier)
    entry = @current_bindings[node.name.to_s] if @current_bindings
    !!entry&.present?
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def ownership_transfer_source_without_local_cleanup?(ast_node)
    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    return false unless node.is_a?(AST::Identifier)
    entry = @current_bindings[node.name.to_s] if @current_bindings
    !!(entry&.present? && !entry.needs_cleanup?)
  end

  sig { params(ast_node: T.untyped, ti: Type).returns(T::Boolean) }
  def borrowed_union_sink_value?(ast_node, ti)
    return false if ast_node.is_a?(AST::MoveNode) || ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return false unless ast_node.is_a?(AST::Identifier) || ast_node.is_a?(AST::GetIndex)
    root = AST.root_identifier(ast_node) rescue nil
    borrowed = (root&.symbol&.borrow_provenance?) || (ast_node.respond_to?(:container_borrow) && ast_node.container_borrow)
    return false unless borrowed
    return false unless @union_schemas&.key?(ti.resolved)
    return false if ti.respond_to?(:implicitly_copyable?) && ti.implicitly_copyable?(@schema_lookup)
    true
  end

  # Check if a value node is an Rc/Arc identifier that needs retain (not moved, not unwrapped)
  sig { params(value_node: T.untyped).returns(T::Boolean) }
  def rc_retain_needed?(value_node)
    return false unless value_node.is_a?(AST::Identifier)
    ti = Type.from_node!(value_node, context: "rc retain")
    return false unless ti.any_rc?
    return false if ti.atomic_ptr?
    rc_map = @rc_unwrap_map || {}
    return false if rc_map.key?(value_node.name)
    true
  end

  sig { params(value_node: AST::Identifier).returns(MIR::RcRetain) }
  def make_rc_retain(value_node)
    ti = Type.from_node!(value_node, context: "rc retain emit")
    func = ti.shared? ? "arcRetain" : "rcRetain"
    zig_base = rc_payload_zig_type(ti)
    MIR::RcRetain.new(lower(value_node), zig_base, func)
  end

  # Lazy-create PipelineHost for complex pipeline operator dispatch.
  sig { returns(PipelineHost) }
  def pipeline_host
    cached = @pipeline_host
    return cached if cached

    @pipeline_host = PipelineHost.new(
      lowering: self,
      emitter: begin
      require_relative "mir_emitter"
        @_emitter || MIREmitter.new
      end
    )
    @pipeline_host
  end
end
