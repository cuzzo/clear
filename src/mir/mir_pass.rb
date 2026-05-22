# typed: strict
# src/mir_pass.rb - MIR transformation pass
#
# Runs after annotation. Classifies cleanup bindings, stamps fn.cleanup_bindings,
# inserts MIR promotion/suppress nodes, and propagates heap provenance.
#
# Dependencies are defined in control_flow.rb (required first) and promotion_plan.rb.

require "sorbet-runtime"

require_relative "promotion_plan"
require_relative "escape_analysis"
require_relative "escape_graph"

class MIRPass
    extend T::Sig

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

  sig { params(fn_nodes: T::Hash[String, T.untyped], schema_lookup: Proc).void }
  def initialize(fn_nodes:, schema_lookup:)
    @fn_nodes = fn_nodes
    @schema_lookup = schema_lookup
    @cleanup_bindings = T.let({}, T::Hash[String, T::Hash[String, CleanupEntry]])
    @fn_has_catch = T.let(false, T::Boolean)
  end

  # Computes plans, classifies bindings, inserts MIR nodes, and stamps AST.
  # Phase 0 hoists heap-promoted temporaries (HPTs) into VarDecl nodes so that
  # existing classify_binding + cleanup_bindings infrastructure handles their cleanup.
  # PromotionClassifier must run before cleanup classification because its Phase 0
  # (scan_for_hpt_downgrade) clears heap provenance on return sub-expressions
  # that the classifier depends on.
  sig { params(ast: AST::Program).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def transform!(ast)
    # The single value-flow escape analysis. ONE rule per declaration:
    #   storage = :heap iff inherently_heap?(type)
    #                     ∨ (escapes?(value-flow graph) ∧ @list/String)
    # Replaces the 5 fragmented proxies (E1 compute_heap_return_fns!,
    # E2 analyze! 9 conditions, E3a tag_transitive_provenance!, E3b
    # tag_carry_call_sites!, and the escape half of PromotionClassifier).
    # Produces heap_fns and stamps storage/provenance on heap decls.
    # MIRChecker's 7 invariants are unchanged and PROVE the result
    # (fail-closed: any escape gap surfaces as a located error).
    heap_fns, @bg_heap_upgraded = EscapeGraph.apply!(@fn_nodes)
    @bg_heap_upgraded = T.let(@bg_heap_upgraded, T.untyped)

    # SYNC propagation ran inside EscapeGraph.apply! above (single-pass
    # escape principle). Nothing to do here.

    # needs_rt finalization: the annotator computed needs_rt before
    # escape analysis, so it could not see a function that owns a
    # heap-placed local (escape analysis decides that). Any function
    # with a heap binding allocates via `rt`; propagate to its callers
    # (they must thread rt to pass it).
    finalize_needs_rt!

    # Phase 0.5: Rust-aligned hoist. For every fn whose returns may carry
    # heap-owning sub-expressions, propagate storage=:heap into the
    # allocating field expressions of RETURN's struct/union literals.
    # Lowering then picks heapAlloc directly; PromotionClassifier sees
    # field.heap_provenance? = true and skips struct_promote. This is the
    # architectural fix that lets the residual promoteDeep sites collapse:
    # EscapeGraph decides storage per-declaration, this pass extends the
    # decision INTO anonymous return-value sub-expressions that have no
    # declaration of their own.
    @fn_nodes.each do |_name, fn|
      next unless fn_may_return_owning?(fn)
      hoist_return_subexprs_to_heap!(fn.body, fn.return_provenance == :heap)
    end

    # (Phase 1 promotion plan was deleted: storage decisions live at
    # declaration time via EscapeGraph + Phase 0.5 hoist; there is no
    # plan to build, and insert_promotion! / MIR::Promote / MIR::EscapePromote
    # / promote()/promoteList()/promoteDeep() are all gone.)

    # Phase 2: LoopFrameAnalysis ran inside EscapeGraph.apply! above so
    # every escape decision is marked in a single pass (per the
    # "all escapes marked in one pass" architectural principle). Nothing to
    # do here -- mark_per_iter and storage upgrades are already set.

    # Phase 2.5: classify cleanup bindings (uses finalized provenance from Phase 2).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

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

  # Finalize needs_rt after escape analysis. The annotator's
  # compute_needs_rt! ran before placement was decided, so it could not
  # see a function that owns a heap-placed LOCAL (escape analysis
  # decides that). Any function with a heap binding allocates via `rt`;
  # propagate to callers, which must thread rt to pass it.
  sig { void }
  def finalize_needs_rt!
    @fn_nodes.each do |_name, fn|
      next unless fn.body
      next if fn.needs_rt
      AST.walk_body(fn.body) do |n|
        if (n.is_a?(AST::VarDecl) || n.is_a?(AST::BindExpr)) && n.symbol&.heap_provenance?
          fn.needs_rt = true
        end
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

  # Matches the same fn predicate PromotionClassifier.classify uses to gate
  # its analysis: any of body-allocates / heap return / escapable-return.
  # These are the fns whose RETURN literals might carry promotable
  # sub-expressions.
  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def fn_may_return_owning?(fn)
    return false unless fn.body
    # Match the trigger used by PromotionClassifier.classify so the same
    # set of functions enter both passes (otherwise the hoist would
    # skip fns whose returns the classifier processes, leaving residual
    # promoteDeep sites).
    body_allocates = fn.uses_frame == true || fn.uses_heap == true || fn.uses_alloc == true
    body_allocates ||
      fn.return_provenance == :heap ||
      EscapeGraph.local_fn_returns_heap?(fn) ||
      PromotionClassifier.send(:fn_has_escapable_return?, fn, @schema_lookup)
  end

  # Walk fn body, find every RETURN whose value is a struct/union literal,
  # and stamp `storage = :heap` on each field expression that
  #   (a) is not already heap/rodata/borrow,
  #   (b) is not an Identifier (binding-level promotion handled by EscapeGraph),
  #   (c) is not a COPY (already heap-dupes),
  #   (d) has a type that needs_escape_promotion?
  # Lowering reads node.storage via alloc_for_node and picks heapAlloc when
  # the stamp is :heap; downstream PromotionClassifier sees
  # field.heap_provenance? = true and skips struct_promote for the field.
  # This is the Rust-aligned "decide at declaration / construction time"
  # equivalent for nested allocating sub-expressions in return literals.
  sig { params(stmts: T.nilable(T::Array[T.untyped]), heap_return: T::Boolean).void }
  def hoist_return_subexprs_to_heap!(stmts, heap_return = false)
    return unless stmts
    AST.walk_body(stmts) do |node|
      # RETURN with a struct/union literal: propagate :heap into field
      # sub-expressions. RETURN with a bare Identifier borrowed param:
      # synthesize COPY so the value lowers to dupeValue.
      if node.is_a?(AST::ReturnNode)
        val = node.value
        next unless val
        if val.is_a?(AST::StructLit) || val.is_a?(AST::UnionVariantLit)
          hoist_lit_fields!(val)
        elsif val.is_a?(AST::Identifier)
          wrap_identifier_with_copy_if_needed!(node, val)
          # A heap-returning fn returning a borrowed string binding must
          # heap-dupe it: the caller frees with the heap allocator.
          node.catch_string_dupe_ret = true if heap_return && return_string_borrow?(val)
        elsif heap_return && return_string_borrow?(val)
          # rodata literal / field-or-element string borrow returned from
          # a heap-returning fn: dupe to heap for caller-side free.
          node.catch_string_dupe_ret = true
        end
      end
      # Heap-storage VarDecl/BindExpr with struct/union literal value:
      # propagate at construction time. Rodata-literal string fields in a
      # heap struct need heap-cloning so the caller's recursive cleanup
      # doesn't try to free rodata. Same hoist logic, applied at the
      # declaration rather than the RETURN.
      if heap_construction_decl?(node)
        val = node.respond_to?(:value) ? node.value : nil
        if val.is_a?(AST::StructLit) || val.is_a?(AST::UnionVariantLit)
          hoist_lit_fields!(val)
          # After hoist, the literal's fields are all heap-owned (either
          # already-heap, CopyNode-wrapped, or storage=:heap-stamped). Tell
          # PromotionClassifier so it skips this binding -- otherwise its
          # post-loop "fn returns heap struct" arm pessimistically asks
          # compute_struct_promote to deep-promote at return time, double-
          # promoting fields the hoist already handled.
          sym = node.respond_to?(:symbol) ? node.symbol : nil
          sym.init_contents_heap = true if sym
        end
      end
    end
  end

  # A returned string value that is a borrow or rodata (not a fresh
  # owned allocation): an owning (heap-returning) fn must heap-dupe it
  # so the caller can free it with the heap allocator.
  sig { params(v: T.untyped).returns(T::Boolean) }
  def return_string_borrow?(v)
    ti = Type.from_node(v)
    return false unless ti.is_a?(Type) && ti.string?
    case v
    when AST::Literal, AST::GetField, AST::GetIndex then true
    when AST::Identifier then !v.symbol&.heap_provenance?
    else false
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def heap_construction_decl?(node)
    is_decl =
      node.is_a?(AST::VarDecl) ||
      (node.is_a?(AST::BindExpr) && node.respond_to?(:mode) && node.mode == :decl)
    return false unless is_decl
    target_sym = node.respond_to?(:symbol) ? node.symbol : nil
    !!(target_sym&.heap_provenance? ||
       (node.respond_to?(:storage) && node.storage == :heap))
  end

  sig { params(ret_node: AST::ReturnNode, id: AST::Identifier).void }
  def wrap_identifier_with_copy_if_needed!(ret_node, id)
    sym = id.symbol
    return if sym&.takes
    return if sym&.heap_provenance?
    return if sym&.init_contents_heap
    return if sym&.borrow_provenance?
    ti = Type.from_node(id)
    return unless ti.is_a?(Type)
    return if ti.string?  # Strings get caller-side dupe via catch_string_dupe / DupeSlice
    return unless ti.needs_escape_promotion? ||
                  PromotionClassifier.send(:struct_has_promotable_fields?, ti, @schema_lookup)
    copy = AST::CopyNode.new(id.token, id)
    copy.full_type = ti
    ret_node.value = copy
  end

  sig { params(lit: T.untyped).void }
  def hoist_lit_fields!(lit)
    return unless lit.respond_to?(:fields) && lit.fields
    lit.fields.each do |fname, fval|
      next if fval.is_a?(AST::CopyNode) || fval.is_a?(AST::MoveNode) || fval.is_a?(AST::CloneNode)
      next if fval.is_a?(AST::Locatable) && fval.heap_provenance?

      fti = Type.from_node(fval)
      next unless fti.is_a?(Type) && fti.needs_escape_promotion?

      replacement = field_heap_replacement(fval, fti)
      lit.fields[fname] = replacement if replacement && !replacement.equal?(fval)
      if replacement.is_a?(AST::StructLit) || replacement.is_a?(AST::UnionVariantLit)
        hoist_lit_fields!(replacement)
      end
    end
  end

  # Two strategies:
  #  - ALLOCATING expression (StringConcat, MethodCall, etc.) -> stamp
  #    storage=:heap so lowering picks heapAlloc directly. ONE alloc.
  #  - NON-ALLOCATING expression (Literal, Identifier) -> wrap with
  #    AST::CopyNode so lowering routes through dupeValue (the unified
  #    type-driven deep clone). Heap-clones rodata literals and frame/
  #    borrowed identifiers into the heap struct's fields.
  sig { params(fval: T.untyped, fti: Type).returns(T.untyped) }
  def field_heap_replacement(fval, fti)
    if fval.is_a?(AST::Identifier)
      sym = fval.symbol
      return fval if sym&.takes
      return fval if sym&.init_contents_heap
      return fval if sym&.borrow_provenance?
      return wrap_with_copy(fval, fti)
    end
    if fval.is_a?(AST::Literal)
      return wrap_with_copy(fval, fti)
    end
    if fval.respond_to?(:storage=)
      fval.storage = :heap
      return fval
    end
    fval
  end

  sig { params(node: T.untyped, ti: Type).returns(AST::CopyNode) }
  def wrap_with_copy(node, ti)
    copy = AST::CopyNode.new(node.token, node)
    copy.full_type = ti
    copy
  end

  sig { params(fn: AST::FunctionDef).returns(T.nilable(T::Hash[String, TrueClass])) }
  def transform_function!(fn)
    bindings = @cleanup_bindings[fn.name] || {}
    has_bindings = bindings && !bindings.empty?

    has_bg_escapes = body_has_bg_escape_promotes?(fn.body)
    has_catch = fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?

    # BG scope-exit annotation runs unconditionally: the function may have no
    # bindings but still contain BG blocks returning frame values.
    annotate_bg_exits_in_body!(fn.body)

    return unless has_bindings || has_bg_escapes || has_catch

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

    # Patch heap carry return vars: refine_moved_guards! (called inside cleanup_decisions!)
    # sets has_moved_guard=false for string vars because strings are Copy types and
    # are never GIVE'd in OwnershipDataflow.  But carry return vars ARE transferred to the
    # caller implicitly via RETURN.  Override the flag so MIR::Drop emits a guarded defer
    # and collect_return_escapes emits SuppressCleanup before the return.
    if fn.respond_to?(:heap_carry_return_vars) && fn.heap_carry_return_vars&.any? && bindings
      fn.heap_carry_return_vars.each do |var_name|
        entry = bindings[var_name.to_s]
        next unless entry && entry.needs_cleanup?
        entry[:has_moved_guard] = true
      end
    end

    # Stamp cleanup_bindings on the FunctionDef so MIRLowering can read
    # allocator + cleanup info without relying on OLD MIR::Alloc/Drop siblings.
    fn.cleanup_bindings = bindings

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    @fn_has_catch = has_catch
    @current_transform_fn = T.let(fn, T.untyped)
    fn.body = transform_body(fn.body, WalkCtx.new(bindings: bindings))
    @current_transform_fn = T.let(nil, T.untyped)

    # Transform catch clause bodies so string returns are annotated for heap-dupe.
    if has_catch
      empty_ctx = WalkCtx.new(bindings: {})
      fn.catch_clauses.each do |clause|
        tb = transform_body(clause.body, empty_ctx)
        clause.body = tb if tb
      end
      if fn.default_catch.is_a?(Array)
        fn.default_catch = transform_body(fn.default_catch, empty_ctx)
      end
    end
    @fn_has_catch = false

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
          entry = bindings.dig(name)
          next unless entry && entry.needs_cleanup?
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
        # Catch string dupe: heap-dupe string returns so both success and
        # error paths have consistent allocation for caller cleanup.
        insert_catch_string_dupe!(result, stmt) if @fn_has_catch
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)
      stamp_while_bind_cleanup!(stmt, bindings)
      stamp_if_bind_cleanup!(stmt, bindings)

      # Insert MIR::Promote before container stores that need frame-to-heap promotion.
      insert_container_promote!(result, stmt)

      # BG escape promotions: frame-allocated captures (heap upgrade already
      # at declaration by EscapeGraph; this only annotates bg_string for
      # string captures that need a dupe inside the fiber body).
      insert_bg_escape_promote!(result, stmt)

      # BG scope-exit promotion: annotate BgBlocks with what their exit value needs.
      # Must run after recurse_branches! so the BgBlock body is already transformed.
      AST.each_bg_block_in_stmt(stmt) do |bg|
        if bg.is_a?(AST::BgBlock)
          annotate_bg_exit_promote!(bg)
        elsif bg.is_a?(AST::BgStreamBlock)
          annotate_yield_string_dupes!(bg)
        end
      end

      # OrRescue fallback dupe: when success path is heap-promoted and fallback
      # is a struct literal, string fields need heap-duping for consistent cleanup.
      insert_or_fallback_dupe!(result, stmt)

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

      # Insert SuppressCleanup after statements that consume bindings.
      insert_suppress_cleanup!(result, stmt, bindings)

      # BG blocks that capture resources transfer ownership — suppress outer cleanup.
      insert_bg_resource_suppress!(result, stmt, bindings)

      # BG blocks where the body uses `GIVE x` on a captured outer name also
      # transfer ownership to the fiber — same rule as a GIVE elsewhere.
      insert_bg_give_suppress!(result, stmt, bindings)
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
  sig { params(result: T::Array[T.untyped], stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Set[String])) }
  def insert_suppress_cleanup!(result, stmt, bindings)
    return if stmt.is_a?(AST::ReturnNode) # handled by insert_return!

    names = collect_consumed_names(stmt, bindings)
    names.each do |name|
      result << MIR::SuppressCleanup.new(stmt.token, name)
    end
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values (VarDecl, BindExpr, Assignment), MethodCall args,
  # FuncCall args. Yields each BgBlock/BgStreamBlock found.
  # Insert MIR::SuppressCleanup for outer bindings consumed by `GIVE x`
  # inside a BG body. Mirrors insert_bg_resource_suppress! — the fiber
  # takes ownership, so the outer scope's defer must be guarded.
  #
  # Reads `bg.capture_analysis.move_mark_names` (computed once by
  # BgCaptureClassifier in the annotator). Previously this re-walked
  # every BG body via `collect_bg_body_give_names` / `_walk_expr_for_give`
  # — a parallel implementation that drifted from
  # OwnershipDataflow.collect_bg_body_gives (the 378036a0 class of bug).
  sig { params(result: T::Array[T.untyped], stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.untyped) }
  def insert_bg_give_suppress!(result, stmt, bindings)
    # Shallow walk: SuppressCleanup is emitted in this stmt's scope and
    # only affects names in `bindings` (this scope's locals). Nested BG
    # blocks capture from THEIR parent BG body's scope, not from here --
    # their SuppressCleanup gets emitted by the recursive transform_body
    # call when it processes the inner BG's body.
    AST.each_bg_block_in_stmt(stmt) do |bg|
      bg.capture_analysis&.move_mark_names&.each do |name|
        entry = bindings.dig(name)
        next unless entry && entry.needs_cleanup?
        result << MIR::SuppressCleanup.new(stmt.token, name)
      end
    end
  end

  # Insert MIR::SuppressCleanup for resources captured by BG blocks.
  # When a BG fiber captures a resource (TCP fd, etc.), ownership transfers
  # to the fiber — the outer scope's defer must not close it.
  #
  # Resource variables always emit a guarded_defer (moved guard pattern)
  # regardless of scope depth. We must insert SuppressCleanup whenever a
  # BG block captures a resource — even for inner-scope variables that
  # don't appear in the function-level bindings hash.
  sig { params(result: T::Array[T.untyped], stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.untyped) }
  def insert_bg_resource_suppress!(result, stmt, bindings)
    # Shallow walk: same reason as insert_bg_give_suppress! above.
    AST.each_bg_block_in_stmt(stmt) do |bg|
      resource_captures = bg.capture_analysis&.resource_captures
      next unless resource_captures&.any?
      resource_captures.each do |name|
        entry = bindings.dig(name)
        # When dataflow says always-moved (needs_cleanup=false), no Drop was
        # inserted - the fiber is the sole owner. No suppress needed.
        next if entry && !entry.needs_cleanup?
        # has_moved_guard was already set by pre_mark_bg_resource_captures!
        result << MIR::SuppressCleanup.new(stmt.token, name)
      end
    end
  end

  # Quick check: does the function body contain any BG/stream blocks with
  # captures needing escape promotion? Used to ensure transform_body runs
  # even for functions with no cleanup bindings.
  sig { params(stmts: T::Array[T.untyped]).returns(T::Boolean) }
  def body_has_bg_escape_promotes?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      found = T.let(false, T::Boolean)
      AST.each_bg_block(stmt) do |bg|
        captured = bg.capture_analysis&.captures
        next unless captured&.any?
        found = true if captured.any? do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          t && t.needs_escape_promotion? && !t.needs_pointer_passing? && !@bg_heap_upgraded&.include?(name)
        end
      end
      found
    end
  end

  # Annotate a BgBlock with the scope-exit promotion its last expression needs.
  # Mirrors the logic insert_promotion!/insert_catch_string_dupe! apply to
  # function ReturnNodes, but for the BG fiber's implicit return value.
  # Currently handles strings; struct field promotion is left for future work.
  # Walk a statement list looking for BgBlocks (in expression position) and
  # annotate each with the scope-exit promotion its last expression needs.
  # Must run unconditionally — the outer function may have no bindings/promotions
  # but still contain BG blocks that return frame-allocated values.
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def annotate_bg_exits_in_body!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      AST.each_bg_block_in_stmt(stmt) { |bg| annotate_bg_exit_promote!(bg) if bg.is_a?(AST::BgBlock) }
      # Recurse into control-flow branches.
      case stmt
      when AST::IfStatement
        annotate_bg_exits_in_body!(stmt.then_branch)
        annotate_bg_exits_in_body!(stmt.else_branch)
      when AST::WhileLoop
        annotate_bg_exits_in_body!(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        annotate_bg_exits_in_body!(stmt.body)
      when AST::MatchStatement
        stmt.cases.each { |c| annotate_bg_exits_in_body!(c.body) }
        annotate_bg_exits_in_body!(stmt.default_case)
      when AST::WithBlock
        annotate_bg_exits_in_body!(stmt.body)
      when AST::DoBlock
        stmt.branches.each { |b| annotate_bg_exits_in_body!(b[:body]) }
      end
    end
  end

  sig { params(bg_node: AST::BgBlock).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def annotate_bg_exit_promote!(bg_node)
    body = bg_node.body
    return unless body.is_a?(Array)

    # Walk backward past MIR marker nodes to find the last real expression.
    last_expr = T.let(nil, T.untyped)
    body.reverse_each do |stmt|
      next if stmt.is_a?(MIR::Alloc) || stmt.is_a?(MIR::Drop) ||
              stmt.is_a?(MIR::SuppressCleanup) || stmt.is_a?(MIR::Return) ||
              stmt.is_a?(MIR::AllocMark) ||
              stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::MoveMark)
      last_expr = stmt.is_a?(AST::ThenChain) ? stmt.steps.last&.dig(:expr) : stmt
      break
    end

    return unless last_expr
    return if last_expr.is_a?(AST::Assignment)

    t = last_expr.full_type
    return if t.void?

    bg_node.exit_promote = { strategy: :string_dupe } if bg_exit_needs_string_dupe?(last_expr, t)
  end

  # Returns true when a BG block's last expression is a frame-allocated string
  # that will be invalidated when the fiber's frame is rewound on exit.
  # - rodata strings (literals) live in the binary — safe without dupe.
  # - heap strings are already owned by the caller — no dupe needed.
  # - frame strings (from allocating stdlib calls or frame-provenance types) must be duped.
  sig { params(expr: T.untyped, t: Type).returns(T::Boolean) }
  def bg_exit_needs_string_dupe?(expr, t)
    return false unless t.string?
    return false if t.heap? || t.rodata?
    return true  if t.frame?
    # No explicit provenance: check the stdlib def for frame allocation.
    msd = expr.matched_stdlib_def
    !!(msd && msd.emit&.return_alloc == :frame)
  end

  # Annotate YieldExpr nodes inside a BgStreamBlock that yield frame-allocated strings.
  # Sets yield_node.yield_dupe = true; the lowerer then wraps the push arg in a heap dupe.
  sig { params(stream_node: AST::BgStreamBlock).returns(T.nilable(T::Array[T.untyped])) }
  def annotate_yield_string_dupes!(stream_node)
    walk_stream_yields(stream_node.body)
  end

  sig { params(stmts: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def walk_stream_yields(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::YieldExpr)
        t = stmt.expr.full_type
        stmt.yield_dupe = true if bg_exit_needs_string_dupe?(stmt.expr, t)
      else
        case stmt
        when AST::WhileLoop    then walk_stream_yields(stmt.do_branch)
        when AST::ForRange, AST::ForEach then walk_stream_yields(stmt.body)
        when AST::IfStatement
          walk_stream_yields(stmt.then_branch)
          walk_stream_yields(stmt.else_branch)
        when AST::BgStreamBlock  # stop at nested stream boundaries
        end
      end
    end
  end

  # Annotate BG-captured string locals for in-fiber dupe (bg_string strategy).
  # Lists are heap-upgraded at declaration by EscapeGraph (Phase 1.5b); if a
  # frame list reaches BG capture, that is an EscapeGraph gap, surfaced loudly.
  sig { params(result: T::Array[T.untyped], stmt: T.untyped).void }
  def insert_bg_escape_promote!(result, stmt)
    AST.each_bg_block_in_stmt(stmt) do |bg|
      captured = bg.capture_analysis&.captures
      next unless captured&.any?
      captured.each do |name, type_obj|
        t = type_obj ? Type.new(type_obj) : nil
        next unless t && t.needs_escape_promotion?
        next if t.needs_pointer_passing?
        next if bg.capture_analysis&.capture_symbols&.dig(name)&.is_param
        next if @bg_heap_upgraded&.include?(name)
        if t.list_collection?
          raise "BG-captured frame list '#{name}' reached insert_bg_escape_promote! " \
                "without EscapeGraph heap-upgrading it. Storage must be decided " \
                "at declaration, not via runtime promotion. Extend EscapeGraph " \
                "Phase 1.5b to cover this case."
        end
        # :bg_string: annotate the BgBlock; transpiler emits dupe in-fiber.
        bg.capture_string_dupes ||= Set.new
        bg.capture_string_dupes.add(name)
      end
    end
  end

  # Annotate the ReturnNode when a catch function returns a string type.
  # Both success and error paths must return heap-backed strings for
  # consistent caller cleanup. Annotation on the node replaces the old
  # MIR::Promote(:catch_string_dupe) pending-flag mechanism.
  sig { params(result: T::Array[T.untyped], ret_node: AST::ReturnNode).returns(T.nilable(T::Boolean)) }
  def insert_catch_string_dupe!(result, ret_node)
    return unless ret_node.value
    return unless ret_node.value.full_type.string?
    ret_node.catch_string_dupe_ret = true
  end

  # Annotate an OrRescue node where the success path is heap-promoted and the
  # fallback is a struct literal. Sets or_fallback_dupe on the BinaryOp so the
  # transpiler heap-dupes string fields in the fallback to match cleanup semantics.
  sig { params(result: T::Array[T.untyped], stmt: T.untyped).void }
  def insert_or_fallback_dupe!(result, stmt)
    or_node = find_or_rescue_in_value(stmt)
    return unless or_node
    return unless or_node.right.is_a?(AST::StructLit)
    return unless or_rescue_needs_fallback_dupe?(or_node)
    # Annotate directly on BinaryOp node (no MIR::Promote needed)
    or_node.or_fallback_dupe = true
  end

  # Walk into a statement's value expression to find an OrRescue node.
  sig { params(stmt: T.untyped).returns(T.nilable(AST::BinaryOp)) }
  def find_or_rescue_in_value(stmt)
    expr = case stmt
           when AST::VarDecl, AST::BindExpr then stmt.value
           when AST::Assignment then stmt.value
           when AST::ReturnNode then stmt.value
           else nil
           end
    find_or_rescue_expr(expr)
  end

  sig { params(expr: T.untyped).returns(T.nilable(AST::BinaryOp)) }
  def find_or_rescue_expr(expr)
    return nil unless expr
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      return expr
    end
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR
      return find_or_rescue_expr(expr.left)
    end
    nil
  end

  # Check if an OrRescue's success path is heap-promoted (same logic as
  # the transpiler's has_heap_promoted_call? but at MIR insertion time).
  sig { params(or_node: AST::BinaryOp).returns(T::Boolean) }
  def or_rescue_needs_fallback_dupe?(or_node)
    return false unless or_node.is_a?(AST::BinaryOp) && or_node.op == :OR_RESCUE
    left = or_node.left
    return true if left.is_a?(AST::Locatable) && left.heap_provenance?
    if left.is_a?(AST::BinaryOp) && (left.op == :OR || left.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(left)
    end
    false
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  def or_rescue_needs_fallback_dupe_left?(expr)
    return false unless expr
    return true if expr.is_a?(AST::Locatable) && expr.heap_provenance?
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(expr.left)
    end
    false
  end

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
          when AST::Assignment
            # Map indexed assignments (map[k] = val) apply dupeUnionValue before
            # calling put, so the map stores a deep copy. The original value is NOT
            # consumed -- its cleanup defer must fire normally.
            lhs = stmt.name
            if lhs.is_a?(AST::GetIndex)
              lhs.target.full_type.map? ? nil : stmt.value
            else
              stmt.value
            end
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
    when AST::MoveNode
      if node.value.is_a?(AST::Identifier)
        add_if_consumed(node.value, names, bindings, node.value.was_moved == true)
      else
        walk_consumed(node.value, names, bindings)
      end
    when AST::FuncCall, AST::MethodCall
      node.args.each do |a|
        if a.is_a?(AST::Identifier) && a.was_moved
          add_if_consumed(a, names, bindings, true)
        else
          walk_consumed(a, names, bindings)
        end
      end
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

  # Add identifier to consumed set if it has a moved guard and passes
  # Copy-type filters. RC types only consume on explicit GIVE (MoveNode).
  sig { params(ident: AST::Identifier, names: T::Set[String], bindings: T::Hash[String, CleanupEntry], is_move: T::Boolean).returns(T.nilable(T::Set[String])) }
  def add_if_consumed(ident, names, bindings, is_move)
    name = ident.name.to_s
    entry = bindings[name]
    return unless entry && entry.has_moved_guard? && entry.needs_cleanup?

    ti = ident.full_type

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

  # Stamp reassign_cleanup on BindExpr :assign nodes that overwrite non-Copy variables.
  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_reassign_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::BindExpr) && stmt.mode == :assign

    entry = bindings[stmt.name.to_s]
    return unless entry && entry.needs_cleanup? && entry.kind != :resource

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
    return unless stmt.expr.is_a?(AST::Identifier) && stmt.expr.was_moved

    src_entry = bindings[stmt.expr.name.to_s]
    has_as_cleanup = T.let(false, T::Boolean)

    stmt.cases.each do |c|
      next unless c.binding
      as_entry = bindings[c.binding.to_s]
      next unless as_entry && as_entry.needs_cleanup?

      has_as_cleanup = true

      # Insert MIR nodes at the start of case body for checker coverage.
      # Order: source suppression, then AS binding Alloc + Drop.
      mir_prefix = []
      if src_entry && src_entry.needs_cleanup?
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
    src_entry[:has_moved_guard] = true if has_as_cleanup && src_entry && src_entry.needs_cleanup?
  end

  sig { params(stmt: T.untyped, bindings: T::Hash[String, CleanupEntry]).void }
  def stamp_while_bind_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::WhileBindLoop)
    entry = bindings[stmt.binding_name.to_s]
    return unless entry && entry.needs_cleanup?
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
      entry = bindings[b.name.to_s]
      next unless entry && entry.needs_cleanup?
      mir_prefix << MIR::Alloc.new(stmt.token, b.name.to_s, entry.alloc)
      drop = MIR::Drop.new(stmt.token, b.name.to_s)
      drop.cleanup_entry = entry
      mir_prefix << drop
    end
    stmt.then_branch = mir_prefix + (stmt.then_branch || []) unless mir_prefix.empty?
  end

  # Insert MIR::Promote before indexed Assignment nodes where the container's
  # INDEX_OPS :set has takes_value and the value type needs frame-to-heap
  # promotion. Driven by the INDEX_OPS registry in std_lib.rb.
  sig { params(result: T::Array[T.untyped], stmt: T.untyped).void }
  def insert_container_promote!(result, stmt)
    return unless stmt.is_a?(AST::Assignment)
    return unless stmt.name.is_a?(AST::GetIndex)
    target_node = stmt.name.target

    # Look up the INDEX_OPS :set entry for this container type.
    target_ti = target_node.full_type
    set_op = resolve_container_set_op(target_ti)
    return unless set_op && set_op[:takes_value]

    # Check if the value type needs frame-to-heap promotion.
    # Strings are handled by the :dupe_string_literal transform in the lowerer;
    # :container_promote only fires for !string? values.
    val_ti = stmt.value.full_type
    return unless val_ti.needs_promotion?(@schema_lookup) && !val_ti.string?

    # AST-level per-field rewrite: for a StructLit/UnionVariantLit value
    # being stored in a heap container, wrap every frame-storage heap-
    # owning field in an AST::CopyNode(:heap). The existing CopyNode
    # lowering deep-copies each wrapped field to heap at construction
    # time, so the StructLit is built with all-heap fields.
    if stmt.value.is_a?(AST::StructLit) || stmt.value.is_a?(AST::UnionVariantLit)
      rewrite_frame_fields_to_copy_heap!(stmt.value)
    end
    # Non-literal values (Identifier, GetIndex etc.) flowing into a
    # heap container are handled by :dupe_borrowed_union (for unions)
    # or by the source binding's storage being already heap. The old
    # :container_promote annotation that emitted a post-construct
    # promote() blk is no longer needed: zero generated blk_prm sites
    # remain after the AST-level rewrite.
  end

  # Walk a StructLit/UnionVariantLit and wrap every frame-storage heap-
  # owning field value in AST::CopyNode(:heap). After this rewrite, the
  # existing field-level CopyNode lowering deep-copies each wrapped
  # field to heap; the StructLit is constructed with all-heap fields,
  # making a post-construct promote() unnecessary.
  sig { params(lit: T.untyped).void }
  def rewrite_frame_fields_to_copy_heap!(lit)
    return unless lit.fields
    lit.fields.each do |fname, fv|
      next if fv.is_a?(AST::CopyNode)              # already an explicit COPY
      next if fv.is_a?(AST::MoveNode)              # explicit move; trust caller
      next if fv.is_a?(AST::CloneNode)             # Rc clone
      next unless fv.respond_to?(:full_type)
      fti = fv.full_type
      fti = Type.new(fti) if fti && !fti.is_a?(Type)
      next unless fti.is_a?(Type)
      next unless fti.needs_promotion?(@schema_lookup) && !fti.string?
      # Skip if the field source is already heap (Identifier with
      # heap_provenance symbol, heap-returning call, or all-heap
      # nested StructLit). Those don't need re-dupe.
      next if field_value_already_heap?(fv)
      # Wrap in CopyNode(:heap). Lowering's CopyNode-of-collection /
      # CopyNode-of-struct path will deep-copy with heapAlloc.
      copy = AST::CopyNode.new(fv.token, fv)
      copy.full_type = fti
      copy.storage = :heap
      copy.alloc = :heap
      lit.fields[fname] = copy
    end
  end

  # True when this field's source already owns heap (no re-dupe needed).
  sig { params(fv: T.untyped).returns(T::Boolean) }
  def field_value_already_heap?(fv)
    case fv
    when AST::CopyNode
      fv.alloc == :heap
    when AST::Identifier
      !!fv.symbol&.heap_provenance?
    when AST::FuncCall, AST::MethodCall
      !!fv.heap_provenance? if fv.respond_to?(:heap_provenance?)
    when AST::StructLit, AST::UnionVariantLit
      return false unless fv.fields
      fv.fields.all? { |_, sub| field_value_already_heap?(sub) }
    else
      false
    end
  end

  # Resolve the INDEX_OPS :set entry for a container type.
  sig { params(type_info: T.nilable(T.any(FalseClass, Type))).returns(T.nilable(T::Hash[Symbol, T::Array[Symbol]])) }
  def resolve_container_set_op(type_info)
    return nil unless type_info
    kind = container_kind(type_info)
    return nil unless kind
    INDEX_OPS.dig(kind, :set)
  end

  # Map a type to its INDEX_OPS container kind symbol.
  sig { params(type_info: Type).returns(T.nilable(Symbol)) }
  def container_kind(type_info)
    type_info.dispatch_key
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

  # Insert MIR::Promote before a return statement and annotate the
  # ReturnNode for struct-level promotion wrapping.
  #
  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  sig { params(result: T::Array[T.untyped], ret_node: AST::ReturnNode, bindings: T::Hash[String, CleanupEntry], fn_node: T.nilable(AST::FunctionDef)).returns(T.nilable(T::Array[String])) }
  def insert_return!(result, ret_node, bindings, fn_node: nil)
    escaped = collect_return_escapes(ret_node, bindings, fn_node: fn_node)
    return if escaped.empty?
    result << MIR::Return.new(ret_node.token, escaped)
    # Insert SuppressCleanup for each escaped var so the transpiler doesn't
    # need to re-compute escape analysis.
    escaped.each do |name|
      result << MIR::SuppressCleanup.new(ret_node.token, name)
    end
  end

  # Walk a return expression and collect variable names whose ownership
  # transfers to the caller. Mirrors transpiler's collect_escaping_identifiers
  # but filters to bindings with has_moved_guard (those needing suppression).
  sig { params(ret_node: AST::ReturnNode, bindings: T::Hash[String, CleanupEntry], fn_node: T.nilable(AST::FunctionDef)).returns(T::Array[String]) }
  def collect_return_escapes(ret_node, bindings, fn_node: nil)
    return [] unless ret_node.value
    ids = collect_escaping_ids(ret_node.value)
    ids.map { |id| id.name.to_s }
       .select { |n| bindings[n]&.dig(:has_moved_guard) && bindings[n]&.dig(:needs_cleanup) }
       .uniq
  end

  sig { params(node: T.untyped).returns(T::Array[T.untyped]) }
  def collect_escaping_ids(node)
    return [] unless node
    case node
    when AST::Identifier then [node]
    when AST::MoveNode   then collect_escaping_ids(node.value)
    when AST::StructLit  then node.fields.values.flat_map { |v| collect_escaping_ids(v) }
    when AST::FuncCall, AST::MethodCall
      node.args.select(&:was_moved).flat_map { |a| collect_escaping_ids(a) }
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode then []
    else []
    end
  end

end
