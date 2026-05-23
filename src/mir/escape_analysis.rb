# typed: strict
# Dead-simple escape placement plus caller sync propagation.
#
# Escape placement is intentionally AST-bound: each escape mechanism is a
# local node predicate and the only output is SymbolEntry#storage = :heap.

require "sorbet-runtime"

require_relative "../ast/type"
require_relative "../ast/ast"
require_relative "../annotator-helpers/function_signature"

module EscapeAnalysis
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  HeapResult = T.type_alias { [T::Set[String], T::Set[String]] }

  sig { params(fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(HeapResult) }
  def self.apply!(fn_nodes, schema_lookup = nil)
    propagate_caller_sync!(fn_nodes)

    heap_fns = T.let(Set.new, T::Set[String])
    bg_heap = T.let(Set.new, T::Set[String])

    fn_nodes.each_value do |fn|
      mark_heap_return_facts!(fn, schema_lookup) if fn.body
    end

    fn_nodes.each do |name, fn|
      next unless fn.body
      before = heap_symbol_count(fn)
      mark_body_escapes!(fn, fn_nodes, bg_heap, schema_lookup)
      propagate_hoist_dependencies!(fn)
      propagate_assignment_ownership!(fn, fn_nodes, schema_lookup)
      heap_fns << name if heap_symbol_count(fn) > before
    end

    [heap_fns, bg_heap]
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
  sig { params(fn_nodes: FnNodes).void }
  def self.propagate_caller_sync!(fn_nodes)
    return if fn_nodes.empty?

    # Index callsites: callee_name => [{ args: }, ...].
    # AST.walk_body only visits top-level statements, not expression
    # sub-trees, so a `let x = foo(...)` would miss the FuncCall. Walk
    # every Locatable descendant.
    callsites = Hash.new { |h, k| h[k] = [] }
    fn_nodes.each do |_, caller_fn|
      next unless caller_fn&.body
      collect_callsites_deep(caller_fn.body, callsites)
    end

    max_iters = 8
    max_iters.times do
      changed = T.let(false, T::Boolean)
      fn_nodes.each do |callee_name, callee_fn|
        next unless callee_fn&.params
        sites = callsites[callee_name]
        next if sites.empty?

        callee_fn.params.each_with_index do |param, idx|
          entry = param.symbol
          next unless entry

          # ── sync axis ────────────────────────────────────────────────
          unless entry.sync && param_sync_was_declared?(param)
            unified = unify_caller_attr(sites, idx) { |s| s&.sync }
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
            next s.storage if s&.storage == :shared || s&.storage == :multiowned
            t = s&.type
            if t.is_a?(Type)
              next :shared     if t.respond_to?(:shared?)     && t.shared?
              next :multiowned if t.respond_to?(:multiowned?) && t.multiowned?
            end
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

  # Walk every Locatable descendant (incl. expression sub-trees), record
  # FuncCalls.
  sig { params(body: T::Array[T.untyped], callsites: T::Hash[String, T::Array[T.untyped]]).returns(NilClass) }
  private_class_method def self.collect_callsites_deep(body, callsites)
    stack = body.is_a?(Array) ? body.dup : [body]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::FuncCall)
        T.must(callsites[node.name.to_s]) << { args: node.args }
      end
      next if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit)
      node.class.members.each do |m|
        v = node[m]
        if v.is_a?(Array)
          v.each { |c| stack.push(c) if c.is_a?(AST::Locatable) }
        elsif v.is_a?(AST::Locatable)
          stack.push(v)
        end
      end
    end
  end

  # Most-general unifier: returns the single non-nil value when every
  # callsite's arg projects to the same value, else nil.
  sig { params(sites: T::Array[T::Hash[T.untyped, T.untyped]], idx: Integer, project: T.untyped).returns(T.nilable(Symbol)) }
  private_class_method def self.unify_caller_attr(sites, idx, &project)
    observed = sites.map do |site|
      arg = site[:args][idx]
      next nil unless arg && arg.respond_to?(:symbol)
      project.call(arg.symbol)
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
    return true unless sync == :atomic

    requires = fn_node.respond_to?(:requires) ? fn_node.requires : nil
    families = requires && requires[param.name.to_s]
    return false unless families.respond_to?(:include?)
    families.include?(:ATOMIC) || families.include?(:SNAPSHOTTED)
  end

  sig { params(fn: AST::FunctionDef).returns(Integer) }
  private_class_method def self.heap_symbol_count(fn)
    count = T.let(0, Integer)
    fn.params.each { |param| count += 1 if param.symbol&.storage == :heap }
    walk_body(fn.body) do |node|
      sym = symbol_for_binding_node(node)
      count += 1 if sym&.storage == :heap
    end
    count
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, bg_heap: T::Set[String], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_body_escapes!(fn, fn_nodes, bg_heap, schema_lookup)
    walk_body(fn.body) do |node|
      case node
      when AST::ReturnNode
        if owning_return_needs_heap_placement?(fn, node.value, schema_lookup)
          mark_expr_identifiers_heap!(node.value)
          mark_heap_return!(fn, node.value)
        end
      when AST::Assignment
        mark_expr_identifiers_heap!(node.value) if heap_destination?(node.name)
      when AST::VarDecl, AST::BindExpr
        if borrow_return_expr?(node.value)
          mark_symbol_borrow!(node.symbol)
        elsif call_result_is_heap?(node.value, fn_nodes, schema_lookup)
          mark_symbol_heap!(node.symbol)
        end
      when AST::BgBlock, AST::BgStreamBlock
        mark_capture_analysis_heap!(node.capture_analysis, bg_heap)
      when AST::LambdaLit
        mark_lambda_captures_heap!(node, bg_heap)
      when AST::FuncCall
        mark_takes_args_heap!(node.args, params_for_call(node, fn_nodes))
      when AST::MethodCall
        mark_method_takes_heap!(node, params_for_method_call(node))
      end
    end
  end

  sig { params(body: T::Array[T.untyped], blk: T.proc.params(arg0: T.untyped).void).void }
  private_class_method def self.walk_body(body, &blk)
    stack = T.let(body.reverse, T::Array[T.untyped])
    until stack.empty?
      node = stack.pop
      next unless node
      blk.call(node) if node.is_a?(AST::Locatable)
      next if node.is_a?(AST::FunctionDef)
      next unless node.is_a?(Struct)

      node.class.members.each do |member|
        value = node[member]
        if value.is_a?(Array)
          value.reverse_each { |child| stack << child if child.is_a?(Struct) }
        elsif value.is_a?(Hash)
          value.each_value { |child| stack << child if child.is_a?(Struct) }
        elsif value.is_a?(AST::Locatable)
          stack << value
        elsif value.is_a?(Struct)
          stack << value
        end
      end
    end
  end

  sig { params(expr: T.untyped).void }
  private_class_method def self.mark_expr_roots_heap!(expr)
    root = AST.root_identifier(unwrap_value(expr))
    if root
      mark_symbol_heap!(root.symbol)
      return
    end

    node = unwrap_value(expr)
    mark_symbol_heap!(node.symbol) if node.is_a?(AST::Identifier)
  end

  sig { params(expr: T.untyped).void }
  private_class_method def self.mark_expr_identifiers_heap!(expr)
    stack = T.let([expr], T::Array[T.untyped])
    until stack.empty?
      node = unwrap_value(stack.pop)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        mark_symbol_heap!(node.symbol)
        next
      end
      root = AST.root_identifier(node)
      if root
        mark_symbol_heap!(root.symbol)
        next
      end
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
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  private_class_method def self.unwrap_value(node)
    current = T.let(node, T.untyped)
    while current.is_a?(AST::MoveNode) || current.is_a?(AST::CopyNode) || current.is_a?(AST::CloneNode) ||
          current.is_a?(AST::ShareNode) || current.is_a?(AST::FreezeNode) || current.is_a?(AST::CapabilityWrap)
      current = current.value
    end
    current
  end

  sig { params(analysis: T.untyped, bg_heap: T::Set[String]).void }
  private_class_method def self.mark_capture_analysis_heap!(analysis, bg_heap)
    return unless analysis
    symbols = analysis.respond_to?(:capture_symbols) ? analysis.capture_symbols : nil
    return unless symbols.respond_to?(:each)
    symbols.each do |name, sym|
      mark_symbol_heap!(sym, bg_heap, name.to_s)
    end
  end

  sig { params(args: T::Array[T.untyped], params: T::Array[AST::Param]).void }
  private_class_method def self.mark_takes_args_heap!(args, params)
    params.each_with_index do |param, idx|
      arg = args[idx]
      next unless arg
      if param.takes || param.mutable
        mark_expr_roots_heap!(arg)
      end
    end
  end

  sig { params(call: AST::MethodCall, params: T::Array[AST::Param]).void }
  private_class_method def self.mark_method_takes_heap!(call, params)
    receiver_param = params.first
    if receiver_is_param?(call.object) &&
       receiver_param && receiver_param.respond_to?(:takes) &&
       (receiver_param.takes || receiver_param.mutable)
      mark_expr_roots_heap!(call.object)
    end

    mark_takes_args_heap!(call.args, params.drop(1))
    mark_collection_owner_for_owned_store!(call, params)
  end

  sig { params(call: AST::MethodCall, params: T::Array[AST::Param]).void }
  private_class_method def self.mark_collection_owner_for_owned_store!(call, params)
    receiver = AST.root_identifier(call.object)
    receiver_sym = receiver&.symbol
    receiver_type = receiver_sym&.type
    return unless receiver_sym && receiver_type.is_a?(Type) && receiver_type.collection?

    params.drop(1).each_with_index do |param, idx|
      next unless param.takes
      arg = call.args[idx]
      next unless arg
      if expr_has_heap_identifier?(arg) || string_concat_expr?(unwrap_value(arg))
        mark_reassigned_symbol_heap!(receiver_sym)
        return
      end
    end
  end

  sig { params(fn: AST::FunctionDef).void }
  private_class_method def self.propagate_hoist_dependencies!(fn)
    bindings = T.let({}, T::Hash[String, T.untyped])
    walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      next unless node.name
      bindings[node.name.to_s] = node.value
    end

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      bindings.each do |name, value|
        sym = symbol_for_name(fn, name)
        next unless sym&.storage == :heap
        before = heap_symbol_count(fn)
        mark_expr_identifiers_heap!(value)
        changed = true if heap_symbol_count(fn) > before
      end

      bindings.each do |name, value|
        sym = symbol_for_name(fn, name)
        next if sym&.storage == :heap || sym&.storage == :borrow || sym&.storage == :rodata
        next if borrow_return_expr?(value)
        next unless heap_bearing_binding?(sym, value)
        next unless expr_has_heap_identifier?(value) || expr_has_owned_inline_value?(value)
        before = heap_symbol_count(fn)
        mark_symbol_heap!(sym)
        changed = true if heap_symbol_count(fn) > before
      end
    end
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.propagate_assignment_ownership!(fn, fn_nodes, schema_lookup)
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      walk_body(fn.body) do |node|
        target = assigned_binding_name(node)
        next unless target
        sym = symbol_for_name(fn, target)
        next unless sym
        next unless assignment_value_is_owned?(node, fn_nodes, schema_lookup)
        changed = true if mark_reassigned_symbol_heap!(sym)
      end
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(String)) }
  private_class_method def self.assigned_binding_name(node)
    if node.is_a?(AST::BindExpr) && node.mode == :assign
      return node.name.to_s
    end
    return nil unless node.is_a?(AST::Assignment)
    target = unwrap_value(node.name)
    return target.name.to_s if target.is_a?(AST::Identifier)
    nil
  end

  sig { params(node: T.untyped, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.assignment_value_is_owned?(node, fn_nodes, schema_lookup)
    return false unless node.respond_to?(:value)
    value = unwrap_value(node.value)
    return true if value.is_a?(AST::CopyNode) || value.is_a?(AST::CloneNode)
    return true if expr_has_heap_identifier?(value)
    return true if call_result_is_heap?(value, fn_nodes, schema_lookup)
    return false if string_concat_expr?(value)
    type_requires_owned_storage?(Type.from_node(value), schema_lookup)
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.string_concat_expr?(expr)
    expr.is_a?(AST::StringConcat) ||
      (expr.is_a?(AST::BinaryOp) && expr.op == :ADD && expr.string_concat == true)
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.type_requires_owned_storage?(ti, schema_lookup)
    return false unless ti
    t = ti.error_union? ? ti.payload_type : ti
    return false unless t
    return false if t.rodata? || t.provenance == :borrow
    t.heap_ptr? || t.recursive_cleanup_shape?(schema_lookup)
  rescue StandardError
    false
  end

  sig { params(sym: T.nilable(SymbolEntry), value: T.untyped).returns(T::Boolean) }
  private_class_method def self.heap_bearing_binding?(sym, value)
    ti = sym&.type
    ti = Type.from_node(value) unless ti.is_a?(Type)
    return false unless ti.is_a?(Type)
    ti.heap_ptr? || ti.recursive_cleanup_shape?(nil)
  rescue StandardError
    false
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.borrow_return_expr?(expr)
    call = unwrap_value(expr)
    return false unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    !!sig && !sig.return_lifetime.empty?
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_has_heap_identifier?(expr)
    found = T.let(false, T::Boolean)
    stack = T.let([expr], T::Array[T.untyped])
    until stack.empty?
      node = unwrap_value(stack.pop)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        found = true if node.symbol&.storage == :heap
        next
      end
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
    found
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_has_owned_inline_value?(expr)
    stack = T.let([[expr, true]], T::Array[[T.untyped, T::Boolean]])
    until stack.empty?
      item = T.must(stack.pop)
      node = unwrap_value(item[0])
      is_root = item[1]
      next unless node.is_a?(AST::Locatable)
      unless is_root || node.is_a?(AST::Identifier)
        return true if node.is_a?(AST::Literal) && node.value.is_a?(String)
        ti = Type.from_node(node)
        return true if ti && !ti.rodata? && ti.provenance != :borrow &&
                       ti.heap_ptr?
      end
      AST.wrapped_children(node).each { |child| stack << [child, false] if child.is_a?(AST::Locatable) }
      node.class.members.each do |member|
        value = node[member]
        if value.is_a?(Array)
          value.each { |child| stack << [child, false] if child.is_a?(AST::Locatable) }
        elsif value.is_a?(Hash)
          value.each_value { |child| stack << [child, false] if child.is_a?(AST::Locatable) }
        elsif value.is_a?(AST::Locatable)
          stack << [value, false]
        end
      end
    end
    false
  rescue StandardError
    false
  end

  sig { params(fn: AST::FunctionDef, name: String).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_name(fn, name)
    found = T.let(nil, T.nilable(SymbolEntry))
    fn.params.each do |param|
      found = param.symbol if param.name.to_s == name
    end
    walk_body(fn.body) do |node|
      next if found
      sym = symbol_for_binding_node(node)
      found = sym if sym && node.respond_to?(:name) && node.name.to_s == name
    end
    found
  end

  sig { params(receiver: T.untyped).returns(T::Boolean) }
  private_class_method def self.receiver_is_param?(receiver)
    root = AST.root_identifier(receiver)
    sym = root&.symbol
    !!(sym && sym.respond_to?(:is_param) && sym.is_param)
  end

  sig { params(node: AST::LambdaLit, bg_heap: T::Set[String]).void }
  private_class_method def self.mark_lambda_captures_heap!(node, bg_heap)
    names = T.let(Set.new, T::Set[String])
    node.captures.each { |capture| names << capture.name.to_s }
    return if names.empty?

    body = node.body.is_a?(Array) ? node.body : [node.body]
    walk_body(body) do |child|
      next unless child.is_a?(AST::Identifier)
      next unless names.include?(child.name.to_s)
      mark_symbol_heap!(child.symbol, bg_heap, child.name.to_s)
    end
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

  sig { params(fn: AST::FunctionDef, expr: T.untyped).returns(T::Boolean) }
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

  sig { params(fn: AST::FunctionDef, expr: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.owning_return_needs_heap_placement?(fn, expr, schema_lookup)
    return false if borrowed_return?(fn, expr)
    ti = owning_return_type(fn, expr)
    return false unless ti
    top_heap_ptr = ti.heap_ptr?
    ti = ti.payload_type if ti.error_union?
    return false if ti.primitive? || ti.void? || ti.any?
    if expr.is_a?(AST::Identifier) && expr.symbol&.storage == :heap
      return true if ti.string? || ti.heap_ptr? || ti.recursive_cleanup_shape?(schema_lookup)
    end
    expr_t = Type.from_node(expr)
    return false if expr_t&.rodata? || expr_t&.provenance == :borrow
    return false if ti.rodata? || ti.provenance == :borrow
    top_heap_ptr || ti.heap_ptr? || ti.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).returns(T.nilable(Type)) }
  private_class_method def self.owning_return_type(fn, expr)
    declared = Type.from_node(fn.return_type)
    declared || Type.from_node(expr)
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).void }
  private_class_method def self.mark_heap_return!(fn, expr)
    ret = fn.return_type
    ret = ret.payload_type if ret.respond_to?(:error_union?) && ret.error_union? && ret.respond_to?(:payload_type)
    ret.provenance = :heap if ret.respond_to?(:provenance=)
    fn.heap_carry_return = true if fn.respond_to?(:heap_carry_return=)

    names = T.let(Set.new, T::Set[String])
    collect_identifier_names!(expr, names)
    return if names.empty?
    fn.heap_carry_return_vars ||= Set.new if fn.respond_to?(:heap_carry_return_vars)
    names.each { |name| fn.heap_carry_return_vars << name } if fn.respond_to?(:heap_carry_return_vars)
  end

  sig { params(fn: AST::FunctionDef, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_heap_return_facts!(fn, schema_lookup)
    walk_body(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value
      mark_heap_return!(fn, node.value) if owning_return_needs_heap_placement?(fn, node.value, schema_lookup)
    end
  end

  sig { params(expr: T.untyped, names: T::Set[String]).void }
  private_class_method def self.collect_identifier_names!(expr, names)
    stack = T.let([expr], T::Array[T.untyped])
    until stack.empty?
      node = unwrap_value(stack.pop)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        names << node.name.to_s
        next
      end
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
  end

  sig { params(target: T.untyped).returns(T::Boolean) }
  private_class_method def self.heap_destination?(target)
    root = AST.root_identifier(target)
    root&.symbol&.storage == :heap
  end

  sig { params(value: T.untyped, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap?(value, fn_nodes, schema_lookup)
    call = unwrap_value(value)
    call = unwrap_value(call.left) if call.is_a?(AST::BinaryOp) && call.op == :OR_RESCUE
    return false unless call.is_a?(AST::FuncCall)
    callee = fn_nodes[call.name.to_s]
    return false if callee && function_def_has_return_lifetime?(callee)
    return call_result_is_heap_for_callee?(call, callee, schema_lookup) if callee

    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    return false unless sig
    return false unless sig.return_lifetime.empty?
    dep = signature_heap_return_from_args?(call, sig)
    return dep unless dep.nil?

    return_type_requires_heap?(sig.return_type, schema_lookup)
  end

  sig { params(call: AST::FuncCall, callee: AST::FunctionDef, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap_for_callee?(call, callee, schema_lookup)
    dep = heap_return_from_args?(call.args, callee.params, callee.heap_carry_return_vars, callee.return_type, schema_lookup)
    return dep unless dep.nil?

    body_has_heap_return_binding?(callee.body) || return_type_requires_heap?(callee.return_type, schema_lookup)
  end

  sig { params(call: AST::FuncCall, sig_obj: FunctionSignature).returns(T.nilable(T::Boolean)) }
  private_class_method def self.signature_heap_return_from_args?(call, sig_obj)
    heap_return_from_args?(call.args, sig_obj.params, sig_obj.heap_carry_return_vars, sig_obj.return_type, nil)
  end

  sig { params(args: T::Array[T.untyped], params: T::Array[AST::Param], returned_names: T.untyped, return_type: T.untyped, schema_lookup: T.nilable(Proc)).returns(T.nilable(T::Boolean)) }
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
      ret = ret.payload_type if ret&.error_union?
      return true if ret&.string? || ret&.recursive_cleanup_shape?(schema_lookup)
      return false
    end
    nil
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_produces_heap?(expr)
    node = unwrap_value(expr)
    node = unwrap_value(node.left) if node.is_a?(AST::BinaryOp) && node.op == :OR_RESCUE
    return false if node.respond_to?(:storage) && [:rodata, :borrow].include?(node.storage)
    return false if node.respond_to?(:rodata_provenance?) && node.rodata_provenance?
    return false if node.respond_to?(:borrow_provenance?) && node.borrow_provenance?
    return true if node.respond_to?(:heap_storage?) && node.heap_storage?
    return true if node.respond_to?(:symbol) && node.symbol&.heap_storage?
    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.op == :ADD && node.string_concat
    ti = Type.from_node(node)
    return false unless ti
    ti.heap_ptr? || ti.recursive_cleanup_shape?(nil)
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.return_type_requires_heap?(ti, schema_lookup)
    return false unless ti
    top_heap_ptr = ti.heap_ptr?
    t = ti.error_union? ? ti.payload_type : ti
    return false unless t
    return false if t.primitive? || t.void? || t.any?
    return false if t.rodata? || t.provenance == :borrow
    top_heap_ptr || t.heap_ptr? || t.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  private_class_method def self.function_def_has_return_lifetime?(fn)
    rl = fn.return_lifetime
    return false if rl.nil?
    return true if rl == :wildcard
    !Array(rl).empty?
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Boolean) }
  private_class_method def self.body_has_heap_return_binding?(body)
    found = T.let(false, T::Boolean)
    walk_body(body) do |node|
      next unless node.is_a?(AST::ReturnNode)
      stack = T.let([node.value], T::Array[T.untyped])
      until stack.empty?
        child = unwrap_value(stack.pop)
        next unless child.is_a?(AST::Locatable)
        if child.is_a?(AST::Identifier) && child.symbol&.storage == :heap
          found = true
          break
        end
        AST.wrapped_children(child).each { |grandchild| stack << grandchild if grandchild.is_a?(AST::Locatable) }
        child.class.members.each do |member|
          value = child[member]
          if value.is_a?(Array)
            value.each { |grandchild| stack << grandchild if grandchild.is_a?(AST::Locatable) }
          elsif value.is_a?(Hash)
            value.each_value { |grandchild| stack << grandchild if grandchild.is_a?(AST::Locatable) }
          elsif value.is_a?(AST::Locatable)
            stack << value
          end
        end
      end
    end
    found
  end

  sig { params(ti: T.nilable(Type)).returns(T::Boolean) }
  private_class_method def self.type_heap_result?(ti)
    return false unless ti
    t = ti.error_union? ? ti.payload_type : ti
    !!(t&.heap_ptr?)
  end

  sig { params(node: T.untyped).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_binding_node(node)
    return node.symbol if (node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) && node.respond_to?(:symbol)
    nil
  end

  sig { params(sym: T.nilable(SymbolEntry), names: T.nilable(T::Set[String]), name: T.nilable(String)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_heap!(sym, names = nil, name = nil)
    return false unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    sym_entry = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
    return false if sym_entry.storage == :heap
    return false if sym_entry.storage == :rodata
    return false if sym_entry.storage == :borrow
    sym_entry.storage = :heap
    names << name if names && name
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_borrow!(sym)
    return false unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    sym_entry = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
    return false if sym_entry.storage == :heap
    return false if sym_entry.storage == :borrow
    sym_entry.storage = :borrow
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_reassigned_symbol_heap!(sym)
    return false unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    sym_entry = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
    return false if sym_entry.storage == :heap
    return false if sym_entry.storage == :borrow
    sym_entry.storage = :heap
    true
  end
end
