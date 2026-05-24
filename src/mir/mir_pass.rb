# typed: strict
# src/mir_pass.rb - MIR transformation pass
#
# Runs after annotation. Escape analysis has already decided binding storage;
# this pass classifies cleanup bindings and inserts cleanup/suppress nodes.
#
# Dependencies are defined in control_flow.rb (required first) and cleanup_classifier.rb.

require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../annotator-helpers/function_signature"
require_relative "cleanup_classifier"
require_relative "escape_analysis"
require_relative "control_flow"

class MIRPass
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  AstCall = T.type_alias { T.any(AST::FuncCall, AST::MethodCall) }

  # Read-only context threaded through transform_body / recurse_branches!.
  WalkCtx = Struct.new(:bindings, keyword_init: true) do
    extend T::Sig

    sig { params(bindings: T::Hash[String, CleanupEntry]).void }
    def initialize(bindings:)
      super
    end

    sig { returns(T::Hash[String, CleanupEntry]) }
    def bindings
      self[:bindings]
    end

    sig { params(bindings: T::Hash[String, CleanupEntry]).returns(MIRPass::WalkCtx) }
    def with(bindings: self.bindings)
      MIRPass::WalkCtx.new(bindings: bindings)
    end
  end

  # cleanup_bindings: { fn_name => { var_name => entry_hash } }
  # Exposed for specs that test classification directly.
  attr_reader :cleanup_bindings

  sig { params(fn_nodes: FnNodes, schema_lookup: Proc).void }
  def initialize(fn_nodes:, schema_lookup:)
    @fn_nodes = T.let(fn_nodes, FnNodes)
    @schema_lookup = schema_lookup
    @cleanup_bindings = T.let({}, T::Hash[String, T::Hash[String, CleanupEntry]])
  end

  sig { params(bindings: T::Hash[String, CleanupEntry], name: T.untyped).returns(T.nilable(CleanupEntry)) }
  def live_cleanup_entry(bindings, name)
    entry = bindings[name.to_s]
    entry&.needs_cleanup? ? entry : nil
  end

  # Computes plans, classifies bindings, inserts MIR nodes, and stamps AST.
  # Hoist has already lifted anonymous allocating expressions into bindings.
  # Escape analysis writes final binding storage; this pass inserts MIR markers.
  sig { params(ast: AST::Program).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def transform!(ast)
    # Dead-simple escape analysis: mark SymbolEntry#storage = :heap for the
    # handful of AST escape mechanisms. No value-flow graph, no promotion plan.
    heap_fns, @bg_heap_upgraded = EscapeAnalysis.apply!(@fn_nodes, @schema_lookup)
    @bg_heap_upgraded = T.let(@bg_heap_upgraded, T.untyped)

    # SYNC propagation ran inside EscapeAnalysis.apply! above (single-pass
    # escape principle). Nothing to do here.

    # Promotion planning is gone: escape analysis writes symbol.storage;
    # lowering and cleanup only read that fact.

    # Phase 2.5: classify cleanup bindings (uses finalized provenance from Phase 2).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

    LoopFrameAnalysis.analyze!(@fn_nodes, @schema_lookup)

    # needs_rt finalization must run after placement and cleanup
    # classification. That is the point where the compiler knows whether a
    # function actually needs an allocator for a heap/frame binding or cleanup.
    # Propagate to callers so runtime threading is decided once from final data.
    finalize_needs_rt!

    # Phase 3: insert MIR nodes + stamp AST.
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt)
    end

    # Synthetic test-body wrappers live in @fn_nodes but never appear
    # under ast.statements, so the loop above skips them. Run the same
    # transform on each so MIR::Drop / MIR::Cleanup nodes land on the
    # shared body array (which is also AST::TestThat.body).
    @fn_nodes.each do |name, fn|
      next unless name.is_a?(String) && name.start_with?("__test_body_")
      next unless fn&.body
      transform_function!(fn)
    end

    # MIR escape analysis can discover heap-return provenance after the
    # annotator created each FunctionSignature. Resync the signature objects
    # so cross-module imports and later lowering see the same ownership facts
    # as the FunctionDef.
    @fn_nodes.each_value do |fn|
      sig = fn.full_type
      sig = sig.raw if sig.is_a?(Type) && sig.raw.is_a?(FunctionSignature)
      FunctionSignature.sync_from_function_def!(sig, fn) if sig.is_a?(FunctionSignature)
    end
  end

  private

  # Finalize needs_rt after escape analysis and cleanup classification. The
  # annotator's compute_needs_rt! ran before placement was decided, so it could
  # not see a function that owns an allocator-backed binding. Any function with
  # a heap/frame cleanup binding or heap-placed local allocates via `rt`;
  # propagate to callers, which must thread rt to pass it.
  sig { void }
  def finalize_needs_rt!
    @fn_nodes.each_value do |fn|
      fn.needs_rt = false if fn.body
    end

    @fn_nodes.each do |_name, fn|
      next unless fn.body
      bindings = @cleanup_bindings[fn.name.to_s] || {}
      if finalized_runtime_input?(fn) ||
         params_need_runtime_cleanup?(fn.params) ||
         bindings.any? { |_binding_name, entry| entry.present? && [:heap, :frame].include?(entry.alloc) }
        fn.needs_rt = true
        next
      end
      walk_ast_nodes(fn.body) do |n|
        if ((n.is_a?(AST::VarDecl) || n.is_a?(AST::BindExpr)) && n.symbol&.storage == :heap) ||
           ast_node_lowers_through_runtime?(n)
          fn.needs_rt = true
        end
      end
      next if fn.needs_rt
      if return_path_needs_allocator?(fn)
        fn.needs_rt = true
      end
    end
    callees = T.let({}, T::Hash[String, T::Set[String]])
    @fn_nodes.each do |name, fn|
      next unless fn.body
      cs = T.let(Set.new, T::Set[String])
      collect_callees(fn.body, cs)
      callees[name] = cs
    end
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      @fn_nodes.each do |name, fn|
        next unless fn.body && !fn.needs_rt
        if callees[name]&.any? { |c| @fn_nodes[c]&.needs_rt }
          fn.needs_rt = true
          changed = true
        end
      end
    end
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def finalized_runtime_input?(fn)
      fn.name.to_s == "main" ||
      fn.uses_rt == true ||
      function_error_context?(fn) ||
      fn.uses_alloc == true ||
      fn.fn_value_ref == true ||
      !fn.thunk_plan.nil? ||
      !fn.mutual_thunk_plan.nil? ||
      recursion_yield_needed?(fn)
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def function_error_context?(fn)
    pre = fn.respond_to?(:pre_clauses) ? fn.pre_clauses : nil
    return true if pre.respond_to?(:any?) && pre.any?
    return true if fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?
    fn.default_catch.is_a?(Array) && fn.default_catch.any?
  end

  sig { params(params: T::Array[AST::Param]).returns(T::Boolean) }
  def params_need_runtime_cleanup?(params)
    params.any? do |param|
      next false unless param.takes
      ti = param.type || Type.new(:Any)
      next true if ti.any?
      next false if ti.primitive? || (ti.generic_instance? && ti.generic_base == :Id)
      true
    end
  end

  sig { params(node: AstCall).returns(T::Boolean) }
  def ast_call_needs_rt?(node)
    return false if @fn_nodes.key?(node.name.to_s)

    sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
    return true if sig&.needs_rt == true

    emit = sig&.emit
    !!(emit && emit.allocates)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def ast_node_lowers_through_runtime?(node)
    case node
    when AST::FuncCall, AST::MethodCall
      ast_call_needs_rt?(node)
    when AST::BgBlock, AST::BgStreamBlock
      true
    when AST::Assignment
      indexed_assignment_lowers_through_runtime?(node)
    when AST::WithBlock
      with_block_lowers_through_runtime?(node)
    else
      false
    end
  end

  sig { params(node: AST::Assignment).returns(T::Boolean) }
  def indexed_assignment_lowers_through_runtime?(node)
    return false unless node.name.is_a?(AST::GetIndex)
    target_node = node.name.target
    ti = Type.from_node(target_node)
    return false unless ti
    return false if ti.untyped?
    return false if ti.fixed? && !ti.string? && !ti.collection?

    kind = ti.dispatch_key
    !!(kind && INDEX_OPS.dig(kind, :set))
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def with_block_lowers_through_runtime?(node)
    return true if node.snapshot_mode == :transaction
    return true if node.view_kind == :materialized_view
    return true if node.universal_poly

    clause = node.lock_error_clause
    return false unless clause
    action_raises = %i[raise exit].include?(clause[:action])
    has_bubble = clause[:bubble_types].is_a?(Array) && clause[:bubble_types].any?
    action_raises || has_bubble
  end

  sig { params(fn_node: AST::FunctionDef).returns(T::Boolean) }
  def recursion_yield_needed?(fn_node)
    return false if fn_node.tight_reentrance
    case fn_node.reentrance_kind
    when :reentrant, :reentrant_tail_call, :reentrant_max_depth
      true
    else
      false
    end
  end

  sig { params(node: T.untyped, acc: T::Set[String]).void }
  def collect_callees(node, acc)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |c| collect_callees(c, acc) }
      return
    end
    return unless node.is_a?(Struct)
    acc << node.name.to_s if (node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)) && node.name
    node.to_a.each { |c| collect_callees(c, acc) }
  end

  sig { params(nodes: T.untyped, visited: T::Set[Integer], block: T.proc.params(arg0: T.untyped).void).void }
  def walk_ast_nodes(nodes, visited = Set.new, &block)
    return unless nodes
    nodes = [nodes] unless nodes.is_a?(Array)
    nodes.each do |node|
      case node
      when AST::Locatable
        next unless visited.add?(node.object_id)
        block.call(node)
        next unless node.is_a?(Struct)
        node.class.members.each { |member| walk_ast_nodes(node[member], visited, &block) }
      when Array
        walk_ast_nodes(node, visited, &block)
      when Hash
        node.each_value { |value| walk_ast_nodes(value, visited, &block) }
      end
    end
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def return_path_needs_allocator?(fn)
    return false unless fn.heap_carry_return
    found = T.let(false, T::Boolean)
    walk_ast_nodes(fn.body) do |node|
      next if found
      next unless node.is_a?(AST::ReturnNode) && node.value
      found = return_expr_needs_allocator?(fn, node.value)
    end
    found
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).returns(T::Boolean) }
  def return_expr_needs_allocator?(fn, expr)
    node = unwrap_return_expr(expr)
    return true if node.is_a?(AST::CopyNode)
    ti = Type.from_node(node)
    ti = ti.payload_type if ti&.error_union?
    return false if ti&.any_rc? || ti&.any_sync?

    if node.is_a?(AST::Identifier)
      return false unless fn.params.any? { |param| param.name.to_s == node.name.to_s }
      return false if fn.params.any? { |param| param.name.to_s == node.name.to_s && param.takes }
      return !!(ti&.string? || ti&.recursive_cleanup_shape?(@schema_lookup))
    end

    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.string_concat == true
    !!(ti&.string? && !node.is_a?(AST::Literal))
  end

  sig { params(expr: T.untyped).returns(T.untyped) }
  def unwrap_return_expr(expr)
    node = T.let(expr, T.untyped)
    while node.is_a?(AST::MoveNode) || node.is_a?(AST::Cast) || node.is_a?(AST::FreezeNode)
      node = node.value
    end
    node = unwrap_return_expr(node.left) if node.is_a?(AST::BinaryOp) && node.op == :OR_RESCUE
    node
  end

  sig { params(fn: AST::FunctionDef).returns(T.nilable(T::Hash[String, TrueClass])) }
  def transform_function!(fn)
    bindings = @cleanup_bindings[fn.name] || {}
    has_bindings = bindings && !bindings.empty?

    return unless has_bindings

    # Borrow checking: verify no moves of borrowed variables inside WITH blocks.
    bc_errors = BorrowChecker.check(fn, schema_lookup: @schema_lookup)
    unless bc_errors.empty?
      raise "[Borrow Error] #{bc_errors.first}"
    end

    # Pre-mark bindings captured by BG blocks so has_moved_guard is correct
    # BEFORE cleanup_decisions! runs and Drops snapshot cleanup_entry.
    pre_mark_bg_resource_captures!(fn, bindings) if has_bindings

    # Ownership dataflow refines cleanup decisions: determines WHETHER cleanup
    # is needed and WHETHER a moved guard is required, based on per-path analysis.
    # Also runs UseAfterMoveChecker (Rule 1: no use after move).
    @last_dataflow = T.let(nil, T.untyped)
    if has_bindings
      can_fail_fns = Set.new
      @fn_nodes.each { |name, f| can_fail_fns << name if f.can_fail }
      @last_dataflow = T.let(OwnershipDataflow.analyze(fn, can_fail_fns: can_fail_fns, schema_lookup: @schema_lookup), T.untyped)
      @last_dataflow.cleanup_decisions!(fn, bindings)
    end

    mark_returned_cleanup_bindings!(fn, bindings)

    # Stamp cleanup_bindings on the FunctionDef so MIRLowering can read
    # allocator + cleanup info without relying on OLD MIR::Alloc/Drop siblings.
    fn.cleanup_bindings = bindings

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    @current_transform_fn = T.let(fn, T.untyped)
    fn.body = transform_body(fn.body, WalkCtx.new(bindings: bindings))
    @current_transform_fn = T.let(nil, T.untyped)

    # Build moved_guard_info map: { var_name => bool } for all bindings.
    stamp_moved_guard_info!(fn, bindings) if has_bindings

  end

  # Pre-mark bindings that are captured by BG blocks as needing moved guards.
  # This runs BEFORE refine_moved_guards! so that when Drops are later created
  # (which snapshot cleanup_entry = entry.dup), the has_moved_guard flag is
  # already correct. Without this, insert_bg_resource_suppress! would mutate
  # bindings AFTER Drops were created, causing a split between the Drop's
  # snapshot and the binding's current state.
  sig { params(fn: AST::FunctionDef, bindings: T::Hash[String, CleanupEntry]).returns(T::Array[T.untyped]) }
  def pre_mark_bg_resource_captures!(fn, bindings)
    T.must(walk_for_bg_captures(fn.body, bindings))
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped]), bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Array[T.untyped])) }
  def walk_for_bg_captures(stmts, bindings)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      AST.each_bg_block_in_stmt(stmt) do |bg|
        resource_captures = bg.capture_analysis&.resource_captures
        next unless resource_captures&.any?
        resource_captures.each do |name|
          entry = live_cleanup_entry(bindings, name)
          next unless entry
          entry[:has_moved_guard] = true
        end
      end
      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        walk_for_bg_captures(stmt.then_branch, bindings)
        walk_for_bg_captures(stmt.else_branch, bindings)
      when AST::WhileLoop
        walk_for_bg_captures(stmt.do_branch, bindings)
      when AST::ForRange, AST::ForEach
        walk_for_bg_captures(stmt.body, bindings)
      when AST::MatchStatement
        stmt.cases.each { |c| walk_for_bg_captures(c.body, bindings) }
        walk_for_bg_captures(stmt.default_case, bindings)
      when AST::WithBlock
        walk_for_bg_captures(stmt.body, bindings)
      when AST::DoBlock
        stmt.branches.each { |b| walk_for_bg_captures(b[:body], bindings) }
      when AST::BgBlock, AST::BgStreamBlock
        walk_for_bg_captures(stmt.body, bindings)
      end
    end
  end

  # Recursively transform a statement list, inserting MIR nodes.
  # Returns a new array (does not mutate the input).
  sig { params(stmts: T::Array[T.untyped], ctx: MIRPass::WalkCtx).returns(T::Array[T.untyped]) }
  def transform_body(stmts, ctx)
    return stmts unless stmts.is_a?(Array)
    result = []
    bindings = ctx.bindings
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      recurse_branches!(stmt, ctx)

      # Insert Return (escape markers) before ReturnNode.
      if stmt.is_a?(AST::ReturnNode)
        insert_return!(result, stmt, bindings, fn_node: @current_transform_fn)
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)
      stamp_while_bind_cleanup!(stmt, bindings)
      stamp_if_bind_cleanup!(stmt, bindings)

      # Emit the original statement.
      result << stmt

      # Insert MIR verification nodes for reassignment and field pre-cleanup.
      if stmt.is_a?(AST::BindExpr) && stmt.reassign_cleanup
        result << MIR::ReassignCleanup.new(stmt.token, stmt.name.to_s, stmt.reassign_cleanup.alloc!)
      end
      if stmt.is_a?(AST::Assignment) && stmt.field_pre_cleanup
        target = stmt.name
        target_name = target.is_a?(AST::GetField) && target.target.respond_to?(:name) ? target.target.name.to_s : nil
        result << MIR::FieldCleanup.new(stmt.token, target_name, target.field, stmt.field_pre_cleanup) if target_name
      end

      mark_consumed_cleanup_guards!(stmt, bindings)
    end
    result
  end

  # Recurse into control flow branches to transform nested bodies.
  sig { params(stmt: T.untyped, ctx: MIRPass::WalkCtx).returns(T.nilable(T::Array[T.untyped])) }
  def recurse_branches!(stmt, ctx)
    case stmt
    when AST::IfStatement
      stmt.then_branch = transform_body(stmt.then_branch, ctx) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, ctx) if stmt.else_branch
    when AST::WhileLoop
      stmt.do_branch = transform_body(stmt.do_branch, ctx) if stmt.do_branch
    when AST::WhileBindLoop
      stmt.do_branch = transform_body(stmt.do_branch, ctx) if stmt.do_branch
    when AST::IfBind
      stmt.then_branch = transform_body(stmt.then_branch, ctx) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, ctx) if stmt.else_branch && !stmt.else_branch.empty?
    when AST::ForRange, AST::ForEach
      stmt.body = transform_body(stmt.body, ctx) if stmt.body
    when AST::MatchStatement
      stmt.cases.each { |c| c.body = transform_body(c.body, ctx) if c.body }
      if stmt.default_case
        stmt.default_case = transform_body(stmt.default_case, ctx)
      end
    when AST::WithBlock
      stmt.body = transform_body(stmt.body, ctx) if stmt.body
    when AST::DoBlock
      stmt.branches.each do |b|
        b[:body] = transform_body(b[:body], ctx) if b[:body]
      end
    when AST::BgBlock, AST::BgStreamBlock
      stmt.body = transform_body(stmt.body, ctx.with(bindings: bg_inner_bindings(stmt, ctx.bindings))) if stmt.body
    end
    # Process BgBlock bodies found in expression positions (MethodCall/FuncCall
    # args, VarDecl/BindExpr values). AST.walk_body misses these since it doesn't
    # recurse into call arguments. Only BgBlock (outer consumer fiber) -- not
    # BgStreamBlock (generator fiber has special YIELD handling).
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      val = stmt.value
      if val.is_a?(AST::BgBlock) && val.body
        val.body = transform_body(val.body, ctx.with(bindings: bg_inner_bindings(val, ctx.bindings)))
      end
    when AST::MethodCall, AST::FuncCall
      stmt.args.each do |a|
        if a.is_a?(AST::BgBlock) && a.body
          a.body = transform_body(a.body, ctx.with(bindings: bg_inner_bindings(a, ctx.bindings)))
        end
      end
    end
  end

  # Bindings as seen from INSIDE a BG body: captured names belong to the
  # outer scope and their moved-guard vars (e.g. `lst_moved`) are not
  # visible here, so we must not emit SuppressCleanup for them inside the
  # fiber. The outer-scope pass (insert_bg_give_suppress!) handles moves
  # of captures; inside the body only BG-local bindings are consumable.
  sig { params(bg_node: T.any(AST::BgBlock, AST::BgStreamBlock), bindings: T::Hash[String, CleanupEntry]).returns(T::Hash[String, CleanupEntry]) }
  def bg_inner_bindings(bg_node, bindings)
    captures = bg_node.capture_analysis&.captures
    return bindings unless captures&.any?
    bindings.reject { |name, _| captures.key?(name) }
  end

  # Insert MIR::SuppressCleanup after statements that consume ownership of
  # tracked bindings. Replaces the transpiler's emit_move_suppression and
  # emit_consumed_moves methods.
  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Set[String])) }
  def mark_consumed_cleanup_guards!(stmt, bindings)
    return if stmt.is_a?(AST::ReturnNode) # handled by insert_return!

    collect_consumed_names(stmt, bindings)
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values (VarDecl, BindExpr, Assignment), MethodCall args,
  # FuncCall args. Yields each BgBlock/BgStreamBlock found.
  # Collect names of bindings consumed by a statement.
  # Three consumption paths:
  #   1. Direct RHS: identifier used as value in assignment/declaration
  #   2. Standalone GIVE: `GIVE x;` as a statement
  #   3. Nested: identifier passed as TAKES/GIVE arg or used as struct field
  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T::Set[String]) }
  def collect_consumed_names(stmt, bindings)
    names = Set.new

    # 1. Direct RHS consumption
    rhs = case stmt
          when AST::VarDecl    then stmt.value
          when AST::BindExpr   then stmt.value
          when AST::Assignment then stmt.value
          else nil
          end

    if rhs
      # Structural unwrap only; the move decision reads the annotator's
      # was_moved stamp, not the MoveNode node type (INV-13).
      ident = rhs.is_a?(AST::MoveNode) ? rhs.value : rhs
      add_if_consumed(ident, names, bindings, ident.was_moved == true) if ident.is_a?(AST::Identifier)
    end

    # 2. Standalone GIVE: `GIVE x;` as a bare statement
    if stmt.is_a?(AST::MoveNode) && stmt.value.is_a?(AST::Identifier)
      add_if_consumed(stmt.value, names, bindings, stmt.value.was_moved == true)
    end

    # 2. Nested consumption (StructLit fields, FuncCall/MethodCall TAKES args)
    value_expr = case stmt
                 when AST::VarDecl, AST::BindExpr then stmt.value
                 when AST::Assignment then stmt.value
                 else stmt
                 end
    value_expr = value_expr.value if value_expr.is_a?(AST::MoveNode)
    walk_consumed(value_expr, names, bindings)

    names
  end

  # Recursively walk an expression to find consumed identifiers in
  # StructLit fields and FuncCall/MethodCall TAKES/GIVE args.
  sig { params(node: T.untyped, names: T::Set[String], bindings: T::Hash[String, CleanupEntry]).returns(T.untyped) }
  def walk_consumed(node, names, bindings)
    return unless node
    case node
    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      walk_consumed(node.value, names, bindings)
    when AST::StructLit
      node.fields.each_value do |v|
        if v.is_a?(AST::Identifier)
          add_if_consumed(v, names, bindings, false)
        else
          walk_consumed(v, names, bindings)
        end
      end
    when AST::ListLit
      node.items.each { |i| walk_consumed(i, names, bindings) }
    when AST::GetField
      if owning_field_move?(node)
        root = AST.root_identifier(node)
        if root
          entry = live_cleanup_entry(bindings, root.name)
          if entry
            entry[:has_moved_guard] = true
            names << root.name.to_s
          end
        end
      else
        walk_consumed(node.target, names, bindings)
      end
    when AST::MoveNode
      if node.value.is_a?(AST::Identifier)
        add_if_consumed(node.value, names, bindings, node.value.was_moved == true)
      else
        walk_consumed(node.value, names, bindings)
      end
    when AST::FuncCall, AST::MethodCall
      consume_call_args(node, names, bindings)
      walk_consumed(node.object, names, bindings) if node.is_a?(AST::MethodCall)
    when AST::BinaryOp
      walk_consumed(node.left, names, bindings)
      walk_consumed(node.right, names, bindings)
    when AST::Assert
      walk_consumed(node.condition, names, bindings)
    when AST::ReturnNode
      walk_consumed(node.value, names, bindings)
    end
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall), names: T::Set[String], bindings: T::Hash[String, CleanupEntry]).void }
  def consume_call_args(node, names, bindings)
    sig_obj = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    params = sig_obj&.params || []
    param_offset = node.is_a?(AST::MethodCall) ? 1 : 0

    node.args.each_with_index do |arg, idx|
      param = params[idx + param_offset]
      consumes = param&.takes == true
      if arg.is_a?(AST::Identifier) && (arg.was_moved || consumes)
        add_if_consumed(arg, names, bindings, arg.was_moved == true || consumes)
      else
        walk_consumed(arg, names, bindings)
      end
    end
  end

  # Add identifier to consumed set if it has a moved guard and passes
  # Copy-type filters. RC types only consume on explicit GIVE (MoveNode).
  sig { params(ident: AST::Identifier, names: T::Set[String], bindings: T::Hash[String, CleanupEntry], is_move: T::Boolean).returns(T.nilable(T::Set[String])) }
  def add_if_consumed(ident, names, bindings, is_move)
    name = ident.name.to_s
    entry = bindings[name]
    return unless entry

    ti = ident.full_type
    owns_transferable_value = ti && ti.needs_cleanup?(@schema_lookup)
    return unless entry.needs_cleanup? || owns_transferable_value

    if is_move
      entry[:has_moved_guard] = true
    elsif !entry.has_moved_guard?
      return
    end

    is_atomic_ptr = ti.atomic_ptr?
    # RC types: only consume on explicit GIVE. AtomicPtr is represented
    # as shared for escape/lifetime purposes, but its runtime value is a
    # unique heap cell pointer, not an Arc handle.
    if ti && (ti.any_rc? rescue false) && !is_atomic_ptr
      names << name if is_move
      return
    end

    names << name
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def owning_field_move?(node)
    return false unless node.is_a?(AST::GetField)
    ti = Type.from_node(node)
    ti.is_a?(Type) && ti.indirect?
  rescue
    false
  end

  # Stamp reassign_cleanup on BindExpr :assign nodes that overwrite non-Copy variables.
  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_reassign_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::BindExpr) && stmt.mode == :assign

    entry = bindings[stmt.name.to_s]
    return unless entry && entry.kind != :resource
    # A heap-owned binding reassigned in a loop must free the OLD value
    # before storing the new one -- even if the binding is ultimately
    # moved out (only the final value is moved; the intermediates would
    # otherwise leak). needs_cleanup? alone misses the moved-out case.
    return unless entry.needs_cleanup? || entry.alloc == :heap

    ti = stmt.full_type
    zig_type = (Type.new(ti.resolved).zig_type rescue ti.resolved.to_s)
    stmt.reassign_cleanup = MIR::ReassignPlan.new(alloc: entry.alloc, zig_type: zig_type)
  end

  # Insert MIR nodes for MATCH-AS cleanup into case bodies.
  # Previously stamp-only; now inserts MIR::Alloc + MIR::Drop + MIR::SuppressCleanup
  # so the checker verifies match_as cleanup like any other binding.
  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_match_as_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::MatchStatement)
    return unless stmt.takes
    return unless stmt.expr.is_a?(AST::Identifier) && stmt.expr.was_moved

    src_entry = live_cleanup_entry(bindings, stmt.expr.name)
    has_as_cleanup = T.let(false, T::Boolean)

    stmt.cases.each do |c|
      next unless c.binding
      as_entry = live_cleanup_entry(bindings, c.binding)
      next unless as_entry

      has_as_cleanup = true

      # Insert MIR nodes at the start of case body for checker coverage.
      # Order: source suppression, then AS binding Alloc + Drop.
      mir_prefix = []
      if src_entry
        mir_prefix << MIR::SuppressCleanup.new(stmt.token, stmt.expr.name.to_s)
      end
      mir_prefix << MIR::Alloc.new(stmt.token, c.binding.to_s, as_entry.alloc)
      drop = MIR::Drop.new(stmt.token, c.binding.to_s)
      drop.cleanup_entry = as_entry
      mir_prefix << drop
      c.body = mir_prefix + c.body
    end

    # Ensure source has moved guard so _moved variable exists for suppression.
    # Only set if the source still needs cleanup (dataflow may have eliminated it).
    src_entry[:has_moved_guard] = true if has_as_cleanup && src_entry
  end

  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_while_bind_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::WhileBindLoop)
    entry = live_cleanup_entry(bindings, stmt.binding_name)
    return unless entry
    alloc_node = MIR::Alloc.new(stmt.token, stmt.binding_name.to_s, entry.alloc)
    drop = MIR::Drop.new(stmt.token, stmt.binding_name.to_s)
    drop.cleanup_entry = entry
    stmt.do_branch = [alloc_node, drop] + (stmt.do_branch || [])
  end

  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_if_bind_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::IfBind)
    mir_prefix = []
    stmt.bindings.each do |b|
      entry = live_cleanup_entry(bindings, b.name)
      next unless entry
      mir_prefix << MIR::Alloc.new(stmt.token, b.name.to_s, entry.alloc)
      drop = MIR::Drop.new(stmt.token, b.name.to_s)
      drop.cleanup_entry = entry
      mir_prefix << drop
    end
    stmt.then_branch = mir_prefix + (stmt.then_branch || []) unless mir_prefix.empty?
  end


  # Build moved_guard_info: { var_name => bool } for all bindings.
  sig { params(fn: AST::FunctionDef, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Hash[String, TrueClass])) }
  def stamp_moved_guard_info!(fn, bindings)
    info = {}
    bindings.each do |name, entry|
      info[name] = true if entry.has_moved_guard? && entry.needs_cleanup?
    end
    fn.moved_guard_info = info unless info.empty?
  end

  sig { params(fn: AST::FunctionDef, bindings: T::Hash[String, CleanupEntry]).void }
  def mark_returned_cleanup_bindings!(fn, bindings)
    return unless fn.body

    returned = T.let(Set.new, T::Set[String])
    walk_ast_nodes(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value
      collect_escaping_ids(node.value).each { |id| returned << id.name.to_s }
    end

    if fn.respond_to?(:heap_carry_return_vars) && fn.heap_carry_return_vars
      fn.heap_carry_return_vars.each { |name| returned << name.to_s }
    end

    returned.each do |name|
      entry = live_cleanup_entry(bindings, name)
      next unless entry&.needs_cleanup?
      entry[:has_moved_guard] = true
    end
  end

  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  sig { params(result: T::Array[T.untyped], ret_node: AST::ReturnNode, bindings: T::Hash[String, CleanupEntry], fn_node: T.nilable(AST::FunctionDef)).returns(T.nilable(T::Array[String])) }
  def insert_return!(result, ret_node, bindings, fn_node: nil)
    escaped = collect_return_escapes(ret_node, bindings, fn_node: fn_node)
    return if escaped.empty?
    result << MIR::Return.new(ret_node.token, escaped)
  end

  # Walk a return expression and collect variable names whose ownership
  # transfers to the caller. Mirrors transpiler's collect_escaping_identifiers
  # but filters to bindings with has_moved_guard (those needing suppression).
  sig { params(ret_node: AST::ReturnNode, bindings: T::Hash[String, CleanupEntry], fn_node: T.nilable(AST::FunctionDef)).returns(T::Array[String]) }
  def collect_return_escapes(ret_node, bindings, fn_node: nil)
    return [] unless ret_node.value
    ids = collect_escaping_ids(ret_node.value)
    ids.select { |id|
        n = id.name.to_s
        (bindings[n]&.dig(:has_moved_guard) && bindings[n]&.dig(:needs_cleanup)) ||
          (n.start_with?("__hoist_") &&
            id.respond_to?(:was_moved) && id.was_moved == true &&
            bindings[n]&.dig(:needs_cleanup))
      }
      .map { |id| id.name.to_s }
       .uniq
  end

  sig { params(node: T.untyped).returns(T::Array[T.untyped]) }
  def collect_escaping_ids(node)
    return [] unless node
    case node
    when AST::Identifier then [node]
    when AST::MoveNode   then collect_escaping_ids(node.value)
    when AST::StructLit, AST::UnionVariantLit
      node.fields.values.flat_map { |v| collect_escaping_ids(v) }
    when AST::FuncCall, AST::MethodCall
      node.args.select(&:was_moved).flat_map { |a| collect_escaping_ids(a) }
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode then []
    else []
    end
  end

end
