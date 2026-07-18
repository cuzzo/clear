# typed: strict
# Dead-simple escape placement plus caller sync propagation.
#
# Escape placement is intentionally AST-bound: each escape mechanism is a
# local node predicate and the only output is SymbolEntry#storage = :heap.

require "sorbet-runtime"
require "set"

require_relative "../ast/type"
require_relative "../ast/ast"
require_relative "../ast/symbol_entry"
require_relative "../annotator/phases/body_analysis"
require_relative "../annotator/helpers/capabilities"
require_relative "../annotator/helpers/function_signature"
require_relative "local_binding_facts"
require_relative "ownership_identity"

module EscapeAnalysis
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  BodySummaries = T.type_alias { T::Hash[String, Annotator::Phases::FunctionBodySummary] }
  HoistBindings = T.type_alias { T::Hash[String, T::Array[AST::VarDecl]] }
  CallSitesByCallee = T.type_alias { T::Hash[String, T::Array[Semantic::CallSiteFact]] }
  HeapResult = T.type_alias { [T::Set[String], T::Set[String]] }
  LambdaIdentifierRefs = T.type_alias { Annotator::Phases::LambdaIdentifierRefs }
  EscapeHandlerRegistry = T.type_alias { T::Hash[Symbol, T::Array[Symbol]] }
  BindingNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr, AST::DestructureTarget) }
  AssignmentNode = T.type_alias { T.any(AST::Assignment, AST::BindExpr, AST::DestructuringAssignment) }
  AssignmentTarget = T.type_alias { T.any(String, Symbol, AST::Node) }
  NodeClass = T.type_alias { T::Module[T.anything] }
  NodeValue = T.type_alias { T.nilable(AST::Node) }
  NodeStack = T.type_alias { T::Array[NodeValue] }
  DynamicValue = T.type_alias { T.nilable(T.any(AST::Node, String, Symbol)) }

  class EscapePlacementFact < T::Struct
    extend T::Sig

    const :fn_name, String
    const :binding, OwnershipIdentity::BindingId
    const :reason, Symbol

    sig { returns(String) }
    def symbol_name
      binding.name
    end

    sig { returns(Integer) }
    def binding_id
      binding.binding_id
    end
  end

  class FunctionFacts < T::Struct
    extend T::Sig

    const :fn, AST::FunctionDef
    const :symbols, T::Hash[String, SymbolEntry]
    const :binding_values, T::Hash[String, T::Array[AST::Locatable]]
    const :return_values, T::Array[AST::Node]
    const :assignment_nodes, T::Array[AssignmentNode]
    const :escape_nodes, T::Array[AST::Locatable]
    const :lambda_body_identifier_refs, LambdaIdentifierRefs, default: {}

    sig { returns(Integer) }
    def heap_symbol_count
      heap_symbol_ids.length
    end

    sig { returns(T::Hash[String, SymbolEntry]) }
    def heap_symbols
      out = T.let({}, T::Hash[String, SymbolEntry])
      fn.params.each do |param|
        sym = param.symbol
        out[param.name.to_s] = sym if EscapeAnalysis.symbol_heap?(sym) && sym
      end
      symbols.each do |name, sym|
        out[name] = sym if EscapeAnalysis.symbol_heap?(sym)
      end
      out
    end

    sig { returns(T::Set[Integer]) }
    def heap_symbol_ids
      heap_symbols.each_value.map(&:binding_id).to_set
    end
  end

  class EscapePlacementFacts < T::Struct
    extend T::Sig

    prop :placements, T::Array[EscapePlacementFact], factory: -> { [] }

    sig { params(facts: FunctionFacts, before_heap_ids: T::Set[Integer], reason: Symbol).void }
    def record_new_heap_symbols!(facts, before_heap_ids, reason)
      facts.heap_symbols.each do |name, sym|
        next if before_heap_ids.include?(sym.binding_id)

        placements << EscapePlacementFact.new(
          fn_name: facts.fn.name.to_s,
          binding: OwnershipIdentity::BindingId.from_symbol(name, sym),
          reason: reason
        )
      end
    end

    sig { returns(T::Set[String]) }
    def heap_function_names
      placements.map(&:fn_name).to_set
    end
  end

  class Result < T::Struct
    const :heap_fns, T::Set[String]
    const :bg_heap, T::Set[String]
    const :placements, EscapePlacementFacts
  end

  class EscapeContext < T::Struct
    const :fn, AST::FunctionDef
    const :facts, T.nilable(FunctionFacts)
    const :fn_nodes, FnNodes
    const :facts_by_name, T::Hash[String, FunctionFacts]
    const :bg_heap, T::Set[String]
    const :schema_lookup, T.nilable(Proc)
  end

  class EscapeSink < T::Struct
    extend T::Sig

    const :name, Symbol
    const :node_classes, T::Array[NodeClass]
    const :handler, Symbol

    sig { params(node: BasicObject).returns(T::Boolean) }
    def matches?(node)
      node_classes.any? { |klass| T.unsafe(node).is_a?(klass) }
    end
  end

  ESCAPE_SINK_HANDLERS = T.let({
    owning_return: [:mark_heap_return_facts!, :mark_body_escapes!].freeze,
    enclosing_scope_store: [:mark_body_escapes!].freeze,
    binding_result: [:mark_body_escapes!].freeze,
    execution_boundary_capture: [:mark_body_escapes!].freeze,
    lambda_capture: [:mark_body_escapes!].freeze,
    takes_or_mutable_arg: [:mark_body_escapes!].freeze,
    receiver_backing_storage: [
      :mark_param_receiver_allocations_heap!,
      :mark_loop_receiver_allocations_heap!,
    ].freeze,
  }.freeze, EscapeHandlerRegistry)

  DERIVED_PLACEMENT_HANDLERS = T.let({
    recursive_aggregate_owner: [:mark_recursive_aggregate_owners_heap!].freeze,
    assignment_ownership: [:propagate_assignment_ownership!].freeze,
    hoist_dependency: [:propagate_hoist_dependencies!].freeze,
  }.freeze, EscapeHandlerRegistry)

  ESCAPE_SINKS = T.let([
    EscapeSink.new(name: :owning_return, node_classes: [AST::ReturnNode], handler: :apply_return_escape_sink!),
    EscapeSink.new(name: :enclosing_scope_store, node_classes: [AST::Assignment], handler: :apply_assignment_escape_sink!),
    EscapeSink.new(name: :binding_result, node_classes: [AST::VarDecl, AST::BindExpr], handler: :apply_binding_escape_sink!),
    EscapeSink.new(name: :execution_boundary_capture, node_classes: [AST::BgBlock, AST::BgStreamBlock], handler: :apply_execution_boundary_escape_sink!),
    EscapeSink.new(name: :lambda_capture, node_classes: [AST::LambdaLit], handler: :apply_lambda_escape_sink!),
    EscapeSink.new(name: :takes_or_mutable_arg, node_classes: [AST::FuncCall], handler: :apply_func_call_escape_sink!),
    EscapeSink.new(name: :takes_or_mutable_arg, node_classes: [AST::MethodCall], handler: :apply_method_call_escape_sink!),
  ].freeze, T::Array[EscapeSink])

  sig { params(fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(HeapResult) }
  def self.apply!(fn_nodes, schema_lookup = nil)
    result = apply_with_facts!(fn_nodes, schema_lookup)
    [result.heap_fns, result.bg_heap]
  end

  sig { params(fn_nodes: FnNodes, schema_lookup: T.nilable(Proc), body_summaries: BodySummaries, hoist_bindings: T.nilable(HoistBindings)).returns(Result) }
  def self.apply_with_facts!(fn_nodes, schema_lookup = nil, body_summaries = {}, hoist_bindings = nil)
    bg_heap = T.let(Set.new, T::Set[String])
    placements = EscapePlacementFacts.new
    facts_by_name = T.let({}, T::Hash[String, FunctionFacts])

    fn_nodes.each do |name, fn|
      facts_by_name[name] = function_facts(fn, body_summaries[name], hoist_bindings&.[](name) || []) if fn.body
    end

    facts_by_name.each_value do |facts|
      record_placement_phase!(placements, facts, :owning_return) do
        mark_heap_return_facts!(facts, schema_lookup)
      end
    end

    facts_by_name.each_value do |facts|
      record_placement_phase!(placements, facts, :receiver_backing_storage) do
        mark_param_receiver_allocations_heap!(facts.escape_nodes)
      end
      record_placement_phase!(placements, facts, :recursive_aggregate_owner) do
        mark_recursive_aggregate_owners_heap!(facts, schema_lookup)
      end
    end

    facts_by_name.each_value do |facts|
      body = facts.fn.body
      record_placement_phase!(placements, facts, :escape_sink) do
        mark_body_escapes!(facts, fn_nodes, facts_by_name, bg_heap, schema_lookup)
      end
      record_placement_phase!(placements, facts, :loop_receiver_backing_storage) do
        mark_loop_receiver_allocations_heap!(body)
      end
      record_placement_phase!(placements, facts, :assignment_ownership) do
        propagate_assignment_ownership!(facts, fn_nodes, facts_by_name, schema_lookup)
      end
      record_placement_phase!(placements, facts, :hoist_dependency) do
        propagate_hoist_dependencies!(facts)
      end
    end

    Result.new(heap_fns: placements.heap_function_names, bg_heap: bg_heap, placements: placements)
  end

  sig { params(placements: EscapePlacementFacts, facts: FunctionFacts, reason: Symbol, blk: T.proc.void).void }
  def self.record_placement_phase!(placements, facts, reason, &blk)
    before = facts.heap_symbol_ids
    blk.call
    placements.record_new_heap_symbols!(facts, before, reason)
  end
  private_class_method :record_placement_phase!

  sig { void }
  def self.validate_escape_sink_handlers!
    validate_handler_registry!("EscapeAnalysis sink registry", ESCAPE_SINK_HANDLERS)
  end

  sig { void }
  def self.validate_escape_sinks!
    missing = T.let([], T::Array[String])
    ESCAPE_SINKS.each do |sink|
      missing << sink.name.to_s unless ESCAPE_SINK_HANDLERS.key?(sink.name)
      missing << sink.handler.to_s unless respond_to?(sink.handler, true)
    end
    return if missing.empty?

    raise "EscapeAnalysis executable sink registry is incomplete: #{missing.sort.join(", ")}"
  end

  sig { void }
  def self.validate_derived_placement_handlers!
    validate_handler_registry!("EscapeAnalysis derived placement registry", DERIVED_PLACEMENT_HANDLERS)
  end

  sig { params(label: String, registry: EscapeHandlerRegistry).void }
  def self.validate_handler_registry!(label, registry)
    missing = T.let([], T::Array[String])
    registry.each do |sink, handlers|
      handlers.each do |handler|
        missing << "#{sink}=#{handler}" unless respond_to?(handler, true)
      end
    end
    return if missing.empty?

    raise "#{label} is incomplete: #{missing.sort.join(", ")}"
  end


  # E3c: Propagate caller arg sync (and Arc-storage) into callee param
  # SymbolEntry. Two axes flow with the same all-callers-agree rule:
  #   - sync     (:locked / :write_locked / :always_mutable)
  #   - storage  (:shared / :multiowned for Arc/Rc-wrapped bindings)
  # The storage axis is what mir_lowering needs to emit Arc unwrap
  # (`x.ctrl.data.*` vs `x`) at WITH/field-access sites. Sync drives the
  # acquire/release method choice. Runs to fixed point so transitive calls
  # also pick up both axes.
  #
  # Rule: a param with no caller-derived value (and no explicit declared
  # value) adopts a caller's value iff every observed caller passes the
  # same non-nil value. Disagreement leaves the param at its current
  # value. Params with declared sync (legacy) are not overwritten.
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  # @param body_summaries [Hash] name -> annotated function body facts
  sig { params(fn_nodes: FnNodes, body_summaries: BodySummaries).void }
  def self.propagate_caller_sync!(fn_nodes, body_summaries)
    # Index annotated call sites by callee name. These facts are collected once
    # during body analysis and keyed by stable CallSiteId.
    callsites = T.let({}, CallSitesByCallee)
    body_summaries.each_value do |summary|
      summary.call_site_facts.each do |call_site|
        next if call_site.fn_var_call
        (callsites[call_site.callee_name] ||= []) << call_site
      end
    end

    fn_nodes.length.times do
      changed = T.let(false, T::Boolean)
      fn_nodes.each do |callee_name, callee_fn|
        sites = callsites.fetch(callee_name, [])

        callee_fn.params.each_with_index do |param, idx|
          entry = param.symbol
          next unless entry

          # ── sync axis ────────────────────────────────────────────────
          unless param_sync_was_declared?(param)
            unified = unify_caller_attr(sites, idx) do |s|
              next s.sync if s.sync
              t = s.type
              t.sync
            end
            if unified && entry.sync != unified && param_accepts_caller_sync?(callee_fn, param, unified)
              entry.sync = unified
              changed = true
            end
          end

          # ── storage axis (Arc / Rc) ──────────────────────────────────
          # We're trying to detect "this binding is Arc/Rc-wrapped" so
          # the callee's lowering knows to emit `x.ctrl.data.*` unwrap.
          # For struct types, that fact lives on entry.storage (:shared /
          # :multiowned). For collection types, finalize_storage maps
          # @shared:locked + collection to :heap, so the wrapping fact
          # lives on entry.type.ownership instead. Check both axes.
          unified_storage = unify_caller_attr(sites, idx) do |s|
            next s.storage if s.rc_stored?
            t = s.type
            next :shared     if t.shared?
            next :multiowned if t.multiowned?
            nil
          end
          if unified_storage && entry.storage != unified_storage
            entry.storage = unified_storage
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # Most-general unifier: returns the single non-nil value when every
  # callsite's arg projects to the same value, else nil.
  sig { params(sites: T::Array[Semantic::CallSiteFact], idx: Integer, project: T.proc.params(entry: SymbolEntry).returns(T.nilable(Symbol))).returns(T.nilable(Symbol)) }
  private_class_method def self.unify_caller_attr(sites, idx, &project)
    observed = sites.map do |site|
      arg = site.args[idx]
      next nil unless arg && arg.respond_to?(:symbol)
      symbol = T.unsafe(arg).symbol
      next nil unless symbol.is_a?(SymbolEntry)

      project.call(symbol)
    end
    return nil if observed.empty?
    unique = observed.uniq
    (unique.length == 1 && unique.first) ? unique.first : nil
  end

  # True when the param's declared type carried explicit sync (so the
  # entry.sync currently reflects an annotation, not a propagated value).
  sig { params(param: AST::Param).returns(T.nilable(T::Boolean)) }
  private_class_method def self.param_sync_was_declared?(param)
    t = param.type
    t.is_a?(Type) && t.any_sync?
  end

  sig { params(fn_node: AST::FunctionDef, param: AST::Param, sync: Symbol).returns(T::Boolean) }
  private_class_method def self.param_accepts_caller_sync?(fn_node, param, sync)
    t = param.type
    return true if t.is_a?(Type) && (t.shared? || t.any_sync?)
    # Sync axes other than :atomic were already accepted above (via shared?
    # / any_sync?) -- only :atomic needs the REQUIRES family check.
    return true unless SymbolEntry.atomic_sync?(sync)

    requires = fn_node.respond_to?(:requires) ? fn_node.requires : nil
    families = requires && requires[param.name.to_s]
    return false unless families.respond_to?(:include?)
    families.include?(:ATOMIC) || families.include?(:SNAPSHOTTED)
  end

  sig { params(facts: FunctionFacts, fn_nodes: FnNodes, facts_by_name: T::Hash[String, FunctionFacts], bg_heap: T::Set[String], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_body_escapes!(facts, fn_nodes, facts_by_name, bg_heap, schema_lookup)
    context = EscapeContext.new(fn: facts.fn, facts: facts, fn_nodes: fn_nodes, facts_by_name: facts_by_name, bg_heap: bg_heap, schema_lookup: schema_lookup)
    facts.escape_nodes.each do |node|
      ESCAPE_SINKS.each { |sink| apply_escape_sink!(sink, node, context) if sink.matches?(node) }
    end
  end

  sig { params(sink: EscapeSink, node: AST::Locatable, context: EscapeContext).void }
  private_class_method def self.apply_escape_sink!(sink, node, context)
    case sink.handler
    when :apply_return_escape_sink! then apply_return_escape_sink!(T.cast(node, AST::ReturnNode), context)
    when :apply_assignment_escape_sink! then apply_assignment_escape_sink!(T.cast(node, AST::Assignment), context)
    when :apply_binding_escape_sink! then apply_binding_escape_sink!(T.cast(node, T.any(AST::VarDecl, AST::BindExpr)), context)
    when :apply_execution_boundary_escape_sink! then apply_execution_boundary_escape_sink!(T.cast(node, T.any(AST::BgBlock, AST::BgStreamBlock)), context)
    when :apply_lambda_escape_sink! then apply_lambda_escape_sink!(T.cast(node, AST::LambdaLit), context)
    when :apply_func_call_escape_sink! then apply_func_call_escape_sink!(T.cast(node, AST::FuncCall), context)
    when :apply_method_call_escape_sink! then apply_method_call_escape_sink!(T.cast(node, AST::MethodCall), context)
    else Kernel.raise "BUG: unknown escape sink #{sink.handler}"
    end
    nil
  end

  sig { params(node: AST::ReturnNode, context: EscapeContext).void }
  private_class_method def self.apply_return_escape_sink!(node, context)
    value = node.value
    return unless value
    return unless owning_return_needs_heap_placement?(context.fn, value, context.schema_lookup)

    mark_expr_identifiers_heap!(value) unless returned_call_result?(value)
    mark_heap_return!(T.must(context.facts), value) if context.facts
  end

  sig { params(node: AST::Assignment, context: EscapeContext).void }
  private_class_method def self.apply_assignment_escape_sink!(node, context)
    facts = context.facts
    return unless facts

    target = T.cast(node.name, AssignmentTarget)
    mark_expr_identifiers_heap!(node.value) if assignment_target_heap_destination?(facts, target, context.schema_lookup)
  end

  sig { params(node: T.any(AST::VarDecl, AST::BindExpr), context: EscapeContext).void }
  private_class_method def self.apply_binding_escape_sink!(node, context)
    if borrow_return_expr?(node.value)
      mark_symbol_borrow!(node.symbol)
    elsif call_result_is_heap?(node.value, context.fn_nodes, context.schema_lookup, facts_by_name: context.facts_by_name)
      mark_symbol_heap!(node.symbol)
    end
  end

  sig { params(node: T.any(AST::BgBlock, AST::BgStreamBlock), context: EscapeContext).void }
  private_class_method def self.apply_execution_boundary_escape_sink!(node, context)
    mark_capture_analysis_heap!(node.capture_analysis, context.bg_heap)
    mark_fsm_ctx_locals_heap!(node, context.schema_lookup) if node.is_a?(AST::BgBlock)
  end

  sig { params(node: AST::LambdaLit, context: EscapeContext).void }
  private_class_method def self.apply_lambda_escape_sink!(node, context)
    mark_lambda_captures_heap!(node, context.bg_heap, context.facts)
  end

  sig { params(node: AST::FuncCall, context: EscapeContext).void }
  private_class_method def self.apply_func_call_escape_sink!(node, context)
    mark_takes_args_heap!(node.args, params_for_call(node, context.fn_nodes), context.schema_lookup)
  end

  sig { params(node: AST::MethodCall, context: EscapeContext).void }
  private_class_method def self.apply_method_call_escape_sink!(node, context)
    mark_method_takes_heap!(node, params_for_method_call(node), context.fn_nodes, context.facts_by_name, context.schema_lookup)
  end

  sig { params(nodes: T::Array[AST::Locatable]).void }
  private_class_method def self.mark_param_receiver_allocations_heap!(nodes)
    nodes.each do |node|
      case node
      when AST::MethodCall
        sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
        next unless sig
        next unless sig.emits_allocating? && sig.mutates_receiver?
        root = AST.root_identifier(node.object)
      when AST::Assignment
        next unless node.name.is_a?(AST::GetIndex)
        root = AST.root_identifier(node.name)
        ti = root&.symbol&.type
        next unless ti.is_a?(Type) && ti.collection?
      else
        next
      end
      sym = root&.symbol
      next unless sym&.is_param
      mark_symbol_heap!(sym)
    end
  end

  sig { params(facts: FunctionFacts, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_recursive_aggregate_owners_heap!(facts, schema_lookup)
    fn = facts.fn
    fn.params.each do |param|
      next unless aggregate_owner_requires_heap?(Type.new(param.type), schema_lookup)
      mark_symbol_heap!(param.symbol)
    end

    facts.binding_values.each_key do |name|
      sym = facts.symbols[name]
      next unless sym
      reg = sym.reg
      next unless reg.is_a?(AST::Locatable)
      node = reg
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::DestructureTarget) ||
                  (node.is_a?(AST::BindExpr) && node.mode == :decl)
      ti = node.full_type!(context: "recursive aggregate owner")
      next unless aggregate_owner_requires_heap?(ti, schema_lookup)
      mark_symbol_heap!(sym)
    end
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.aggregate_owner_requires_heap?(ti, schema_lookup)
    return false unless ti
    t = ti.value_payload_type
    return false unless t
    return false if t.rodata? || t.borrowed_reference?

    if t.collection_value?
      return t.needs_explicit_cleanup?(:frame, T.unsafe(schema_lookup))
    end

    return false if t.string? || t.heap_ptr?
    t.ownership_bearing?(T.unsafe(schema_lookup))
  rescue StandardError
    false
  end

  sig { params(body: AST::RawBody).void }
  private_class_method def self.mark_loop_receiver_allocations_heap!(body)
    body.each do |stmt|
      AST.child_bodies(stmt).each do |child_body|
        mark_receiver_allocations_in_loop!(child_body) if AST.loop_node?(stmt)
        mark_loop_receiver_allocations_heap!(child_body)
      end
    end
  end

  sig { params(body: AST::RawBody).void }
  private_class_method def self.mark_receiver_allocations_in_loop!(body)
    return unless loop_body_has_frame_allocation_candidate?(body)

    declared_names = loop_body_declared_names(body)
    each_loop_body_node(body) do |node|
      case node
      when AST::MethodCall
        sig = FunctionSignature.unwrap(node.matched_signature)
        next unless sig
        next unless sig.emits_allocating? && sig.mutates_receiver?
        root = AST.root_identifier(node.object)
        value_params = sig.params.drop(1)
      when AST::Assignment
        next unless node.name.is_a?(AST::GetIndex)
        root = AST.root_identifier(node.name)
        ti = root&.symbol&.type
        next unless ti.is_a?(Type) && ti.collection?
        value_params = []
      else
        next
      end
      next unless root&.symbol
      next if declared_names.include?(root.name.to_s)
      mark_symbol_heap!(root.symbol)
      if node.is_a?(AST::MethodCall)
        value_params.each_with_index do |param, idx|
          next unless param.takes || param.mutable
          arg = node.args[idx]
          mark_expr_identifiers_heap!(arg) if arg
        end
      end
    end
  end

  sig { params(body: AST::RawBody, blk: T.proc.params(arg0: AST::Locatable).void).void }
  private_class_method def self.walk_body(body, &blk)
    AST.each_locatable(body, &blk)
  end

  sig { params(expr: NodeValue).void }
  private_class_method def self.mark_expr_roots_heap!(expr)
    unwrapped = unwrap_value(expr)
    root = unwrapped.is_a?(AST::Locatable) ? AST.root_identifier(unwrapped) : nil
    if root
      mark_node_symbol_heap!(root)
      return
    end

    node = unwrapped
    mark_node_symbol_heap!(node) if node.is_a?(AST::Identifier)
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.mark_expr_identifiers_heap!(expr)
    changed = T.let(false, T::Boolean)
    stack = T.let([expr], NodeStack)
    until stack.empty?
      node = stack.pop
      next if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)
      node = unwrap_value(node)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        changed = true if mark_node_symbol_heap!(node)
        next
      end
      root = AST.root_identifier(node)
      if root
        changed = true if mark_node_symbol_heap!(root)
        next
      end
      push_locatable_children!(node, stack)
    end
    changed
  end

  sig { params(node: DynamicValue).returns(DynamicValue) }
  private_class_method def self.unwrap_value(node)
    current = T.let(node, DynamicValue)
    while current.is_a?(AST::Locatable)
      if AST.recovery_wrapper?(current)
        current = AST.recovery_payload(current)
      elsif AST.ownership_wrapper?(current)
        wrapper = T.cast(current, T.any(
          AST::MoveNode,
          AST::CopyNode,
          AST::CloneNode,
          AST::ShareNode,
          AST::FreezeNode,
          AST::CapabilityWrap,
        ))
        current = wrapper.value
      else
        break
      end
    end
    current
  end

  sig { params(node: AST::Locatable, stack: NodeStack).void }
  private_class_method def self.push_locatable_children!(node, stack)
    AST.wrapped_children(node).each { |child| stack << child if child.is_a?(AST::Locatable) }
    node.class.members.each do |member|
      value = node[member]
      if value.is_a?(Array)
        value.each { |child| stack << child if child.is_a?(AST::Locatable) }
      elsif value.is_a?(Hash)
        value.each_value { |child| stack << child if child.is_a?(AST::Locatable) }
      elsif value.is_a?(AST::Locatable)
        stack << value
      end
    end
  end

  sig { params(analysis: T.nilable(CapabilityHelper::CaptureAnalysis), bg_heap: T::Set[String]).void }
  private_class_method def self.mark_capture_analysis_heap!(analysis, bg_heap)
    return unless analysis
    analysis.capture_symbols.each do |name, sym|
      mark_symbol_heap!(sym, bg_heap, name.to_s)
    end
  end

  sig { params(node: AST::BgBlock, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_fsm_ctx_locals_heap!(node, schema_lookup)
    return unless node.spawn_form == :fsm
    walk_body(node.body) do |child|
      next unless child.is_a?(AST::VarDecl) || (child.is_a?(AST::BindExpr) && child.mode == :decl)
      ti = child.full_type!(context: "FSM context local").success_type
      next unless ti&.heap_ptr? || ti&.recursive_cleanup_shape?(T.unsafe(schema_lookup))
      mark_symbol_heap!(child.symbol)
    end
  end

  sig { params(args: T::Array[AST::Node], params: T::Array[AST::Param], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_takes_args_heap!(args, params, schema_lookup)
    params.each_with_index do |param, idx|
      arg = args[idx]
      next unless param.takes || symbol_heap?(param.symbol)
      arg_type = arg.is_a?(AST::Locatable) ? arg.full_type!(context: "TAKES argument") : nil
      next unless ownership_bearing_transfer_expr?(arg, schema_lookup) ||
                  type_requires_owned_storage?(arg_type, schema_lookup)
      mark_expr_roots_heap!(arg)
    end
  end

  sig { params(call: AST::MethodCall, params: T::Array[AST::Param], fn_nodes: FnNodes, facts_by_name: T::Hash[String, FunctionFacts], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_method_takes_heap!(call, params, fn_nodes, facts_by_name, schema_lookup)
    receiver_param = params.first
    if receiver_is_param?(call.object) && symbol_heap?(receiver_param&.symbol)
      mark_expr_roots_heap!(call.object)
    end

    value_params = params.drop(1)
    mark_takes_args_heap!(call.args, value_params, schema_lookup)
    mark_receiver_for_owned_sink!(call.object, call.args, value_params, fn_nodes, facts_by_name, schema_lookup)
    mark_receiver_scope_escapes!(call.object, call.args, value_params)
  end

  sig { params(receiver: AST::Node, args: T::Array[AST::Node], params: T::Array[AST::Param], fn_nodes: FnNodes, facts_by_name: T::Hash[String, FunctionFacts], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_receiver_for_owned_sink!(receiver, args, params, fn_nodes, facts_by_name, schema_lookup)
    receiver_root = AST.root_identifier(receiver)
    receiver_sym = receiver_root&.symbol
    return unless receiver_sym

    params.each_with_index do |param, idx|
      next unless param.takes
      arg = args[idx]
      next unless arg
      next unless ownership_bearing_transfer_expr?(arg, schema_lookup) ||
                  call_result_is_heap?(arg, fn_nodes, schema_lookup, facts_by_name: facts_by_name)
      mark_symbol_heap!(receiver_sym)
      return
    end
  end

  sig { params(body: AST::RawBody).returns(T::Boolean) }
  private_class_method def self.loop_body_has_frame_allocation_candidate?(body)
    found = T.let(false, T::Boolean)
    MIR::LocalBindingAnalysis.each_direct_loop_node(body) do |node|
      next if found
      found = true if loop_binding_frame_allocation_candidate?(node)
    end
    found
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  private_class_method def self.loop_binding_frame_allocation_candidate?(node)
    return false unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return false if node.respond_to?(:symbol) && node.symbol&.heap_storage?

    value = node.respond_to?(:value) ? node.value : nil
    unwrapped = unwrap_value(value)
    return true if unwrapped.is_a?(AST::Locatable) && string_concat_expr?(unwrapped)

    entry = MIR::LocalBindingAnalysis.binding_entry(node)
    return true if entry&.present? && entry.frame?

    ti = node.full_type!(context: "loop receiver heap promotion")
    ti.needs_cleanup? && ti.cleanup_allocator == :frame
  rescue StandardError
    false
  end

  sig { params(body: AST::RawBody).returns(T::Set[String]) }
  private_class_method def self.loop_body_declared_names(body)
    names = T.let(Set.new, T::Set[String])
    each_loop_body_node(body) do |node|
      name = MIR::LocalBindingAnalysis.binding_decl_name(node)
      names << name if name
    end
    names
  end

  sig { params(body: AST::RawBody, block: T.proc.params(arg0: AST::Node).void).void }
  private_class_method def self.each_loop_body_node(body, &block)
    stack = T.let(body.reverse, T::Array[AST::Node])
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      yield node
      next if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit) ||
              node.is_a?(AST::BgBlock) || node.is_a?(AST::BgStreamBlock)

      AST.child_bodies(node).reverse_each do |child_body|
        child_body.reverse_each { |child| stack << child }
      end
    end
    nil
  end

  sig { params(arg: NodeValue, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.ownership_bearing_transfer_expr?(arg, schema_lookup)
    if arg.is_a?(AST::MoveNode)
      return type_requires_owned_storage?(arg.value.full_type!(context: "moved transfer value"), schema_lookup)
    end
    return true if heap_owned_transfer_source?(arg)
    return true if ownership_transferring_expr?(arg, include_allocating_expr: true) &&
                   arg.is_a?(AST::Locatable) &&
                   type_requires_owned_storage?(arg.full_type!(context: "ownership transfer expression"), schema_lookup)
    false
  rescue StandardError
    false
  end

  sig { params(arg: NodeValue).returns(T::Boolean) }
  private_class_method def self.heap_owned_transfer_source?(arg)
    return false if arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode)
    unwrapped = unwrap_value(arg)
    root = unwrapped.is_a?(AST::Locatable) ? AST.root_identifier(unwrapped) : nil
    sym = root&.symbol
    symbol_heap?(sym)
  rescue StandardError
    false
  end

  sig { params(receiver: AST::Node, args: T::Array[AST::Node], params: T::Array[AST::Param]).void }
  private_class_method def self.mark_receiver_scope_escapes!(receiver, args, params)
    receiver_root = AST.root_identifier(receiver)
    receiver_depth = receiver_root&.symbol&.scope_depth
    return unless receiver_depth.is_a?(Integer)

    params.each_with_index do |param, idx|
      next unless param.takes || param.mutable
      arg = args[idx]
      next unless arg
      arg_root = AST.root_identifier(arg)
      arg_depth = arg_root&.symbol&.scope_depth
      next unless arg_depth.is_a?(Integer) && arg_depth > receiver_depth
      mark_expr_identifiers_heap!(arg)
    end
  end

  sig { params(facts: FunctionFacts).void }
  private_class_method def self.propagate_hoist_dependencies!(facts)
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      facts.binding_values.each do |name, values|
        sym = facts.symbols[name]
        next unless symbol_heap?(sym)
        values.each do |value|
          next unless heap_binding_carries_sources?(value)
          changed = true if mark_expr_identifiers_heap!(value)
        end
      end
    end
  end

  sig { params(value: AST::Node).returns(T::Boolean) }
  private_class_method def self.heap_binding_carries_sources?(value)
    node = value
    return false if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)
    node = unwrap_value(node)
    return true if node.is_a?(AST::Identifier)
    return true if node.is_a?(AST::StructLit) || node.is_a?(AST::UnionVariantLit) ||
                   node.is_a?(AST::ListLit) || node.is_a?(AST::HashLit)
    false
  end

  sig { params(facts: FunctionFacts, fn_nodes: FnNodes, facts_by_name: T::Hash[String, FunctionFacts], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.propagate_assignment_ownership!(facts, fn_nodes, facts_by_name, schema_lookup)
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      facts.assignment_nodes.each do |node|
        target = assigned_binding_name(node)
        next unless target
        sym = facts.symbols[target]
        next unless sym
        next unless assignment_value_is_owned?(node, fn_nodes, facts_by_name, schema_lookup)
        changed = true if mark_reassigned_symbol_heap!(sym)
      end
    end
  end

  sig { params(node: AssignmentNode).returns(T.nilable(String)) }
  private_class_method def self.assigned_binding_name(node)
    if node.is_a?(AST::BindExpr) && node.mode == :assign
      return node.name.to_s
    end
    return nil if node.is_a?(AST::DestructuringAssignment)
    return nil unless node.is_a?(AST::Assignment)
    target = unwrap_value(node.name)
    return target.to_s if target.is_a?(String) || target.is_a?(Symbol)
    return target.name.to_s if target.is_a?(AST::Identifier)
    nil
  end

  sig { params(node: AssignmentNode, fn_nodes: FnNodes, facts_by_name: T::Hash[String, FunctionFacts], schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.assignment_value_is_owned?(node, fn_nodes, facts_by_name, schema_lookup)
    return false unless node.respond_to?(:value)
    value = node.value
    return true if ownership_transferring_expr?(value, include_allocating_expr: false)
    unwrapped = unwrap_value(value)
    return false if unwrapped.is_a?(AST::Locatable) && string_concat_expr?(unwrapped)
    return true if expr_has_owned_inline_value?(value)
    call_result_is_heap?(value, fn_nodes, schema_lookup, facts_by_name: facts_by_name)
  end

  sig { params(expr: NodeValue, include_allocating_expr: T::Boolean).returns(T::Boolean) }
  private_class_method def self.ownership_transferring_expr?(expr, include_allocating_expr:)
    value = unwrap_value(expr)
    value = unwrap_value(value.left) if value.is_a?(AST::BinaryOp) && value.op == :OR_ELSE
    return true if value.is_a?(AST::CopyNode) || value.is_a?(AST::CloneNode)
    return true if value.is_a?(AST::Locatable) && expr_has_heap_identifier?(value)
    return true if include_allocating_expr && value.is_a?(AST::Locatable) && string_concat_expr?(value)
    return true if T.unsafe(value).respond_to?(:heap_storage?) && T.unsafe(value).heap_storage?
    return true if T.unsafe(value).respond_to?(:symbol) && T.unsafe(value).symbol&.heap_storage?
    return false unless value.is_a?(AST::Locatable)
    ti = value.full_type!(context: "ownership transferring expression")
    !!(!ti.string? && !ti.rodata? && ti.provenance != :borrow && ti.heap_ptr?)
  rescue StandardError
    false
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.string_concat_expr?(expr)
    expr.is_a?(AST::StringConcat) ||
      (expr.is_a?(AST::BinaryOp) && expr.string_concat == true)
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.type_requires_owned_storage?(ti, schema_lookup)
    return false unless ti
    t = ti.value_payload_type
    return false unless t
    return false if t.rodata? || t.borrowed_reference?
    t.ownership_bearing?(T.unsafe(schema_lookup))
  rescue StandardError
    false
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.borrow_return_expr?(expr)
    call = unwrap_value(expr)
    return false unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    !!sig && !sig.return_lifetime.empty?
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.expr_has_heap_identifier?(expr)
    found = T.let(false, T::Boolean)
    AST.each_locatable(expr) do |raw|
      node = unwrap_value(raw)
      if node.is_a?(AST::Identifier)
        found = true if symbol_heap?(node.symbol)
      end
    end
    found
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.expr_has_owned_inline_value?(expr)
    root = unwrap_value(expr)
    AST.each_locatable(expr) do |raw|
      node = unwrap_value(raw)
      next unless node.is_a?(AST::Locatable)
      is_root = node.equal?(root)
      unless is_root || node.is_a?(AST::Identifier)
        return true if node.is_a?(AST::Literal) && node.value.is_a?(String)
        ti = node.full_type!(context: "owned inline value")
        return true if !ti.rodata? && ti.provenance != :borrow && ti.heap_ptr?
      end
    end
    false
  rescue StandardError
    false
  end

  sig { params(facts: FunctionFacts, name: String).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_name(facts, name)
    facts.symbols[name]
  end

  sig { params(fn: AST::FunctionDef, summary: T.nilable(Annotator::Phases::FunctionBodySummary), hoist_bindings: T::Array[AST::VarDecl]).returns(FunctionFacts) }
  private_class_method def self.function_facts(fn, summary = nil, hoist_bindings = [])
    symbols = T.let({}, T::Hash[String, SymbolEntry])
    binding_values = T.let({}, T::Hash[String, T::Array[AST::Locatable]])
    return_values = T.let([], T::Array[AST::Node])
    assignment_nodes = T.let([], T::Array[AssignmentNode])
    escape_nodes = T.let([], T::Array[AST::Locatable])
    fn.params.each do |param|
      sym = param.symbol
      symbols[param.name.to_s] = sym if sym
    end
    if summary
      summary.binding_nodes.each { |node| record_binding_fact!(node, symbols, binding_values) }
      summary.assignment_nodes.each do |node|
        record_symbol_fact!(node, symbols) if node.is_a?(AST::BindExpr)
        assignment_nodes << node
      end
      hoist_bindings.each { |node| record_binding_fact!(node, symbols, binding_values) }
      summary.return_nodes.each { |node| return_values << node.value if node.value }
      escape_nodes.concat(summary.escape_nodes)
      escape_nodes.concat(hoist_bindings)
      return FunctionFacts.new(
        fn: fn,
        symbols: symbols,
        binding_values: binding_values,
        return_values: return_values,
        assignment_nodes: assignment_nodes,
        escape_nodes: escape_nodes,
        lambda_body_identifier_refs: summary.lambda_body_identifier_refs,
      )
    end

    walk_body(fn.body) do |node|
      escape_nodes << node if node.is_a?(AST::Locatable)
      return_values << node.value if node.is_a?(AST::ReturnNode) && node.value
      assignment_nodes << node if node.is_a?(AST::Assignment) || node.is_a?(AST::DestructuringAssignment)
      case node
      when AST::VarDecl
        record_binding_fact!(node, symbols, binding_values)
      when AST::BindExpr
        if node.mode == :assign
          assignment_nodes << node
        else
          record_binding_fact!(node, symbols, binding_values)
        end
      when AST::DestructuringAssignment
        node.targets.each do |target|
          next if target.name == "_"
          record_binding_fact!(target, symbols, binding_values) if target.symbol&.reg.equal?(target)
        end
      end
    end
    FunctionFacts.new(
      fn: fn,
      symbols: symbols,
      binding_values: binding_values,
      return_values: return_values,
      assignment_nodes: assignment_nodes,
      escape_nodes: escape_nodes,
      lambda_body_identifier_refs: collect_lambda_identifier_refs(fn.body),
    )
  end

  sig { params(node: BindingNode, symbols: T::Hash[String, SymbolEntry]).void }
  private_class_method def self.record_symbol_fact!(node, symbols)
    sym = symbol_for_binding_node(node)
    symbols[node.name.to_s] = sym if sym
  end

  sig { params(node: BindingNode, symbols: T::Hash[String, SymbolEntry], binding_values: T::Hash[String, T::Array[AST::Locatable]]).void }
  private_class_method def self.record_binding_fact!(node, symbols, binding_values)
    record_symbol_fact!(node, symbols)
    value = T.let(nil, T.nilable(AST::Node))
    value = node.value if node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return unless value.is_a?(AST::Locatable)

    (binding_values[node.name.to_s] ||= []) << value
  end

  sig { params(receiver: AST::Node).returns(T::Boolean) }
  private_class_method def self.receiver_is_param?(receiver)
    root = AST.root_identifier(receiver)
    sym = root&.symbol
    !!(sym && sym.respond_to?(:is_param) && sym.is_param)
  end

  sig { params(node: AST::LambdaLit, bg_heap: T::Set[String], facts: T.nilable(FunctionFacts)).void }
  private_class_method def self.mark_lambda_captures_heap!(node, bg_heap, facts)
    names = T.let(Set.new, T::Set[String])
    node.captures.each { |capture| names << capture.name.to_s }
    return if names.empty?

    identifiers = facts&.lambda_body_identifier_refs&.fetch(node.object_id, nil)
    identifiers ||= collect_lambda_body_identifiers(node)
    identifiers.each do |child|
      next unless names.include?(child.name.to_s)
      mark_symbol_heap!(child.symbol, bg_heap, child.name.to_s)
    end
  end

  sig { params(body: AST::RawBody).returns(LambdaIdentifierRefs) }
  private_class_method def self.collect_lambda_identifier_refs(body)
    refs = T.let({}, LambdaIdentifierRefs)
    AST.each_locatable(body, descend_functions: false) do |node|
      next unless node.is_a?(AST::LambdaLit)

      refs[node.object_id] = collect_lambda_body_identifiers(node)
    end
    refs
  end

  sig { params(node: AST::LambdaLit).returns(T::Array[AST::Identifier]) }
  private_class_method def self.collect_lambda_body_identifiers(node)
    out = T.let([], T::Array[AST::Identifier])
    stack = T.let(AST.lambda_body_nodes(node.body).reverse, T::Array[AST::Node])
    until stack.empty?
      current = unwrap_value(stack.pop)
      next unless current.is_a?(AST::Locatable)
      if current.is_a?(AST::Identifier)
        out << current
        next
      end
      next if current.is_a?(AST::FunctionDef) || current.is_a?(AST::LambdaLit)

      AST.expression_children(current).reverse_each { |child| stack << child }
      AST.child_bodies(current).reverse_each do |child_body|
        child_body.reverse_each { |child| stack << child }
      end
    end
    out
  end

  sig { params(call: AST::FuncCall, fn_nodes: FnNodes).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_call(call, fn_nodes)
    fn = fn_nodes[call.name.to_s]
    return fn.params if fn
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  sig { params(call: AST::MethodCall).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_method_call(call)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  sig { params(fn: AST::FunctionDef, expr: AST::Node).returns(T::Boolean) }
  private_class_method def self.borrowed_return?(fn, expr)
    return false unless fn.return_lifetime
    returned = T.let(Set.new, T::Set[String])
    collect_identifier_names!(expr, returned)
    if fn.return_lifetime == :wildcard
      param_names = T.let(Set.new, T::Set[String])
      fn.params.each { |param| param_names << param.name.to_s }
      return !(returned & param_names).empty?
    end
    borrowed = T.let(Set.new, T::Set[String])
    Array(fn.return_lifetime).each do |source|
      borrowed << source.name.to_s if source.respond_to?(:name)
    end
    !(returned & borrowed).empty?
  end

  sig { params(fn: AST::FunctionDef, expr: AST::Node, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.owning_return_needs_heap_placement?(fn, expr, schema_lookup)
    return false if borrowed_return?(fn, expr)
    ti = owning_return_type(fn, expr)
    return false unless ti
    top_heap_ptr = ti.heap_ptr?
    ti = ti.value_payload_type
    return false unless ti
    return false if ti.primitive? || ti.void? || ti.any?
    if expr.is_a?(AST::Identifier) && symbol_heap?(expr.symbol)
      return true if ti.string? || ti.heap_ptr? || ti.recursive_cleanup_shape?(T.unsafe(schema_lookup))
    end
    expr_t = expr.is_a?(AST::Locatable) ? expr.full_type!(context: "escaping expression") : nil
    return false if !expr.is_a?(AST::Identifier) && expr_t&.rodata?
    return false if ti.rodata? || ti.borrowed_reference?
    top_heap_ptr || ti.ownership != :affine ||
      ti.ownership_bearing?(T.unsafe(schema_lookup)) ||
      ti.needs_explicit_cleanup?(:heap, T.unsafe(schema_lookup))
  end

  sig { params(fn: AST::FunctionDef, expr: AST::Node).returns(T.nilable(Type)) }
  private_class_method def self.owning_return_type(fn, expr)
    declared = fn.declared_return_type
    declared || (expr.is_a?(AST::Locatable) ? expr.full_type!(context: "owning return expression") : nil)
  end

  sig { params(facts: FunctionFacts, expr: AST::Node).void }
  private_class_method def self.mark_heap_return!(facts, expr)
    fn = facts.fn
    ret = fn.declared_return_type
    ret = ret.value_payload_type if ret
    ret.mark_heap_allocated! if ret
    fn.heap_carry_return = true if fn.respond_to?(:heap_carry_return=)

    names = T.let(Set.new, T::Set[String])
    collect_identifier_names!(expr, names) unless returned_call_result?(expr)
    return if names.empty?
    fn.heap_carry_return_vars ||= Set.new if fn.respond_to?(:heap_carry_return_vars)
    names.each { |name| fn.heap_carry_return_vars << name } if fn.respond_to?(:heap_carry_return_vars)
    mark_decl_symbols_heap_by_name!(facts, names)
  end

  sig { params(expr: AST::Node).returns(T::Boolean) }
  private_class_method def self.returned_call_result?(expr)
    node = unwrap_value(expr)
    node = unwrap_value(node.left) if node.is_a?(AST::BinaryOp) && node.op == :OR_ELSE
    !!(node.is_a?(AST::Locatable) && AST.call?(node))
  end

  sig { params(facts: FunctionFacts, names: T::Set[String]).void }
  private_class_method def self.mark_decl_symbols_heap_by_name!(facts, names)
    names.each do |name|
      sym = facts.symbols[name]
      next unless sym
      changed = mark_symbol_heap!(sym)
      decl = sym.reg
      decl.container_borrow = false if changed && decl.respond_to?(:container_borrow=)
    end
  end

  sig { params(facts: FunctionFacts, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_heap_return_facts!(facts, schema_lookup)
    facts.return_values.each do |value|
      mark_heap_return!(facts, value) if owning_return_needs_heap_placement?(facts.fn, value, schema_lookup)
    end
  end

  sig { params(expr: AST::Node, names: T::Set[String]).void }
  private_class_method def self.collect_identifier_names!(expr, names)
    stack = T.let([expr], T::Array[AST::Node])
    until stack.empty?
      node = unwrap_value(stack.pop)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        names << node.name.to_s
        next
      end
      push_locatable_children!(node, stack)
    end
  end

  sig { params(facts: FunctionFacts, target: AssignmentTarget, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.assignment_target_heap_destination?(facts, target, schema_lookup)
    case target
    when String, Symbol
      symbol_heap?(symbol_for_name(facts, target.to_s))
    else
      heap_destination?(facts, target, schema_lookup)
    end
  end

  sig { params(facts: FunctionFacts, target: AST::Node, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.heap_destination?(facts, target, schema_lookup)
    root = AST.root_identifier(target)
    return false unless root
    return true if symbol_heap?(root.symbol)
    sym = symbol_for_name(facts, root.name.to_s)
    return true if symbol_heap?(sym)
    return false if target.is_a?(AST::Identifier)

    ti = root.full_type!(context: "escape destination allocator")
    ti.cleanup_allocator(T.unsafe(schema_lookup)) == :heap
  rescue StandardError
    false
  end

  sig { params(value: AST::Node, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc), facts_by_name: T::Hash[String, FunctionFacts]).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap?(value, fn_nodes, schema_lookup, facts_by_name: {})
    call = unwrap_value(value)
    call = unwrap_value(call.left) if call.is_a?(AST::BinaryOp) && call.op == :OR_ELSE
    return false unless call.is_a?(AST::Locatable) && AST.call?(call)
    call = T.cast(call, T.any(AST::FuncCall, AST::MethodCall))
    callee = fn_nodes[call.name.to_s]
    return false if callee && function_def_has_return_lifetime?(callee)
    callee_facts = facts_by_name[call.name.to_s]
    return call_result_is_heap_for_callee?(call, callee, schema_lookup, facts: callee_facts) if callee

    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    return false unless sig
    return false unless sig.return_lifetime.empty?
    dep = signature_heap_return_from_args?(call, sig)
    return dep unless dep.nil?

    return true if sig.respond_to?(:heap_carry_return) && sig.heap_carry_return == true
    return true if sig.heap_return_alloc?
    false
  end

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall), callee: AST::FunctionDef, schema_lookup: T.nilable(Proc), facts: T.nilable(FunctionFacts)).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap_for_callee?(call, callee, schema_lookup, facts: nil)
    dep = heap_return_from_args?(call.args, callee.params, callee.heap_carry_return_vars, callee.return_type, schema_lookup)
    return dep unless dep.nil?

    callee_facts = facts || function_facts(callee)
    callee.heap_carry_return == true ||
      function_facts_have_owned_return_value?(callee_facts, schema_lookup) ||
      function_facts_have_heap_return_binding?(callee_facts)
  end

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall), sig_obj: FunctionSignature).returns(T.nilable(T::Boolean)) }
  private_class_method def self.signature_heap_return_from_args?(call, sig_obj)
    heap_return_from_args?(call.args, sig_obj.params, sig_obj.heap_carry_return_vars, sig_obj.return_type, nil)
  end

  sig { params(args: T::Array[AST::Node], params: T::Array[AST::Param], returned_names: T.nilable(T::Set[String]), return_type: T.nilable(Type::TypeInput), schema_lookup: T.nilable(Proc)).returns(T.nilable(T::Boolean)) }
  private_class_method def self.heap_return_from_args?(args, params, returned_names, return_type = nil, schema_lookup = nil)
    return nil unless returned_names && !returned_names.empty?
    by_name = T.let({}, T::Hash[String, Integer])
    params.each_with_index { |param, idx| by_name[param.name.to_s] = idx }
    has_param_return = T.let(false, T::Boolean)
    returned_names.each do |name|
      idx = by_name[name.to_s]
      unless idx
        return true
      end
      has_param_return = true
      arg = args[idx]
      return true if expr_produces_heap?(arg)
    end
    if has_param_return
      ret = Type.from_node(return_type)
      ret = ret.success_type if ret
      return true if ret&.string? || ret&.recursive_cleanup_shape?(T.unsafe(schema_lookup))
      return false
    end
    nil
  end

  sig { params(expr: NodeValue).returns(T::Boolean) }
  private_class_method def self.expr_produces_heap?(expr)
    node = unwrap_value(expr)
    node = unwrap_value(node.left) if node.is_a?(AST::BinaryOp) && node.op == :OR_ELSE
    return false if T.unsafe(node).respond_to?(:storage) && [:rodata, :borrow].include?(T.unsafe(node).storage)
    return false if T.unsafe(node).respond_to?(:rodata_provenance?) && T.unsafe(node).rodata_provenance?
    return false if T.unsafe(node).respond_to?(:borrow_provenance?) && T.unsafe(node).borrow_provenance?
    return true if T.unsafe(node).respond_to?(:heap_storage?) && T.unsafe(node).heap_storage?
    return true if T.unsafe(node).respond_to?(:symbol) && T.unsafe(node).symbol&.heap_storage?
    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.string_concat
    return false unless node.is_a?(AST::Locatable)
    ti = node.full_type!(context: "heap-producing expression")
    ti.heap_ptr? || ti.recursive_cleanup_shape?(nil)
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  private_class_method def self.function_def_has_return_lifetime?(fn)
    rl = fn.return_lifetime
    return false if rl.nil?
    return true if rl == :wildcard
    !Array(rl).empty?
  end

  sig { params(facts: FunctionFacts, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.function_facts_have_owned_return_value?(facts, schema_lookup)
    facts.return_values.any? do |value|
      owning_return_needs_heap_placement?(facts.fn, value, schema_lookup)
    end
  end

  sig { params(facts: FunctionFacts).returns(T::Boolean) }
  private_class_method def self.function_facts_have_heap_return_binding?(facts)
    facts.return_values.any? { |value| expr_has_heap_identifier?(value) }
  end

  sig { params(node: BindingNode).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_binding_node(node)
    node.symbol
  end

  sig { params(sym: T.nilable(SymbolEntry), names: T.nilable(T::Set[String]), name: T.nilable(String)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_heap!(sym, names = nil, name = nil)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage? || sym_entry.borrow_provenance?
    sym_entry.storage = :heap
    names << name if names && name
    true
  end

  sig { params(node: BasicObject).returns(T::Boolean) }
  private_class_method def self.mark_node_symbol_heap!(node)
    changed = mark_symbol_heap!(T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol : nil)
    decl = T.unsafe(node).respond_to?(:symbol) ? T.unsafe(node).symbol&.reg : nil
    decl.container_borrow = false if changed && decl.respond_to?(:container_borrow=)
    changed
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_borrow!(sym)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage? || sym_entry.borrow_provenance?
    sym_entry.storage = :borrow
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_reassigned_symbol_heap!(sym)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage?
    sym_entry.storage = :heap
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.canonical_symbol(sym)
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def self.symbol_heap?(sym)
    canonical_symbol(sym)&.heap_storage? == true
  end
end
