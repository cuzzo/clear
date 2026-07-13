# typed: strict
# src/mir_pass.rb - MIR transformation pass
#
# Runs after annotation. Escape analysis has already decided binding storage;
# this pass classifies cleanup bindings and inserts cleanup/suppress nodes.
#
# Dependencies are defined in control_flow.rb (required first) and cleanup_classifier.rb.

require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../annotator/helpers/function_signature"
require_relative "cleanup_classifier"
require_relative "../semantic/escape_analysis"
require_relative "../semantic/bg_capture_classifier"
require_relative "../compiler/entrypoint"
require_relative "control_flow"
require_relative "../semantic/pass_state"
require_relative "placement"

class MIRPass
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  AstCall = T.type_alias { T.any(AST::FuncCall, AST::MethodCall) }
  HoistBindings = T.type_alias { T::Hash[String, T::Array[AST::VarDecl]] }

  # Read-only context threaded through transform_body / recurse_branches!.
  class WalkCtx < T::Struct
    extend T::Sig

    const :cleanup_facts, CleanupClassifier::FrozenCleanupFacts

    sig { params(cleanup_facts: CleanupClassifier::FrozenCleanupFacts).returns(MIRPass::WalkCtx) }
    def with(cleanup_facts: self.cleanup_facts)
      MIRPass::WalkCtx.new(cleanup_facts: cleanup_facts)
    end
  end

  class OwnershipPreparationPlan < T::Struct
    extend T::Sig

    const :function, AST::FunctionDef
    const :cleanup_facts, CleanupClassifier::FrozenCleanupFacts
    const :can_fail_fns, T::Set[String]

    sig { returns(T::Hash[String, CleanupEntry]) }
    def bindings
      cleanup_facts.bindings
    end

    sig { returns(T::Boolean) }
    def cleanup_bindings?
      !cleanup_facts.empty?
    end
  end

  # cleanup_bindings: { fn_name => { var_name => entry_hash } }
  # Exposed for specs that test classification directly.
  sig { returns(T::Hash[String, T::Hash[String, CleanupEntry]]) }
  attr_reader :cleanup_bindings

  sig { returns(T::Hash[String, CleanupClassifier::CleanupClassificationPlan]) }
  attr_reader :cleanup_plans

  sig { returns(EscapeAnalysis::EscapePlacementFacts) }
  attr_reader :escape_placement_facts

  sig { params(fn_nodes: FnNodes, schema_lookup: Type::SchemaLookup, body_summaries: T::Hash[String, Annotator::Phases::FunctionBodySummary], hoist_bindings: T.nilable(HoistBindings)).void }
  def initialize(fn_nodes:, schema_lookup:, body_summaries: {}, hoist_bindings: nil)
    @fn_nodes = T.let(fn_nodes, FnNodes)
    @schema_lookup = schema_lookup
    @body_summaries = T.let(body_summaries, T::Hash[String, Annotator::Phases::FunctionBodySummary])
    @hoist_bindings = T.let(hoist_bindings || {}, HoistBindings)
    @cleanup_bindings = T.let({}, T::Hash[String, T::Hash[String, CleanupEntry]])
    @cleanup_plans = T.let({}, T::Hash[String, CleanupClassifier::CleanupClassificationPlan])
    @escape_placement_facts = T.let(EscapeAnalysis::EscapePlacementFacts.new, EscapeAnalysis::EscapePlacementFacts)
    @can_fail_fns = T.let(self.class.fallible_function_names(fn_nodes), T::Set[String])
    @current_transform_fn = T.let(nil, T.nilable(AST::FunctionDef))
  end

  sig { params(fn_nodes: FnNodes).returns(T::Set[String]) }
  def self.fallible_function_names(fn_nodes)
    fn_nodes.each_with_object(Set.new) do |(name, fn), names|
      names << name if fn.can_fail
    end
  end

  sig { params(facts: CleanupClassifier::FrozenCleanupFacts, name: T.any(String, Symbol, CleanupClassifier::PlaceId)).returns(CleanupEntry) }
  def live_cleanup_entry(facts, name)
    facts.live_entry_for(name)
  end

  sig { params(name: String, alloc: Symbol, type_info: Type).returns(MIR::AllocMark) }
  def alloc_marker(name, alloc, type_info)
    marker = MIR::AllocMark.new(name, alloc, type_info)
    marker.scope = MIR::Placement.alloc_scope(alloc)
    marker
  end

  # Computes plans, classifies bindings, inserts MIR nodes, and stamps AST.
  # Hoist has already lifted anonymous allocating expressions into bindings.
  # Escape analysis writes final binding storage; this pass inserts MIR markers.
  sig { params(ast: AST::Program).void }
  def transform!(ast)
    pass_state = MIRPassState.for!(ast)
    pass_state.require!(:premir_type_checked, consumer: "MIRPass")

    # Escape analysis writes final SymbolEntry#storage and now also returns the
    # typed placement table explaining which phase forced each heap placement.
    escape_result = EscapeAnalysis.apply_with_facts!(@fn_nodes, @schema_lookup, @body_summaries, @hoist_bindings)
    @escape_placement_facts = escape_result.placements
    BgCaptureClassifier.classify_all!(@fn_nodes, schema_lookup: @schema_lookup)
    pass_state.mark!(:escape_analyzed)

    # SYNC propagation ran inside EscapeAnalysis.apply! above (single-pass
    # escape principle). Nothing to do here.

    # Promotion planning is gone: escape analysis writes symbol.storage;
    # lowering and cleanup only read that fact.

    # Phase 2.5: classify cleanup bindings (uses finalized provenance from Phase 2).
    @fn_nodes.each do |name, fn|
      cleanup_plan = CleanupClassifier.classify_plan(fn, schema_lookup: @schema_lookup)
      @cleanup_plans[name] = cleanup_plan
      @cleanup_bindings[name] = cleanup_plan.bindings
    end
    pass_state.mark!(:cleanup_classified)

    LoopFrameAnalysis.analyze!(@fn_nodes, @schema_lookup)
    pass_state.mark!(:loop_frame_analyzed)

    # needs_rt finalization must run after placement and cleanup
    # classification. That is the point where the compiler knows whether a
    # function actually needs an allocator for a heap/frame binding or cleanup.
    # Propagate to callers so runtime threading is decided once from final data.
    finalize_needs_rt!
    pass_state.mark!(:needs_rt_finalized)

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
      sig = FunctionSignature.from_function_def(fn)
      FunctionSignature.sync_signature_from_function_def!(sig, fn) if sig.is_a?(FunctionSignature)
    end
    pass_state.mark!(:mir_pass_complete)
    nil
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
      cleanup_facts = @cleanup_plans[fn.name.to_s]&.facts ||
        CleanupClassifier::FrozenCleanupFacts.from_bindings(@cleanup_bindings[fn.name.to_s] || {})
      if finalized_runtime_input?(fn) ||
         params_need_runtime_cleanup?(fn.params) ||
         runtime_cleanup_facts?(cleanup_facts)
        fn.needs_rt = true
        next
      end
      AST.each_locatable(fn.body) do |n|
        if ast_node_needs_runtime?(n)
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
      fn.name.to_s == Compiler::Entrypoint::NAME ||
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
      ti = param.type
      next true if ti.any?
      next false if ti.primitive? || ti.id_handle?
      true
    end
  end

  sig { params(facts: CleanupClassifier::FrozenCleanupFacts).returns(T::Boolean) }
  def runtime_cleanup_facts?(facts)
    found = T.let(false, T::Boolean)
    facts.each_entry do |_place, entry|
      found = true if [:heap, :frame].include?(entry.alloc)
    end
    found
  end

  sig { params(node: AstCall).returns(T::Boolean) }
  def ast_call_needs_rt?(node)
    return false if @fn_nodes.key?(node.name.to_s)

    sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
    return false unless sig
    return true if sig.needs_rt == true

    sig.emits_allocating? == true
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def ast_node_lowers_through_runtime?(node)
    case node
    when AST::FuncCall, AST::MethodCall
      ast_call_needs_rt?(node)
    when AST::BgBlock, AST::BgStreamBlock
      true
    when AST::Assignment
      indexed_assignment_lowers_through_runtime?(node)
    when AST::CopyNode, AST::CloneNode
      copy_node_lowers_through_runtime?(node)
    when AST::WithBlock
      with_block_lowers_through_runtime?(node)
    else
      false
    end
  end

  sig { params(node: T.any(AST::CopyNode, AST::CloneNode)).returns(T::Boolean) }
  def copy_node_lowers_through_runtime?(node)
    ti = Type.from_node!(node, context: "COPY runtime requirement").success_type
    return false if ti.primitive? || ti.id_handle?

    ti.string? ||
      ti.heap_ptr? ||
      ti.collection_value? ||
      ti.collection? ||
      ti.any_sync? ||
      ti.optional? && ti.needs_cleanup?(T.unsafe(@schema_lookup)) ||
      ti.needs_cleanup?(T.unsafe(@schema_lookup)) ||
      ti.recursive_cleanup_shape?(T.unsafe(@schema_lookup))
  end

  sig { params(node: AST::Assignment).returns(T::Boolean) }
  def indexed_assignment_lowers_through_runtime?(node)
    return false unless node.name.is_a?(AST::GetIndex)
    target_node = node.name.target
    return false unless target_node.is_a?(AST::Locatable)
    ti = target_node.full_type!(context: "indexed assignment target")
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
    action_raises = [AST::ErrorActionKind::Raise, AST::ErrorActionKind::Exit].include?(clause.action)
    has_bubble = clause.bubble_types.any?
    action_raises || has_bubble
  end

  sig { params(fn_node: AST::FunctionDef).returns(T::Boolean) }
  def recursion_yield_needed?(fn_node)
    AST.recursion_yield_needed?(fn_node)
  end

  sig { params(node: T.any(AST::Node, AST::RawBody), acc: T::Set[String]).void }
  def collect_callees(node, acc)
    AST.each_locatable(node) do |child|
      case child
      when AST::FuncCall, AST::MethodCall
        acc << child.name.to_s if child.name
      end
    end
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def return_path_needs_allocator?(fn)
    return false unless fn.heap_carry_return
    found = T.let(false, T::Boolean)
    AST.each_locatable(fn.body) do |node|
      next if found
      next unless node.is_a?(AST::ReturnNode) && node.value
      found = return_expr_needs_allocator?(fn, node.value)
    end
    found
  end

  sig { params(fn: AST::FunctionDef, expr: AST::Node).returns(T::Boolean) }
  def return_expr_needs_allocator?(fn, expr)
    node = unwrap_return_expr(expr)
    return true if node.is_a?(AST::CopyNode)
    ti = node.is_a?(AST::Locatable) ? node.full_type!(context: "return allocator expression").success_type : nil
    return false if ti&.any_rc? || ti&.any_sync?

    if node.is_a?(AST::Identifier)
      return false if fn.params.any? { |param| param.name.to_s == node.name.to_s && param.takes }
      return !!(ti&.string? || ti&.recursive_cleanup_shape?(T.unsafe(@schema_lookup)))
    end

    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.string_concat == true
    !!(ti && !node.is_a?(AST::Literal) &&
       (ti.string? || ti.heap_ptr? || ti.collection_value? ||
        ti.collection? || ti.needs_cleanup?(T.unsafe(@schema_lookup)) ||
        ti.recursive_cleanup_shape?(T.unsafe(@schema_lookup))))
  end

  sig { params(expr: AST::Node).returns(AST::Node) }
  def unwrap_return_expr(expr)
    case expr
    when AST::MoveNode, AST::Cast, AST::FreezeNode
      unwrap_return_expr(expr.value)
    when AST::BinaryOp
      expr.op == :OR_ELSE ? unwrap_return_expr(expr.left) : expr
    else
      expr
    end
  end

  sig { params(fn: AST::FunctionDef).void }
  def transform_function!(fn)
    plan = ownership_preparation_plan(fn)
    return unless plan.cleanup_bindings?

    cleanup_facts = plan.cleanup_facts
    function = plan.function
    bc_errors = BorrowChecker.check(function, schema_lookup: @schema_lookup)
    raise "[Borrow Error] #{bc_errors.first}" unless bc_errors.empty?

    pre_mark_bg_resource_captures!(function, cleanup_facts)
    dataflow = OwnershipDataflow.analyze(function, can_fail_fns: plan.can_fail_fns, schema_lookup: @schema_lookup)
    dataflow.cleanup_decisions!(function, cleanup_facts)
    mark_returned_cleanup_bindings!(function, cleanup_facts)
    function.cleanup_bindings = cleanup_facts.bindings
    CleanupClassifier.stamp_field_pre_cleanups!(function.body, cleanup_facts, schema_lookup: @schema_lookup)

    @current_transform_fn = function
    function.body = transform_body(function.body, WalkCtx.new(cleanup_facts: cleanup_facts))
    @current_transform_fn = nil
    stamp_moved_guard_info!(function, cleanup_facts)
    nil
  end

  sig { params(fn: AST::FunctionDef).returns(OwnershipPreparationPlan) }
  def ownership_preparation_plan(fn)
    name = fn.name.to_s
    cleanup_facts = @cleanup_plans[name]&.facts ||
      CleanupClassifier::FrozenCleanupFacts.from_bindings(@cleanup_bindings[name] || {})
    OwnershipPreparationPlan.new(
      function: fn,
      cleanup_facts: cleanup_facts,
      can_fail_fns: @can_fail_fns,
    )
  end

  # Pre-mark bindings that are captured by BG blocks as needing moved guards.
  # This runs BEFORE refine_moved_guards! so that when Drops are later created
  # (which snapshot cleanup_entry = entry.dup), the has_moved_guard flag is
  # already correct. Without this, insert_bg_resource_suppress! would mutate
  # bindings AFTER Drops were created, causing a split between the Drop's
  # snapshot and the binding's current state.
  sig { params(fn: AST::FunctionDef, facts: CleanupClassifier::FrozenCleanupFacts).returns(T::Array[AST::Node]) }
  def pre_mark_bg_resource_captures!(fn, facts)
    AST.each_bg_block(fn.body) do |bg|
      resource_captures = bg.capture_analysis&.resource_captures
      next unless resource_captures&.any?

      resource_captures.each do |name|
        facts.with_live_entry_for(name) { |entry| entry.mark_moved_guard! }
      end
    end
    fn.body
  end

  # Recursively transform a statement list, inserting MIR nodes.
  # Returns a new array (does not mutate the input).
  sig { params(stmts: T::Array[AST::Node], ctx: MIRPass::WalkCtx).returns(T::Array[T.untyped]) }
  def transform_body(stmts, ctx)
    result = []
    cleanup_facts = ctx.cleanup_facts
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      recurse_branches!(stmt, ctx)

      # Insert Return (escape markers) before ReturnNode.
      if stmt.is_a?(AST::ReturnNode)
        insert_return!(result, stmt, cleanup_facts, fn_node: @current_transform_fn)
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, cleanup_facts)
      stamp_match_as_cleanup!(stmt, cleanup_facts)
      stamp_while_bind_cleanup!(stmt, cleanup_facts)
      stamp_if_bind_cleanup!(stmt, cleanup_facts)

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

      mark_consumed_cleanup_guards!(stmt, cleanup_facts)
    end
    result
  end

  # Recurse into control flow branches to transform nested bodies.
  sig { params(stmt: AST::Node, ctx: MIRPass::WalkCtx).void }
  def recurse_branches!(stmt, ctx)
    branch_ctx = if stmt.is_a?(AST::BgBlock) || stmt.is_a?(AST::BgStreamBlock)
      ctx.with(cleanup_facts: bg_inner_facts(stmt, ctx.cleanup_facts))
    else
      ctx
    end
    AST.body_slots(stmt).each { |slot| slot.replace(transform_body(slot.body, branch_ctx)) }
    # Process BgBlock bodies found in expression positions (MethodCall/FuncCall
    # args, VarDecl/BindExpr values). AST.walk_body misses these since it doesn't
    # recurse into call arguments. Only BgBlock (outer consumer fiber) -- not
    # BgStreamBlock (generator fiber has special YIELD handling).
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment, AST::DestructuringAssignment
      val = stmt.value
      if val.is_a?(AST::BgBlock) && val.body
        val.body = transform_body(val.body, ctx.with(cleanup_facts: bg_inner_facts(val, ctx.cleanup_facts)))
      end
    when AST::MethodCall, AST::FuncCall
      stmt.args.each do |a|
        if a.is_a?(AST::BgBlock) && a.body
          a.body = transform_body(a.body, ctx.with(cleanup_facts: bg_inner_facts(a, ctx.cleanup_facts)))
        end
      end
    end
  end

  # Bindings as seen from INSIDE a BG body: captured names belong to the
  # outer scope and their moved-guard vars (e.g. `lst_moved`) are not
  # visible here, so we must not emit SuppressCleanup for them inside the
  # fiber. The outer-scope pass (insert_bg_give_suppress!) handles moves
  # of captures; inside the body only BG-local bindings are consumable.
  sig { params(bg_node: T.any(AST::BgBlock, AST::BgStreamBlock), facts: CleanupClassifier::FrozenCleanupFacts).returns(CleanupClassifier::FrozenCleanupFacts) }
  def bg_inner_facts(bg_node, facts)
    captures = bg_node.capture_analysis&.captures
    return facts unless captures&.any?
    facts.without_names(captures.keys.map(&:to_s))
  end

  # Insert MIR::SuppressCleanup after statements that consume ownership of
  # tracked bindings. Replaces the transpiler's emit_move_suppression and
  # emit_consumed_moves methods.
  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).returns(T.nilable(T::Set[String])) }
  def mark_consumed_cleanup_guards!(stmt, facts)
    return if stmt.is_a?(AST::ReturnNode) # handled by insert_return!

    collect_consumed_names(stmt, facts)
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values (VarDecl, BindExpr, Assignment), MethodCall args,
  # FuncCall args. Yields each BgBlock/BgStreamBlock found.
  # Collect names of bindings consumed by a statement.
  # Three consumption paths:
  #   1. Direct RHS: identifier used as value in assignment/declaration
  #   2. Standalone GIVE: `GIVE x;` as a statement
  #   3. Nested: identifier passed as TAKES/GIVE arg or used as struct field
  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).returns(T::Set[String]) }
  def collect_consumed_names(stmt, facts)
    names = Set.new

    # 1. Direct RHS consumption
    rhs = case stmt
          when AST::VarDecl, AST::BindExpr, AST::Assignment, AST::DestructuringAssignment then stmt.value
          else nil
          end

    if rhs
      # Structural unwrap only; the move decision reads the annotator's
      # was_moved stamp, not the MoveNode node type (INV-13).
      ident = rhs.is_a?(AST::MoveNode) ? rhs.value : rhs
      add_if_consumed(ident, names, facts, AST.moved?(ident)) if ident.is_a?(AST::Identifier)
    end

    # 2. Standalone GIVE: `GIVE x;` as a bare statement
    if stmt.is_a?(AST::MoveNode) && stmt.value.is_a?(AST::Identifier)
      add_if_consumed(stmt.value, names, facts, AST.moved?(stmt.value))
    end

    # 2. Nested consumption (StructLit fields, FuncCall/MethodCall TAKES args)
    value_expr = case stmt
                 when AST::VarDecl, AST::BindExpr, AST::Assignment, AST::DestructuringAssignment then stmt.value
                 else stmt
                 end
    value_expr = value_expr.value if value_expr.is_a?(AST::MoveNode)
    walk_consumed(value_expr, names, facts)

    names
  end

  # Recursively walk an expression to find consumed identifiers in
  # StructLit fields and FuncCall/MethodCall TAKES/GIVE args.
  sig { params(node: T.nilable(AST::Node), names: T::Set[String], facts: CleanupClassifier::FrozenCleanupFacts).void }
  def walk_consumed(node, names, facts)
    return unless node
    case node
    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      walk_consumed(node.value, names, facts)
    when AST::StructLit
      node.fields.each_value do |v|
        if v.is_a?(AST::Identifier)
          add_if_consumed(v, names, facts, false)
        else
          walk_consumed(v, names, facts)
        end
      end
    when AST::ListLit
      node.items.each { |i| walk_consumed(i, names, facts) }
    when AST::GetField
      if owning_field_move?(node)
        root = AST.root_identifier(node)
        if root
          facts.with_live_entry_for_node(root.name, root) do |entry|
            entry.mark_moved_guard!
            names << root.name.to_s
          end
        end
      else
        walk_consumed(node.target, names, facts)
      end
    when AST::MoveNode
      if node.value.is_a?(AST::Identifier)
        add_if_consumed(node.value, names, facts, AST.moved?(node.value))
      else
        walk_consumed(node.value, names, facts)
      end
    when AST::FuncCall, AST::MethodCall
      consume_call_args(node, names, facts)
      walk_consumed(node.object, names, facts) if node.is_a?(AST::MethodCall)
    when AST::BinaryOp
      walk_consumed(node.left, names, facts)
      walk_consumed(node.right, names, facts)
    when AST::Assert, AST::ReturnNode
      expr = node.is_a?(AST::Assert) ? node.condition : node.value
      walk_consumed(expr, names, facts)
    end
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall), names: T::Set[String], facts: CleanupClassifier::FrozenCleanupFacts).void }
  def consume_call_args(node, names, facts)
    sig_obj = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    params = sig_obj&.params || []
    param_offset = node.is_a?(AST::MethodCall) ? 1 : 0

    node.args.each_with_index do |arg, idx|
      param = params[idx + param_offset]
      consumes = param&.takes == true
      if arg.is_a?(AST::Identifier) && (arg.was_moved || consumes)
        add_if_consumed(arg, names, facts, AST.moved?(arg) || consumes)
      else
        walk_consumed(arg, names, facts)
      end
    end
  end

  # Add identifier to consumed set if it has a moved guard and passes
  # Copy-type filters. RC types only consume on explicit GIVE (MoveNode).
  sig { params(ident: AST::Identifier, names: T::Set[String], facts: CleanupClassifier::FrozenCleanupFacts, is_move: T::Boolean).returns(T.nilable(T::Set[String])) }
  def add_if_consumed(ident, names, facts, is_move)
    name = ident.name.to_s
    entry = facts.entry_for_node(name, ident)
    return unless entry.present?

    ti = ident.full_type!
    owns_transferable_value = ti && ti.needs_cleanup?(T.unsafe(@schema_lookup))
    return unless entry.needs_cleanup? || owns_transferable_value

    if is_move
      entry.mark_moved_guard!
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

  sig { params(node: AST::Node).returns(T::Boolean) }
  def owning_field_move?(node)
    return false unless node.is_a?(AST::GetField)
    ti = node.full_type!(context: "MIR pass field move")
    Type.indirect_type?(ti)
  rescue
    false
  end

  sig { params(node: AST::Locatable).returns(T::Boolean) }
  def ast_node_needs_runtime?(node)
    AST.declaration_with_heap_symbol?(node) || ast_node_lowers_through_runtime?(node)
  end

  # Stamp reassign_cleanup on BindExpr :assign nodes that overwrite non-Copy variables.
  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def stamp_reassign_cleanup!(stmt, facts)
    return unless stmt.is_a?(AST::BindExpr) && stmt.mode == :assign

    entry = cleanup_entry_for_binding_node(stmt, facts)
    return unless entry.present? && entry.kind != :resource
    # A heap-owned binding reassigned in a loop must free the OLD value
    # before storing the new one -- even if the binding is ultimately
    # moved out (only the final value is moved; the intermediates would
    # otherwise leak). needs_cleanup? alone misses the moved-out case.
    return unless entry.needs_cleanup? || entry.heap?

    ti = stmt.full_type!
    zig_type = (Type.new(ti.resolved).zig_type rescue ti.resolved.to_s)
    stmt.reassign_cleanup = MIR::ReassignPlan.new(alloc: entry.alloc, zig_type: zig_type)
  end

  sig { params(node: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).returns(CleanupEntry) }
  def cleanup_entry_for_binding_node(node, facts)
    symbol = node.respond_to?(:symbol) ? node.symbol : nil
    decl = symbol&.reg
    entry = MIR::LocalBindingAnalysis.binding_entry(decl)
    return entry if entry

    return facts.entry_for_node(node.public_send(:name).to_s, node) if node.respond_to?(:name)

    CleanupEntry::NONE
  end

  # Insert MIR nodes for MATCH-AS cleanup into case bodies.
  # Previously stamp-only; now inserts MIR::AllocMark + MIR::Drop + MIR::SuppressCleanup
  # so the checker verifies match_as cleanup like any other binding.
  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def stamp_match_as_cleanup!(stmt, facts)
    return unless stmt.is_a?(AST::MatchStatement)
    return unless stmt.takes
    expr = stmt.expr
    return unless expr.is_a?(AST::Identifier) && expr.was_moved

    src_entry = live_cleanup_entry(facts, expr.name)
    has_as_cleanup = T.let(false, T::Boolean)
    has_source_cleanup = src_entry.needs_cleanup?

    stmt.cases.each do |c|
      next unless c.binding

      binding = T.must(c.binding)
      facts.with_live_entry_for(binding) do |as_entry|
        has_as_cleanup = true

        # Insert MIR nodes at the start of case body for checker coverage.
        # Order: source suppression, then AS binding Alloc + Drop.
        mir_prefix = []
        if has_source_cleanup
          mir_prefix << MIR::SuppressCleanup.new(stmt.token, expr.name.to_s)
        end
        destructure = c.destructure
        alloc_type = if destructure
          destructure.full_type!(context: "match AS allocation marker")
        else
          Type.from_node!(expr, context: "match AS allocation marker")
        end
        mir_prefix << alloc_marker(binding, as_entry.alloc, alloc_type)
        drop = MIR::Drop.new(stmt.token, binding)
        drop.cleanup_entry = as_entry
        mir_prefix << drop
        c.body = mir_prefix + c.body
      end
    end

    # Ensure source has moved guard so _moved variable exists for suppression.
    # Only set if the source still needs cleanup (dataflow may have eliminated it).
    src_entry.mark_moved_guard! if has_as_cleanup && has_source_cleanup
  end

  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def stamp_while_bind_cleanup!(stmt, facts)
    return unless stmt.is_a?(AST::WhileBindLoop)
    facts.with_live_entry_for(stmt.binding_name) do |entry|
      alloc_node = alloc_marker(
        stmt.binding_name.to_s,
        entry.alloc,
        T.must(Type.from_node!(stmt.condition, context: "while-bind allocation marker").wrapped_type),
      )
      drop = MIR::Drop.new(stmt.token, stmt.binding_name.to_s)
      drop.cleanup_entry = entry
      stmt.do_branch = [alloc_node, drop] + (stmt.do_branch || [])
    end
  end

  sig { params(stmt: AST::Node, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def stamp_if_bind_cleanup!(stmt, facts)
    return unless stmt.is_a?(AST::IfBind)
    mir_prefix = []
    stmt.bindings.each do |b|
      # Capture cleanup is binding-identity scoped. Looking it up by the
      # display name lets `IF COPY x AS item` contaminate a later borrowed
      # `IF x AS item` in the same function.
      entry = b.mir_binding_entry
      next unless entry&.needs_cleanup?

      mir_prefix << alloc_marker(b.name.to_s, entry.alloc, b.unwrapped_type)
      drop = MIR::Drop.new(stmt.token, b.name.to_s)
      drop.cleanup_entry = entry
      mir_prefix << drop
    end
    stmt.then_branch = mir_prefix + (stmt.then_branch || []) unless mir_prefix.empty?
  end


  # Build moved_guard_info: { var_name => bool } for all bindings.
  sig { params(fn: AST::FunctionDef, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def stamp_moved_guard_info!(fn, facts)
    info = {}
    facts.bindings.each do |name, entry|
      info[name] = true if entry.has_moved_guard? && entry.needs_cleanup?
    end
    fn.moved_guard_info = info unless info.empty?
  end

  sig { params(fn: AST::FunctionDef, facts: CleanupClassifier::FrozenCleanupFacts).void }
  def mark_returned_cleanup_bindings!(fn, facts)
    return unless fn.body

    returned = T.let(Set.new, T::Set[String])
    AST.each_locatable(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value
      collect_escaping_ids(node.value).each { |id| returned << id.name.to_s }
    end

    if fn.respond_to?(:heap_carry_return_vars) && fn.heap_carry_return_vars
      fn.heap_carry_return_vars.each { |name| returned << name.to_s }
    end

    returned.each do |name|
      facts.with_live_entry_for(name) { |entry| entry.mark_moved_guard! }
    end
  end

  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  sig { params(result: T::Array[AST::Node], ret_node: AST::ReturnNode, facts: CleanupClassifier::FrozenCleanupFacts, fn_node: T.nilable(AST::FunctionDef)).void }
  def insert_return!(result, ret_node, facts, fn_node: nil)
    _ = [result, ret_node, facts, fn_node]
    nil
  end

  # Walk a return expression and collect variable names whose ownership
  # transfers to the caller. Mirrors transpiler's collect_escaping_identifiers
  # but filters to bindings with has_moved_guard (those needing suppression).
  sig { params(ret_node: AST::ReturnNode, facts: CleanupClassifier::FrozenCleanupFacts, fn_node: T.nilable(AST::FunctionDef)).returns(T::Array[String]) }
  def collect_return_escapes(ret_node, facts, fn_node: nil)
    return [] unless ret_node.value
    ids = collect_escaping_ids(ret_node.value)
    ids.select { |id|
        n = id.name.to_s
        decl = id.symbol&.reg
        entry = MIR::LocalBindingAnalysis.binding_entry(decl)
        cleanup_entry = entry || facts.entry_for_node(n, id)
        (cleanup_entry.has_moved_guard? && cleanup_entry.needs_cleanup?) ||
          (n.start_with?("__hoist_") &&
            AST.moved?(id) &&
            cleanup_entry.needs_cleanup?)
      }
      .map { |id| id.name.to_s }
       .uniq
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Array[AST::Identifier]) }
  def collect_escaping_ids(node)
    return [] unless node
    case node
    when AST::Identifier then [node]
    when AST::MoveNode   then collect_escaping_ids(node.value)
    when AST::StructLit, AST::UnionVariantLit
      node.fields.values.flat_map { |v| collect_escaping_ids(v) }
    when AST::FuncCall, AST::MethodCall
      node.args.select(&:was_moved).flat_map { |a| collect_escaping_ids(a) }
    else []
    end
  end

  private :live_cleanup_entry

end
