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
require_relative "lowering/variables"
require_relative "lowering/control_flow"

class MIRLowering
    extend T::Sig

  include ZigTypeMapper
  include FsmLowering
  include TestLowering
  include MIRHoistLowering
  include MIRLoweringFunctions
  include MIRLoweringCapabilities
  include MIRLoweringConcurrency
  include MIRLoweringExpressions
  include MIRLoweringVariables
  include MIRLoweringControlFlow

  ZIG_PRIMITIVE_RE = /\A[uif]\d+\z/

  attr_reader :fn_sigs
  attr_accessor :shard_context

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
      ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) },
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
    # Allocator of the binding whose value is currently being lowered;
    # an anonymous allocating sub-expression inherits it (with_decl_alloc).
    @decl_alloc = T.let(nil, T.nilable(Symbol))
    @current_bindings = T.let({}, T::Hash[String, CleanupEntry])  # set per-function by lower_function_def from fn.cleanup_bindings
    @target = target
    @fn_alloc_marked_names = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @decl_zig_name_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @guarded_cleanup_names = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @fn_name_rename_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @current_fn_snapshot_types = T.let(nil, T.nilable(T::Set[T.untyped]))
    @atomic_emit_raw = T.let(false, T::Boolean)
    @used_sharded_map = T.let(false, T::Boolean)
    @current_fn_has_rt = T.let(false, T::Boolean)
    @current_fn_tail_call = T.let(false, T::Boolean)
    @current_fn_return_alloc = T.let(nil, T.nilable(Symbol))
    @current_fn_zig_name = T.let(nil, T.nilable(String))
    @current_fn_return_payload_zig = T.let(nil, T.nilable(String))
    @current_fn_returned_names = T.let(Set.new, T::Set[String])
    @current_fn_has_catch = T.let(false, T::Boolean)
    @current_fn_collection_params = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_param_names = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fn_mutable_scalar_params = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_bg_pointer_captures = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_fiber_capture_symbols = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @do_capture_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @locked_unwrap_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @rc_unwrap_map = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @safe_nav_counter = T.let(0, Integer)
    @extern_counter = T.let(0, Integer)
    @lambda_counter = T.let(0, Integer)
    @do_block_counter = T.let(0, Integer)
    @bg_block_counter = T.let(0, Integer)
    @stream_gen_counter = T.let(0, Integer)
    @current_stream_is_inf = T.let(nil, T.nilable(T::Boolean))
    @current_stream_local = T.let(nil, T.nilable(String))
    @loop_mark_counter = T.let(0, Integer)
    @for_counter = T.let(0, Integer)
    @_emitter = T.let(nil, T.nilable(MIREmitter))
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
    return mir if heap_owned_value?(mir, ast_node)

    MIR::DupeSlice.new(mir, :heap)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T::Boolean) }
  def heap_owned_value?(mir, ast_node)
    return heap_owned_value?(mir.expr, ast_node) if mir.is_a?(MIR::Cast)
    return heap_owned_value?(mir.expr, ast_node) if mir.is_a?(MIR::TryExpr)
    return true if mir.is_a?(MIR::DupeSlice) && mir.alloc == :heap
    return true if mir.is_a?(MIR::ConcatStr) && mir.alloc == :heap
    return true if mir.is_a?(MIR::DeepCopy) && mir.strategy == :full_value && mir.alloc == :heap
    return true if mir.is_a?(MIR::Call) && mir.heap_provenance
    return true if mir.is_a?(MIR::TryCatch) && mir.heap_provenance
    return true if ast_node.is_a?(AST::NextExpr)
    if mir.is_a?(MIR::InlineZig)
      return true if mir.stdlib_def&.emit&.return_alloc == :heap
      return true if mir.allocs.is_a?(Hash) && mir.allocs.values.any? { |a| a == :heap }
    end

    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    node.is_a?(AST::Identifier) && node.symbol&.heap_provenance?
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
      # SuppressCleanup is an AST-level marker that pre-dates line-suffix
      # rename; its .name is a raw identifier string with no link back to
      # the renamed decl. Consult @fn_name_rename_map so the emitted
      # "x_moved = true" line matches the Cleanup's suffixed guard var.
      safe = zig_safe_name(node.name)
      safe = @fn_name_rename_map[safe] if @fn_name_rename_map&.key?(safe)
      MIR::MoveMark.new(safe)
    when MIR::Alloc             then MIR::AllocMark.new(node.name, node.alloc, nil)
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
        mir_allocates?(mir)
        entry = hoist_cleanup_entry(mir, s)
        if entry
          mir = MIR::DiscardOwned.new(mir, entry, discard_owned_zig_type(s, entry))
          hoisted_discard = true
        end
      end
      pending = flush_pending
      if needs_discard &&
         s.respond_to?(:resolved_type) && s.resolved_type && s.resolved_type != :Void &&
         !hoisted_discard
        mir = MIR::ExprStmt.new(mir, true)
      end
      result.concat(pending)
      # Inject source map comment for this user-visible statement.
      # Placed after pending (hoisted synthetic temps have no user source line).
      line = s.token&.line
      col  = s.token&.column
      result << MIR::Comment.new("CLR:#{line}") if line
      # lower_var_decl may return [AllocMark, Let, Cleanup] when the binding needs cleanup.
      if mir.is_a?(Array)
        mir.compact.each do |m|
          stamp_source_line!(m, line, col)
          result << m
        end
      else
        stamp_source_line!(mir, line, col)
        result << mir
      end
    }
    result
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

    T.must(prefix_lowered) + pending + T.must(suffix_lowered) + [MIR::BreakStmt.new(label, result_mir)]
  end

  # Lower a full program into MIR::Program with standard imports + footer.
  sig { params(node: AST::Program, use_c_allocator: T::Boolean, needs_safety: T::Boolean, use_debug_allocator: T::Boolean).returns(T.nilable(MIR::Program)) }
  def lower_program(node, use_c_allocator: false, needs_safety: false, use_debug_allocator: false)
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

    MIR::Program.new(items)
  end

  # Lower a module AST into MIR items for inlining via REQUIRE.
  # Emits only public declarations (types + functions + re-exports).
  # No standard imports or runtime footer -- the importing file provides those.
  #
  # Returns { items: [MIR nodes], type_items: [MIR type nodes] }
  sig { params(node: AST::Program).returns(T::Hash[Symbol, T::Array[T.untyped]]) }
  def lower_module(node)
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
    return :heap if node_is_heap?(node)
    # Binding-value position: an anonymous allocating expression has no
    # symbol of its own, so it inherits the enclosing binding's
    # allocator (set by with_decl_alloc). One allocator per binding.
    @decl_alloc == :heap ? :heap : :frame
  end

  # Run `blk` with @decl_alloc set to the allocator of the binding whose
  # value is being lowered. alloc_for_node / :node_storage read it so an
  # anonymous allocating sub-expression uses its binding's allocator.
  sig { params(alloc: T.nilable(Symbol), blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_decl_alloc(alloc, &blk)
    prev = @decl_alloc
    @decl_alloc = alloc
    begin
      blk.call
    ensure
      @decl_alloc = prev
    end
  end

  sig { params(callee_param: T.untyped).returns(T.nilable(Symbol)) }
  def takes_arg_alloc(callee_param)
    return @decl_alloc unless callee_param
    sym = callee_param.respond_to?(:symbol) ? callee_param.symbol : nil
    return :heap if sym&.heap_provenance? || sym&.storage == :heap
    raw_ti = callee_param.respond_to?(:type) ? callee_param.type : nil
    ti = Type.from_node!(raw_ti, context: "TAKES parameter allocator")
    return :heap if takes_param_needs_heap_cleanup?(ti)
    @decl_alloc || :heap
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def takes_param_needs_heap_cleanup?(ti)
    ti.recursive_cleanup_shape?(@schema_lookup)
  end

  sig { params(ti: Type, seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  def type_shape_needs_recursive_cleanup?(ti, seen = nil)
    ti.recursive_cleanup_shape?(@schema_lookup, seen)
  end

  # True when `node` is heap-placed. Symbol#storage is escape analysis's
  # definitive answer for any symbol-bearing node; anonymous expression
  # nodes (no binding) fall back to annotation-time node.storage.
  #
  # An Identifier's `.symbol` can lag behind the decl's symbol after
  # escape promotion -- resolve through `sym.reg.symbol` to the
  # authoritative decl-level entry.
  sig { params(node: T.untyped).returns(T::Boolean) }
  def node_is_heap?(node)
    return false unless node
    sym = node.respond_to?(:symbol) ? node.symbol : nil
    if sym
      decl = sym.respond_to?(:reg) ? sym.reg : nil
      auth = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
      return !!auth.heap_provenance?
    end
    !!(node.respond_to?(:storage) && node.storage == :heap)
  end


  sig { params(kind: Symbol, _rt_name: T.untyped).returns(Symbol) }
  def alloc_expr(kind, _rt_name = nil)
    kind == :heap ? :heap : :frame
  end

  sig { params(sym: Symbol).returns(Symbol) }
  def alloc_from_sym(sym)
    case sym
    when :heap  then :heap
    when :frame then :frame
    else :heap
    end
  end

  # Wrap a stdlib arg's emitted Zig in `@as(<declared_zig_type>, ...)` so the
  # template body can rely on a concrete type instead of comptime_int /
  # anytype. Bug 256 (`sleep(1)` -> `@bitCast(1)`) was caused by templates
  # consuming raw text that happened to be a comptime literal; coercing
  # at the boundary closes that whole class.
  #
  # `@as(T, x)` is a no-op when x is already T, so this is free for
  # already-typed args. We skip when the spec doesn't have a usable
  # declared type (Hash without :type, generic :Any, slice/collection
  # symbols whose Zig form is a runtime value rather than a literal-coercion
  # target).
  sig { params(arg_zig: String, spec: T.untyped).returns(String) }
  def coerce_stdlib_arg(arg_zig, spec)
    type_sym = spec.is_a?(Hash) ? spec[:type] : spec
    return arg_zig unless type_sym
    return arg_zig if type_sym == :Any
    # Numeric and Bool primitives are the cases templates consume as values
    # and where comptime_int / untyped slips through. String and collection
    # types are passed through Zig's existing slice / struct coercion and
    # don't need (and sometimes don't accept) an explicit `@as`.
    return arg_zig unless [:Int64, :Float64, :Int32, :Int16, :Int8,
                            :UInt64, :UInt32, :UInt16, :UInt8, :Bool].include?(type_sym)
    zig_t = Type.new(type_sym).zig_type rescue nil
    return arg_zig unless zig_t
    "@as(#{zig_t}, #{arg_zig})"
  end

  # Resolve a registry alloc symbol (:heap, :frame, :receiver_storage, :node_storage)
  # to a concrete :heap/:frame symbol. Used by InlineZig allocs field.
  sig { params(alloc_sym: Symbol, target_node: T.untyped, node: T.untyped).returns(Symbol) }
  def resolve_alloc_sym(alloc_sym, target_node = nil, node = nil)
    case alloc_sym
    when :heap  then :heap
    when :frame then :frame
    when :receiver_storage
      # The operation's allocator is the receiver binding's definitive
      # placement (Symbol#storage) -- one allocator per binding. No
      # type-shape override.
      needs_heap = node_is_heap?(target_node)
      # Resolve from the receiver's binding: Symbol#storage is escape
      # analysis's definitive placement. A nested mutation
      # (`root[i].field.append(x)`) inherits the ROOT container's
      # allocator -- the same root the MIR checker attributes the op to.
      needs_heap ||= if node.is_a?(AST::MethodCall)
        obj = node.object
        receiver_root_heap?(obj) || node_is_heap?(obj) ||
          # Pointer-passed `@list` parameter crosses a frame boundary;
          # force heap so the grown buffer outlives any frame mark.
          (obj.is_a?(AST::Identifier) && @current_fn_collection_params&.include?(obj.name))
      elsif node.mutates_receiver
        first = node.args&.first
        receiver_root_heap?(first) || node_is_heap?(first) ||
          (first.is_a?(AST::Identifier) && @current_fn_collection_params&.include?(first.name))
      end
      needs_heap ||= node_is_heap?(node)
      needs_heap ? :heap : :frame
    when :node_storage
      # A container-MUTATION method (append/...) allocates with the
      # receiver's allocator -- the effect lives in the receiver. A
      # VALUE-PRODUCING method (toList/toString/...) produces a fresh
      # result placed by its own binding (@decl_alloc), independent of
      # the receiver -- consulting the receiver wrongly forces heap when
      # the receiver happens to be heap (e.g. a range).
      if node.is_a?(AST::MethodCall) && node.object && node.mutates_receiver
        (receiver_root_heap?(node.object) || node_is_heap?(node.object) ||
         node_is_heap?(node) || @decl_alloc == :heap) ? :heap : :frame
      else
        (node_is_heap?(node) || @decl_alloc == :heap) ? :heap : :frame
      end
    else :heap
    end
  end

  # Shared by extract_root_var_name (checker attribution) and
  # receiver_root_heap? (allocator resolution); they must agree on the
  # root or an op's allocator diverges from its AllocMark.
  sig { params(node: T.untyped).returns(T.untyped) }
  def root_receiver_node(node)
    root = AST.root_identifier(node)
    return root if root
    node.respond_to?(:target) ? root_receiver_node(node.target) : nil
  end

  # A nested @list inside a heap container element is itself heap-
  # backed, so `root[i].field.append(x)` must use the root's allocator.
  sig { params(node: T.untyped).returns(T::Boolean) }
  def receiver_root_heap?(node)
    root = root_receiver_node(node)
    return false unless root.is_a?(AST::Identifier)
    # Symbol#storage is escape analysis's definitive placement; resolve
    # through the authoritative decl-level symbol.
    node_is_heap?(root)
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
    case kind
    when :heap    then "#{@rt_name}.heapAlloc()"
    when :frame   then "#{@rt_name}.frameAlloc()"
    else "#{@rt_name}.heapAlloc()"
    end
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

  # Resolve the stdlib alloc: symbol for an AllocMark from the FuncCall node's
  # matched_stdlib_def. Returns nil when not available (falls back to entry alloc).
  sig { params(node: AST::VarDecl).returns(T.nilable(Symbol)) }
  def resolve_decl_stdlib_alloc(node)
    val = node.value
    return nil unless val
    mdef = val.matched_stdlib_def
    return nil unless mdef.is_a?(Hash)
    case mdef[:alloc]
    when :heap, :frame then mdef[:alloc]
    when :node_storage
      val.respond_to?(:storage) && val.storage == :heap ? :heap : :frame
    end
  end

  # ================================================================
  # Old MIR translation (MATCH AS bindings still use Drop/Alloc)
  # ================================================================

  sig { params(node: MIR::Drop).returns(MIR::Cleanup) }
  def lower_drop(node)
    MIR::Cleanup.new(zig_safe_name(node.name), node.cleanup_entry)
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

  sig { params(node: AST::ListLit).returns(T.untyped) }
  def lower_list_lit(node)
    ti = node.coerced_type_info || node.full_type

    # Bounded stream: ~T[N] - emit BoundedStream struct with Promise items
    if ti.respond_to?(:bounded_stream?) && ti.bounded_stream?
      # BC backend: there's no Promise/BoundedStream runtime; with the
      # synchronous BG_SPAWN the items are already concrete values, so
      # treat the literal as a plain list. NEXT on the bound slot pops
      # the head via LIST_POP_FRONT (same as BG STREAM materialization).
      # The "__bc_stream__" sentinel elem_type lets the emitter mark
      # the binding's slot as a stream so NEXT routes via LIST_POP_FRONT.
      if @target == :bc
        items_mir_bc = node.items.map { |i| lower(i) }
        return MIR::MakeList.new("__bc_stream__", items_mir_bc, :frame)
      end

      @stream_lit_counter ||= T.let(0, T.nilable(Integer))
      s_id = @stream_lit_counter
      @stream_lit_counter += 1

      elem_zig = ti.stream_element_type.zig_type
      n = ti.stream_capacity
      promise_zig = "CheatLib.Promise(#{elem_zig})"
      stream_zig = ti.zig_type

      # PHASE-3: bounded-stream literal is emitted as InlineZig; item allocations
      # inside are invisible to the checker until this path is structured as MIR.
      promise_decls = node.items.each_with_index.map { |item, i|
        item_code = emit_expr(lower(item))
        "const __stream#{s_id}_item#{i} = #{item_code};"
      }.join("\n        ")

      items_list = (0...n).map { |i| "__stream#{s_id}_item#{i}" }.join(", ")

      code = "__stream#{s_id}: {\n" \
             "        #{promise_decls}\n" \
             "        break :__stream#{s_id} #{stream_zig}{\n" \
             "            .items = [#{n}]#{promise_zig}{ #{items_list} },\n" \
             "        };\n" \
             "    }"
      iz = MIR::InlineZig.new(code, "bounded_stream_init")
      iz.stdlib_def = { allocates: true }
      return iz
    end

    list_alloc = alloc_for_node(node)
    items_mir = node.items.map do |i|
      with_decl_alloc(list_alloc) { hoist_alloc(lower(i), i, err_cleanup: true) }
    end

    if ti.respond_to?(:fixed?) && ti.fixed? &&
       (node.storage == :stack || node.storage == :frame)
      # Raw fixed-size array (`T[N] = [...]`). Always lowers to a Zig
      # `[N]T{...}` literal regardless of CLEAR's storage classification:
      # the size > 128 slot threshold in finalize_storage promotes large
      # fixed-array literals to :frame, but for raw fixed-size arrays
      # there is no separate frame allocation -- the array data lives in
      # the function's own stack/frame either way, and Zig handles multi-
      # KB fixed arrays fine. Falling through to MakeList here would
      # produce an ArrayList whose Zig type doesn't match the variable's
      # declared `[N]T`, so the assignment fails to compile.
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      return MIR::ArrayInit.new(elem_zig, node.items.length.to_s, items_mir)
    end

    if node.items.empty?
      # Empty list: MIR expression depends on collection type
      if ti.respond_to?(:list_collection?) && ti.list_collection?
        zig_t = transpile_type(ti)
        return MIR::ContainerInit.new(zig_t, :list_empty, list_alloc, nil)
      end
      # Dynamic empty list: use makeList with empty items
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      return MIR::MakeList.new(elem_zig, [], list_alloc)
    end

    # Non-empty list literal -> makeList
    elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
    MIR::MakeList.new(elem_zig, items_mir, list_alloc)
  end

  sig { params(node: AST::HashLit).returns(T.untyped) }
  def lower_hash_lit(node)
    # HashMaps are always heap-allocated
    ti = node.coerced_type_info || node.full_type
    rt_name = @rt_name
    alloc_str = "#{rt_name}.heapAlloc()"

    # For Arc/Rc-wrapped maps, build bare inner type for init, then wrap
    is_arc = ti.shared?
    is_rc = ti.multiowned?
    if is_arc || is_rc
      # Sharded maps have their sync mode built into the Zig type
      # (e.g. MutexShardedStringMap), so they need the legacy direct-
      # composition path that preserves shard_count + sync on bare_ft.
      # Plain (non-sharded) maps go through compose_capability_wrap for
      # the unified Group 1 / Group 2 separation.
      if ti.striped?
        bare_ft = Type.new(ti.resolved.to_s)
        bare_ft.shard_count = ti.shard_count if ti.shard_count
        bare_ft.sync = ti.sync if ti.shard_count && ti.sync
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.map_init_needs_alloc?
        inner = if needs_alloc
          MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
        else
          MIR::StructInit.new(zig_t, [])
        end

        wrap_fn = is_arc ? "arcCreate" : "rcCreate"
        inner = MIR::Call.new("CheatLib.#{wrap_fn}", [MIR::Ident.new(zig_t), MIR::Ident.new(alloc_str), inner], true)
        return inner if node.pairs.empty?
      else
        bare_ft = ti.bare_data_type
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.respond_to?(:map_init_needs_alloc?) ? bare_ft.map_init_needs_alloc? :
                      (!zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType"))
        inner = if needs_alloc
          MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
        else
          MIR::StructInit.new(zig_t, [])
        end

        wrapped = compose_capability_wrap(inner, zig_t, ti, :heap)
        return wrapped if node.pairs.empty?
        inner = wrapped
      end
    end

    zig_t = transpile_type(ti)

    if node.pairs.empty?
      # PartitionedStringMap, PartitionedNumericMap, and NumericMapType don't have an .alloc field
      needs_alloc = !zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType")
      strategy = needs_alloc ? :map_bare : :map_empty
      # Numeric maps are frame-allocated; string maps are heap-allocated.
      map_alloc = (ti.respond_to?(:numeric_map?) && ti.numeric_map?) ? :frame : :heap
      return MIR::ContainerInit.new(zig_t, strategy, map_alloc, nil)
    end

    # Non-empty hash: init + puts
    items = []
    alloc_expr = MIR::MethodCall.new(MIR::Ident.new(rt_name), "heapAlloc", [], false)
    items << MIR::Let.new("__hm", MIR::StructInit.new(zig_t, [{ name: "alloc", value: alloc_expr }]), true, nil, nil)
    node.pairs.each do |key_node, val_node|
      k = lower(key_node)
      v = lower(val_node)
      put_call = MIR::MethodCall.new(MIR::Ident.new("__hm"), "put", [alloc_expr, alloc_expr, k, v], true)
      items << MIR::ExprStmt.new(put_call, false)
    end
    items << MIR::BreakStmt.new("__hm_blk", MIR::Ident.new("__hm"))
    MIR::BlockExpr.new("__hm_blk", items)
  end

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
        { consumes: [], produces: [], borrows: [] })

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
    MIR::Call.new("std.debug.print", [format_lit, tuple], false)
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
    tc = MIR::TryCatch.new(strip_try(left), catch_body, capture)
    tc.heap_provenance = mir_allocates?(left) || (!!fallback && mir_allocates?(fallback))
    tc
  end

  sig { params(mir_node: T.untyped).returns(T.untyped) }
  def strip_try(mir_node)
    case mir_node
    when MIR::Call
      MIR::Call.new(mir_node.callee, mir_node.args, false, mir_node.heap_provenance)
    when MIR::MethodCall
      MIR::MethodCall.new(mir_node.receiver, mir_node.method, mir_node.args, false)
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

  sig { params(value: T.untyped, ast_node: T.untyped, sink_alloc: Symbol).returns(T.untyped) }
  def materialize_owned_sink_value(value, ast_node, sink_alloc)
    return value unless ast_node
    ti = Type.from_node!(ast_node, context: "owned sink materialization")

    if ti.string?
      return value if owned_sink_value?(value, ast_node)
      return MIR::DupeSlice.new(value, sink_alloc)
    end

    return value unless borrowed_union_sink_value?(ast_node, ti)
    zig_t = bare_zig_type(ti)
    emit_builtin(:dupeUnionValue, [MIR::Ident.new(zig_t), value, MIR::Ident.new(alloc_zig_str(sink_alloc))])
  end

  sig { params(value: T.untyped, ast_node: T.untyped).returns(T::Boolean) }
  def owned_sink_value?(value, ast_node)
    return true if ast_node.is_a?(AST::MoveNode) || ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return true if ast_node.respond_to?(:heap_provenance?) && ast_node.heap_provenance?
    return true if node_is_heap?(ast_node)
    return true if mir_allocates?(value)
    false
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
    return false if value_node.is_a?(AST::MoveNode)
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
