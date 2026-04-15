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

require_relative "mir"
require_relative "../ast/ast"
require_relative "../ast/type"
require_relative "../backends/zig_type_mapper"

class MIRLowering
  include ZigTypeMapper

  ZIG_PRIMITIVE_RE = /\A[uif]\d+\z/

  attr_reader :fn_sigs
  attr_accessor :shard_context

  def initialize(struct_schemas: {}, enum_schemas: {}, union_schemas: {},
                 fn_sigs: {}, moved_guard_info: {},
                 pipeline_fallback: nil, importer: nil, source_dir: nil,
                 debug_mode: false)
    @struct_schemas = struct_schemas || {}
    @enum_schemas = enum_schemas || {}
    @union_schemas = union_schemas || {}
    @fn_sigs = fn_sigs || {}
    @moved_guard_info = moved_guard_info || {}
    @rt_name = "rt"
    @shard_context = nil  # { map: "varname", idx: "__sh0_sh.shard", key: "__sh0_key" }
    @emitted_extern_modules = Set.new
    @block_expr_counter = 0
    @indirect_fields = {}
    @pipeline_fallback = pipeline_fallback
    @pipeline_host = nil
    @importer = importer
    @source_dir = source_dir
    @emitted_types = Set.new
    @debug_mode = debug_mode
    @pending_stmts = []
    @tmp_counter = 0
    @current_bindings = {}  # set per-function by lower_function_def from fn.cleanup_bindings
  end

  # Flush and return all pending hoisted Let statements accumulated since the
  # last flush. Called by lower_body before appending the main statement so
  # hoisted Lets precede the statement that uses them.
  def flush_pending
    stmts = @pending_stmts
    @pending_stmts = []
    stmts
  end

  # Returns true when an MIR expression node performs a HEAP allocation.
  # Used by hoist_alloc to decide whether to hoist to a named Let.
  #
  # Frame allocations are intentionally excluded: they're ephemeral (cleaned
  # up by frame mark/rewind) and don't need cleanup tracking. Only heap
  # allocations require hoisting so the checker can verify their cleanup paths.
  def mir_allocates?(node)
    case node
    when MIR::DupeSlice    then node.alloc == :heap
    when MIR::AllocSlice   then node.alloc == :heap
    when MIR::MakeList     then node.alloc == :heap
    when MIR::HeapCreate   then true  # always heap by definition
    when MIR::CapWrap      then node.alloc == :heap
    when MIR::DeepCopy     then node.alloc == :heap
    when MIR::ConcatStr    then node.alloc == :heap
    when MIR::ContainerInit
      node.alloc == :heap
    when MIR::Call
      node.heap_provenance ? true : false
    when MIR::Cast
      # Cast is a type coercion wrapper with no allocation of its own.
      # Delegate to the wrapped expression.
      mir_allocates?(node.expr)
    when MIR::InlineZig
      # Only hoist if the node heap-allocates (stdlib_def allocates: true AND
      # allocs contains a :heap entry -- frame-only intrinsics are excluded).
      return false unless node.stdlib_def&.dig(:allocates)
      return true unless node.allocs
      node.allocs.any? { |_k, v| v == :heap }
    else
      false
    end
  end

  # If expr allocates, hoist it to a named Let (pushed to @pending_stmts)
  # and return an Ident pointing to it. Otherwise return expr unchanged.
  # ast_node: the original AST node for type info (used to compute cleanup entry).
  # err_cleanup: true => emit ErrCleanup (ownership transfers on success; only clean
  #   up on error). Use when the value is consumed by a TAKES arg, a struct/union
  #   field init, or any position where the receiver takes ownership on success.
  #   false (default) => emit Cleanup (defer; freed on all paths).
  def hoist_alloc(expr, ast_node = nil, err_cleanup: false)
    return expr unless mir_allocates?(expr)
    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    @pending_stmts << MIR::AllocMark.new(name, :heap)
    @pending_stmts << MIR::Let.new(name, expr, false, nil, nil)
    entry = hoist_cleanup_entry(expr, ast_node)
    if entry
      cleanup = err_cleanup ? MIR::ErrCleanup.new(name, entry) : MIR::Cleanup.new(name, entry)
      @pending_stmts << cleanup
    end
    MIR::Ident.new(name)
  end

  # Synthesize a cleanup plan entry for a hoisted temp.
  # Returns nil if the cleanup cannot be determined statically.
  def hoist_cleanup_entry(mir, ast_node)
    case mir
    when MIR::DupeSlice, MIR::ConcatStr
      { kind: :heap_string, alloc: :heap, has_moved_guard: false }
    when MIR::AllocSlice
      { kind: :takes_slice, alloc: :heap, has_moved_guard: false, elem_zig_type: mir.elem_type }
    when MIR::MakeList
      zig_type = "std.ArrayListUnmanaged(#{mir.elem_type})"
      { kind: :list, alloc: :heap, has_moved_guard: false, zig_type: zig_type }
    when MIR::HeapCreate
      { kind: :heap_struct_plain, alloc: :heap, has_moved_guard: false, zig_type: mir.zig_type }
    when MIR::ContainerInit
      { kind: :list, alloc: :heap, has_moved_guard: false, zig_type: mir.zig_type }
    when MIR::DeepCopy
      case mir.strategy
      when :string
        { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      when :list_shallow, :list_deep
        { kind: :takes_slice, alloc: :heap, has_moved_guard: false, elem_zig_type: mir.elem_type }
      when :union
        { kind: :non_copy_union, alloc: :heap, has_moved_guard: false, zig_type: mir.zig_type }
      else
        raise "hoist_cleanup_entry: MIR::DeepCopy with unknown strategy :#{mir.strategy} -- " \
              "mir_allocates? returned true but no cleanup entry defined. Add a case."
      end
    when MIR::CapWrap
      # CapWrap creates an Rc/Arc/Locked/RwLocked wrapper on the heap.
      if mir.sync_fn
        kind = mir.sync_fn == "rwLockedCreate" ? :write_locked : :locked
        { kind: kind, alloc: :heap, has_moved_guard: false, zig_type: mir.sync_type }
      elsif mir.own_fn
        ti = ast_node.respond_to?(:type_info) ? (ast_node.type_info rescue nil) : nil
        ti = ti.is_a?(Type) ? ti : nil
        zig_t = ti&.zig_type
        raise "hoist_cleanup_entry: MIR::CapWrap (own_fn=#{mir.own_fn}) has no zig_type -- " \
              "ast_node type_info unavailable" unless zig_t
        { kind: :rc, alloc: :heap, has_moved_guard: false, zig_type: zig_t,
          rc_variant: :standard, rc_alloc: :heap }
      else
        # :passthrough / :local -- inner value passes through; no additional cleanup.
        nil
      end
    when MIR::Cast
      # Cast is a transparent wrapper; the cleanup is the same as the inner expr.
      hoist_cleanup_entry(mir.expr, ast_node)
    when MIR::Call
      ti = ast_node.respond_to?(:type_info) ? (ast_node.type_info rescue nil) : nil
      ti = ti.is_a?(Type) ? ti : nil
      return nil unless ti
      ti = ti.payload_type || ti if ti.respond_to?(:error_union?) && ti.error_union?
      if ti.respond_to?(:string?) && ti.string?
        { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      else
        resolved = ti.respond_to?(:resolved) ? ti.resolved : nil
        return nil unless resolved
        zig_t = (Type.new(resolved).zig_type rescue nil)
        return nil unless zig_t
        { kind: :non_copy_union, alloc: :heap, has_moved_guard: false, zig_type: zig_t }
      end
    else
      raise "hoist_cleanup_entry: unhandled allocating MIR node #{mir.class} -- " \
            "mir_allocates? returned true but no cleanup entry is defined. Add a case."
    end
  end

  # Lower an AST node (or old MIR node) into a new MIR node.
  def lower(node)
    case node

    # --- Top-level ---
    when AST::Program           then lower_program(node)

    # --- Old MIR nodes (from MIRPass) -> new MIR nodes ---
    when MIR::Drop              then lower_drop(node)
    when MIR::Promote           then lower_promote(node)
    when MIR::SuppressCleanup   then MIR::MoveMark.new(zig_safe_name(node.name))
    when MIR::Alloc             then MIR::AllocMark.new(node.name, node.alloc)
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
    when AST::WhileLoop         then lower_while(node)
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
    when AST::CapabilityWrap    then lower_cap_wrap(node)
    when AST::LinkNode          then lower_link(node)
    when AST::ResolveNode       then lower_resolve(node)
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
      raise "MIRLowering: unhandled node type #{node.class} at #{node.respond_to?(:token) && node.token ? "line #{node.token.line}" : 'unknown'}"
    end.tap { |mir|
      # Apply type coercion (int->float, float->int, etc.) when AST node has coerced_type
      if mir && node.respond_to?(:coerced_type) && node.coerced_type &&
         node.respond_to?(:full_type) && node.full_type &&
         node.coerced_type != node.full_type
        # Skip coercion for stack-allocated fixed-size arrays (SROA)
        skip = node.is_a?(AST::ListLit) && node.storage == :stack &&
               (node.respond_to?(:coerced_type_info) ? node.coerced_type_info : node.type_info)&.fixed?
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
  def lower_body(stmts)
    return [] unless stmts
    result = []
    stmts.each { |s|
      mir = lower(s)
      pending = flush_pending
      next unless mir
      # Non-void function-like expressions used as statements need explicit discard (_ =)
      needs_discard = (s.is_a?(AST::FuncCall) || s.is_a?(AST::MethodCall)) ||
                      (s.is_a?(AST::BinaryOp) && (s.op == :OR_RESCUE || s.op == :PIPE_ERR))
      if needs_discard &&
         s.respond_to?(:resolved_type) && s.resolved_type && s.resolved_type != :Void
        mir = MIR::ExprStmt.new(mir, true)
      end
      result.concat(pending)
      # Inject source map comment for this user-visible statement.
      # Placed after pending (hoisted synthetic temps have no user source line).
      line = s.respond_to?(:token) && s.token ? s.token.line : nil
      result << MIR::Comment.new("CLR:#{line}") if line
      # lower_var_decl may return [AllocMark, Let, Cleanup] when the binding needs cleanup.
      if mir.is_a?(Array)
        result.concat(mir.compact)
      else
        result << mir
      end
    }
    result
  end

  def statement_node?(node)
    node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr) ||
    node.is_a?(AST::Assignment) ||
    node.is_a?(AST::IfStatement) || node.is_a?(AST::WhileLoop) ||
    node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach) ||
    node.is_a?(AST::MatchStatement) || node.is_a?(AST::ReturnNode) ||
    node.is_a?(AST::BreakNode) || node.is_a?(AST::ContinueNode) ||
    node.is_a?(AST::WithBlock) || node.is_a?(AST::BgBlock) ||
    node.is_a?(AST::BgStreamBlock) || node.is_a?(AST::DoBlock) ||
    node.is_a?(AST::FunctionDef) || node.is_a?(AST::StructDef) ||
    node.is_a?(AST::EnumDef) || node.is_a?(AST::UnionDef) ||
    node.is_a?(AST::TestBlock) || node.is_a?(AST::RequireNode) ||
    node.is_a?(AST::ExternFnDecl) || node.is_a?(AST::ExternStructDecl) ||
    node.is_a?(AST::StubDecl) || node.is_a?(AST::PassStmt) ||
    node.is_a?(AST::ThrowNode) || node.is_a?(AST::DieNode) ||
    node.is_a?(AST::Raise) || node.is_a?(AST::AssertRaises) ||
    node.is_a?(AST::BenchmarkStmt) || node.is_a?(AST::SmashStmt) ||
    node.is_a?(AST::ProfileStmt) ||
    node.is_a?(MIR::Drop) || node.is_a?(MIR::Promote) ||
    node.is_a?(MIR::SuppressCleanup) || node.is_a?(MIR::Alloc) ||
    node.is_a?(MIR::Return) || node.is_a?(MIR::ReassignCleanup) ||
    node.is_a?(MIR::FieldCleanup)
  end

  # Lower a full program into MIR::Program with standard imports + footer.
  def lower_program(node, use_c_allocator: false, needs_safety: false)
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

    # Lower each statement, adding source line comments
    node.statements.each do |stmt|
      lowered = lower(stmt)
      next unless lowered
      line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
      # Some lowerings (e.g. union with helpers) return arrays of nodes
      nodes = lowered.is_a?(::Array) ? lowered : [lowered]
      nodes.each_with_index do |n, i|
        items << MIR::Comment.new("CLR:#{line}") if line && i == 0
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
  def lower_module(node)
    type_items = []
    fn_items = []

    node.statements.each do |stmt|
      case stmt
      when AST::FunctionDef
        next if stmt.visibility == :private
        lowered = lower(stmt)
        next unless lowered
        line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          fn_items << MIR::Comment.new("CLR:#{line}") if line && i == 0
          fn_items << n
        end
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        next if stmt.visibility == :private
        lowered = lower(stmt)
        next unless lowered
        line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          type_items << MIR::Comment.new("CLR:#{line}") if line && i == 0
          type_items << n
        end
      when AST::RequireNode
        lowered = lower(stmt)
        next unless lowered
        (lowered.is_a?(::Array) ? lowered : [lowered]).each { |n| fn_items << n }
      when AST::ExternFnDecl, AST::ExternStructDecl
        lowered = lower(stmt)
        next unless lowered
        line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
        nodes = lowered.is_a?(::Array) ? lowered : [lowered]
        nodes.each_with_index do |n, i|
          fn_items << MIR::Comment.new("CLR:#{line}") if line && i == 0
          fn_items << n
        end
      end
    end

    { items: type_items + fn_items, type_items: type_items }
  end

  private

  # ================================================================
  # Name and type helpers
  # ================================================================

  def zig_safe_name(name)
    cleaned = (name.end_with?('!') || name.end_with?('?')) ? name[0..-2] : name
    cleaned = "clearMain" if cleaned == "main"
    cleaned =~ ZIG_PRIMITIVE_RE ? "@\"#{cleaned}\"" : cleaned
  end

  def alloc_for_node(node)
    (node.respond_to?(:storage) && node.storage == :heap) ? :heap : :frame
  end


  def alloc_expr(kind, _rt_name = nil)
    kind == :heap ? :heap : :frame
  end

  def alloc_from_sym(sym)
    case sym
    when :heap  then :heap
    when :frame then :frame
    else :heap
    end
  end

  # Resolve a registry alloc symbol (:heap, :frame, :receiver_storage, :node_storage)
  # to a concrete :heap/:frame symbol. Used by InlineZig allocs field.
  def resolve_alloc_sym(alloc_sym, receiver_type = nil, target_node = nil, node = nil)
    case alloc_sym
    when :heap  then :heap
    when :frame then :frame
    when :receiver_storage
      needs_heap = receiver_type&.needs_heap_backing?
      needs_heap ||= (target_node.respond_to?(:storage) && target_node.storage == :heap)
      # For method calls, check the receiver object's storage (e.g., parts.append -> parts.storage).
      # Also check the declaration node (symbol.reg) in case Phase 2.5 heap-promoted the container
      # after the Identifier was annotated (Identifier.storage may be stale).
      needs_heap ||= if node.is_a?(AST::MethodCall)
        obj = node.object
        (obj.respond_to?(:storage) && obj.storage == :heap) ||
          (obj.respond_to?(:symbol) && obj.symbol&.reg.respond_to?(:storage) && obj.symbol.reg.storage == :heap)
      elsif node.respond_to?(:mutates_receiver) && node.mutates_receiver
        first = node.args&.first
        (first&.respond_to?(:storage) && first.storage == :heap) ||
          (first.respond_to?(:symbol) && first&.symbol&.reg.respond_to?(:storage) && first.symbol.reg.storage == :heap)
      end
      needs_heap ||= (node.respond_to?(:storage) && node.storage == :heap)
      needs_heap ? :heap : :frame
    when :node_storage
      storage = node.respond_to?(:storage) ? node.storage : nil
      storage == :heap ? :heap : :frame
    else :heap
    end
  end

  # Extract root variable name from a potentially nested AST node (e.g., pool[id]?.vars).
  def extract_root_var_name(node)
    case node
    when AST::Identifier then node.name.to_s
    when AST::GetField   then extract_root_var_name(node.target)
    when AST::GetIndex   then extract_root_var_name(node.target)
    else
      node.respond_to?(:target) ? extract_root_var_name(node.target) : nil
    end
  end

  # Resolve allocator symbol to Zig string (for InlineZig/RawZig patterns only).
  def alloc_zig_str(kind)
    case kind
    when :heap    then "#{@rt_name}.heapAlloc()"
    when :frame   then "#{@rt_name}.frameAlloc()"
    when :cleanup then "#{@rt_name}.cleanupAlloc()"
    else "#{@rt_name}.heapAlloc()"
    end
  end

  # Produce a MIR::Cast node for type coercion, or nil if no cast needed.
  # Mirrors transpile_cast logic but returns MIR nodes instead of strings.
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

  # Pre-compute zig_type, elem_zig_type, is_fixed into the cleanup entry hash.
  # Mutates entry in-place. Called by lower_var_decl and lower_function_def
  # (TAKES params) to avoid deferring type resolution to the emitter.
  def build_drop_entry!(entry, ti, source_node)
    ti = Type.new(ti) if ti && !ti.is_a?(Type)

    zig_type = case entry[:kind]
    when :heap_slice
      is_bare = source_node.respond_to?(:value) && source_node.value.is_a?(AST::CopyNode) && !ti&.list_collection?
      if is_bare
        elem = ti&.element_type ? Type.new(ti.element_type).zig_type : "UNKNOWN"
        "[]#{elem}"
      else
        ti&.zig_type
      end
    when :list, :list_with_elem_cleanup, :string_map, :numeric_map, :set, :fixed_soa
      ti&.zig_type
    when :heap_union, :heap_struct, :locked, :write_locked, :always_mutable,
         :struct_with_cleanup_fields, :struct_rc, :non_copy_union, :takes_union
      Type.new((ti&.resolved || :Any).to_s).zig_type
    when :rc
      ti&.zig_type
    end

    elem_zig = case entry[:kind]
    when :list_with_elem_cleanup, :takes_slice
      et = ti&.element_type
      if et
        t = et.is_a?(Type) ? et : Type.new(et)
        t.zig_type
      end
    when :array_with_struct_strings
      ti&.element_type ? Type.new(ti.element_type).zig_type : nil
    end

    entry[:zig_type] = zig_type || entry[:zig_type] || "UNKNOWN"
    entry[:elem_zig_type] = elem_zig || entry[:elem_zig_type]
    entry[:is_fixed] = ti&.fixed? if entry[:kind] == :array_with_struct_strings
  end

  # Resolve the stdlib alloc: symbol for an AllocMark from the FuncCall node's
  # matched_stdlib_def. Returns nil when not available (falls back to entry alloc).
  def resolve_decl_stdlib_alloc(node)
    val = node.respond_to?(:value) ? node.value : nil
    return nil unless val
    mdef = val.respond_to?(:matched_stdlib_def) ? val.matched_stdlib_def : nil
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

  def lower_drop(node)
    MIR::Cleanup.new(zig_safe_name(node.name), node.cleanup_entry)
  end

  def lower_promote(node)
    MIR::EscapePromote.new(
      node.name ? zig_safe_name(node.name) : node.name,
      node.zig_type,
      node.strategy,
      node.fields,
      @rt_name
    )
  end

  # ================================================================
  # Type definitions
  # ================================================================

  def lower_enum_def(node)
    @enum_schemas[node.name.to_sym] = node.variants
    MIR::EnumDef.new(node.name, node.variants.map(&:to_s), nil)
  end

  def lower_struct_def(node)
    @struct_schemas[node.name.to_sym] = node.fields

    if node.type_params&.any?
      # Generic struct: fn Name(comptime T: type) type { return struct { ... }; }
      comptime_params = node.type_params.map { |p| "comptime #{p}: type" }
      fields_mir = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      inner_struct = MIR::StructDef.new(nil, fields_mir, nil, nil)
      body = [MIR::ReturnStmt.new(inner_struct)]
      MIR::FnDef.new(node.name, [], "type", body, nil, false, comptime_params)
    else
      fields = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  def lower_union_def(node)
    @union_schemas[node.name.to_sym] = node.variants

    # Track @indirect fields
    node.variants.each do |var_name, var_data|
      next unless var_data.is_a?(Hash) && var_data[:indirect_fields]
      var_data[:indirect_fields].each do |fname|
        @indirect_fields["#{node.name}_#{var_name}.#{fname}"] = true
      end
    end

    # Emit helper structs for inline struct variants
    helper_structs = node.variants.filter_map do |var_name, var_data|
      next unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      indirect = var_data[:indirect_fields] || Set.new
      fields = var_data[:fields].map { |fname, ftype|
        zig_t = transpile_type(ftype, is_field: true)
        zig_t = "*#{zig_t}" if indirect.include?(fname)
        MIR::FieldDef.new(fname.to_s, zig_t, nil)
      }

      deinit_lines = (var_data[:deinit_entries] || []).flat_map { |de|
        case de[:kind]
        when :indirect
          ["        CheatLib.cleanup(#{de[:zig_type]}, alloc, self.#{de[:field]});",
           "        alloc.destroy(self.#{de[:field]});"]
        when :array
          ["        if (comptime CheatLib.needsCleanup(#{de[:elem_zig_type]})) { for (self.#{de[:field]}) |*__e| { CheatLib.cleanup(#{de[:elem_zig_type]}, alloc, __e); } }",
           "        if (self.#{de[:field]}.len > 0) alloc.free(self.#{de[:field]});"]
        else []
        end
      }

      methods = if deinit_lines.any?
        body = deinit_lines.join("\n")
        deinit_fn = MIR::RawZig.new(
          "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n#{body}\n    }",
          "union_inline_struct_deinit",
          { consumes: [], produces: [], borrows: [] }
        )
        [deinit_fn]
      end

      MIR::StructDef.new("#{node.name}_#{var_name}", fields, methods, nil)
    end

    # Build variant list
    variants = node.variants.map { |var_name, var_data|
      zig_t = if var_data.nil?
        "void"
      elsif var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
        "#{node.name}_#{var_name}"
      elsif var_data.is_a?(Hash) && var_data[:kind] == :indirect_payload
        "*#{transpile_type(var_data[:type], is_field: true)}"
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

  # Quick inline emit for struct defs used as union helpers.
  def emit_struct_def_inline(sdef)
    fields = sdef.fields.map { |f| "    #{f.name}: #{f.zig_type}," }.join("\n")
    methods = (sdef.methods || []).map { |m|
      m.is_a?(MIR::RawZig) ? "\n    #{m.code}" : ""
    }.join
    "const #{sdef.name} = struct {\n#{fields}#{methods}\n};"
  end

  def emit_union_inline(udef)
    fields = udef.variants.map { |v| "    #{v[:name]}: #{v[:zig_type]}," }.join("\n")
    "const #{udef.name} = union(enum) {\n#{fields}\n};"
  end

  def lower_extern_fn(node)
    mod = node.from_module
    if @emitted_extern_modules.add?(mod)
      mod_parts = mod.split(".")
      import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
      mod_alias = mod.gsub(".", "_")
      module_path = mod_parts.first == "std" ? mod_parts.first : "#{mod_parts.first}.zig"
      MIR::Import.new(mod_alias, module_path, mod_parts.length > 1 ? mod_parts[1..].join(".") : nil)
    else
      MIR::Noop.new("extern_fn_import_already_emitted")
    end
  end

  def lower_extern_struct(node)
    if node.from_module
      mod = node.from_module
      mod_parts = mod.split(".")
      mod_alias = mod.gsub(".", "_")

      items = []
      if @emitted_extern_modules.add?(mod)
        member_chain = mod_parts[1..].any? ? mod_parts[1..].join(".") : nil
        module_path = mod_parts.first == "std" ? mod_parts.first : "#{mod_parts.first}.zig"
        items << MIR::Import.new(mod_alias, module_path, member_chain)
      end
      # AS "ZigTypeExpr" allows aliasing to parameterized types like Parsed(JsonRecord).
      zig_rhs = node.as_type ? "#{mod_alias}.#{node.as_type}" : "#{mod_alias}.#{node.name}"
      items << MIR::TypeAlias.new(node.name, zig_rhs)
      items.length == 1 ? items.first : items
    elsif node.fields.empty?
      MIR::Noop.new("empty_local_extern_struct")
    else
      fields = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  # Minimal emit for combining multi-node results.
  def emit_item(node)
    case node
    when MIR::RawZig then node.code
    when MIR::TypeAlias then "const #{node.name} = #{node.target};"
    when MIR::Import
      base = "@import(\"#{node.module_path}\")"
      base = "#{base}.#{node.member}" if node.member
      "const #{node.alias_name} = #{base};"
    else node.to_s
    end
  end

  # ================================================================
  # Functions
  # ================================================================

  def lower_function_def(node)
    ret_type = node.return_type || :Void
    if ret_type.is_a?(Type) && ret_type.frame? && ret_type.struct?
      ret_type = Type.new(ret_type.resolved)
    end
    final_type = transpile_type(ret_type)

    fn_needs_rt = node.needs_rt.nil? ? true : node.needs_rt
    fn_can_fail = node.can_fail.nil? ? true : node.can_fail
    @current_fn_has_rt = fn_needs_rt
    @current_fn_tail_call = node.tail_call
    @current_fn_zig_name = zig_safe_name(node.name)

    # Set current bindings so lower_var_decl can look up cleanup info.
    @current_bindings = node.cleanup_bindings || {}

    # Mutable scalar params: Zig params are const, need shadow vars
    mutable_scalar_params = (node.params || []).select { |p|
      p[:mutable] && !transpile_type(p[:type], is_param: true).start_with?("[]", "*")
    }.map { |p| p[:name] }.to_set

    # Collection params: already passed by pointer, skip & at recursive call sites
    @current_fn_collection_params = (node.params || []).select { |p|
      p_type_obj = p[:type].is_a?(Type) ? p[:type] : Type.new(p[:type] || :Any)
      p_type_obj.needs_pointer_passing?
    }.map { |p| p[:name] }.to_set

    # All param names: used to distinguish params (slices) from locals (ArrayLists)
    @current_fn_param_names = (node.params || []).map { |p| p[:name] }.to_set

    # Build param list
    params_mir = (node.params || []).map { |param|
      p_name = mutable_scalar_params.include?(param[:name]) ? "_m_#{param[:name]}" : param[:name]
      p_type_sym = param[:type].is_a?(Type) ? param[:type].resolved : param[:type]
      p_type_obj = param[:type].is_a?(Type) ? param[:type] : Type.new(param[:type] || :Any)
      is_user_struct = @struct_schemas&.key?(p_type_sym)
      zig_t = if is_user_struct
        "anytype"
      elsif p_type_obj.collection?
        "anytype"
      else
        transpile_type(param[:type], is_param: true)
      end
      MIR::Param.new(p_name, zig_t)
    }

    # Prepend rt param
    if fn_needs_rt
      params_mir.unshift(MIR::Param.new("rt", "*Runtime"))
    end

    # Comptime params
    comptime_params = (node.type_params || []).map { |tp| "comptime #{tp}: type" }

    # Build return type string. The error prefix is baked into the string,
    # so can_fail on MIR::FnDef is always false (emitter would double it).
    return_type_str = if fn_can_fail
      if final_type.start_with?("!")
        final_type
      elsif node.reentrant == :reentrant
        "anyerror!#{final_type}"
      else
        "!#{final_type}"
      end
    else
      final_type
    end

    vis = (node.visibility == :pub) ? :pub : :private

    # Determine used names for param suppression
    used_names = collect_identifier_names(node.body)

    # Build prologue statements
    prologue = []

    # Frame mark save/restore.
    # uses_frame from annotation is stale for vars upgraded frame->heap by MIRPass
    # (upgrade_always_escaped_to_heap!, upgrade_bg_captures_to_heap!, etc.).
    # When cleanup_bindings is set (post-MIRPass), derive from it: it reflects the
    # post-upgrade allocators. Fall back to uses_frame when cleanup_bindings is absent
    # (synthetic functions, specs). uses_alloc tracks stdlib frame calls (append,
    # concat) which are not in cleanup_bindings and are always accurate.
    has_frame_bindings = if node.cleanup_bindings
                           node.cleanup_bindings.any? { |_, e| e[:alloc] == :frame }
                         else
                           node.uses_frame
                         end
    uses_frame_or_alloc = has_frame_bindings || node.uses_alloc
    ret_type_obj = node.return_type.is_a?(Type) ? node.return_type : Type.new(node.return_type || :Void)
    returns_value_type = ret_type_obj.void? || ret_type_obj.primitive? || ret_type_obj.resource? ||
                         @enum_schemas&.key?(ret_type_obj.resolved) ||
                         @union_schemas&.key?(ret_type_obj.resolved)
    returns_string = ret_type_obj.string? || (ret_type_obj.error_union? && ret_type_obj.payload_type&.string?)
    has_promotion = node.has_promotion

    heap_carry_return = node.respond_to?(:heap_carry_return) && node.heap_carry_return
    if fn_needs_rt
      prologue << MIR::ExprStmt.new(MIR::Call.new("@setEvalBranchQuota", [MIR::Lit.new("100000")], false), false)
      # FrameRestore is safe only when the return value is NOT frame-allocated:
      #   - value types (primitives, enums): no frame pointer returned
      #   - heap carry return strings: result is on heap, frame rewind is safe
      # For frame-string returns (no heap_carry_return), we skip the mark/restore
      # entirely: the returned string lives in the caller's frame region.
      if uses_frame_or_alloc && (returns_value_type || (returns_string && heap_carry_return)) && !has_promotion
        prologue << MIR::FrameSave.new(@rt_name)
        prologue << MIR::FrameRestore.new(@rt_name)
      else
        prologue << MIR::Suppress.new("rt")
      end
    end

    # NonReentrant guard
    if node.reentrant == :non_reentrant
      guard_init = MIR::Let.new("_guard",
        MIR::TryExpr.new(MIR::Call.new("safety.StackGuard.enter", [MIR::Call.new("@src", [], false)], false)),
        true, nil, nil)
      guard_push = MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("_guard"), "push", [], false), false)
      guard_defer = MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("_guard"), "pop", [], false))
      prologue.unshift(guard_defer)
      prologue.unshift(guard_push)
      prologue.unshift(guard_init)
    end

    # Param suppressions for unused params
    (node.params || []).each do |p|
      next if used_names.include?(p[:name])
      suppress_name = mutable_scalar_params.include?(p[:name]) ? "_m_#{p[:name]}" : p[:name]
      prologue << MIR::Suppress.new(suppress_name)
    end

    # Mutable scalar param shadows
    mutable_scalar_params.each do |name|
      next unless used_names.include?(name)
      prologue << MIR::Let.new(name, MIR::Ident.new("_m_#{name}"), true, nil, "_ = &#{name};")
    end

    # Emit AllocMark + Cleanup for TAKES parameters (replaces insert_takes_drops! from MIRPass).
    # TAKES params own their value from function entry; cleanup is always defer (Cleanup, not ErrCleanup).
    takes_mir = []
    (node.params || []).select { |p| p[:takes] }.each do |p|
      entry = @current_bindings[p[:name].to_s]
      next unless entry && entry[:needs_cleanup]
      ti = p[:type].is_a?(Type) ? p[:type] : Type.new(p[:type] || :Any)
      drop_entry = entry.dup
      build_drop_entry!(drop_entry, ti, nil)
      takes_mir << MIR::AllocMark.new(p[:name].to_s, entry[:alloc])
      takes_mir << MIR::Cleanup.new(zig_safe_name(p[:name].to_s), drop_entry)
    end

    # Lower body (track snapshot types for catch blocks)
    has_catch = node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
    @current_fn_has_catch = has_catch
    @current_fn_snapshot_types = Set.new if has_catch
    body_mir = takes_mir + lower_body(node.body)

    if has_catch
      # Emit inner/outer function pair
      inner_name = "__#{node.name}_body"
      inner_ret = fn_can_fail ? "anyerror!#{final_type}" : "!#{final_type}"

      inner_fn = MIR::FnDef.new(inner_name, params_mir, inner_ret,
                                 prologue + body_mir, :private, false, comptime_params)

      # Outer function: calls inner, catches errors
      call_args = fn_needs_rt ? ["rt"] + (node.params || []).map { |p| p[:name] } : (node.params || []).map { |p| p[:name] }
      inner_call = "#{inner_name}(#{call_args.join(', ')})"

      catch_zig, catch_clause_bodies = build_catch_clauses(node, fn_can_fail)
      error_reassigns = collect_catch_reassigns(node)
      outer_body = [
        MIR::CatchWrapper.new("return #{inner_call} catch {\n    #{catch_zig}\n};", error_reassigns, catch_clause_bodies)
      ]

      outer_fn = MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                                  outer_body, vis, false, comptime_params)

      # Return both FnDefs as an array (lower_program/lower_module flatten arrays)
      [inner_fn, outer_fn]
    else
      MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                      prologue + body_mir, vis, false, comptime_params)
    end
  end

  # Returns [zig_string, clause_bodies] where clause_bodies is an array of
  # MIR stmt arrays (one per clause + optional default). Using lower_body
  # ensures flush_pending is called per statement so hoisted Lets stay in scope.
  def build_catch_clauses(node, fn_can_fail)
    rt_name = @rt_name
    clause_bodies = []

    # Build snapshot declaration if function has exactly one snapshot type
    snap_types = node.respond_to?(:snapshot_types) ? (node.snapshot_types || Set.new) : Set.new
    snapshot_decl = ""
    if snap_types.size == 1
      snap_zig = transpile_type(snap_types.first)
      snapshot_decl = "const __snap_ptr = #{rt_name}.__error.snapshotAs(#{snap_zig});\n" \
                      "            const snapshot = if (__snap_ptr) |p| p.* else undefined;\n" \
                      "            const __has_snapshot = __snap_ptr != null;\n" \
                      "            _ = &snapshot; _ = &__has_snapshot;\n            "
    end

    parts = (node.catch_clauses || []).map { |clause|
      kind = clause[:kind]
      error_name = clause[:error_name]
      # Use lower_body to flush pending hoisted Lets per statement (prevents
      # hoist_alloc-produced Lets from escaping the catch body scope).
      clause_mir = lower_body(clause[:body])
      clause_bodies << clause_mir
      clause_body_zig = clause_mir.map { |m| emit_expr(m) }.join("\n            ")

      cond_parts = ["#{rt_name}.__error.matchesKind(.#{kind})"]
      cond_parts << "#{rt_name}.__error.matchesName(\"#{error_name}\")" if error_name
      cond = cond_parts.join(" and ")

      "if (#{cond}) {\n            #{snapshot_decl}const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{clause_body_zig}\n        }"
    }.join(" else ")

    default_code = if node.default_catch.is_a?(Array) && node.default_catch.any?
      # Use lower_body for the same reason as above.
      default_mir = lower_body(node.default_catch)
      clause_bodies << default_mir
      default_body = default_mir.map { |m| emit_expr(m) }.join("\n            ")
      " else {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{default_body}\n        }"
    elsif fn_can_fail
      " else {\n            #{rt_name}.freeSnapshot();\n            return error.CheatError;\n        }"
    else
      " else {\n            #{rt_name}.freeSnapshot();\n            unreachable;\n        }"
    end

    ["#{parts}#{default_code}", clause_bodies]
  end

  # Extract error-path reassignment metadata from catch clauses (INV-9).
  # Returns [{ name:, alloc:, line: }] for each reassignment to an existing
  # binding inside a catch body. Used by MIRChecker to verify allocator consistency.
  def collect_catch_reassigns(node)
    reassigns = []
    catch_bodies = []
    (node.catch_clauses || []).each { |c| catch_bodies << c[:body] if c[:body] }
    catch_bodies << node.default_catch if node.default_catch.is_a?(Array)

    catch_bodies.each do |body|
      walk_catch_body_for_reassigns(body, reassigns)
    end
    reassigns
  end

  def walk_catch_body_for_reassigns(stmts, reassigns)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::BindExpr
        if stmt.mode == :assign
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << { name: stmt.name.to_s, alloc: alloc, line: (stmt.token&.line || 0) } if alloc
        end
      when AST::Assignment
        if stmt.name.is_a?(AST::Identifier)
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << { name: stmt.name.name.to_s, alloc: alloc, line: (stmt.token&.line || 0) } if alloc
        end
      when AST::IfStatement
        walk_catch_body_for_reassigns(stmt.then_branch, reassigns)
        walk_catch_body_for_reassigns(stmt.else_branch, reassigns)
      when AST::MatchStatement
        stmt.cases&.each { |c| walk_catch_body_for_reassigns(c[:body], reassigns) }
        walk_catch_body_for_reassigns(stmt.default_case, reassigns)
      end
    end
  end

  def infer_catch_value_allocator(expr)
    return nil unless expr
    ti = expr.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return :heap if ti&.heap_provenance?
    storage = expr.respond_to?(:storage) ? expr.storage : nil
    return storage if storage == :heap || storage == :frame
    nil
  end

  # ================================================================
  # Function / method calls
  # ================================================================

  def lower_func_call(node)
    # Stub interception: replace stubbed function calls with stub behavior
    stub_info = (@active_stubs || {})[node.name]
    if stub_info
      case stub_info[:kind]
      when :returns
        return MIR::Ident.new(stub_info[:var])
      when :with
        args_mir = node.args.map { |a| lower(a) }
        return MIR::Call.new(stub_info[:var], args_mir, false)
      when :captures, :sequence
        # TEST-INFRA: stub call args are discarded (stub ignores values); no allocation escapes.
        args_zig = node.args.map { |a| emit_expr(lower(a)) }
        stub_code = if stub_info[:kind] == :captures
          "{ #{stub_info[:var]} += 1; }"
        else
          "blk_stub: { const __si = #{stub_info[:var]}_idx; #{stub_info[:var]}_idx += 1; break :blk_stub #{stub_info[:var]}_seq[__si]; }"
        end
        return MIR::InlineZig.new(stub_code, "stub_call")
      end
    end

    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern FFI call
    if node.respond_to?(:extern_call) && node.extern_call
      return lower_extern_call(node)
    end

    # Standard call
    args_mir = node.args.map { |a|
      # CopyNode/MoveNode = TAKES: callee owns the value on success, so only clean
      # up on error (partial failure). Non-TAKES args are borrowed; use Cleanup.
      takes = a.is_a?(AST::CopyNode) || a.is_a?(AST::MoveNode)
      arg = hoist_alloc(lower(a), a, err_cleanup: takes)
      # Array/List args: convert to slice via .items (skip strings - already []const u8)
      ti = a.type_info
      if ti&.array? && !ti&.string? && !a.is_a?(AST::CopyNode) && !a.is_a?(AST::MoveNode)
        MIR::ItemsAccess.new(arg, true)
      elsif ti.is_a?(Type) && Type.new(ti).needs_pointer_passing?
        # Skip & for params already received as pointers (prevents double-& in recursive calls)
        # Also skip & for BG pointer captures (already stored as *T in fiber context)
        if a.is_a?(AST::Identifier) && (@current_fn_collection_params&.include?(a.name) ||
                                         @current_bg_pointer_captures&.include?(a.name))
          arg
        else
          MIR::AddressOf.new(arg)
        end
      else
        arg
      end
    }

    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""

    if node.respond_to?(:fn_var_call) && node.fn_var_call
      # fn-type variable call
      all_args = [MIR::Ident.new(@rt_name)] + args_mir
      return MIR::Call.new("try #{node.name}", all_args, false)
    end

    # Resolve rt/fail from fn_sigs
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    # Generic type args
    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(Type.new(t).zig_type) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    # Heap dupe result
    if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
      inner_call = MIR::Call.new(fn_zig, all_args, can_fail)
      return MIR::DupeSlice.new(inner_call, :heap)
    end

    call = MIR::Call.new(fn_zig, all_args, can_fail)
    call.heap_provenance = call_heap_provenance?(node)
    call
  end

  def lower_method_call(node)
    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern method dispatch
    if node.instance_variable_get(:@extern_method)
      return lower_extern_method(node)
    end

    # Standard UFCS call: method(object, args...)
    obj_mir = lower(node.object)
    args_mir = node.args.map { |a|
      takes = a.is_a?(AST::CopyNode) || a.is_a?(AST::MoveNode)
      arg = hoist_alloc(lower(a), a, err_cleanup: takes)
      ti = a.type_info
      if ti&.array? && !ti&.string? && !a.is_a?(AST::CopyNode) && !a.is_a?(AST::MoveNode)
        MIR::ItemsAccess.new(arg, true)
      elsif ti.is_a?(Type) && Type.new(ti).needs_pointer_passing?
        if a.is_a?(AST::Identifier) && (@current_fn_collection_params&.include?(a.name) ||
                                         @current_bg_pointer_captures&.include?(a.name))
          arg
        else
          MIR::AddressOf.new(arg)
        end
      else
        arg
      end
    }

    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(Type.new(t).zig_type) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + [obj_mir] + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
      inner_call = MIR::Call.new(fn_zig, all_args, can_fail)
      return MIR::DupeSlice.new(inner_call, :heap)
    end

    call = MIR::Call.new(fn_zig, all_args, can_fail)
    call.heap_provenance = call_heap_provenance?(node)
    call
  end

  def lower_intrinsic(node)
    # Symbol-based intrinsics are complex special builtins
    if node.zig_pattern.is_a?(Symbol)
      case node.zig_pattern
      when :macro_print
        return lower_macro_print(node)
      when :macro_map
        raise "BUG: macro_map should have been rewritten by PipelineRewriter"
      else
        raise "MIRLowering: unhandled symbol intrinsic: #{node.zig_pattern}"
      end
    end

    # Template-based intrinsics: lower args to MIR, apply ownership transforms, emit
    mir_args = if node.is_a?(AST::MethodCall)
      obj_mir = lower(node.object)
      # Auto-deref Arc/Rc-wrapped receivers: obj.ctrl.data.*
      obj_ti = node.object.type_info
      if obj_ti&.shared? || obj_ti&.multiowned?
        obj_mir = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(obj_mir, "ctrl"), "data"))
      end
      [obj_mir] + node.args.map { |a| lower(a) }
    else
      node.args.map { |a| lower(a) }
    end

    # Hot-path collection lengths should lower to direct `.len` / `.items.len`
    # instead of going through CheatLib.len, which adds avoidable call overhead
    # in tight loops. Streams are not handled here; they stay on NEXT-based paths.
    if node.zig_pattern == "CheatLib.len({0})"
      len_expr = lower_direct_length(node)
      return len_expr if len_expr
    end

    pattern = node.zig_pattern.dup

    # Resolve {alloc} to a symbol and wrap TAKES string args in MIR::DupeSlice.
    # The {alloc} PLACEHOLDER stays in the pattern -- the emitter substitutes it.
    resolved_allocs = {}
    if pattern.include?("{alloc}")
      alloc_sym = node.matched_stdlib_def&.dig(:alloc) || :node_storage
      # Resolve receiver type: MethodCall -> receiver object; UFCS FuncCall -> first arg
      receiver_type = if node.is_a?(AST::MethodCall)
        ti = node.object.type_info rescue nil
        ti ? Type.new(ti) : nil
      else
        ti = node.args&.first&.type_info rescue nil
        ti ? Type.new(ti) : nil
      end
      resolved = resolve_alloc_sym(alloc_sym, receiver_type, nil, node)
      resolved_allocs[:alloc] = resolved

      # Wrap non-heap strings at TAKES positions in DupeSlice (visible to MIR checker)
      stdlib_args = node.matched_stdlib_def&.dig(:args)
      if stdlib_args.is_a?(Array)
        raw_args = node.is_a?(AST::MethodCall) ? node.args : node.args[1..]
        raw_args&.each_with_index do |arg_node, ai|
          param_def = stdlib_args[ai + 1]
          next unless param_def.is_a?(Hash) && param_def[:takes]
          mir_idx = node.is_a?(AST::MethodCall) ? ai + 1 : ai
          ti = arg_node.type_info rescue nil
          next unless ti&.string?
          storage = arg_node.respond_to?(:storage) ? arg_node.storage : nil
          next if storage == :heap
          next if arg_node.is_a?(AST::CopyNode)
          dupe_alloc = alloc_sym == :heap ? :heap : alloc_for_node(arg_node)
          mir_args[mir_idx] = MIR::DupeSlice.new(mir_args[mir_idx], dupe_alloc)
        end
      end
    end

    # Emit all args to Zig strings
    args_zig = mir_args.map { |a| emit_expr(a) }

    # Resolve {key_zig} and {val_zig} from receiver type (numeric/sharded maps)
    if pattern.include?("{key_zig}") || pattern.include?("{val_zig}")
      obj_ti = node.is_a?(AST::MethodCall) ? node.object.type_info : nil
      map_ft = obj_ti ? Type.new(obj_ti) : nil
      pattern = pattern.gsub("{key_zig}", map_ft&.key_type&.zig_type || "i64")
      pattern = pattern.gsub("{val_zig}", map_ft&.value_type&.zig_type || "f64")
    end

    # Resolve &{N} as address-of for positional args
    args_zig.each_with_index { |val, i| pattern = pattern.gsub("&{#{i}}", "&#{val}") }

    # Substitute positional args
    args_zig.each_with_index { |val, i| pattern = pattern.gsub("{#{i}}", val) }

    iz = MIR::InlineZig.new(pattern, "intrinsic")
    iz.stdlib_def = node.matched_stdlib_def if node.respond_to?(:matched_stdlib_def)
    iz.allocs = resolved_allocs unless resolved_allocs.empty?
    # Store target variable name for checker cross-reference with AllocMark.
    if node.is_a?(AST::MethodCall) && node.object.respond_to?(:name)
      iz.target_var = node.object.name.to_s
    elsif node.respond_to?(:mutates_receiver) && node.mutates_receiver && node.args&.first&.respond_to?(:name)
      iz.target_var = node.args.first.name.to_s  # UFCS: first arg is receiver
    end
    iz
  end

  def resolve_intrinsic_alloc(alloc_sym, node)
    case alloc_sym
    when :heap  then "#{@rt_name}.heapAlloc()"
    when :frame then "#{@rt_name}.frameAlloc()"
    when :node_storage
      storage = node.respond_to?(:storage) ? node.storage : nil
      storage == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
    when :receiver_storage
      ti = if node.is_a?(AST::MethodCall)
        node.object.type_info rescue nil
      else
        node.args&.first&.type_info rescue nil
      end
      ti = ti.is_a?(Type) ? ti : (Type.new(ti) rescue nil) if ti
      needs_heap = ti&.needs_heap_backing?
      needs_heap ||= (node.respond_to?(:storage) && node.storage == :heap)
      needs_heap ||= if node.is_a?(AST::MethodCall)
        node.object.respond_to?(:storage) && node.object.storage == :heap
      elsif node.respond_to?(:mutates_receiver) && node.mutates_receiver
        node.args&.first&.respond_to?(:storage) && node.args.first.storage == :heap
      end
      needs_heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
    when :cleanup
      "#{@rt_name}.cleanupAlloc()"
    else
      "#{@rt_name}.frameAlloc()"
    end
  end


  def lower_extern_call(node)
    return lower_extern_direct_call(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_call(node)
  end

  def lower_extern_method(node)
    return lower_extern_direct_method(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_method(node)
  end

  def lower_extern_direct_call(node)
    args = node.args.map { |a| lower(a) }
    if node.respond_to?(:extern_effects) && (alloc_kind = node.extern_effects&.dig(:alloc))
      rt = MIR::Ident.new(@rt_name)
      alloc_call = alloc_kind == :heap \
        ? MIR::MethodCall.new(rt, "heapAlloc",  [], false) \
        : MIR::MethodCall.new(rt, "frameAlloc", [], false)
      n_comptime = node.args.count { |a| a.respond_to?(:full_type) && a.full_type == :Type }
      args = args[0, n_comptime] + [alloc_call] + args[n_comptime..]
    end
    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""
    MIR::Call.new("#{mod_prefix}#{node.name}", args, false)
  end

  def lower_extern_direct_method(node)
    obj = lower(node.object)
    args = node.args.map { |a| lower(a) }
    MIR::MethodCall.new(obj, node.name.to_s, args, false)
  end

  # Lower an extern trampoline argument, stripping the Byte[N]→String coercion
  # (@as([]const u8, "lit")) so string literals keep their native Zig type
  # *const [N:0]u8, which coerces to both []const u8 AND [*:0]const u8.
  # Without this, string literals passed to C-string params would fail with
  # "expected [*:0]const u8, found []const u8".
  def lower_extern_arg(ast_arg)
    mir = lower(ast_arg)
    if mir.is_a?(MIR::Cast) && mir.method == :as && mir.target_type == "[]const u8" && mir.expr.is_a?(MIR::Lit)
      mir.expr
    else
      mir
    end
  end

  def build_extern_trampoline_call(node)
    @extern_counter = (@extern_counter || 0) + 1
    id = @extern_counter
    alloc_kind = node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil
    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""
    fn_zig = "#{mod_prefix}#{node.name}"

    # Separate comptime type args (full_type == :Type) from runtime args.
    # Comptime args can't be struct fields (Zig type is `type`, comptime-only).
    # They are baked directly into the call_zig string.
    comptime_args, runtime_ast_args = node.args.partition { |a| a.respond_to?(:full_type) && a.full_type == :Type }
    comptime_codes = comptime_args.map { |a| emit_expr(lower_extern_arg(a)) }

    args = runtime_ast_args.map { |a| lower_extern_arg(a) }
    arg_codes = args.map { |a| emit_expr(a) }
    arg_tuple = arg_codes.empty? ? ".{}" : ".{ #{arg_codes.join(', ')} }"

    call_parts = comptime_codes + (alloc_kind ? ["_alloc_"] : []) + arg_codes.each_index.map { |i| "f.a#{i}" }
    call_zig = "#{fn_zig}(#{call_parts.map { |p| p == "_alloc_" ? "f.alloc" : p }.join(', ')})"

    build_extern_trampoline_common(
      id: id,
      prefix: "__Ext",
      args_tuple_name: "__ext#{id}_args",
      frame_name: "__ext#{id}_frame",
      arg_codes: arg_codes,
      arg_field_types: nil,
      arg_tuple: arg_tuple,
      alloc_kind: alloc_kind,
      return_type: node.full_type,
      call_zig: call_zig,
      receiver_field: nil
    )
  end

  def build_extern_trampoline_method(node)
    @extern_counter = (@extern_counter || 0) + 1
    id = @extern_counter
    obj = lower(node.object)
    args = node.args.map { |a| lower_extern_arg(a) }
    arg_codes = args.map { |a| emit_expr(a) }
    arg_tuple = arg_codes.empty? ? ".{}" : ".{ #{arg_codes.join(', ')} }"
    receiver_code = emit_expr(obj)
    build_extern_trampoline_common(
      id: id,
      prefix: "__ExtM",
      args_tuple_name: "__extm#{id}_args",
      frame_name: "__extm#{id}_frame",
      arg_codes: arg_codes,
      arg_field_types: nil,
      arg_tuple: arg_tuple,
      alloc_kind: node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil,
      return_type: node.full_type,
      call_zig: "f.self_val.#{node.name}(#{extern_call_args_zig(arg_codes.length, node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil)})",
      receiver_field: receiver_code
    )
  end

  def extern_call_args_zig(argc, alloc_kind)
    parts = []
    parts << "f.alloc" if alloc_kind
    argc.times { |i| parts << "f.a#{i}" }
    parts.join(", ")
  end

  def build_extern_trampoline_common(id:, prefix:, args_tuple_name:, frame_name:, arg_codes:, arg_field_types:, arg_tuple:, alloc_kind:, return_type:, call_zig:, receiver_field:)
    ret_t = return_type.is_a?(Type) ? return_type : Type.new(return_type || :Void)
    can_fail = ret_t.error_union?
    payload_t = can_fail ? ret_t.payload_type : ret_t
    returns_void = payload_t.resolved == :Void

    fields = []
    fields << "self_val: @TypeOf(#{receiver_field})" if receiver_field
    fields << "alloc: std.mem.Allocator" if alloc_kind
    arg_codes.each_index do |i|
      field_type = arg_field_types&.[](i)
      fields << "a#{i}: #{field_type || "@TypeOf(#{args_tuple_name}[#{i}])"}"
    end
    fields << "err: ?anyerror = null" if can_fail
    fields << "ret: #{payload_t.zig_type} = undefined" unless returns_void

    call_stmt = if can_fail
      if returns_void
        "#{call_zig} catch |err| { f.err = err; return; };"
      else
        "f.ret = (#{call_zig} catch |err| { f.err = err; return; });"
      end
    else
      returns_void ? "#{call_zig};" : "f.ret = #{call_zig};"
    end

    init_fields = []
    init_fields << ".self_val = #{receiver_field}" if receiver_field
    arg_codes.each_index { |i| init_fields << ".a#{i} = #{args_tuple_name}[#{i}]" }
    if alloc_kind
      alloc_expr = alloc_kind == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
      init_fields << ".alloc = #{alloc_expr}"
    end

    code = +""
    if returns_void
      code << "{ "
    else
      code << "blk_ext#{id}: { "
    end
    code << "const #{args_tuple_name} = #{arg_tuple}; "
    code << "const #{prefix}#{id} = struct { #{fields.join(', ')}, fn run(ptr: ?*anyopaque) callconv(.c) void { const f: *@This() = @ptrCast(@alignCast(ptr)); #{call_stmt} } }; "
    code << "var #{frame_name} = #{prefix}#{id}{ #{init_fields.join(', ')} }; "
    code << "#{@rt_name}.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &#{prefix}#{id}.run), @ptrCast(&#{frame_name})); "
    code << "if (#{frame_name}.err) |e| return e; " if can_fail
    code << "break :blk_ext#{id} #{frame_name}.ret; " unless returns_void
    code << "}"

    iz = MIR::InlineZig.new(code, "extern_trampoline")
    iz.stdlib_def = { allocates: true } if call_heap_provenance_from_type?(payload_t)
    iz
  end

  def call_heap_provenance_from_type?(ti)
    t = ti.is_a?(Type) ? ti : (Type.new(ti) rescue nil)
    t&.heap_provenance? || false
  end


  # ================================================================
  # Lambda
  # ================================================================

  def lower_lambda(node)
    sig = node.full_type
    @lambda_counter = (@lambda_counter || 0) + 1
    fn_name = "_lambda_#{@lambda_counter}"

    params_list = sig.respond_to?(:params) ? sig.params : sig[:params] || []
    params_mir = [MIR::Param.new("_rt", "*Runtime")] + params_list.map { |p|
      p_type = p[:type]
      type_str = p_type.is_a?(Type) ? p_type.zig_type(is_param: true) : transpile_type(p_type || :Any, is_param: true)
      MIR::Param.new(p[:name], type_str)
    }

    ret = sig.respond_to?(:return_type) ? (sig.return_type || :Void) : (sig[:return]&.fetch(:type, nil) || :Void)
    ret_zig = ret.is_a?(Type) ? ret.zig_type : transpile_type(ret)
    ret_str = ret_zig.start_with?("!") ? ret_zig : "anyerror!#{ret_zig}"

    # Build body: suppressions + return expr
    body_mir = []
    body_mir << MIR::Suppress.new("_rt")
    params_list.each { |p| body_mir << MIR::Suppress.new(p[:name]) }
    body_mir << MIR::ReturnStmt.new(lower(node.body))

    fn_def = MIR::FnDef.new(fn_name, params_mir, ret_str, body_mir, nil, false, nil)
    MIR::LambdaExpr.new(fn_def)
  end

  # ================================================================
  # Collections
  # ================================================================

  def lower_list_lit(node)
    ti = node.coerced_type_info || node.type_info || Type.new(node.full_type || :Any)

    # Bounded stream: ~T[N] - emit BoundedStream struct with Promise items
    if ti.respond_to?(:bounded_stream?) && ti.bounded_stream?
      @stream_lit_counter ||= 0
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
      return MIR::InlineZig.new(code, "bounded_stream_init")
    end

    items_mir = node.items.map { |i| hoist_alloc(lower(i), i) }

    if node.storage == :stack && ti.respond_to?(:fixed?) && ti.fixed?
      # Stack-allocated fixed array
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      return MIR::ArrayInit.new(elem_zig, node.items.length.to_s, items_mir)
    end

    if node.items.empty?
      # Empty list: MIR expression depends on collection type
      if ti.respond_to?(:list_collection?) && ti.list_collection?
        zig_t = transpile_type(ti)
        alloc = alloc_for_node(node)
        return MIR::ContainerInit.new(zig_t, :list_empty, alloc, nil)
      end
      # Dynamic empty list: use makeList with empty items
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      alloc = alloc_for_node(node)
      return MIR::MakeList.new(elem_zig, [], alloc)
    end

    # Non-empty list literal -> makeList
    elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
    alloc = alloc_for_node(node)
    MIR::MakeList.new(elem_zig, items_mir, alloc)
  end

  def lower_hash_lit(node)
    # HashMaps are always heap-allocated
    ti = node.coerced_type_info || node.type_info || Type.new(node.full_type || :Any)
    rt_name = @rt_name
    alloc_str = "#{rt_name}.heapAlloc()"

    # For Arc/Rc-wrapped maps, build bare inner type for init, then wrap
    is_arc = ti.respond_to?(:shared?) && ti.shared?
    is_rc = ti.respond_to?(:multiowned?) && ti.multiowned?
    if is_arc || is_rc
      bare_ft = Type.new(ti.resolved.to_s)
      bare_ft.shard_count = ti.shard_count if ti.respond_to?(:shard_count) && ti.shard_count
      bare_ft.sync = ti.sync if ti.respond_to?(:sync) && ti.shard_count && ti.sync
      zig_t = bare_ft.zig_type

      needs_alloc = bare_ft.respond_to?(:map_init_needs_alloc?) ? bare_ft.map_init_needs_alloc? :
                    (!zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType"))
      inner = if needs_alloc
        MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
      else
        MIR::StructInit.new(zig_t, [])
      end

      # Apply sync wrapping if needed (skip for striped maps)
      if !bare_ft.respond_to?(:striped?) || !bare_ft.striped?
        if ti.sync == :write_locked
          inner = MIR::Call.new("CheatLib.RwLocked(#{zig_t}).init", [inner], false)
        elsif ti.sync == :locked
          inner = MIR::Call.new("CheatLib.Locked(#{zig_t}).init", [inner], false)
        end
      end

      wrap_fn = is_arc ? "arcCreate" : "rcCreate"
      inner = MIR::Call.new("CheatLib.#{wrap_fn}", [MIR::Ident.new(zig_t), MIR::Ident.new(alloc_str), inner], true)
      return inner if node.pairs.empty?
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

  def lower_cast(node)
    inner = lower(node.value)
    target_type = transpile_type(node.target)
    MIR::Cast.new(inner, target_type, :as)
  end

  # ================================================================
  # Concurrent / capability blocks
  # ================================================================

  def lower_with_block(node)
    rt_name = @rt_name
    bindings = []

    (node.capabilities || []).each do |cap|
      var_name = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      resolved = cap[:resolved_type]
      zig_var = @do_capture_map&.dig(var_name) || var_name

      case cap[:capability]
      when :multiowned, :shared
        inner = "__#{var_name}_unwrap"
        bindings << "const #{inner} = #{zig_var}.ctrl.data.*;\n_ = &#{inner};"
      when :EXCLUSIVE
        guard_var = "__#{var_name}_guard"
        lock_expr = resolved&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        if resolved&.write_locked?
          bindings << "var #{guard_var} = #{lock_expr}.write();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        else
          bindings << "var #{guard_var} = #{lock_expr}.acquire();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        end
      when :write_locked_read
        guard_var = "__#{var_name}_guard"
        lock_expr = resolved&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        bindings << "var #{guard_var} = #{lock_expr}.read();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
      when :BORROWED
        # PURE: cap[:var_node] is always an Identifier or field ref; never allocating.
        source_zig = emit_expr(lower(cap[:var_node]))
        bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
      when :RESTRICT
        if !resolved&.any_sync?
          # PURE: same as BORROWED; var_node is a simple variable reference.
          source_zig = emit_expr(lower(cap[:var_node]))
          if cap[:alias_mutable]
            bindings << "const #{zig_safe_name(alias_name)} = &#{source_zig};"
          else
            bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
          end
        end
      end
    end

    # Set up unwrap maps so lower_get_field uses aliases inside the WITH body
    prev_locked = @locked_unwrap_map
    prev_rc = @rc_unwrap_map
    @locked_unwrap_map = (prev_locked || {}).dup
    @rc_unwrap_map = (prev_rc || {}).dup

    (node.capabilities || []).each do |cap|
      var_name = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      case cap[:capability]
      when :EXCLUSIVE, :write_locked_read
        @locked_unwrap_map[alias_name] = true
        # Also map original var_name → alias so field accesses on the original
        # variable get rewritten to use the unwrapped inner alias.
        @locked_unwrap_map[var_name] = alias_name if alias_name != var_name
      when :multiowned, :shared
        @rc_unwrap_map[var_name] = "__#{var_name}_unwrap"
      end
    end

    body_zig = emit_stmts_zig(lower_body(node.body))
    @locked_unwrap_map = prev_locked
    @rc_unwrap_map = prev_rc

    all_bindings = bindings.reject(&:empty?).join("\n")
    borrows = (node.capabilities || []).filter_map { |c|
      vn = c[:var_node]
      vn.respond_to?(:name) ? vn.name.to_s : nil
    }
    MIR::RawZig.new("{\n#{all_bindings}\n#{body_zig}\n}", "with_block",
      { consumes: [], produces: [], borrows: borrows })
  end

  def lower_do_block(node)
    @do_block_counter = (@do_block_counter || 0) + 1
    id = @do_block_counter - 1
    n = node.branches.length
    wg_var = "__do#{id}_wg"

    all_branch_bodies = []
    branch_parts = node.branches.each_with_index.map { |branch, i|
      ctx_type = "__DoBranchCtx#{id}_#{i}"
      ctx_var = "__do#{id}_ctx#{i}"
      analysis = branch[:capture_analysis]
      captured = analysis&.captures || {}
      pinned = branch[:pinned]

      capture_fields = captured.map { |name, type_obj|
        zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
        "#{name}: *const #{zig_t},"
      }.join("\n    ")

      capture_inits = ([".wg = &#{wg_var}"] + captured.map { |name, _| ".#{name} = &#{name}" }).join(", ")

      # Lower branch body to MIR nodes (for checker visibility) and emit Zig code.
      branch_mir = nil
      body_code = with_fiber_capture_map(captured.map { |name, _| [name, "ctx.#{name}.*"] }.to_h, rt_override: "__rt") do
        body_stmts = branch[:body].map { |e| lower(e) }
        branch_mir = body_stmts
        body_stmts.map { |mir|
          code = emit_expr(mir)
          code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
          code
        }.join("\n        ")
      end
      all_branch_bodies << (branch_mir || [])

      task_cfg = task_config_zig(branch[:stack_size], branch[:computed_stack_tier])
      spawn_fn = pinned ? "try #{wg_var}.sched.submitSpawn" : "try CheatHeader.spawnBest"

      <<~ZIG.chomp
        const #{ctx_type} = struct {
            wg: *CheatHeader.WaitGroup,
            #{capture_fields}
            fn run(__raw_rt_do#{id}_#{i}: *anyopaque, __raw_args_do#{id}_#{i}: ?*anyopaque) anyerror!void {
                const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_do#{id}_#{i})));
                #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_do#{id}_#{i}.?)));
                defer ctx.wg.done();
                #{body_code}
            }
        };
        var #{ctx_var} = #{ctx_type}{ #{capture_inits} };
        #{spawn_fn}(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
            &#{ctx_var},
            #{task_cfg}
        );
        #{wg_var}.add(1);
      ZIG
    }

    inner = branch_parts.join("\n")
    do_code = <<~ZIG.chomp
      {
          var #{wg_var} = CheatHeader.WaitGroup.init(rt.getSched());
          errdefer #{wg_var}.wait();
          #{inner}
          #{wg_var}.wait();
      }
    ZIG
    MIR::DoBlock.new(do_code, all_branch_bodies)
  end

  def lower_bg_block(node)
    @bg_block_counter = (@bg_block_counter || 0) + 1
    id = @bg_block_counter - 1

    tense_t = Type.new(node.full_type || :"~Void")
    inner_t = Type.new(tense_t.tense_type)
    inner_zig = inner_t.zig_type
    promise_zig = tense_t.zig_type
    is_void = inner_zig == "void"

    ctx_type = "__BgCtx#{id}"
    alloc_var = "__bg#{id}_alloc"
    promise_var = "__bg#{id}_promise"
    ctx_var = "__bg#{id}_ctx"
    blk_label = "__bg#{id}"
    bg_rt = "__rt_bg#{id}"

    analysis = node.capture_analysis
    captured = analysis&.captures || {}
    capture_close_zig = analysis&.close_patterns || {}
    pointer_captures = analysis&.pointer_captures || Set.new
    resource_captures = analysis&.resource_captures || Set.new

    rt_name = @rt_name

    # Build capture fields
    capture_fields = captured.map { |name, type_obj|
      t = type_obj ? Type.new(type_obj) : nil
      zig_t = t ? t.zig_type : "anyopaque"
      pointer_captures.include?(name) ? "#{name}: *#{zig_t}," : "#{name}: #{zig_t},"
    }.join("\n        ")

    # String captures annotated directly on BgBlock.capture_string_dupes
    bg_string_promotes, promoted_names = fiber_string_promotes(node, id, "bg")

    capture_inits = ([".inner = #{promise_var}.inner", ".alloc = #{alloc_var}"] +
      captured.map { |name, _|
        if pointer_captures.include?(name)
          ".#{name} = &#{name}"
        elsif promoted_names[name]
          ".#{name} = #{promoted_names[name]}"
        else
          ".#{name} = #{name}"
        end
      }).join(", ")

    # Flatten ThenChain + lower body
    flat_steps = []
    node.body.each { |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |s| flat_steps << s }
      else
        flat_steps << { expr: stmt, binding: nil }
      end
    }
    last_step = flat_steps.pop
    pre_steps = flat_steps

    # Rewrite captured variable references and rt inside the fiber body
    bg_capture_map = captured.map { |name, _| [name, "__ctx_#{id}.#{name}"] }.to_h
    prev_bg_ptr_caps = @current_bg_pointer_captures
    @current_bg_pointer_captures = pointer_captures
    # Lower the fiber body to MIR nodes (for checker visibility) and build Zig strings.
    # run_body carries the MIR stmts so the checker can walk allocations inside the fiber.
    run_body = nil
    stmt_code, result_line = with_fiber_capture_map(bg_capture_map, rt_override: bg_rt) do
      body_mir = []
      sc = pre_steps.filter_map { |step|
        mir = lower(step[:expr])
        code = emit_expr(mir)
        body_mir << (step[:binding] ? MIR::Let.new(step[:binding], mir, false, nil, nil) : mir)
        # AllocMark and other verification-only nodes emit nil -- skip them.
        next nil if code.nil?
        if step[:binding]
          "const #{step[:binding]} = #{code};"
        elsif code.strip.end_with?(";") || code.strip.end_with?("}")
          code
        else
          expr_type = step[:expr].respond_to?(:full_type) ? step[:expr].full_type : :Void
          is_void_step = expr_type.nil? || expr_type == :Void || (expr_type.respond_to?(:to_s) && Type.new(expr_type).zig_type == "void")
          is_void_step ? "#{code};" : "_ = #{code};"
        end
      }.join("\n            ")

      last_is_assign = last_step && last_step[:expr].is_a?(AST::Assignment)
      rl = if last_step.nil? || is_void || last_is_assign
        if last_step
          last_mir = lower(last_step[:expr])
          body_mir << last_mir
          last_code = emit_expr(last_mir)
          (last_code.strip.end_with?("}") || last_code.strip.end_with?(";")) ? last_code : "#{last_code};"
        else
          ""
        end
      else
        last_mir = lower(last_step[:expr])
        body_mir << last_mir
        result_code = emit_expr(last_mir)
        # Apply scope-exit promotion: frame strings must be heap-duped so they
        # outlive the fiber's frame, which is rewound when the fiber exits.
        if node.exit_promote&.dig(:strategy) == :string_dupe
          # Use __ctx_N.alloc — __bg_alloc is the same allocator but declared
          # in the outer block, not accessible inside the run fn.
          "__ctx_#{id}.inner.result = try __ctx_#{id}.alloc.dupe(u8, #{result_code});"
        else
          result_code = result_code.sub(/\Atry /, '') if result_code.start_with?("try ")
          "__ctx_#{id}.inner.result = #{result_code};"
        end
      end
      run_body = body_mir
      [sc, rl]
    end
    @current_bg_pointer_captures = prev_bg_ptr_caps

    arena_init = node.arena_mode ? "#{bg_rt}.arena_mode = true;" : ""

    capture_frees = captured.filter_map { |name, _|
      if bg_string_promotes.include?(name)
        "defer __ctx_#{id}.alloc.free(__ctx_#{id}.#{name});"
      elsif capture_close_zig[name]
        "defer #{capture_close_zig[name].gsub('{0}', "__ctx_#{id}.#{name}")};"
      end
    }.join("\n                    ")

    promoted_decls = fiber_promoted_decls_zig(promoted_names, alloc_var)

    task_cfg = task_config_zig(node.stack_size, node.computed_stack_tier)
    pin_mode = node.respond_to?(:pinned) ? node.pinned : nil
    spawn_call = fiber_spawn_call_zig(rt_name, ctx_type, ctx_var, task_cfg, pin_mode)

    bg_code = <<~ZIG.chomp
      #{blk_label}: {
          const #{ctx_type} = struct {
              inner: *#{promise_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_#{id}: *anyopaque, __raw_args_#{id}: ?*anyopaque) anyerror!void {
                  const #{bg_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_#{id})));
                  #{(stmt_code + result_line + capture_frees + arena_init).include?(bg_rt) ? "" : "_ = &#{bg_rt};"}
                  #{arena_init}
                  const __ctx_#{id} = @as(*@This(), @ptrCast(@alignCast(__raw_args_#{id}.?)));
                  defer __ctx_#{id}.alloc.destroy(__ctx_#{id});
                  defer __ctx_#{id}.inner.wg.done();
                  errdefer |fiber_err| __ctx_#{id}.inner.result = fiber_err;
                  #{capture_frees}
                  #{stmt_code}
                  #{result_line}
                  #{is_void ? "__ctx_#{id}.inner.result = {};" : ""}
              }
          };
          const #{alloc_var} = #{node.pinned == true || node.pinned == :local ? "#{rt_name}.getSched().allocator" : "#{rt_name}.heapAlloc()"};
          const #{promise_var} = try #{promise_zig}.spawn(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{blk_label} #{promise_var};
      }
    ZIG
    MIR::BgBlock.new(bg_code, captured, run_body || [])
  end

  def lower_bg_stream_block(node)
    @stream_gen_counter = (@stream_gen_counter || 0) + 1
    id = @stream_gen_counter - 1

    tense_t = Type.new(node.full_type || :"~?Void[]")
    is_inf = tense_t.inf_stream?
    stream_zig = tense_t.zig_type

    ctx_type = "__SgCtx#{id}"
    alloc_var = "__sg#{id}_alloc"
    stream_var = "__sg#{id}_stream"
    ctx_var = "__sg#{id}_ctx"
    blk_label = "__sg#{id}"
    local_stream = "__sg#{id}_local"

    analysis = node.capture_analysis
    captured = analysis&.captures || {}
    rt_name = @rt_name

    # String captures annotated directly on BgStreamBlock.capture_string_dupes
    bg_string_promotes, promoted_names = fiber_string_promotes(node, id, "sg")

    capture_fields = captured.map { |name, type_obj|
      zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
      "#{name}: #{zig_t},"
    }.join("\n        ")

    capture_inits = ([".stream_inner = #{stream_var}.inner", ".alloc = #{alloc_var}"] +
      captured.map { |name, _|
        promoted_names[name] ? ".#{name} = #{promoted_names[name]}" : ".#{name} = #{name}"
      }).join(", ")

    # Save/restore stream context for YieldExpr
    prev_stream_local = @current_stream_local
    prev_stream_is_inf = @current_stream_is_inf
    @current_stream_local = local_stream
    @current_stream_is_inf = is_inf

    stream_capture_map = captured.map { |name, _| [name, "ctx.#{name}"] }.to_h
    # Lower stream body to MIR nodes (for checker visibility) and build Zig strings.
    stream_run_body = nil
    body_code = with_fiber_capture_map(stream_capture_map, rt_override: "__rt") do
      body_mir = node.body.map { |expr| lower(expr) }
      stream_run_body = body_mir
      body_mir.map { |mir|
        code = emit_expr(mir)
        code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      }.join("\n            ")
    end

    @current_stream_local = prev_stream_local
    @current_stream_is_inf = prev_stream_is_inf

    promoted_decls = fiber_promoted_decls_zig(promoted_names, alloc_var)
    string_frees = bg_string_promotes.filter_map { |n| "defer ctx.alloc.free(ctx.#{n});" }.join("\n                    ")

    task_cfg = task_config_zig(node.stack_size, node.computed_stack_tier)
    spawn_call = fiber_spawn_call_zig(rt_name, ctx_type, ctx_var, task_cfg, :local)

    sg_code = <<~ZIG.chomp
      #{blk_label}: {
          const #{ctx_type} = struct {
              stream_inner: *#{stream_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_sg#{id}: *anyopaque, __raw_args_sg#{id}: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_sg#{id})));
                  #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_sg#{id}.?)));
                  defer ctx.alloc.destroy(ctx);
                  #{is_inf ? "defer ctx.alloc.destroy(ctx.stream_inner);" : ""}
                  #{string_frees}
                  var #{local_stream} = #{stream_zig}{ .inner = ctx.stream_inner, .alloc = ctx.alloc };
                  defer #{local_stream}.close();
                  errdefer |gen_err| #{local_stream}.inner.err = gen_err;
                  #{body_code}
              }
          };
          const #{alloc_var} = #{rt_name}.getSched().allocator;
          const #{stream_var} = try #{stream_zig}.spawnNew(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{blk_label} #{stream_var};
      }
    ZIG
    MIR::BgBlock.new(sg_code, captured, stream_run_body || [])
  end

  def lower_yield(node)
    stream_local = @current_stream_local || "__stream_local"
    lowered = lower(node.expr)
    if node.yield_dupe
      # Frame string: dupe to stream allocator before push so the value outlives
      # the fiber's frame rewind (or loop mark rewind between yields).
      # PHASE-3 (task #46, blocked by task #51): the dupe is embedded in an InlineZig
      # arg; hoisting requires a structured MIR::FnDef for the BG stream fiber body.
      inner_code = emit_expr(lowered)
      dupe_iz = MIR::InlineZig.new(
        "try #{stream_local}.alloc.dupe(u8, #{inner_code})",
        "yield_string_dupe"
      )
      dupe_iz.stdlib_def = { allocates: true }
      return MIR::MethodCall.new(MIR::Ident.new(stream_local), "push", [dupe_iz], true)
    end
    MIR::MethodCall.new(MIR::Ident.new(stream_local), "push", [lowered], true)
  end

  def lower_next_expr(node, alloc_sym = :frame)
    promise_type = node.expr.respond_to?(:full_type) ? Type.new(node.expr.full_type || :Void) : nil

    if promise_type&.promise_list?
      # NEXT on ~T[]@list: iterate the promise list, await each promise, collect results.
      # alloc_sym determines whether results are heap- or frame-allocated (caller passes
      # decl_alloc from the enclosing VarDecl so the allocator matches the cleanup plan).
      inner = lower(node.expr)
      inner_str = emit_expr(inner)
      elem_zig = promise_type.tense_type.element_type.zig_type
      @tmp_counter += 1
      blk_label = "__next_all_#{@tmp_counter}"
      results_var = "__next_results_#{@tmp_counter}"
      alloc_fn = alloc_sym == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
      code = "#{blk_label}: {\n" \
             "    var #{results_var} = std.ArrayListUnmanaged(#{elem_zig}).empty;\n" \
             "    for (#{inner_str}.items) |__p| {\n" \
             "        try #{results_var}.append(#{alloc_fn}, try __p.next());\n" \
             "    }\n" \
             "    break :#{blk_label} #{results_var};\n" \
             "}"
      return MIR::InlineZig.new(code, "next_promise_list")
    end

    inner = lower(node.expr)
    MIR::MethodCall.new(inner, "next", [], true)
  end

  def lower_static_call(node)
    pattern = node.zig_pattern.dup
    # Hoist any heap-allocating args to named Lets via hoist_alloc so the
    # checker can verify their cleanup. Non-allocating args (and frame allocs)
    # are left inline -- the pending Lets are emitted by lower_body's
    # flush_pending before the enclosing statement.
    arg_strs = node.args.map { |a| emit_expr(hoist_alloc(lower(a), a)) }
    arg_strs.each_with_index { |arg, i| pattern = pattern.gsub("{#{i}}", arg) }
    iz = MIR::InlineZig.new(pattern, "static_call")
    iz.stdlib_def = node.matched_stdlib_def if node.matched_stdlib_def
    iz
  end

  def lower_or_exit(node)
    rt = MIR::Ident.new(@rt_name)
    msg_node = node.message ? lower(node.message) : MIR::Lit.new('""')
    set_error = MIR::MethodCall.new(rt, "setError", [
      MIR::Ident.new(".System"), MIR::Lit.new('""'), msg_node, MIR::Lit.new(node.token.line.to_s)
    ], false)
    ret = MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
    MIR::ScopeBlock.new([MIR::ExprStmt.new(set_error, false), ret])
  end

  # ================================================================
  # Test framework
  # ================================================================

  TEST_PREAMBLE = <<~ZIG.chomp
    var da = std.heap.DebugAllocator(.{}){};
        defer _ = da.deinit();
        const allocator = da.allocator();
        var global_ctx = EbrContext{};
        defer global_ctx.deinit(allocator);
        var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
        defer rt.deinit();
        rt.wireAllocator();
  ZIG

  def lower_test_block(node)
    test_name = node.name
    setup_zig = emit_stmts_zig(lower_body(node.setup), indent: "    ")

    tests = []
    (node.whens || []).each do |when_block|
      when_desc = when_block.description

      prev_stubs = (@active_stubs || {}).dup
      @active_stubs = prev_stubs.dup

      stubs = when_block.setup.select { |s| s.is_a?(AST::StubDecl) }
      non_stub_setup = when_block.setup.reject { |s| s.is_a?(AST::StubDecl) }
      when_setup_zig = emit_stmts_zig(lower_body(non_stub_setup), indent: "    ")
      # TEST-INFRA: stub decls emit Zig test scaffolding; not program memory.
      stub_decls = stubs.map { |s| emit_expr(lower(s)) }.join("\n    ")

      (when_block.tests || []).each do |test_that|
        full_name = "#{test_name}: #{when_desc}: #{test_that.description}"
        body_zig = emit_stmts_zig(lower_body(test_that.body), indent: "    ")

        tests << <<~ZIG
          test "#{full_name}" {
              #{TEST_PREAMBLE}
              #{stub_decls}
              #{setup_zig}
              #{when_setup_zig}
              #{body_zig}
          }
        ZIG
      end

      (when_block.benchmarks || []).each do |b|
        bench_name = "#{test_name}: #{when_desc}: benchmark"
        # TEST-INFRA: benchmark expression for Zig test block; not program memory.
        bench_zig = emit_expr(lower(b))
        tests << <<~ZIG
          test "#{bench_name}" {
              #{TEST_PREAMBLE}
              #{stub_decls}
              #{setup_zig}
              #{when_setup_zig}
              #{bench_zig}
          }
        ZIG
      end
      @active_stubs = prev_stubs
    end

    MIR::RawZig.new(tests.join("\n"), "test_block",
      { consumes: [], produces: [], borrows: [] })
  end

  def lower_assert_raises(node)
    rt_name = @rt_name
    kind = node.kind
    # TEST-INFRA: ASSERT_RAISES expression assembled as raw Zig; not program memory.
    expr_zig = emit_expr(lower(node.expression))
    error_check = node.error_name ? " and !#{rt_name}.__error.matchesName(\"#{node.error_name}\")" : ""
    ar_code = <<~ZIG.chomp
      {
          if (#{expr_zig}) |_| {
              @panic("ASSERT_RAISES: expected #{kind} error but none raised");
          } else |_| {
              if (!#{rt_name}.__error.matchesKind(.#{kind})#{error_check}) {
                  @panic("ASSERT_RAISES: expected #{kind} error, got different kind");
              }
          }
      }
    ZIG
    MIR::RawZig.new(ar_code, "assert_raises",
      { consumes: [], produces: [], borrows: [] })
  end

  def lower_stub_decl(node)
    fn_name = node.function_name
    stub_var = "__stub_#{fn_name}"
    @active_stubs ||= {}

    case node.kind
    when :returns
      val = lower(node.value)
      @active_stubs[fn_name] = { kind: :returns, var: stub_var }
      MIR::Let.new(stub_var, val, false, nil, nil)
    when :captures
      cap_name = node.value
      @active_stubs[fn_name] = { kind: :captures, var: cap_name }
      MIR::Let.new(cap_name, MIR::Lit.new("0"), true, "i64", "_ = &#{cap_name};")
    when :sequence
      values = node.value
      # TEST-INFRA: stub sequence values for test scaffolding; not program memory.
      items = if values.respond_to?(:items)
        values.items.map { |v| emit_expr(lower(v)) }
      else
        [emit_expr(lower(values))]
      end
      @active_stubs[fn_name] = { kind: :sequence, var: stub_var }
      arr_items = items.join(", ")
      MIR::RawZig.new(
        "const #{stub_var}_seq = [_][]const u8{ #{arr_items} };\nvar #{stub_var}_idx: usize = 0; _ = &#{stub_var}_idx;",
        "stub_sequence",
        { consumes: [], produces: [], borrows: [] }
      )
    when :with
      val = lower(node.value)
      @active_stubs[fn_name] = { kind: :with, var: stub_var }
      MIR::Let.new(stub_var, val, false, nil, nil)
    else
      raise "MIRLowering: unhandled StubDecl kind: #{node.kind} for #{fn_name}"
    end
  end

  def lower_benchmark(node)
    MIR::Comment.new("benchmark lowering placeholder")
  end

  def lower_smash(node)
    MIR::Comment.new("smash test placeholder")
  end

  def lower_profile(node)
    MIR::Comment.new("profile placeholder")
  end

  def lower_require(node)
    if node.kind == :package
      MIR::Import.new(node.namespace || node.path, "#{node.namespace || node.path}.zig", nil)
    else
      # Local require: compile the module and inline the Zig body
      raise "MIRLowering: REQUIRE \"#{node.path}\" but no importer available" unless @importer

      mod = @importer.compile_file(node.path, caller_dir: @source_dir)

      # Merge schemas so downstream code can resolve imported types
      merge_module_schemas!(mod)

      # Propagate fn_sigs from imported functions
      if mod.ast
        mod.ast.statements.each do |stmt|
          next unless stmt.is_a?(AST::FunctionDef)
          sig = stmt.full_type
          if sig.is_a?(FunctionSignature)
            @fn_sigs[stmt.name] = sig
          else
            fs = FunctionSignature.new(params: [], return_type: :Any)
            fs.needs_rt = stmt.needs_rt
            fs.can_fail = stmt.can_fail
            @fn_sigs[stmt.name] = fs
          end
        end
      end

      # Emit type definitions at file scope, then function body in struct wrapper
      same_dir = mod.source_dir == @source_dir
      file_scope_types = visible_type_defs(mod, same_dir: same_dir)
      body = mod.transpiled_body.strip
      fn_body = strip_all_type_defs(body)
      indented = fn_body.lines.map { |l| l.rstrip.empty? ? "" : "    #{l.rstrip}" }.join("\n")

      lines = []
      lines << file_scope_types if file_scope_types && !file_scope_types.strip.empty?
      lines << "const #{node.namespace} = struct {\n#{indented}\n};"
      MIR::RawZig.new(lines.join("\n"), "require_local",
        { consumes: [], produces: [], borrows: [] })
    end
  end

  def merge_module_schemas!(mod)
    if mod.struct_schemas
      @struct_schemas.merge!(mod.struct_schemas)
    end
    if mod.union_schemas
      @union_schemas.merge!(mod.union_schemas)
      mod.union_schemas.each do |uname, variants|
        variants.each do |var_name, var_data|
          next unless var_data.is_a?(Hash) && var_data[:indirect_fields]
          var_data[:indirect_fields].each do |fname|
            @indirect_fields["#{uname}_#{var_name}.#{fname}"] = true
          end
        end
      end
    end
    if mod.enum_schemas
      @enum_schemas.merge!(mod.enum_schemas)
    end
  end

  def visible_type_defs(mod, same_dir: false)
    return nil unless mod&.type_defs && !mod.type_defs.strip.empty?
    return nil unless mod&.ast

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
            next unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
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

  def strip_all_type_defs(body)
    lines = body.lines
    result = []
    i = 0
    while i < lines.length
      line = lines[i]
      if line =~ /\Aconst (\w+)\s*=\s*(struct|union\(enum\)|enum)\s*[\{(]/
        depth = line.count('{') - line.count('}')
        i += 1
        while i < lines.length && depth > 0
          depth += lines[i].count('{') - lines[i].count('}')
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
        depth = line.count('{') - line.count('}')
        i += 1
        while i < lines.length && depth > 0
          block_lines << lines[i]
          depth += lines[i].count('{') - lines[i].count('}')
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

  STACK_SIZE_ZIG_VARIANT = {
    nil       => "Standard",
    :micro    => "Micro", :standard => "Standard", :large => "Large", :xl => "Xl",
    "micro"   => "Micro", "standard" => "Standard", "large" => "Large", "xl" => "Xl",
    :service  => "Huge",
  }.freeze

  TIER_RANK = { "Micro" => 0, "Standard" => 1, "Large" => 2, "Xl" => 3, "Huge" => 4 }.freeze

  def task_config_zig(stack_size, computed_tier)
    default = "Standard"
    variant = if stack_size
      STACK_SIZE_ZIG_VARIANT.fetch(stack_size, default)
    elsif computed_tier
      computed = STACK_SIZE_ZIG_VARIANT.fetch(computed_tier, default)
      TIER_RANK.fetch(computed, 0) >= TIER_RANK.fetch(default, 0) ? computed : default
    else
      default
    end
    ".{ .stack_size = .#{variant} }"
  end

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
    else
      "try CheatHeader.spawnBest(\n    #{spawn_args}\n);"
    end
  end

  def fiber_string_promotes(node, id, prefix)
    promotes = node.capture_string_dupes || Set.new
    names = {}
    promotes.each { |name| names[name] = "__#{prefix}p_#{id}_#{name}" }
    [promotes, names]
  end

  def fiber_promoted_decls_zig(promoted_names, alloc_var)
    promoted_names.map { |name, promoted|
      "const #{promoted} = try #{alloc_var}.dupe(u8, #{name});\n            errdefer #{alloc_var}.free(#{promoted});"
    }.join("\n            ")
  end

  # ================================================================
  # Expressions
  # ================================================================

  def lower_literal(node)
    case node.type
    when :STRING
      escaped = node.value.bytes.map { |b|
        case b
        when 0x5C then '\\\\'
        when 0x22 then '\\"'
        when 0x0A then '\\n'
        when 0x0D then '\\r'
        when 0x09 then '\\t'
        when 0x00 then '\\x00'
        when 0x80..0xFF then "\\x#{'%02x' % b}"
        else b.chr
        end
      }.join
      MIR::Lit.new("\"#{escaped}\"")
    when :NUMBER
      if node.coerced_type == :Int64
        MIR::Lit.new(node.value.to_i.to_s)
      else
        s = node.value.to_s
        s = "#{s}.0" if node.value == node.value.to_i && !s.include?('.')
        MIR::Lit.new(s)
      end
    when :INT64    then MIR::Lit.new(node.value.to_s)
    when :INT8     then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i8", :as)
    when :INT16    then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i16", :as)
    when :INT32    then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i32", :as)
    when :UINT16   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u16", :as)
    when :UINT32   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u32", :as)
    when :UINT64   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u64", :as)
    when :FLOAT32
      s = node.value.to_s
      s = "#{s}.0" if node.value == node.value.to_i && !s.include?('.')
      MIR::Cast.new(MIR::Lit.new(s), "f32", :as)
    when :BOOLEAN  then MIR::Lit.new(node.value.to_s)
    when :NIL      then MIR::Lit.new("null")
    else
      MIR::Lit.new(node.value.to_s)
    end
  end

  def lower_identifier(node)
    # Pipeline bindings (@u, @v, @item, ...) are substituted by PipelineHost
    # before reaching the MIR lowering. If one arrives here it means it was
    # used outside its pipeline context (after the pipeline expression ended,
    # or in a pipeline that doesn't have a matching AS declaration).
    if node.name.match?(/\A@[a-z]/)
      line = node.token&.respond_to?(:line) ? node.token.line : "?"
      raise "line #{line}: Undefined pipeline binding '#{node.name}'. " \
            "Pipeline bindings must be declared with 'AS #{node.name}' " \
            "in the same pipeline expression where they are used."
    end

    return MIR::FnRef.new(zig_safe_name(node.name)) if node.respond_to?(:fn_ref) && node.fn_ref

    # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
    rc_map = @rc_unwrap_map || {}
    return MIR::Ident.new(rc_map[node.name]) if rc_map.key?(node.name)

    # Inside a WITH EXCLUSIVE block, rewrite original var name to the unwrapped inner alias
    locked_map = @locked_unwrap_map || {}
    alias_name = locked_map[node.name]
    return MIR::Ident.new(alias_name) if alias_name.is_a?(String)

    # Inside a DO block branch, access captured outer variables via ctx pointer
    capture_map = @do_capture_map || {}
    return MIR::Ident.new(capture_map[node.name]) if capture_map.key?(node.name)

    ident = MIR::Ident.new(zig_safe_name(node.name))
    # Loop-carry string: identifier was marked for heap dupe at the use site
    # (frame string being assigned to a heap-carry outer variable).
    return MIR::DupeSlice.new(ident, :heap) if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
    ident
  end

  def lower_unary_op(node)
    right = lower(node.right)
    case node.op
    when :NOT, "!" then MIR::UnaryOp.new("!", right)
    when :SUB, "-" then MIR::UnaryOp.new("-", right)
    when :BITWISE_NOT, "~" then MIR::UnaryOp.new("~", right)
    else raise "MIRLowering: unknown unary op #{node.op}"
    end
  end

  def lower_binary_op(node)
    # Pipeline operator: x s> f -> f(x), or complex pipeline ops
    return lower_smooth(node) if node.op == :SMOOTH

    # Error chain: expr OR handler
    return lower_or_rescue(node) if node.op == :OR_RESCUE

    # Named pipeline binding (AS @v): passthrough to LHS value.
    # The @v registration is handled by the pipeline host at the binding point.
    return lower(node.left) if node.op == :BIND_VAR

    # String concat (2-part) uses std.mem.concat
    if node.string_concat
      left = hoist_alloc(lower(node.left), node.left)
      right = hoist_alloc(lower(node.right), node.right)
      alloc = alloc_for_node(node)
      return MIR::ConcatStr.new([left, right], alloc, nil)
    end

    left = lower(node.left)
    right = lower(node.right)

    # Power operator
    if node.op == :POW
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      type_arg = resolved == :Int64 ? "i64" : "f64"
      return MIR::Call.new("std.math.pow", [MIR::Ident.new(type_arg), left, right], false)
    end

    # Modulo on signed int
    if node.op == :MOD
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      if resolved == :Int64
        return MIR::Call.new("@mod", [left, right], false)
      end
    end

    # String comparison
    if Type.new(node.left.full_type).string? || Type.new(node.right.full_type).string?
      # Hoist allocating sub-expressions so their heap strings get cleanup.
      # (e.g. ASSERT f() == "x" -- f() returns a heap string that needs freeing)
      left = hoist_alloc(left, node.left)
      right = hoist_alloc(right, node.right)
      cmp_node = case node.op
            when :EQ  then emit_builtin(:eql, [left, right])
            when :NEQ then MIR::UnaryOp.new("!", emit_builtin(:eql, [left, right]))
            when :LT  then MIR::BinOp.new("<",  emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :LTE then MIR::BinOp.new("<=", emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :GT  then MIR::BinOp.new(">",  emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :GTE then MIR::BinOp.new(">=", emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            end
      return cmp_node if cmp_node
    end

    # Integer division
    if node.op == :DIV
      left_ti = node.left.type_info
      right_ti = node.right.type_info
      if left_ti&.integer? && right_ti&.integer?
        return MIR::Call.new("@divTrunc", [left, right], false)
      end
    end

    # Wrapping operators
    if %i[WRAP_ADD WRAP_SUB WRAP_MUL].include?(node.op)
      fn = { WRAP_ADD: :wrapAdd, WRAP_SUB: :wrapSub, WRAP_MUL: :wrapMul }[node.op]
      return emit_builtin(fn, [left, right])
    end

    # Checked operators
    if %i[CHECK_ADD CHECK_SUB CHECK_MUL].include?(node.op)
      fn = { CHECK_ADD: :checkAdd, CHECK_SUB: :checkSub, CHECK_MUL: :checkMul }[node.op]
      return emit_builtin(fn, [left, right])
    end

    # Default integer arithmetic: checked in debug
    if %i[ADD SUB MUL].include?(node.op)
      left_ti = node.left.type_info
      right_ti = node.right.type_info
      left_is_comptime = node.left.is_a?(AST::Literal) && node.left.type == :NUMBER && !left_ti&.integer?
      right_is_comptime = node.right.is_a?(AST::Literal) && node.right.type == :NUMBER && !right_ti&.integer?
      both_int = left_ti&.integer? && right_ti&.integer?
      no_lits = !left_is_comptime && !right_is_comptime
      no_float_coerce = !node.left.respond_to?(:coerced_type) || node.left.coerced_type.nil? || Type.new(node.left.coerced_type).integer?
      no_float_coerce &&= !node.right.respond_to?(:coerced_type) || node.right.coerced_type.nil? || Type.new(node.right.coerced_type).integer?
      if both_int && no_lits && no_float_coerce
        fn = { ADD: :intAdd, SUB: :intSub, MUL: :intMul }[node.op]
        return emit_builtin(fn, [left, right])
      end
    end

    # Standard operators
    op_str = ZigTypeMapper::ZIG_OPS[node.op]
    raise "MIRLowering: unknown binary op #{node.op}" unless op_str
    MIR::BinOp.new(op_str, left, right)
  end

  # ================================================================
  # Pipeline (SMOOTH) operator
  # ================================================================

  def lower_smooth(node)
    rhs = node.right

    # Complex pipeline ops that survived PipelineRewriter (pool/sharded/SOA
    # sources, OrderByOp, IndexOp, WindowOp, JoinOp, ConcurrentOp).
    # All decisions are made here in lowering -- RawZig is INV-7 compliant.
    complex_ops = [
      AST::SelectOp, AST::WhereOp, AST::IndexOp, AST::ReduceOp,
      AST::OrderByOp, AST::LimitOp, AST::UnnestOp, AST::DistinctOp,
      AST::EachOp, AST::FindOp, AST::AnyOp, AST::AllOp,
      AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp,
      AST::TakeWhileOp, AST::WindowOp, AST::JoinOp, AST::RecoverOp,
      AST::TapOp, AST::SkipOp, AST::ShardOp, AST::ConcurrentOp
    ]
    if complex_ops.any? { |t| rhs.is_a?(t) }
      # Test fallback bypasses pipeline host entirely
      if @pipeline_fallback
        zig_code = @pipeline_fallback.call(node)
        inner = MIR::RawZig.new(zig_code, "pipeline_#{rhs.class.name.split('::').last.downcase}",
          { consumes: [], produces: [], borrows: [] })
        return MIR::Pipeline.new(node, inner, nil, nil, nil, nil)
      end

      host = pipeline_host

      # Detect source type for pipeline IR metadata.
      source_type = node.left.is_a?(AST::RangeLit) ? :range : nil

      # Try MIR path first (migrated operators return MIR node tree)
      mir_result = host.lower_pipeline(node)
      return MIR::Pipeline.new(node, mir_result, source_type, nil, nil, nil) if mir_result

      # Fall back to string path (non-migrated operators)
      zig_code = host.transpile_pipeline(node)
      inner = MIR::RawZig.new(zig_code, "pipeline_#{rhs.class.name.split('::').last.downcase}",
        { consumes: [], produces: [], borrows: [] })
      return MIR::Pipeline.new(node, inner, source_type, nil, nil, nil)
    end

    # RecoverOp: x s> RECOVER(default) -> (x catch default)
    if rhs.is_a?(AST::RecoverOp)
      left = lower(node.left)
      default_val = lower(rhs.default_expr)
      return MIR::TryCatch.new(strip_try(left), default_val, nil)
    end

    # Simple pipe: x s> f -> f(x) or x s> f(y) -> f(x, y)
    left = lower(node.left)
    left_zig = emit_expr(left)

    # Capture snapshot for CATCH blocks: store LHS before the failable call
    snapshot_stmts = nil
    if @current_fn_has_catch
      lhs_type = node.left.respond_to?(:full_type) ? node.left.full_type : nil
      if lhs_type
        t = Type.new(lhs_type)
        unless t.void? || t.error_union?
          snap_zig_type = transpile_type(t)
          snapshot_stmts = [
            MIR::Let.new("__snap_input", left, false, nil, nil),
            MIR::ExprStmt.new(
              MIR::MethodCall.new(MIR::Ident.new(@rt_name), "captureSnapshot", [
                MIR::Ident.new(snap_zig_type),
                MIR::AddressOf.new(MIR::Ident.new("__snap_input"))
              ], false), false)
          ]
          # Rewrite left to use the hoisted variable
          left = MIR::Ident.new("__snap_input")
        end
      end
    end

    call_mir = if rhs.is_a?(AST::Identifier)
      # x s> f -> f(x)
      synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left])
      synthetic.full_type = node.full_type
      synthetic.storage = node.storage if node.respond_to?(:storage)
      synthetic.zig_pattern = rhs.zig_pattern if rhs.respond_to?(:zig_pattern) && rhs.zig_pattern
      lower_func_call(synthetic)
    elsif rhs.is_a?(AST::FuncCall)
      # x s> f(y) -> f(x, y)
      synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left] + rhs.args)
      synthetic.full_type = node.full_type || rhs.full_type
      synthetic.storage = node.storage if node.respond_to?(:storage)
      synthetic.zig_pattern = rhs.zig_pattern if rhs.respond_to?(:zig_pattern) && rhs.zig_pattern
      if rhs.respond_to?(:coerced_type) && rhs.coerced_type
        synthetic.coerced_type = rhs.coerced_type
      end
      lower_func_call(synthetic)
    else
      raise "MIRLowering: unhandled SMOOTH RHS #{rhs.class}"
    end

    if snapshot_stmts
      label = "__snap_blk"
      MIR::BlockExpr.new(label, snapshot_stmts + [MIR::BreakStmt.new(label, call_mir)])
    else
      call_mir
    end
  end

  # ================================================================
  # OR_RESCUE error chain
  # ================================================================

  def lower_or_rescue(node)
    t_left = node.left.respond_to?(:full_type) && node.left.full_type ? Type.new(node.left.full_type) : nil
    is_error = (t_left&.error_union?) || (node.left.respond_to?(:can_fail) && node.left.can_fail)

    left = lower(node.left)

    # OR RAISE: bubble up error (Zig's try)
    if node.right.is_a?(AST::OrRaise)
      # Extern trampolines already propagate errors internally (if frame.err |e| return e).
      # Wrapping in TryExpr produces invalid `try { block }` — Zig's try takes an expression.
      return left if left.is_a?(MIR::InlineZig) && left.reason == "extern_trampoline"
      return MIR::TryExpr.new(strip_try(left)) if is_error
      return left
    end

    # OR EXIT "message": set error context + propagate
    if node.right.is_a?(AST::OrExit)
      if is_error
        rt = MIR::Ident.new(@rt_name)
        msg_node = node.right.message ? lower(node.right.message) : MIR::Lit.new('""')
        line = node.respond_to?(:token) && node.token ? node.token.line : 0
        error_obj = MIR::FieldGet.new(rt, "__error")
        set_msg = MIR::Set.new(MIR::FieldGet.new(error_obj, "message"), msg_node)
        set_line = MIR::Set.new(MIR::FieldGet.new(error_obj, "clear_line"), MIR::Lit.new(line.to_s))
        ret_err = MIR::ReturnStmt.new(MIR::Ident.new("__exit_err"))
        catch_block = MIR::ScopeBlock.new([set_msg, set_line, ret_err])
        return MIR::TryCatch.new(strip_try(left), catch_block, "__exit_err")
      end
      return left
    end

    # OR PASS: ignore error (Zig's catch undefined)
    if node.right.is_a?(AST::OrPass)
      return MIR::TryCatch.new(strip_try(left), MIR::Ident.new("undefined"), nil) if is_error
      return left
    end

    # OR BREAK: error-to-break (Zig's catch break)
    if node.right.is_a?(AST::OrBreak)
      return MIR::TryCatch.new(strip_try(left), MIR::Ident.new("break"), nil) if is_error
      return left
    end

    # OR PRUNE: same as OR PASS for now
    if node.right.is_a?(AST::OrPrune)
      return MIR::TryCatch.new(strip_try(left), MIR::Ident.new("undefined"), nil) if is_error
      return left
    end

    # Default: expr OR fallback -> error union catch or optional orelse
    right = lower(node.right)

    if is_error
      # or_fallback_dupe annotated directly on BinaryOp node
      if node.or_fallback_dupe && node.right.is_a?(AST::StructLit)
        ret_type = node.right.full_type
        ret_type = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type) if ret_type
        resolved = ret_type&.resolved
        schema = @struct_schemas&.dig(resolved)
        string_fields = schema&.filter_map do |fname, fdef|
          next if fname.is_a?(Symbol)
          ft = (fdef.is_a?(Hash) ? fdef[:type] : fdef)
          ft = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
          fname if ft.string?
        end || []
        if string_fields.any?
          rt_name = @rt_name
          left_raw = emit_expr(strip_try(left))
          right_zig = emit_expr(right)
          # Dupe each string field with proper cleanup on partial failure:
          # - First field: `try dupe(...)` — propagates OOM, no prior state to clean up.
          # - Each subsequent field: catch, free all previously-duped fields, re-return error.
          #   This prevents leaking heap-duped fields if a later dupe fails under OOM.
          promos = string_fields.each_with_index.map { |f, i|
            if i == 0
              "__fb.#{f} = try #{rt_name}.heapAlloc().dupe(u8, __fb.#{f});"
            else
              frees = string_fields[0...i].map { |prev| "#{rt_name}.heapAlloc().free(__fb.#{prev});" }.join(" ")
              "__fb.#{f} = #{rt_name}.heapAlloc().dupe(u8, __fb.#{f}) catch |__dupe_err| { #{frees} return __dupe_err; };"
            end
          }.join(" ")
          return MIR::RawZig.new(
            "(#{left_raw} catch __fb: { var __fb = #{right_zig}; #{promos} break :__fb __fb; })",
            "or_fallback_dupe",
            { consumes: [], produces: [], borrows: [] }
          )
        end
      end

      return MIR::TryCatch.new(strip_try(left), right, nil)
    end

    # Optional orelse
    MIR::Orelse.new(left, right)
  end

  def lower_get_field(node)
    # Union unit-variant constructor: Type{ .Variant = {} }
    if node.target.is_a?(AST::Identifier)
      schema = @union_schemas&.dig(node.target.name.to_sym)
      if schema
        var_data = schema[node.field]
        unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
          return MIR::StructInit.new(node.target.name, [{ name: node.field.to_s, value: MIR::Lit.new("{}") }])
        end
      end
    end

    # Safe field access on optional Rc/Arc: expr?.field
    # AST::OptionalUnwrap + multiowned/shared inner type -> force-unwrap would panic on nil.
    # Generate (if (expr) |_r| _r.ctrl.data.field else null) so the result stays ?FieldType
    # and a subsequent OR fallback can orelse it correctly.
    if node.target.is_a?(AST::OptionalUnwrap)
      inner_ti = node.target.type_info  # unwrapped type set by visit_OptionalUnwrap
      if inner_ti&.multiowned? || inner_ti&.shared?
        inner_mir = lower(node.target.target)
        inner_zig = emit_expr(inner_mir)
        return MIR::RawZig.new(
          "(if (#{inner_zig}) |_r| _r.ctrl.data.#{node.field} else null)",
          "optional_rc_field_get",
          { consumes: [], produces: [], borrows: [] }
        )
      end
    end

    target = lower(node.target)
    ti = node.target.type_info

    # Rc/Arc: unwrap through .ctrl.data
    rc_map = @rc_unwrap_map || {}
    locked_map = @locked_unwrap_map || {}
    is_rc_unwrapped = node.target.is_a?(AST::Identifier) && rc_map.key?(node.target.name)
    is_locked_unwrapped = node.target.is_a?(AST::Identifier) && locked_map.key?(node.target.name)

    if (ti&.multiowned? || ti&.shared?) && !is_rc_unwrapped
      # target.ctrl.data.field
      ctrl = MIR::FieldGet.new(target, "ctrl")
      data = MIR::FieldGet.new(ctrl, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    elsif (ti&.locked? || ti&.write_locked?) && !is_locked_unwrapped
      # target.ctrl.data.field
      ctrl = MIR::FieldGet.new(target, "ctrl")
      data = MIR::FieldGet.new(ctrl, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    elsif ti&.always_mutable? && !is_locked_unwrapped
      # target.data.field
      data = MIR::FieldGet.new(target, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    end

    result = MIR::FieldGet.new(target, node.field.to_s)

    # Auto-dereference @indirect fields
    target_type = ti&.resolved.to_s
    if @indirect_fields&.dig("#{target_type}.#{node.field}")
      return MIR::Deref.new(result)
    end

    result
  end

  def lower_get_index(node)
    target = lower(node.target)
    index = lower(node.index)
    ti = node.target.type_info

    # Auto-deref Arc/Rc-wrapped maps: target.ctrl.data.*
    if ti&.map? && (ti&.shared? || ti&.multiowned?)
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end

    if node.target.metatype == :hashmap
      target_var = node.target.is_a?(AST::Identifier) ? node.target.name : nil
      map_ft = Type.new(node.target.full_type)
      if @shard_context && target_var == @shard_context[:map]
        # Inside SHARD body: use getDirect (no routing, no sendAndWait)
        target_zig = emit_expr(target)
        kind = map_ft.numeric_map? ? :numeric_map : :string_map
        op = INDEX_OPS.dig(kind, :get)
        pattern = op[:shard_direct_zig].dup
        pattern = pattern.gsub("{target}", target_zig)
        pattern = pattern.gsub("{shard_idx}", @shard_context[:idx])
        pattern = pattern.gsub("{shard_key}", @shard_context[:key])
        MIR::InlineZig.new(pattern, "shard_direct_get")
      elsif map_ft.numeric_map? && !(map_ft.sharded? || map_ft.striped?)
        key_zig = map_ft.key_type.zig_type
        val_zig = map_ft.value_type.zig_type
        emit_builtin(:numericMapGet, [MIR::Ident.new(key_zig), MIR::Ident.new(val_zig), target, index])
      else
        MIR::MethodCall.new(target, "get", [index], false)
      end
    elsif ti&.pool?
      MIR::MethodCall.new(target, "get", [index], false)
    elsif node.needs_mut_ref
      # target.items[@as(usize, @intCast(index))]
      items = MIR::FieldGet.new(target, "items")
      cast_idx = MIR::Cast.new(index, "usize", :intCast)
      MIR::IndexGet.new(items, cast_idx)
    elsif ti && direct_indexable_collection_type?(ti)
      direct_index_get(target, index, node.target, ti) || begin
        builtin = INDEX_OPS.dig(ti&.dispatch_key, :get, :builtin) || :getAt
        emit_builtin(builtin, [target, index])
      end
    else
      # Registry-driven: dispatch_key → INDEX_OPS get :builtin (string_raw → charAt,
      # array → getAt, etc.). Falls back to :getAt for unregistered types.
      builtin = INDEX_OPS.dig(ti&.dispatch_key, :get, :builtin) || :getAt
      emit_builtin(builtin, [target, index])
    end
  end

  def lower_struct_lit(node)
    # Collect hoisted statements for @indirect fields.
    # Each @indirect field is allocated to a temp Let before the StructInit so
    # the HeapCreate is in Let-init position (not an anonymous sub-expression).
    hoisted = []

    fields = node.fields.map { |k, v|
      val = if rc_retain_needed?(v)
        make_rc_retain(v)
      else
        # err_cleanup: struct owns its fields on success; only clean up on error.
        hoist_alloc(lower(v), v, err_cleanup: true)
      end
      vt = v.type_info.is_a?(Type) ? v.type_info : nil
      needs_items = vt&.list_collection? && !v.is_a?(AST::CopyNode) &&
                    !(v.respond_to?(:target_is_list_field) && v.target_is_list_field)
      # BORROWED fields: source may be ArrayList but field expects slice
      field_def = @struct_schemas&.dig(node.name.to_sym, k)
      if field_def.is_a?(Hash) && field_def[:borrowed] && vt&.array? && !needs_items
        val = MIR::ItemsAccess.new(val, true)
      elsif needs_items
        val = MIR::ItemsAccess.new(val, false)
      end
      # @indirect field: hoist HeapCreate to a named temp so it is a Let-init,
      # not an anonymous sub-expression (INV-H).
      if v.respond_to?(:needs_heap_create) && v.needs_heap_create
        zig_t = v.type_info ? transpile_type(v.type_info.resolved.to_s) : "UNKNOWN"
        @block_expr_counter += 1
        temp = "__ind_#{@block_expr_counter}_#{k}"
        hc = MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}")
        hoisted << MIR::AllocMark.new(temp, :heap)
        hoisted << MIR::Let.new(temp, hc, false, nil, nil)
        # errdefer cleans this field if a later allocation (another field or
        # the outer struct pointer) fails.
        hoisted << MIR::ErrDeferStmt.new(
          MIR::DestroyPtr.new(MIR::Ident.new(temp), :heap)
        )
        val = MIR::Ident.new(temp)
      end
      { name: k.to_s, value: val }
    }

    type_name = if node.type_args&.any?
      zig_args = node.type_args.map { |a| Type.new(a.to_sym).zig_type }.join(", ")
      "#{node.name}(#{zig_args})"
    else
      node.name.to_s
    end

    init = MIR::StructInit.new(type_name, fields)

    # Heap/frame allocated struct → pointer
    result = if node.storage == :heap || node.storage == :frame
      alloc = alloc_for_node(node)
      MIR::HeapCreate.new(type_name, init, alloc, "blk")
    else
      init
    end

    # Wrap in BlockExpr if @indirect fields were hoisted, so the AllocMark
    # nodes are visible to the MIR checker.
    if hoisted.any?
      @block_expr_counter += 1
      label = "__ind_blk_#{@block_expr_counter}"
      hoisted << MIR::BreakStmt.new(label, result)
      MIR::BlockExpr.new(label, hoisted)
    else
      result
    end
  end

  def lower_union_variant_lit(node)
    schema = @union_schemas&.dig(node.union_name.to_sym)
    var_data = schema&.dig(node.variant_name)
    indirect = (var_data.is_a?(Hash) && var_data[:indirect_fields]) || Set.new

    # Collect hoisted statements for @indirect fields (same pattern as lower_struct_lit).
    hoisted = []

    variant_struct_name = "#{node.union_name}_#{node.variant_name}"
    field_values = node.fields.map { |k, v|
      # err_cleanup: union owns its payload on success; only clean up on error.
      val = hoist_alloc(lower(v), v, err_cleanup: true)
      if indirect.include?(k)
        zig_t = transpile_type(var_data[:fields][k])
        @block_expr_counter += 1
        temp = "__ind_#{@block_expr_counter}_#{k}"
        hc = MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}")
        hoisted << MIR::AllocMark.new(temp, :heap)
        hoisted << MIR::Let.new(temp, hc, false, nil, nil)
        hoisted << MIR::ErrDeferStmt.new(
          MIR::DestroyPtr.new(MIR::Ident.new(temp), :heap)
        )
        val = MIR::Ident.new(temp)
      end
      { name: k.to_s, value: val }
    }

    inner = MIR::StructInit.new(variant_struct_name, field_values)
    result = MIR::StructInit.new(node.union_name.to_s, [
      { name: node.variant_name.to_s, value: inner }
    ])

    if hoisted.any?
      @block_expr_counter += 1
      label = "__ind_blk_#{@block_expr_counter}"
      hoisted << MIR::BreakStmt.new(label, result)
      MIR::BlockExpr.new(label, hoisted)
    else
      result
    end
  end

  def lower_string_concat(node)
    parts = node.parts.map { |p| hoist_alloc(lower(p), p) }
    alloc = alloc_for_node(node)
    MIR::ConcatStr.new(parts, alloc, @rt_name)
  end

  def lower_block_expr(node)
    @block_expr_counter += 1
    label = "__blk_#{@block_expr_counter}"
    body = lower_body(node.body)
    result = lower(node.result)
    body << MIR::BreakStmt.new(label, result)
    MIR::BlockExpr.new(label, body)
  end

  def lower_range_lit(node)
    s = lower(node.start)
    e = lower(node.finish)
    elem_type = node.type_info&.tense_type&.element_type&.resolved
    if node.inclusive
      MIR::RangeLit.new(s, MIR::BinOp.new("+", e, MIR::Lit.new("1")), elem_type)
    else
      MIR::RangeLit.new(s, e, elem_type)
    end
  end

  def lower_slice(node)
    target = lower(node.target)
    start_expr = lower(node.start)
    end_expr = lower(node.end)
    exclusive = node.instance_variable_get(:@exclusive)

    target_ti = node.target.type_info
    if target_ti&.list_collection? || target_ti&.array?
      target = MIR::ItemsAccess.new(target, true)
    end

    start_cast = MIR::Cast.new(start_expr, "usize", :intCast)
    end_cast = if exclusive
      MIR::Cast.new(end_expr, "usize", :intCast)
    else
      MIR::BinOp.new("+", MIR::Cast.new(end_expr, "usize", :intCast), MIR::Lit.new("1"))
    end

    elem_zig = node.target.type_info&.element_type ? Type.new(node.target.type_info.element_type).zig_type : "u8"
    MIR::SliceExpr.new(target, start_cast, end_cast, elem_zig)
  end

  def lower_assert(node)
    cond = lower(node.condition)
    msg = node.message.to_s.gsub('"', '\\"')
    emit_builtin(:assert, [cond, MIR::Lit.new("\"#{msg}\"")])
  end

  def lower_raise(node)
    rt = MIR::Ident.new(@rt_name)
    kind = ".#{node.kind || :Unknown}"
    error_name = node.error_name ? node.error_name.to_s : ""
    msg_expr = node.message_expr ? lower(node.message_expr) : MIR::Lit.new('""')
    line = node.token.line.to_s

    set_error = MIR::MethodCall.new(rt, "setError", [
      MIR::Ident.new(kind),
      MIR::Lit.new("\"#{error_name}\""),
      msg_expr,
      MIR::Lit.new(line)
    ], false)

    ret = MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
    MIR::ScopeBlock.new([MIR::ExprStmt.new(set_error, false), ret])
  end

  # ================================================================
  # Memory / capability expressions
  # ================================================================

  def lower_copy(node)
    source = lower(node.value)
    ti = node.value.type_info
    alloc = :heap

    if ti && @union_schemas&.key?(ti.resolved)
      MIR::DeepCopy.new(source, transpile_type(ti), nil, :union, alloc)
    elsif ti&.string?
      MIR::DeepCopy.new(source, nil, nil, :string, alloc)
    elsif ti&.list_collection? || (ti&.array? && !ti&.string?)
      elem_type = ti.element_type
      elem_zig = transpile_type(elem_type)
      needs_deep = node.respond_to?(:deep_copy) && node.deep_copy
      strategy = needs_deep ? :list_deep : :list_shallow
      src = ti&.list_collection? ? MIR::ItemsAccess.new(source, false) : source
      MIR::DeepCopy.new(src, nil, elem_zig, strategy, alloc)
    else
      MIR::DeepCopy.new(source, nil, nil, :passthrough, nil)
    end
  end

  def lower_clone(node)
    ti = node.value.type_info
    func = if ti&.split_open_stream?
      "splitRetain"
    elsif ti&.shared_promise?
      "arcRetain"
    else
      raise "Internal: lower_clone on unsupported type #{ti&.resolved || node.value.resolved_type}"
    end
    zig_base = ti&.split_open_stream? ? ti.zig_type : transpile_type(ti.resolved.to_s)
    MIR::RcRetain.new(lower(node.value), zig_base, func)
  end

  def lower_move(node)
    if node.value.is_a?(AST::Identifier)
      MIR::Ident.new(zig_safe_name(node.value.name))
    else
      lower(node.value)
    end
  end

  def lower_cap_wrap(node)
    inner = lower(node.value)
    base_type = node.value.resolved_type.to_s
    zig_base = transpile_type(base_type)
    alloc = :heap

    sync_fn = case node.sync
              when :locked then "lockedCreate"
              when :write_locked then "rwLockedCreate"
              when :always_mutable then "refCellCreate"
              end
    sync_type = case node.sync
                when :locked then "CheatLib.Locked(#{zig_base})"
                when :write_locked then "CheatLib.RwLocked(#{zig_base})"
                when :always_mutable then "CheatLib.RefCell(#{zig_base})"
                end
    own_fn = case node.ownership
             when :shared then "arcCreate"
             when :multiowned then "rcCreate"
             end

    strategy = if node.sync == :local || (node.layout == :indirect && !node.sync && !node.ownership)
      :local
    elsif sync_fn && own_fn
      :both
    elsif sync_fn
      :sync_only
    elsif own_fn
      :own_only
    else
      :passthrough
    end

    MIR::CapWrap.new(inner, zig_base, strategy, sync_fn, sync_type, own_fn, alloc)
  end

  def lower_link(node)
    inner = lower(node.value)
    ti = node.value.type_info
    base = transpile_type(ti.resolved.to_s)
    func = ti.shared? ? "arcDowngrade" : "rcDowngrade"
    MIR::RcDowngrade.new(inner, base, func)
  end

  def lower_resolve(node)
    inner = lower(node.value)
    ti = node.value.type_info
    base = transpile_type(ti.resolved.to_s)
    source = ti.link_source || :multiowned
    func = source == :shared ? "weakArcUpgrade" : "weakRcUpgrade"
    MIR::WeakUpgrade.new(inner, base, func)
  end

  # ================================================================
  # Declarations
  # ================================================================

  def lower_var_decl(node)
    is_mutable = node.respond_to?(:mutable) && node.mutable
    ft = Type.new(node.full_type || :Void)
    is_mutable ||= ft.dynamic_stream? || ft.bounded_stream? || ft.shared_promise? || ft.open_stream? || ft.inf_stream?
    is_mutable ||= ft.collection?
    is_mutable ||= ft.resource? || node.resource_close_zig
    is_mutable = false if ft.local?

    # Look up the cleanup entry from the bindings stamped by MIRPass.
    decl_name = node.name.to_s
    binding_entry = @current_bindings[decl_name]
    has_mir_drop = binding_entry && binding_entry[:needs_cleanup] && !binding_entry[:match_as]

    actually_mutated = is_mutable && node.respond_to?(:var_mutated) && node.var_mutated == true
    has_mutable_cleanup = has_mir_drop || ft&.collection? || ft&.dynamic_stream? || ft&.bounded_stream? || ft&.shared_promise? ||
                          ft&.open_stream? || ft&.inf_stream? || (ft&.array? && ft&.dynamic?) ||
                          ft&.heap_provenance? || ft&.resource? || node.resource_close_zig
    forced_var = is_mutable && has_mutable_cleanup
    keyword_mutable = if !is_mutable
      false
    elsif actually_mutated || forced_var
      true
    else
      false
    end

    zig_type = transpile_type(node.full_type)
    needs_annotation = ZigTypeMapper::ZIG_PRIMITIVES.include?(zig_type) || ft.fn_type? ||
                       (node.value.is_a?(AST::Literal) && node.value.type == :NIL) ||
                       (ft.string? && ft.heap_provenance?)  # ""/literal infers *const [0:0]u8 without annotation
    annotation = needs_annotation ? zig_type : nil

    # Resolve init value - special handling for collection types.
    # Allocator comes from the cleanup plan (single source of truth).
    decl_alloc = binding_entry&.dig(:alloc) || :heap
    init = if ft.pool?
      cap = ft.capacity
      MIR::ContainerInit.new(transpile_type(ft), :pool, decl_alloc, cap)
    elsif ft.set_collection?
      MIR::ContainerInit.new(transpile_type(ft), :set_empty, nil, nil)
    elsif ft.list_collection?
      rhs = node.value
      rhs_unwrapped = (rhs.is_a?(AST::BinaryOp) && rhs.op == :OR_RESCUE) ? rhs.left : rhs
      if rhs_unwrapped.is_a?(AST::NextExpr)
        # Pass decl_alloc so NEXT ~T[]@list uses the right allocator (heap when result
        # escapes via return, frame when it stays local).
        lower_next_expr(rhs_unwrapped, decl_alloc)
      elsif rhs_unwrapped.is_a?(AST::FuncCall) || rhs_unwrapped.is_a?(AST::MethodCall)
        lower(node.value)
      elsif ft.capacity.is_a?(Integer) && ft.capacity > 0
        MIR::ContainerInit.new(transpile_type(ft), :list_capacity, decl_alloc, ft.capacity)
      else
        MIR::ContainerInit.new(transpile_type(ft), :list_empty, nil, nil)
      end
    elsif ft.fixed_soa?
      # T[N]@soa: pre-allocate with initCapacity to avoid frame-arena doubling waste
      MIR::ContainerInit.new(transpile_type(ft), :list_capacity, decl_alloc, ft.capacity)
    else
      rhs = node.value.is_a?(AST::MoveNode) ? node.value.value : node.value
      is_move = node.value.is_a?(AST::MoveNode)
      # Propagate VarDecl heap storage to StructLit so lower_struct_lit emits HeapCreate.
      # upgrade_heap_ptr_returns_to_heap! sets decl.storage = :heap but not decl.value.storage.
      rhs.storage = :heap if node.storage == :heap && rhs.is_a?(AST::StructLit)
      if !is_move && rc_retain_needed?(rhs)
        make_rc_retain(rhs)
      elsif ft.string? && ft.heap_provenance? && !is_move &&
            rhs.is_a?(AST::Literal) && rhs.type == :STRING
        # Heap carry var with string literal initial value: dupe to heap so the
        # defer free() on the var doesn't attempt to free a comptime literal.
        MIR::DupeSlice.new(lower(rhs), :heap)
      else
        lower(node.value)
      end
    end

    safe_name = zig_safe_name(node.name)

    suppression = if keyword_mutable
      if actually_mutated && node.var_used && !forced_var
        nil
      else
        "_ = &#{safe_name};"
      end
    else
      (node.var_used || has_mir_drop) ? nil : "_ = #{safe_name};"
    end

    let_node = MIR::Let.new(safe_name, init, keyword_mutable, annotation, suppression)

    # Emit AllocMark + Let + Cleanup triple when the binding needs cleanup.
    # Replaces the OLD MIR::Alloc/Drop sibling nodes inserted by MIRPass.
    if has_mir_drop
      drop_entry = binding_entry.dup
      build_drop_entry!(drop_entry, node.type_info, node)
      mir_alloc = resolve_decl_stdlib_alloc(node) || binding_entry[:alloc]
      [MIR::AllocMark.new(decl_name, mir_alloc), let_node, MIR::Cleanup.new(safe_name, drop_entry)]
    else
      let_node
    end
  end

  def lower_bind_expr(node)
    if node.mode == :decl
      # Proxy to VarDecl logic. cleanup_alloc/has_cleanup are no longer needed
      # since lower_var_decl reads from @current_bindings[name].
      proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
      proxy.full_type = node.full_type
      proxy.storage = node.storage
      proxy.slot_size = node.slot_size
      proxy.resource_close_zig = node.resource_close_zig
      proxy.var_used = node.var_used
      lower_var_decl(proxy)
    else
      safe = zig_safe_name(node.name)
      value = lower(node.value)
      if node.reassign_cleanup
        zig_type = node.reassign_cleanup[:zig_type] || "UNKNOWN"
        alloc = alloc_from_sym(node.reassign_cleanup[:alloc])
        MIR::ReassignWithCleanup.new(safe, value, zig_type, alloc)
      else
        MIR::Set.new(MIR::Ident.new(safe), value)
      end
    end
  end

  def lower_assignment(node)
    # Indexed assignment: map[k]=v, list[i]=v
    if node.name.is_a?(AST::GetIndex)
      return lower_indexed_assignment(node)
    end

    # Auto-lock field assignment (handles its own pre-cleanup)
    if node.name.is_a?(AST::GetField) && node.auto_lock
      return lower_auto_lock_assignment(node)
    end

    # Field assignment with pre-cleanup (non-locked structs)
    if node.name.is_a?(AST::GetField) && node.field_pre_cleanup
      return lower_field_assignment_with_cleanup(node)
    end

    target = if node.name.is_a?(String)
      MIR::Ident.new(zig_safe_name(node.name))
    else
      lower(node.name)
    end
    value = lower(node.value)
    result = MIR::Set.new(target, value)

    # Detect field assignments where old value needs cleanup but no pre-cleanup exists.
    if node.name.is_a?(AST::GetField) && !node.field_pre_cleanup
      field_ti = node.name.type_info rescue nil
      field_ti = Type.new(field_ti) if field_ti && !field_ti.is_a?(Type)
      sl = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
      if field_ti&.needs_cleanup?(sl)
        result.needs_field_cleanup = true
      elsif field_ti&.string?
        # String fields on heap-allocated structs need cleanup
        root = node.name.target
        root = root.target while root.is_a?(AST::GetField)
        if root.is_a?(AST::Identifier)
          root_ti = root.type_info rescue nil
          root_ti = Type.new(root_ti) if root_ti && !root_ti.is_a?(Type)
          result.needs_field_cleanup = true if root_ti&.heap_provenance?
        end
      end
    end

    result
  end

  def lower_indexed_assignment(node)
    target_node = node.name.target
    ti = target_node.type_info rescue nil

    # Raw slice index (synthetic nodes from SOA rewrite have no type_info)
    unless ti
      target = lower(target_node)
      idx = lower(node.name.index)
      val = lower(node.value)
      return MIR::Set.new(MIR::IndexGet.new(target, idx), val)
    end

    receiver_type = Type.new(ti)
    rt_name = @rt_name

    # Resolve INDEX_OPS :set entry via dispatch_key
    kind = ti&.dispatch_key
    op = kind && INDEX_OPS.dig(kind, :set)

    target = lower(target_node)
    idx = lower(node.name.index)
    val = lower(node.value)

    # Auto-deref Arc/Rc-wrapped containers
    if ti&.map? && (ti&.shared? || ti&.multiowned?)
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end

    # Fallback for unknown container types or missing registry entries
    unless op
      return MIR::ExprStmt.new(emit_builtin(:setAt, [target, idx, val]), false)
    end

    # Pick shard-direct zig when inside a SHARD pipeline body and target matches
    target_var = target_node.is_a?(AST::Identifier) ? target_node.name : nil
    shard_direct = @shard_context && target_var == @shard_context[:map] && op[:shard_direct_zig]
    zig = if shard_direct
      op[:shard_direct_zig]
    elsif (receiver_type&.sharded? || receiver_type&.striped?) && op[:sharded_zig]
      op[:sharded_zig]
    else
      op[:zig]
    end

    # Map keys are duped internally by put -- always frame-allocate the key
    # expression so it's cleaned by arena rewind (no orphaned heap temporary).
    if kind == :string_map && idx.is_a?(MIR::ConcatStr)
      idx = MIR::ConcatStr.new(idx.parts, alloc_expr(:frame), idx.rt_expr)
    end

    # Select value transforms for the chosen zig variant. Each variant declares
    # its own transforms (e.g. shard_direct_value_transforms for putDirect).
    val_node = node.value
    val_ti = val_node.type_info rescue nil
    transforms = if shard_direct then op[:shard_direct_value_transforms] || op[:value_transforms] || []
                 else op[:value_transforms] || []
                 end
    transforms.each do |transform|
      case transform
      when :dupe_string_literal
        if val_ti&.string? && !val_node.is_a?(AST::CopyNode)
          val = MIR::DupeSlice.new(val, :heap)
        end
      when :dupe_borrowed_union
        unless val_ti&.string?
          if should_dupe_borrowed_union?(val_node, val_ti)
            zig_t = transpile_type(val_ti)
            val = emit_builtin(:dupeUnionValue, [MIR::Ident.new(zig_t), val, MIR::Ident.new(alloc_zig_str(:heap))])
          end
        end
      when :container_promote
        unless val_ti&.string?
          zig_type = node.container_promote_zig_type
          if zig_type
            val_zig = emit_expr(val)
            new_zig = apply_container_promote_zig(val_zig, rt_name, zig_type)
            val = MIR::InlineZig.new(new_zig, "index_promote")
            val.stdlib_def = { allocates: true }
          end
        end
      end
    end

    # Substitute non-allocator placeholders into the pattern
    target_zig = emit_expr(target)
    idx_zig = emit_expr(idx)
    val_zig = emit_expr(val)

    pattern = zig.dup
    pattern = pattern.gsub("{target}", target_zig)
    pattern = pattern.gsub("&{target}", "&#{target_zig}")
    pattern = pattern.gsub("{index}", idx_zig)
    pattern = pattern.gsub("{value}", val_zig)

    # Substitute shard-direct placeholders when inside SHARD body
    if @shard_context && pattern.include?("{shard_idx}")
      pattern = pattern.gsub("{shard_idx}", @shard_context[:idx])
      pattern = pattern.gsub("{shard_key}", @shard_context[:key])
    end

    # Resolve allocator placeholders to SYMBOLS (not Zig strings).
    # Placeholders ({key_alloc}, {val_alloc}, {alloc}) stay in the code.
    # The emitter substitutes them using iz.allocs at emit time.
    resolved_allocs = {}
    [:alloc, :key_alloc, :val_alloc, :shard_alloc].each do |alloc_key|
      placeholder = "{#{alloc_key}}"
      next unless pattern.include?(placeholder)
      alloc_sym = op[alloc_key] || :heap
      resolved = resolve_alloc_sym(alloc_sym, receiver_type, target_node, node)
      resolved_allocs[alloc_key] = resolved
    end

    # Resolve type placeholders from receiver (not allocators -- safe to inline)
    if pattern.include?("{key_zig}") || pattern.include?("{val_zig}")
      pattern = pattern.gsub("{key_zig}", receiver_type.key_type&.zig_type || "i64")
      pattern = pattern.gsub("{val_zig}", receiver_type.value_type&.zig_type || "f64")
    end

    iz = MIR::InlineZig.new(pattern, "index_set")
    iz.stdlib_def = op
    iz.allocs = resolved_allocs unless resolved_allocs.empty?
    # Store target variable name for checker cross-reference with AllocMark.
    iz.target_var = extract_root_var_name(target_node)
    MIR::ExprStmt.new(iz, false)
  end

  def lower_field_assignment_with_cleanup(node)
    target = lower(node.name.target)
    field = node.name.field.to_s
    value = lower(node.value)
    fpc = node.field_pre_cleanup
    alloc = MIR::Ident.new(alloc_zig_str(fpc[:alloc] || :heap))
    cleanup_call = MIR::Call.new("CheatLib.cleanup", [
      MIR::Ident.new(fpc[:zig_type]), alloc,
      MIR::AddressOf.new(MIR::FieldGet.new(target, field))
    ], false)
    assign = MIR::Set.new(MIR::FieldGet.new(target, field), value)
    MIR::ScopeBlock.new([MIR::ExprStmt.new(cleanup_call, false), assign])
  end

  def lower_auto_lock_assignment(node)
    var_name = node.auto_lock[:var]
    sync = node.auto_lock[:sync]
    guard_var = "__#{var_name}_guard"
    alias_var = "__#{var_name}_inner"
    zig_var = @do_capture_map&.dig(var_name) || var_name
    field = node.name.field
    rt_name = @rt_name

    if sync == :always_mutable
      # Hoist heap-allocating RHS to a named Let via hoist_alloc so the checker
      # can verify cleanup. The pending Let is flushed by lower_body's
      # flush_pending before this RawZig statement.
      value_zig = emit_expr(hoist_alloc(lower(node.value), node.value))
      fpc = node.field_pre_cleanup
      if fpc
        alloc = alloc_zig_str(fpc[:alloc] || :heap)
        code = "{ const __old = #{zig_var}.get().#{field}; #{zig_var}.get().#{field} = #{value_zig}; if (__old.len > 0) #{alloc}.free(__old); }"
      else
        code = "#{zig_var}.get().#{field} = #{value_zig};"
      end
    else
      acquire = sync == :write_locked ? "#{zig_var}.write()" : "#{zig_var}.acquire()"
      # Lower RHS with locked unwrap map so field accesses on the locked var use the alias
      prev_locked = @locked_unwrap_map
      @locked_unwrap_map = (prev_locked || {}).merge({ alias_var => true, var_name => alias_var })
      value_zig = emit_expr(hoist_alloc(lower(node.value), node.value))
      @locked_unwrap_map = prev_locked
      fpc = node.field_pre_cleanup
      if fpc
        alloc = alloc_zig_str(fpc[:alloc] || :heap)
        code = "{\nvar #{guard_var} = #{acquire};\ndefer #{guard_var}.release();\nconst #{alias_var} = #{guard_var}.get();\nconst __old = #{alias_var}.#{field};\n#{alias_var}.#{field} = #{value_zig};\nif (__old.len > 0) #{alloc}.free(__old);\n}"
      else
        code = "{\nvar #{guard_var} = #{acquire};\ndefer #{guard_var}.release();\nconst #{alias_var} = #{guard_var}.get();\n#{alias_var}.#{field} = #{value_zig};\n}"
      end
    end
    MIR::RawZig.new(code, "auto_lock_assign",
      { consumes: [], produces: [], borrows: [var_name.to_s] })
  end

  # ================================================================
  # Control flow
  # ================================================================

  def lower_if(node)
    cond = lower(node.condition)
    then_body = lower_body(node.then_branch)
    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    MIR::IfStmt.new(cond, then_body, else_body)
  end

  def lower_while(node)
    rt = MIR::Ident.new(@rt_name)
    cond = lower(node.condition)
    b = node.do_branch
    body = b.is_a?(Array) ? lower_body(b) : []

    if !node.tight && node.mark_per_iter && @current_fn_has_rt
      @loop_mark_counter = (@loop_mark_counter || 0) + 1
      mark_var = "__loop_mark_#{@loop_mark_counter}"
      # Prologue: save loop mark
      save = MIR::Let.new(mark_var, MIR::MethodCall.new(rt, "saveLoopMark", [], false), false, nil, nil)
      restore = MIR::DeferStmt.new(
        MIR::MethodCall.new(rt, "restoreLoopMark", [MIR::Ident.new(mark_var)], false)
      )
      body = [save, restore] + body
    end

    # Yield check at end of loop body
    if !node.tight && @current_fn_has_rt
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false), false)
    end

    MIR::WhileStmt.new(cond, body, nil, nil, node.mark_per_iter, !!node.tight)
  end

  def lower_for_each(node)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    rt = MIR::Ident.new(@rt_name)
    coll = lower(node.collection)
    coll_type = node.collection.full_type
    ct = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)
    is_mutable = node.is_mutable == true
    mark_per_iter = node.respond_to?(:mark_per_iter) ? node.mark_per_iter : nil
    tight = node.respond_to?(:tight) && node.tight

    # Inject saveLoopMark/restoreLoopMark when the body has loop-local frame allocs.
    # Mirrors the same injection done in lower_while and lower_for_range.
    if !tight && mark_per_iter && @current_fn_has_rt
      @loop_mark_counter = (@loop_mark_counter || 0) + 1
      mark_var = "__loop_mark_#{@loop_mark_counter}"
      save = MIR::Let.new(mark_var, MIR::MethodCall.new(rt, "saveLoopMark", [], false), false, nil, nil)
      restore = MIR::DeferStmt.new(
        MIR::MethodCall.new(rt, "restoreLoopMark", [MIR::Ident.new(mark_var)], false)
      )
      body = [save, restore] + body
    end

    # Yield check at end of body
    if @current_fn_has_rt
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false), false)
    end

    if ct.map?
      @for_counter = (@for_counter || 0) + 1
      iter_var = "__kit_#{@for_counter}"
      # { var iter = coll.keyIterator(); while (iter.next()) |var| { body } }
      iter_init = MIR::Let.new(iter_var, MIR::MethodCall.new(coll, "keyIterator", [], false), true, nil, nil)
      while_stmt = MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(iter_var), "next", [], false),
        body, var, nil, mark_per_iter, tight
      )
      MIR::ScopeBlock.new([iter_init, while_stmt])
    elsif ct.pool?
      # Pool: iterate over slots, skip dead entries.
      # Emits: for (pool.slots) |*__pslot_N| { if (!__pslot_N.alive) continue; const var = __pslot_N.value; body }
      @for_counter = (@for_counter || 0) + 1
      slot_var = "__pslot_#{@for_counter}"
      slot_ident = MIR::Ident.new(slot_var)
      slots_iter = MIR::FieldGet.new(coll, "slots")
      skip_dead = MIR::IfStmt.new(
        MIR::UnaryOp.new("!", MIR::FieldGet.new(slot_ident, "alive")),
        [MIR::ContinueStmt.new(nil)],
        nil
      )
      value_bind = MIR::Let.new(var, MIR::FieldGet.new(slot_ident, "value"), false, nil, nil)
      full_body = [skip_dead, value_bind] + body
      MIR::ForStmt.new(slots_iter, "*#{slot_var}", full_body, nil, mark_per_iter, tight)
    elsif ct.dynamic_stream?
      # Finite stream (~T[]): next() returns ?T; while-loop with optional capture.
      MIR::WhileStmt.new(
        MIR::MethodCall.new(coll, "next", [], true),
        body, var, nil, mark_per_iter, tight)
    elsif ct.bounded_stream?
      # Bounded stream (~T[N]): next() returns T (panics when exhausted).
      # Use nextOrNull() so the while-loop optional-capture pattern works.
      # defer deinit drains any unconsumed promises on early exit.
      defer_deinit = MIR::DeferStmt.new(MIR::MethodCall.new(coll, "deinit", [], false))
      MIR::ScopeBlock.new([
        defer_deinit,
        MIR::WhileStmt.new(
          MIR::MethodCall.new(coll, "nextOrNull", [], true),
          body, var, nil, mark_per_iter, tight)
      ])
    elsif ct.inf_stream?
      # Infinite stream (~T[INF]): nextOrNull() returns ?T, null only when stream is
      # closed.  A LIMIT stage in the body breaks the loop after N items.
      # No extra defer needed: the variable-scope `defer name.deinit()` (emitted by
      # the variable's cleanup entry) signals the generator to stop at function exit.
      MIR::WhileStmt.new(
        MIR::MethodCall.new(coll, "nextOrNull", [], true),
        body, var, nil, mark_per_iter, tight)
    else
      is_field_access = node.collection.is_a?(AST::GetField)
      is_param = node.collection.is_a?(AST::Identifier) &&
                 @current_fn_param_names&.include?(node.collection.name)
      # list_collection? covers T[N]@list (fixed capacity ArrayList) in addition to
      # T[]@list (dynamic). Both map to std.ArrayListUnmanaged and require .items.
      is_arraylist = (ct.list_collection? || (ct.array? && ct.dynamic?)) &&
                     !ct.string? && !is_param && !is_field_access
      iter = if is_arraylist
        MIR::FieldGet.new(coll, "items")
      elsif is_param || (is_field_access && ct.array? && (ct.dynamic? || ct.list_collection?))
        coll
      else
        MIR::AddressOf.new(coll)
      end
      capture = is_mutable ? "*#{var}" : var
      MIR::ForStmt.new(iter, capture, body, nil, mark_per_iter, tight)
    end
  end

  def lower_for_range(node)
    start_val = lower(node.start_expr)
    end_val = lower(node.end_expr)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    rt = MIR::Ident.new(@rt_name)
    cmp = node.inclusive ? "<=" : "<"
    @for_counter = (@for_counter || 0) + 1
    iter_var = "__for_#{@for_counter}"

    # Prologue: const var: i64 = iter; _ = &var;
    var_decl = MIR::Let.new(var, MIR::Ident.new(iter_var), false, "i64", "_ = &#{var};")

    # Frame mark if needed
    if !node.tight && node.mark_per_iter && @current_fn_has_rt
      @loop_mark_counter = (@loop_mark_counter || 0) + 1
      mark_var = "__loop_mark_#{@loop_mark_counter}"
      save = MIR::Let.new(mark_var, MIR::MethodCall.new(rt, "saveLoopMark", [], false), false, nil, nil)
      restore = MIR::DeferStmt.new(
        MIR::MethodCall.new(rt, "restoreLoopMark", [MIR::Ident.new(mark_var)], false)
      )
      body = [save, restore, var_decl] + body
    else
      body = [var_decl] + body
    end

    # Yield check
    if !node.tight && @current_fn_has_rt
      body << MIR::ExprStmt.new(MIR::MethodCall.new(rt, "checkYield", [], false), false)
    end

    # Update: iter += 1
    update = MIR::Set.new(MIR::Ident.new(iter_var), MIR::BinOp.new("+", MIR::Ident.new(iter_var), MIR::Lit.new("1")))

    # Condition: iter cmp end
    cond = MIR::BinOp.new(cmp, MIR::Ident.new(iter_var), end_val)

    # Wrapping block: { var __for: i64 = start; while (...) : (...) { body } }
    iter_init = MIR::Let.new(iter_var, start_val, true, "i64", nil)
    tight = node.respond_to?(:tight) && node.tight
    while_stmt = MIR::WhileStmt.new(cond, body, nil, update, node.respond_to?(:mark_per_iter) ? node.mark_per_iter : nil, tight)
    MIR::ScopeBlock.new([iter_init, while_stmt])
  end

  def lower_match(node)
    subject = lower(node.expr)

    # Determine if union MATCH
    union_lookup = begin
      t = Type.new(node.expr.resolved_type || :Any)
      t.generic_instance? ? t.generic_base : t.resolved
    end
    is_union = @union_schemas&.key?(union_lookup)

    # For simple int/enum matches, emit SwitchStmt
    expr_type = node.expr.resolved_type
    expr_type_sym = expr_type.is_a?(Type) ? expr_type.resolved : expr_type

    is_int_match = !is_union && !node.string_match &&
      (expr_type == :Int64 || expr_type == :Int32 || expr_type == :Int16 || expr_type == :Int8 ||
       (expr_type.is_a?(Type) && expr_type.integer?)) &&
      node.cases.all? { |c| c[:kind] != :when && c[:kind] != :struct_pattern &&
                            c[:value].is_a?(AST::Literal) && (c[:value].type == :INT64 || c[:value].type == :NUMBER) }

    is_enum_match = !is_union && !node.string_match && @enum_schemas&.key?(expr_type_sym) &&
      node.cases.all? { |c| c[:kind] != :when && c[:kind] != :struct_pattern &&
                            c[:value].is_a?(AST::GetField) }

    if is_int_match || is_enum_match
      arms = node.cases.map { |c|
        body = lower_body(c[:body])
        pattern = if is_enum_match
          ".#{c[:value].field}"
        else
          # PURE: int match case value is always an integer literal; never allocating.
          emit_expr(lower(c[:value]))
        end
        { pattern: pattern, body: body }
      }
      default = (node.default_case && !node.default_case.empty?) ? lower_body(node.default_case) : nil
      # Non-exhaustive enum match without DEFAULT needs else => {} to satisfy Zig
      if is_enum_match && !default
        all_variants = @enum_schemas[expr_type_sym]&.map(&:to_s)&.sort || []
        covered = node.cases.map { |c| c[:value].field.to_s }.sort
        default = [] unless covered == all_variants
      end
      MIR::SwitchStmt.new(subject, arms, default)
    else
      # If-chain for unions, strings, and complex patterns
      branches = node.cases.map { |c|
        body = lower_body(c[:body])
        cond = if is_union
          variant = case c[:value]
                    when AST::GetField then c[:value].field
                    when AST::MethodCall then c[:value].name
                    # PURE: fallback case value for union/string match is a literal or identifier.
                    else emit_expr(lower(c[:value]))
                    end
          # Union AS binding: const alias = subject.Variant;
          if c[:binding]
            is_mutable = node.expr.is_a?(AST::Identifier) && node.expr.was_moved
            payload = MIR::FieldGet.new(subject, variant.to_s)
            payload = MIR::Deref.new(payload) if c[:indirect_payload_as]
            binding = MIR::Let.new(c[:binding], payload, is_mutable, nil, "_ = &#{c[:binding]};")
            body = [binding] + body
          elsif c[:destructure]
            bind_stmts = c[:destructure].fields.filter_map do |f|
              next if f[:value] == :wildcard
              if f[:value] == :bind
                payload_field = MIR::FieldGet.new(MIR::FieldGet.new(subject, variant.to_s), f[:name].to_s)
                MIR::Let.new(f[:name].to_s, payload_field, false, nil, "_ = &#{f[:name]};")
              end
            end
            body = bind_stmts + body if bind_stmts.any?
          end
          tag_check = MIR::Call.new("std.meta.activeTag", [subject], false)
          MIR::BinOp.new("==", tag_check, MIR::Ident.new(".#{variant}"))
        elsif node.string_match
          val = lower(c[:value])
          emit_builtin(:strEql, [subject, val])
        elsif c[:kind] == :struct_pattern
          pat = c[:value]
          cond_parts, bind_stmts = lower_struct_pattern(subject, pat)
          body = bind_stmts + body if bind_stmts.any?
          cond_node = if cond_parts.empty?
            MIR::Lit.new("true")
          else
            cond_parts.reduce { |acc, part| MIR::BinOp.new("and", acc, part) }
          end
          cond_node
        elsif c[:kind] == :when
          # WHEN guard: condition IS the guard expression, not subject == guard
          lower(c[:value])
        else
          val = lower(c[:value])
          MIR::BinOp.new("==", subject, val)
        end
        { cond: cond, body: body }
      }
      default = (node.default_case && !node.default_case.empty?) ? lower_body(node.default_case) : nil
      MIR::IfChain.new(branches, default)
    end
  end

  def lower_return(node)
    value = node.value ? lower(node.value) : nil
    rt_name = @rt_name

    # If the return value is a hoisted temp, convert its Cleanup to ErrCleanup:
    # the caller takes ownership on success, so we only clean up on error.
    # Borrow-position temps (intermediates, not the return value) keep regular
    # Cleanup (defer) -- they are freed normally when the function exits.
    if value.is_a?(MIR::Ident)
      @pending_stmts.each_with_index do |s, i|
        if s.is_a?(MIR::Cleanup) && s.name == value.name
          @pending_stmts[i] = MIR::ErrCleanup.new(s.name, s.cleanup_entry)
        end
      end
    end

    # Tail call optimization: convert self-recursive return to @call(.always_tail, ...)
    # Disabled in debug mode (stage2 Zig backend doesn't support always_tail reliably)
    if @current_fn_tail_call && !@debug_mode && value.is_a?(MIR::Call) && value.callee == @current_fn_zig_name
      return MIR::ReturnStmt.new(MIR::TailCall.new(value.callee, value.args))
    end

    # Read scope-exit promotion from node annotations (no global flags).
    needs_string_dupe = node.catch_string_dupe_ret
    ret_field_promote = node.ret_field_promote_data

    if node.promote_ret_wrap == :var && ret_field_promote && value
      rt = MIR::Ident.new(rt_name)
      zig_type = ret_field_promote[:zig_type]
      stmts = [MIR::Let.new("__ret", value, true, nil, nil)]
      # AllocMark documents that CheatLib.promote/promoteDeep will heap-allocate
      # fields of __ret.  Phase 4 will replace this frame+promote pattern with a
      # direct HeapCreate so the AllocMark reflects an actual upfront allocation.
      stmts << MIR::AllocMark.new("__ret", :heap)
      # ErrCleanup: if any promote call fails, free partially-promoted fields.
      # Uses struct_with_cleanup_fields (same Zig template as non_copy_union).
      stmts << MIR::ErrCleanup.new("__ret",
        { kind: :struct_with_cleanup_fields, alloc: :heap, has_moved_guard: false, zig_type: zig_type })
      if ret_field_promote[:fields]
        ret_field_promote[:fields].each do |fname|
          stmts << MIR::ExprStmt.new(
            MIR::Call.new("CheatLib.promote", [
              MIR::Call.new("@TypeOf", [MIR::FieldGet.new(MIR::Ident.new("__ret"), fname)], false),
              rt,
              MIR::AddressOf.new(MIR::FieldGet.new(MIR::Ident.new("__ret"), fname))
            ], true), false)
        end
      else
        zig_type = ret_field_promote[:zig_type]
        stmts << MIR::ExprStmt.new(
          MIR::Call.new("CheatLib.promoteDeep", [
            MIR::Ident.new(zig_type), rt, MIR::AddressOf.new(MIR::Ident.new("__ret"))
          ], true), false)
      end
      stmts << MIR::ReturnStmt.new(MIR::Ident.new("__ret"))
      MIR::ScopeBlock.new(stmts)
    elsif node.promote_ret_wrap == :const && value
      stmts = [
        MIR::Let.new("__ret", value, false, nil, nil),
        MIR::ReturnStmt.new(MIR::Ident.new("__ret"))
      ]
      MIR::ScopeBlock.new(stmts)
    elsif needs_string_dupe && value
      ret_type = node.value.respond_to?(:full_type) ? Type.new(node.value.full_type) : nil
      if ret_type&.string?
        MIR::ScopeBlock.new([
          MIR::AllocMark.new("__ret_dupe", :heap),
          MIR::Let.new("__ret_dupe", MIR::DupeSlice.new(value, :heap), false, nil, nil),
          MIR::ErrCleanup.new("__ret_dupe", { kind: :heap_string, alloc: :heap, has_moved_guard: false }),
          MIR::ReturnStmt.new(MIR::Ident.new("__ret_dupe"))
        ])
      else
        MIR::ReturnStmt.new(value)
      end
    else
      # Rc/Arc return: retain before returning (increment refcount)
      if node.value && rc_retain_needed?(node.value)
        MIR::ReturnStmt.new(make_rc_retain(node.value))
      else
        # Hoist allocating expressions (DeepCopy, ConcatStr, Cast wrapping these,
        # etc.) to a named Let so the checker sees it in Let-init position.
        # ErrCleanup: the caller takes ownership on success.
        # Skip Call nodes: they are not flagged by UNHOISTED_ALLOC and the test
        # contract requires heap-returning calls to remain inline (no __tmp wrap).
        value = hoist_alloc(value, node.value, err_cleanup: true) if value && !value.is_a?(MIR::Call)
        MIR::ReturnStmt.new(value)
      end
    end
  end

  # ================================================================
  # Helpers
  # ================================================================

  # Check if an AST FuncCall/MethodCall returns a heap-allocated value.
  def call_heap_provenance?(node)
    ti = node.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    ti&.heap_provenance? || false
  end

  def callee_needs_rt?(name)
    return true if name.nil? || name.to_s.empty?
    sig = @fn_sigs&.dig(name) || @fn_sigs&.dig(name.to_sym) || @fn_sigs&.dig(name.to_s)
    sig ? (sig.needs_rt.nil? ? true : sig.needs_rt) : true
  end

  # Lower a StructPattern into (conditions, binding_stmts).
  # conditions: Array of Zig boolean fragments ("subject.x == 10")
  # binding_stmts: Array of MIR nodes (const decls for :bind fields)
  def lower_struct_pattern(subject, pat)
    conditions = []
    bindings = []

    pat.fields.each do |f|
      next if f[:value] == :wildcard
      if f[:value] == :bind
        field_access = MIR::FieldGet.new(subject, f[:name].to_s)
        bindings << MIR::Let.new(f[:name].to_s, field_access, false, nil, "_ = &#{f[:name]};")
      else
        val = lower(f[:value])
        field_access = MIR::FieldGet.new(subject, f[:name].to_s)
        conditions << MIR::BinOp.new("==", field_access, val)
      end
    end

    [conditions, bindings]
  end

  def lower_macro_print(node)
    formats = node.args.map { |arg| zig_format_for_type(arg.full_type) }.join(" ")
    args_mir = node.args.map { |a| hoist_alloc(lower(a), a) }
    format_lit = MIR::Lit.new("\"#{formats}\\n\"")
    tuple_inner = args_mir.map { |a| emit_expr(a) }.join(", ")
    tuple = MIR::Ident.new(".{#{tuple_inner}}")
    MIR::Call.new("std.debug.print", [format_lit, tuple], false)
  end

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

  def callee_can_fail?(name)
    return true if name.nil? || name.to_s.empty?
    sig = @fn_sigs&.dig(name) || @fn_sigs&.dig(name.to_sym) || @fn_sigs&.dig(name.to_s)
    sig ? (sig.can_fail.nil? ? true : sig.can_fail) : true
  end

  def collect_identifier_names(nodes)
    names = Set.new
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
  def emit_builtin(name, args)
    entry = BUILTIN_OPS[name]
    raise "emit_builtin: unknown builtin :#{name}" unless entry
    pattern = entry[:zig].dup
    if name == :dupeUnionValue && args.first.is_a?(MIR::Ident)
      args = args.dup
      args[0] = MIR::Ident.new(args[0].name.sub(/\A\*/, ''))
    end
    args.each_with_index { |a, i| pattern = pattern.gsub("{#{i}}", emit_expr(a)) }
    iz = MIR::InlineZig.new(pattern, "builtin_#{name}")
    iz.stdlib_def = entry
    iz
  end

  def direct_indexable_collection_type?(type_info)
    ti = Type.new(type_info)
    ti.list_collection? || (ti.array? && !ti.string?)
  end

  def direct_slice_backed_expr?(ast_node, type_info)
    ti = Type.new(type_info)
    return true if ti.fixed?
    return true if ast_node.is_a?(AST::GetField)
    ast_node.is_a?(AST::Identifier) &&
      @current_fn_param_names&.include?(ast_node.name)
  end

  def direct_index_get(target, index, ast_node, type_info)
    cast_idx = MIR::Cast.new(index, "usize", :intCast)
    ti = Type.new(type_info)
    base =
      if ti.list_collection?
        MIR::FieldGet.new(target, "items")
      elsif direct_slice_backed_expr?(ast_node, ti)
        target
      else
        return nil
      end
    MIR::IndexGet.new(base, cast_idx)
  end

  def lower_direct_length(node)
    recv_ast = node.is_a?(AST::MethodCall) ? node.object : node.args.first
    return nil unless recv_ast

    recv_ti = recv_ast.type_info rescue nil
    return nil unless recv_ti

    recv = lower(recv_ast)
    ti = Type.new(recv_ti)
    len_expr =
      if ti.list_collection?
        # Explicit @list: always std.ArrayListUnmanaged — safe to go direct.
        MIR::FieldGet.new(MIR::FieldGet.new(recv, "items"), "len")
      elsif ti.string? || (ti.array? && !ti.string? && direct_slice_backed_expr?(recv_ast, ti))
        MIR::FieldGet.new(recv, "len")
      else
        # Local dynamic arrays: CheatLib.len handles both ArrayListUnmanaged
        # (via .items.len) and slices (via .len) at runtime — fall back to it.
        nil
      end

    return nil unless len_expr
    MIR::Cast.new(len_expr, "i64", :intCast)
  end

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
  def strip_try(mir_node)
    case mir_node
    when MIR::Call
      MIR::Call.new(mir_node.callee, mir_node.args, false)
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
  def with_fiber_capture_map(new_entries, rt_override: "__rt", &blk)
    prev_map = @do_capture_map || {}
    prev_rt  = @rt_name
    @do_capture_map = prev_map.merge(new_entries)
    @rt_name = rt_override
    result = blk.call
    @do_capture_map = prev_map
    @rt_name = prev_rt
    result
  end

  private

  # Dupe a borrowed non-Copy union value before storing into a TAKES container.
  def should_dupe_borrowed_union?(val_node, val_ti = nil)
    return false if val_node.is_a?(AST::MoveNode) || val_node.is_a?(AST::CopyNode) || val_node.is_a?(AST::CloneNode)
    return false unless val_node.is_a?(AST::Identifier) || val_node.is_a?(AST::GetIndex)
    val_ti ||= (val_node.type_info rescue nil)
    return false unless val_ti && @union_schemas&.key?(val_ti.resolved)
    schema_lookup = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
    return false if val_ti.respond_to?(:implicitly_copyable?) && val_ti.implicitly_copyable?(schema_lookup)
    true
  end

  # Apply container_promote: zig_type comes from Assignment.container_promote_zig_type annotation
  def apply_container_promote_zig(val_ref, rt_name, zig_type)
    promote_type = zig_type.sub(/\A\*/, '')
    "blk_prm: {\n    var __prm = #{val_ref};\n    try CheatLib.promote(#{promote_type}, #{rt_name}, &__prm);\n    break :blk_prm __prm;\n}"
  end

  # Check if a value node is an Rc/Arc identifier that needs retain (not moved, not unwrapped)
  def rc_retain_needed?(value_node)
    return false unless value_node.is_a?(AST::Identifier)
    return false if value_node.is_a?(AST::MoveNode)
    ti = value_node.type_info
    return false unless ti&.any_rc?
    rc_map = @rc_unwrap_map || {}
    return false if rc_map.key?(value_node.name)
    true
  end

  def make_rc_retain(value_node)
    ti = value_node.type_info
    func = ti.shared? ? "arcRetain" : "rcRetain"
    zig_base = transpile_type(ti.resolved.to_s)
    MIR::RcRetain.new(lower(value_node), zig_base, func)
  end

  # Lazy-create PipelineHost for complex pipeline operator dispatch.
  def pipeline_host
    @pipeline_host ||= begin
      require_relative "../backends/pipeline_host"
      require_relative "mir_emitter"
      emitter = @_emitter || MIREmitter.new
      PipelineHost.new(lowering: self, emitter: emitter)
    end
  end
end
