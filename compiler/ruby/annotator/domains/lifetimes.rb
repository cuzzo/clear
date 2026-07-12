# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module Lifetimes
      extend T::Sig


      sig { params(node: AST::MoveNode).returns(T.nilable(T::Set[String])) }
      def visit_MoveNode(node)
        T.bind(self, SemanticAnnotator)

        record_capture_site!(node, copied: false)
        without_capture_moves { visit(node.value) }

        unless node.value.is_a?(AST::Identifier)
          error!(node, :MOVE_NEEDS_IDENTIFIER)
        end

        ti = node.value.full_type!(context: "MOVE value")

        # Check if the identifier is a resource
        is_resource = false
        if node.value.is_a?(AST::Identifier)
          info = node.value.symbol
          is_resource = info&.resource
        end

        is_copy = ti.implicitly_copyable? { |t| lookup_type_schema(t) }
        unless ti.multiowned? || ti.shared? || ti.requires_move? || is_resource || !is_copy
          error!(node, :GIVE_ON_COPY_TYPE, type: node.value.resolved_type)
        end

        # Inherit the capability type so the VarDecl or ReturnNode can infer storage correctly
        stamp_type!(node, node.value.full_type!(context: "MOVE result"))
        node.storage   = node.value.storage

        # Consume the source variable — it is affinely transferred. Downstream
        # MIR lowering uses was_moved as the single ownership-transfer signal.
        node.value.was_moved = true if node.value.respond_to?(:was_moved=)
        node.was_moved = true if node.respond_to?(:was_moved=)
        og_set_moved(node.value.name, at_token: node.value.token, action: :give)
      end

      # Ensure a value node is owned data suitable for storage in structs, unions,
      # and TAKES parameters. Returns a replacement CopyNode if wrapping is needed,
      # or nil if the value is already owned.
      #
      # Rules:
      # - @list (list_collection): wrap in CopyNode (frame buffer -> heap copy)
      # - Rodata string: wrap in CopyNode (auto-dupe to heap)
      # - Non-heap string expression: error (require explicit COPY)
      # - Already CopyNode: no-op
      #
      # +val_node+:      the AST value node being stored
      # +expected_type+: the target field/param type (Type or Symbol)
      # +container_desc+: string for error messages (e.g. "MyUnion.Variant")
      sig { params(val_node: AST::Node, expected_type: T.nilable(Type::TypeInput), container_desc: T.nilable(String), container_alloc: Symbol).returns(T.nilable(AST::Node)) }
      def ensure_owned_value!(val_node, expected_type, container_desc = nil, container_alloc: :heap)
        T.bind(self, SemanticAnnotator)

        return nil if val_node.is_a?(AST::Literal) && val_node.type == :NIL
        return nil if val_node.is_a?(AST::CopyNode)
        vti = val_node.full_type!(context: "owned value source")
        vti = Type.new(vti) if vti && !vti.is_a?(Type)
        return nil unless vti
        return nil if vti.symbol?

        # Copy payloads are stored by value and cannot leak the borrow itself.
        if val_node.is_a?(AST::Identifier) && val_node.symbol&.non_escaping
          return nil if vti.implicitly_copyable? { |name| lookup_type_schema(name) }
          error!(val_node, :STORE_WITH_SCOPED_INTO_CONTAINER, name: val_node.name, container: container_desc || 'a container')
        end

        expected_t = expected_type.is_a?(Type) ? expected_type : (expected_type ? Type.new(expected_type) : nil)
        return nil if expected_t&.symbol? && vti.symbol?

        if vti.list_collection?
          # When the target field is also @list (ArrayList), skip CopyNode wrapping.
          # The move mechanism will transfer the ArrayList struct directly.
          # CopyNode produces a slice which is the wrong type for ArrayList fields.
          et = expected_t
          return nil if et&.list_collection?

          copy = AST::CopyNode.new(val_node.token, val_node)
          stamp_type!(copy, expected_t || Type.new(:Any))
          copy.storage = container_alloc
          copy.alloc = container_alloc
          elem = vti.element_type
          if elem
            es = lookup_type_schema(elem.resolved)
            copy.deep_copy = Schemas.union?(es) &&
              (es.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
          end
          return copy
        end

        if vti.string? && vti.rodata?
          copy = AST::CopyNode.new(val_node.token, val_node)
          # Auto-COPY of rodata literal into a non-rodata container -- new
          # string lives in the container's allocator so the container has
          # uniform-provenance elements (no cleanupAlloc needed).
          stamp_type!(copy, Type.new(Type::STRING_TYPE, location: container_alloc))
          copy.storage = container_alloc
          copy.alloc = container_alloc
          return copy
        end

        if vti.string? && val_node.is_a?(AST::Identifier) && container_desc
          sym = val_node.symbol
          unless sym&.heap_storage?
            error!(val_node, :STORE_STRING_NEEDS_COPY, name: val_node.name, container: container_desc)
          end
        end

        nil
      end

      sig { params(node: AST::CopyNode).returns(T.nilable(T::Boolean)) }
      def visit_CopyNode(node)
        T.bind(self, SemanticAnnotator)

        record_capture_site!(node, copied: true)
        without_capture_moves { visit(node.value) }
        finish_previsited_copy!(node)
      end

      # Ownership transport decisions are made after the routine's ordinary
      # annotation has emitted all liveness facts.  At that point the source
      # expression is already fully resolved, and its lexical scope may have
      # closed.  Finish the synthetic COPY from those facts; never re-walk the
      # source AST or perform a second name lookup.
      sig { params(node: AST::CopyNode).returns(T.nilable(T::Boolean)) }
      def finish_previsited_copy!(node)
        T.bind(self, SemanticAnnotator)

        # COPY produces an owned deep-copy. The source is NOT consumed.
        # Clone the Type so mutating provenance doesn't affect the inner node.
        inner_type = node.value.full_type!(context: "COPY value")
        stamp_type!(node, inner_type.is_a?(Type) ? Type.new(inner_type) : inner_type)
        ti = node.full_type!(context: "COPY result")
        resolver = ->(name) { lookup_type_schema(name) }

        # COPY of a primitive or Id<T> is a semantic no-op (value copy, no allocation).
        # All other explicit COPYs produce heap-owned data.
        source_sync = node.value.respond_to?(:symbol) ? node.value.symbol&.sync : nil
        is_value_copy = ti.is_a?(Type) &&
          source_sync.nil? && !ti.multiowned? && !ti.shared? &&
          (ti.primitive? || ti.id_handle?)
        if is_value_copy
          node.storage = :stack
        else
          # COPY always produces heap-owned data for non-value types.
          # Type's clone constructor inherits source provenance (e.g., :rodata from
          # a string literal); override on the cloned Type so internal Type
          # predicates (needs_cleanup?, finalize_storage) see :heap. The
          # storage_override is the authoritative signal for Locatable readers.
          ti.mark_heap_allocated! if ti.is_a?(Type)
          node.storage = :heap
          current_fn_ctx&.record_heap_use!
        end

        deep_copy = collection_copy_deep_copy_required(node)
        node.deep_copy = deep_copy unless deep_copy.nil?
      end

      sig { params(node: AST::CopyNode).returns(T.nilable(T::Boolean)) }
      def collection_copy_deep_copy_required(node)
        T.bind(self, SemanticAnnotator)

        # Determine if elements need deep copy (dupeUnionValue) vs shallow (memcpy).
        # For list/array types, check if element type is a non-Copy union.
        vti = Type.from_node!(node.value, context: "array/list deep-copy")
        return nil unless vti.direct_indexable_collection?

        elem = vti.element_type
        return nil unless elem

        schema = lookup_type_schema(elem.resolved)
        return nil unless Schemas.union?(schema)

        (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      end
      private :collection_copy_deep_copy_required

      sig { params(node: AST::Copy).returns(T.nilable(T::Boolean)) }
      def visit_Copy(node)
        T.bind(self, SemanticAnnotator)

        record_capture_site!(node, copied: true)
        without_capture_moves { visit(node.value) }
        stamp_type!(node, node.value.full_type!(context: "COPY value"))
        node.storage = node.value.storage
        nil
      end

      # Infer return type for list.remove(i) — returns the element type.
      # `node` is unused (the receiver is args.first); nilable because
      # FunctionReturn#resolve dispatches without a call node.
      sig { params(node: AST::LinkNode).returns(T.nilable(Type)) }
      def visit_LinkNode(node)
        T.bind(self, SemanticAnnotator)

        visit(node.value)
        ti = node.value.full_type!(context: "LINK value")

        unless ti&.any_rc?
          error!(node, :LINK_NEEDS_SHARED_OR_MULTIOWNED, got: node.value.resolved_type)
        end

        # Result is the same base type with :link ownership
        link_type = Type.new(ti.resolved)
        # Track which strong ownership kind the link was created from
        link_type.apply_reference_ownership!(:link, link_source: ti.shared? ? :shared : :multiowned)
        stamp_type!(node, link_type)
      end

      sig { params(node: AST::ResolveNode).returns(T.nilable(Type)) }
      def visit_ResolveNode(node)
        T.bind(self, SemanticAnnotator)

        visit(node.value)
        ti = node.value.full_type!(context: "RESOLVE value")

        unless ti&.link?
          error!(node, :RESOLVE_NEEDS_LINK, got: node.value.resolved_type)
        end

        # RESOLVE returns ?T@multiowned or ?T@shared.
        # Use RESOLVE(link)?.field OR fallback to safely access the target.
        source = ti.link_source || :multiowned
        resolved_type = Type.new(:"?#{ti.resolved}")
        resolved_type.apply_reference_ownership!(source == :shared ? :shared : :multiowned, link_source: source)
        stamp_type!(node, resolved_type)
      end

      sig { params(node: AST::FreezeNode).returns(Symbol) }
      def visit_FreezeNode(node)
        T.bind(self, SemanticAnnotator)

        without_capture_moves { visit(node.value) }
        ti = node.value.full_type!(context: "FREEZE value")
        unless ti&.multiowned? || ti&.shared?
          error!(node, :FREEZE_NEEDS_OWNED, got: node.value.resolved_type)
        end
        base = ti.resolved.to_s.sub(/^\?/, '')
        result_type = Type.new(base.to_sym)
        result_type.apply_reference_ownership!(:frozen)
        stamp_type!(node, result_type)
        node.storage   = :frozen
      end

      sig { params(node: AST::CloneNode).returns(T.nilable(T::Boolean)) }
      def visit_CloneNode(node)
        T.bind(self, SemanticAnnotator)

        record_capture_site!(node, copied: true)
        without_capture_moves { visit(node.value) }
        finish_previsited_clone!(node)
      end

      # See finish_previsited_copy!: this consumes resolved semantic facts and
      # deliberately does not revisit the source expression.
      sig { params(node: AST::CloneNode).returns(T.nilable(T::Boolean)) }
      def finish_previsited_clone!(node)
        T.bind(self, SemanticAnnotator)

        type = node.value.full_type!(context: "CLONE value")
        root = get_root_object(node.value)
        if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
          error!(node, :CLONE_WITH_SCOPED, name: root.name)
        end

        unless type&.split_open_stream? || type&.shared_promise? || type&.any_rc?
          error!(node, :CLONE_BAD_TARGET, got: node.value.resolved_type)
        end

        stamp_type!(node, node.value.full_type!(context: "CLONE result"))
        node.storage = node.value.storage
        current_fn_ctx&.mark_runtime_used! if type&.any_rc?
        nil
      end

      sig { params(node: AST::ShareNode).void }
      def visit_ShareNode(node)
        T.bind(self, SemanticAnnotator)

        visit(node.value)
        source_type = node.value.full_type!(context: "SHARE value")
        root = get_root_object(node.value)
        if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
          error!(node, :SHARE_WITH_SCOPED, name: root.name)
        end

        result = Type.new(source_type, ownership: :shared)
        stamp_type!(node, result)
        node.storage = :heap

        if share_consumes_source?(node.value)
          root = get_root_object(node.value)
          if root.is_a?(AST::Identifier)
            og_set_moved(root.name, at_token: root.token, action: :share)
            root.was_moved = true
          end
        end

        current_fn_ctx&.record_heap_use!
        record_effect(EffectTracker::HEAP)
      end

      sig { params(node: AST::Node).returns(AST::Node) }
      def get_root_object(node)
        T.bind(self, SemanticAnnotator)

        curr = T.let(node, AST::Node)
        while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
          curr = curr.target
        end
        curr
      end

      # Collect all identifier names referenced (directly) in an AST subtree.
      # Used by the WHILE loop moved-value check to skip variables not referenced in the body.
      sig { params(nodes: T.any(AST::Node, T::Array[AST::Node])).returns(T::Set[String]) }
      def collect_body_identifier_names(nodes)
        T.bind(self, SemanticAnnotator)

        names = Set.new
        traverse = T.let(nil, T.untyped)
        traverse = lambda do |n|
          case n
          when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
          when Array
            n.each { |item| traverse.call(item) }
          when Hash
            n.each_value { |v| traverse.call(v) }
          when AST::FunctionDef
            # Don't descend into nested function definitions.
          when AST::Identifier
            names.add(n.name)
          else
            n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
          end
        end
        traverse.call(nodes)
        names
      end

      # ── Ownership: move, escape, borrow, drop ────────────────────────
      # All ownership state lives in the receiver-owned OwnershipGraph. The scope is
      # The scope handles type resolution, variable declarations, mutability,
      # and capability tracking. All ownership state is in the OwnershipGraph.

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def handle_assign_move(node)
        T.bind(self, SemanticAnnotator)

        plan = node.respond_to?(:ownership_transport_plan) ? T.unsafe(node).ownership_transport_plan : nil
        return if language_mode != :strict && plan.is_a?(OwnershipTransportPlan) && plan.action != :move
        return if language_mode != :strict && node.value.is_a?(AST::Identifier) &&
          T.unsafe(node.value).ownership_pending_transfer == true
        return if node.value.is_a?(AST::CopyNode)

        # DEFAULT/EASY field and index reads are local borrowed views unless
        # the user explicitly writes a transfer form. The container-borrow
        # fact is registered later, after the destination symbol exists; do
        # not simultaneously mark the source place moved here. Doing both
        # suppressed the parent's cleanup while also suppressing cleanup on
        # the borrowed destination, leaking owned fields.
        return if language_mode != :strict && AST.borrowed_ownership_view?(node.value)

        reject_scoped_assignment_move!(node)

        if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
          handle_assignment_path_move!(node)
          return
        end

        handle_assignment_identifier_move!(node)
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def reject_scoped_assignment_move!(node)
        T.bind(self, SemanticAnnotator)

        # Non-escaping values (WITH block aliases) cannot be moved/consumed.
        # Copy types (Int64, Bool, Float64, etc.) are exempt: assignment copies the
        # value with no pointer transfer, so no lifetime hazard exists.
        return unless node.value.is_a?(AST::Identifier) && node.value.symbol&.non_escaping

        vti = node.value.full_type!(context: "assignment scoped move value")
        needs_move = begin
          vti && Type.new(vti).requires_move?
        rescue
          true
        end
        error!(node, :MOVE_WITH_SCOPED, name: node.value.name) if needs_move
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def handle_assignment_path_move!(node)
        T.bind(self, SemanticAnnotator)

        reject_borrowed_index_assignment_move!(node)
        path = get_path_to_root(node.value)
        return if path.empty?
        value_type = Type.new(node.value.resolved_type)
        return unless value_type.requires_move?

        graph_path = path.map(&:to_s).join(".")
        declare_assignment_graph_path!(graph_path, value_type) unless ownership_graph[graph_path]
        og_set_moved(graph_path, at_token: node.value.token, action: :move)
      end

      sig { params(graph_path: String, value_type: Type).void }
      def declare_assignment_graph_path!(graph_path, value_type)
        T.bind(self, SemanticAnnotator)

        ownership_graph.declare(graph_path, kind: :affine, type_info: value_type, scope_depth: ownership_graph.scope_depth)
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def reject_borrowed_index_assignment_move!(node)
        T.bind(self, SemanticAnnotator)

        # Container indexing of borrowed source into an owned target (HashMap
        # assignment) is an error. Plain variable declarations get borrow marking
        # via register_container_borrow! instead.
        return unless node.is_a?(AST::Assignment) && node.value.is_a?(AST::GetIndex)

        vti = node.value.full_type!(context: "assignment index value")
        is_copy = vti.implicitly_copyable? { |t| lookup_type_schema(t) }
        return if is_copy
        return unless find_container_source(node.value)

        source_name = root_variable_name(node.value)
        if source_name && ownership_graph[source_name]&.kind == :borrowed
          error!(node, :MOVE_BORROWED_INDEX, source: source_name)
        end
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def handle_assignment_identifier_move!(node)
        T.bind(self, SemanticAnnotator)

        return unless node.value.is_a?(AST::Identifier)
        rhs_name = node.value.name
        rhs_type = current_scope.resolve_type(rhs_name)
        rhs_info = current_scope.resolve_entry(rhs_name)
        return if rhs_info&.rc_stored? || rhs_info&.sync

        type_obj = rhs_type
        # A String *binding* is owned/move (CLEAR contract). implicitly_copyable?
        # returns true for a String only via the rvalue rodata exemption
        # (type.rb: string? && rodata?); escape analysis stamps the binding's
        # declaration :rodata because the initializer is a literal, but a
        # binding's move semantics are type-intrinsic, not value-location.
        # Exclude string? from the Copy gate at this ownership-decision site;
        # genuinely-Copy aggregates keep their exemption.
        is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) } &&
                  (!type_obj.string? || type_obj.symbol?)
        if !is_copy && (type_obj.requires_move? || rhs_info&.resource)
          # Cannot move a borrowed value (non-TAKES parameter).
          if ownership_graph[rhs_name]&.kind == :borrowed
            error!(node, :MOVE_BORROWED_PARAM, name: rhs_name)
          end
          lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name.to_s
          # Track the move site at the RHS identifier's token so
          # use-of-moved errors can suggest fixes at the consuming line.
          move_tok = node.value.respond_to?(:token) ? node.value.token : node.token
          og_move(rhs_name, lhs_name, at_token: move_tok)
          node.value.was_moved = true
        end
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def handle_assign_borrow(node)
        T.bind(self, SemanticAnnotator)

        return unless node.value.is_a?(AST::FuncCall) || node.value.is_a?(AST::MethodCall)
        call_node = node.value
        return if AST.collection_method_call?(call_node)

        # Resolve the borrowed argument from either user-defined or stdlib functions.
        actual_arg = resolve_borrow_source(call_node)
        return unless actual_arg

        path = get_path_to_root(actual_arg)
        return if path.empty?

        root_var = path.first.to_s
        borrowed_scope = lookup_scope_for(root_var)
        error!(node, :BORROWED_VAR_NOT_FOUND) if borrowed_scope.nil?
        return if T.must(borrowed_scope).is_immutable?(root_var)

        lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : "__borrow_#{root_var}"
        mutable = node.is_a?(AST::VarDecl) && node.mutable
        err = ownership_graph.borrow(lhs_name, root_var, mutable: mutable)
        error!(node, :LIFETIME_ALREADY_BORROWED, name: root_var) if err
      end

      # Returns the AST node of the argument the return value borrows from, or nil.
      sig { params(call_node: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(AST::Node)) }
      def resolve_borrow_source(call_node)
        T.bind(self, SemanticAnnotator)

        # Path 1: stdlib functions with lifetime: "self"
        matched_def = call_node.matched_stdlib_def
        if matched_def
          lifetimes = matched_def.intrinsic_lifetime
          unless lifetimes.empty?
            if lifetimes.include?("self") && call_node.is_a?(AST::MethodCall)
              return call_node.object
            end
            # Named param lifetime -- find by index in args list
            args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
            idx = matched_def.intrinsic_arg_specs.index do |arg_spec|
              arg_spec.name && lifetimes.include?(arg_spec.name)
            end
            return args[idx] if idx && args[idx]
            return nil
          end
        end

        # Path 2: user-defined functions with return_lifetime: [...]
        func_name = call_node.name
        scope = lookup_scope_for(func_name)
        return nil unless scope

        func_type = FunctionSignature.unwrap(scope.resolve_type(func_name))
        return nil unless func_type

        # Multi-binding lifetime returns track the first source only. Borrow
        # tracking still records under one root; if a
        # multi-source RETURNS is used, the caller-side check in
        # `handle_assign_borrow` uses this single source. Multi-source
        # borrow tracking (record borrows on ALL sources, error when ANY
        # is already borrowed) needs broader audit work. Wildcard returns nil
        # because there is no specific source to track.
        lifetime = func_type.return_lifetime
        return nil if lifetime.empty? || lifetime == [:wildcard]
        primary = lifetime.first
        return nil if primary == :wildcard
        primary_root = primary.to_s.split(".").first

        param_index = func_type.params.find_index { |p| p.name == primary_root }
        return nil unless param_index

        args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
        args[param_index]
      end

      sig { params(node: T.any(AST::Assignment, AST::VarDecl, AST::BindExpr)).void }
      def verify_unrestricted!(node)
        T.bind(self, SemanticAnnotator)

        path = get_path_to_root(node.name)
        return if path.empty?
        root_name = path.first.to_s
        unless ownership_graph.can_write?(root_name)
          error!(node, :ASSIGN_WHILE_BORROWED, name: root_name)
        end
      end

      sig { params(node: AST::Locatable, branch: T.nilable(Symbol)).void }
      def finalize_scope(node, branch: nil)
        T.bind(self, SemanticAnnotator)

        drops = T.let([], T::Array[AST::DeferredDrop])
        current_scope.owned_names.each do |name|
          info = current_scope.local_entry(name)
          next unless info
          # TAKES params always need cleanup guards even if moved (the _moved
          # flag controls whether cleanup runs at runtime).
          is_takes = info.respond_to?(:takes) && info.takes
          next unless ownership_graph.live?(name) || (is_takes && ownership_graph[name]&.moved?)
          classify_ownership!(info) unless info.ownership_kind

          case info.ownership_kind
          when :resource
            drops << deferred_drop_for(name, info, resource: true)
            og_drop(name)
          when :affine
            t = Type.new(info.type)
            if t.single_future?
              error!(node, :PROMISE_NOT_CONSUMED, name: name)
            end
            drops << deferred_drop_for(name, info)
            og_drop(name)
          end
        end

        case branch
        when :then  then T.cast(node, AST::IfStatement).then_drops = drops
        when :else  then T.cast(node, AST::IfStatement).else_drops = drops
        else T.unsafe(node).deferred_drops = drops
        end

        # Unused variable warnings (function-level finalize only)
        if branch.nil?
          current_scope.owned_names.each do |name|
            info = current_scope.local_entry(name)
            next unless info
            next if name.start_with?('_')
            next if info.read
            next if info.reg.respond_to?(:var_used) && info.reg.var_used
            classify_ownership!(info) unless info.ownership_kind
            next if [:resource, :collection, :rc].include?(info.ownership_kind)
            next unless info.reg

            # Keep this as a plain stderr warning: `_` collides with Zig discard
            # and deleting the line could drop RHS side effects.
            loc = info.reg.respond_to?(:line) ? " (line #{info.reg.line})" : ""
            $stderr.puts "\e[33m[Warning]\e[0m Unused variable '#{name}'#{loc}"
          end

          # MUTABLE-never-reassigned warnings
          current_scope.owned_names.each do |name|
            info = current_scope.local_entry(name)
            next unless info
            next if name.start_with?('_')
            next unless info.mutable
            next unless info.read || (info.reg.respond_to?(:var_used) && info.reg.var_used)
            next if info.reg.respond_to?(:var_mutated) && info.reg.var_mutated
            # Also skip when the binding was passed as a MUTABLE arg to a
            # callee — the binding's contents get mutated through the
            # call, so the receiving function's MUTABLE-param signature
            # forces the caller to keep MUTABLE on the local. function_analysis
            # marks `info.mutated` (entry-level) for this case but
            # intentionally does NOT set `info.reg.var_mutated` (which
            # drives the Zig-level var/const choice). Without this skip,
            # `clear fmt` strips MUTABLE here and the next build fails
            # the param's mutability check at the call site.
            next if info.respond_to?(:mutated) && info.mutated

            emit_mutable_unused_finding!(info.reg, name)
          end
        end
        nil
      end

      sig { params(node: T.nilable(AST::MatchStatement)).returns(T::Array[AST::DeferredDrop]) }
      def collect_scope_drops(node: nil)
        T.bind(self, SemanticAnnotator)

        drops = T.let([], T::Array[AST::DeferredDrop])
        current_scope.owned_entries.each do |name, info|
          next unless ownership_graph.live?(name)
          classify_ownership!(info) unless info.ownership_kind
          case info.ownership_kind
          when :resource
            drops << deferred_drop_for(name, info, resource: true)
            og_drop(name)
          when :affine
            t = Type.new(info.type)
            if node && t.single_future?
              error!(node, :PROMISE_NOT_CONSUMED, name: name)
            end
            drops << deferred_drop_for(name, info)
            og_drop(name)
          end
        end
        drops
      end

      sig { params(name: String, info: SymbolEntry, resource: T::Boolean).returns(AST::DeferredDrop) }
      def deferred_drop_for(name, info, resource: false)
        T.bind(self, SemanticAnnotator)

        AST::DeferredDrop.new(
          name: name,
          type: Type.from_node!(info.type, context: "deferred drop type"),
          resource: resource,
        )
      end

      # Walk a GetField/GetIndex chain and flag any GetIndex nodes as needing
      # mutable pointer access.  Called when the chain leads to mutation
      # (field assignment, mutating method call, etc.) so the transpiler can
      # emit `.items[idx]` instead of by-value `getAt(list, idx)`.
      sig { params(node: AST::Node).void }
      def mark_chain_needs_mut_ref!(node)
        T.bind(self, SemanticAnnotator)

        curr = T.let(node, T.nilable(AST::Node))
        while curr
          curr.needs_mut_ref = true if curr.is_a?(AST::GetIndex)
          curr = curr.respond_to?(:target) ? T.unsafe(curr).target : nil
        end
      end

      sig { params(node: T.any(AST::Node, String, Symbol)).returns(T::Array[Symbol]) }
      def get_path_to_root(node)
        T.bind(self, SemanticAnnotator)

        path = []
        curr = T.let(node, T.untyped)
        while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex) || curr.is_a?(AST::OptionalUnwrap)
          path.unshift(curr.field.to_sym) if curr.is_a?(AST::GetField)
          path.unshift(:*) if curr.is_a?(AST::GetIndex)
          curr = curr.target
        end
        return [] unless curr.is_a?(AST::Identifier)
        path.unshift(curr.name.to_sym)
        path
      end

      # A tied-lifetime value cannot be stored where it would outlive any
      # source. Nil-lifetime bindings flow through unchanged.
      sig { params(assign_node: AST::Assignment).void }
      def verify_tied_assignment!(assign_node)
        T.bind(self, SemanticAnnotator)

        val = assign_node.value
        sym = val.respond_to?(:symbol) ? val.symbol : nil
        sources = lifetime_sources_for_value(val)
        return if sources.empty?
        return if sym && sources == [sym]   # :current_scope is its own check path

        dest_depth = dest_scope_depth_for_target(assign_node.name)
        return if dest_depth.nil?

        # CLEAR scopes are LIFO-stacked: shallower depth = scope lives
        # LONGER. The destination outlives the source iff
        # `dest_depth < source.scope_depth`, which means storing a
        # tied value would let it outlive its anchor.
        sources.each do |source|
          next if source.scope_depth.nil?
          next unless dest_depth < T.must(source.scope_depth)
          source_name = lookup_source_name(source) || "(unnamed)"
          msg = "Lifetime Error: cannot store value tied to '#{source_name}' " \
                "(declared at scope depth #{source.scope_depth}) into a destination " \
                "at scope depth #{dest_depth} -- the destination outlives the source. " \
                "Move the destination into the same scope, or COPY the value."
          # Atomic sources get a migration fix; non-atomic tied sources do not
          # have an equivalent @shared:locked repair.
          fix = build_atomic_escape_migration_fix(source, source_name)
          if fix
            fixable!(assign_node, code: :ATOMIC_ESCAPE_ASSIGN, detail: msg,
                     category: :escape,
                     level: :error, fixes: [fix], raise_in_collector: true)
          else
            error!(assign_node, :ATOMIC_ESCAPE_ASSIGN, detail: msg)
          end
        end
      end

      # Returning a tied-lifetime value is legal only when the function declares
      # a matching `RETURNS <source>:T`; wildcard accepts any source.
      sig { params(return_node: AST::ReturnNode).void }
      def verify_tied_return!(return_node)
        T.bind(self, SemanticAnnotator)

        val = return_node.value
        return unless val.is_a?(AST::Identifier)
        sym = val.symbol
        return unless sym
        sources = sym.lifetime_sources
        return if sources.empty?
        # `:current_scope` lifetime (lifetime_sources == [self]) means the
        # binding is anchored to its own declaring scope. Returning it is
        # always invalid — covered by the existing non_escaping check.
        return if sources == [sym]

        fn_node = function_node_for(current_fn_ctx&.name)
        rl = fn_node&.return_lifetime
        return if rl == :wildcard
        declared = rl || []

        declared_names = declared.flat_map do |n|
          path = get_path_to_root(n)
          path.empty? ? [] : [T.must(path.first).to_s]
        end

        source_names = sources.map do |s|
          # Find the binding name by comparing the source entry with visible
          # scope entries by identity.
          lookup_source_name(s)
        end.compact

        matched = source_names.any? { |n| declared_names.include?(n) }
        return if matched

        sources_msg = source_names.empty? ? "(unnamed source)" :
                                            source_names.join(", ")
        declared_msg = declared_names.empty? ? "no `RETURNS <name>:T`" :
                                               "`RETURNS #{declared_names.join(', ')}:T`"
        msg = "Lifetime Error: cannot RETURN a value whose lifetime is tied " \
              "to #{sources_msg}, because the enclosing function declares " \
              "#{declared_msg} -- the caller's scope outlives the source. " \
              "Either declare the function as `RETURNS #{source_names.first}:T` " \
              "(propagates the lifetime to the caller), or COPY the value " \
              "before returning it."

        # Pick the first atomic source we can repair; otherwise use the plain
        # lifetime error path.
        atomic_fix = T.let(nil, T.untyped)
        sources.each_with_index do |source, idx|
          name = source_names[idx] || lookup_source_name(source) || "(unnamed)"
          f = build_atomic_escape_migration_fix(source, name)
          if f
            atomic_fix = f
            break
          end
        end

        if atomic_fix
          fixable!(return_node, code: :ATOMIC_ESCAPE_RETURN, detail: msg,
                   category: :escape,
                   level: :error, fixes: [atomic_fix], raise_in_collector: true)
        else
          error!(return_node, :ATOMIC_ESCAPE_RETURN, detail: msg)
        end
      end

        # Look up the binding name of a SymbolEntry by scanning visible scope entries.
      # Returns the String name or nil if not found.
      sig { params(sym: SymbolEntry).returns(T.nilable(String)) }
      def lookup_source_name(sym)
        T.bind(self, SemanticAnnotator)

        sc = sym.scope
        if sc
          sc.visible_entries.each do |name, entry|
            return name if entry.equal?(sym)
          end
        end
        # Param symbols may have been refreshed via Scope.live_param_syms;
        # fall back to a function-level scan.
        function_node_map.each_value do |fn|
          next unless fn.respond_to?(:params)
          fn.params.each do |p|
            return p.name.to_s if p.symbol.equal?(sym)
          end
        end
        nil
      end

      sig { params(val_node: AST::Node).returns(T::Array[SymbolEntry]) }
      def lifetime_sources_for_value(val_node)
        T.bind(self, SemanticAnnotator)

        sources = T.let([], T::Array[SymbolEntry])
        if val_node.respond_to?(:symbol)
          sym = val_node.symbol
          sources.concat(sym.lifetime_sources) if sym
        end
        sources.concat(collect_bg_sources_in_expr(val_node))
        sources.uniq
      end

      # Convenience: the escape destination's effective scope depth.
      # For a struct-field assign `a.field = v`, depth = a's binding scope.
      # For a method receiver (`list.append(v)`), depth = list's binding scope.
      # For a free local in current scope, depth = current scope.
      sig { params(target_node: AST::Node).returns(T.nilable(Integer)) }
      def dest_scope_depth_for_target(target_node)
        T.bind(self, SemanticAnnotator)

        if target_node.is_a?(AST::Identifier)
          sym = target_node.symbol
          sym ||= lookup_scope_for(target_node.name)&.resolve_entry(target_node.name)
          return sym&.scope_depth
        end
        if target_node.is_a?(AST::GetField) || target_node.is_a?(AST::GetIndex)
          return dest_scope_depth_for_target(target_node.target)
        end
        nil
      end

      # A BG handle's lifetime is bounded by the shortest-lived captured
      # atomic/locked/multiowned/local source.
      #
      # Skipped sources (no lifetime contribution):
      #   - @shared (Arc): refcounted; the inner data lives as long as
      #     any reference exists, so the BG handle isn't bounded by the
      #     declaring scope of the original Arc binding.
      #   - @local: BG is auto-pinned, so the BG and the @local binding
      #     run on the same scheduler. The capture is by-pointer; the
      #     captured pointer's validity IS bounded by the @local
      #     binding's scope, so we include it.
      #   - Captures whose binding has no SymbolEntry on capture_symbols
      #     (e.g. observable view aliases); those are already errored at
      #     visit_BgBlock via has_non_escaping_capture.
      sig { params(decl_node: T.any(AST::VarDecl, AST::BindExpr)).void }
      def stamp_bg_handle_lifetime!(decl_node)
        T.bind(self, SemanticAnnotator)

        sources = collect_bg_sources_in_expr(decl_node.value).uniq
        return if sources.empty?
        sym = decl_node.symbol
        return unless sym
        sym.lifetime = SymbolEntry.tied_lifetime(sources)
      end

      # Single-writer stamp: this binding's heap-bearing contents were already
      # materialized for heap storage at bind time.
      sig { params(decl_node: T.any(AST::VarDecl, AST::BindExpr)).void }
      def stamp_init_contents_heap!(decl_node)
        T.bind(self, SemanticAnnotator)

        sym = decl_node.symbol
        return unless sym
        init = decl_node.respond_to?(:value) ? decl_node.value : nil
        sym.mark_init_contents_heap! if init_value_contents_heap?(init)
      end

      sig { params(init: T.nilable(AST::Node)).returns(T::Boolean) }
      def init_value_contents_heap?(init)
        T.bind(self, SemanticAnnotator)

        return false unless init
        case init
        when AST::StructLit, AST::UnionVariantLit
          init.fields.all? do |_, fval|
            next true unless fval
            fti = Type.from_node!(fval, context: "heap init field")
            next true unless fti.string? || fti.collection?
            fval.is_a?(AST::Locatable) && fval.heap_storage?
          end
        when AST::FuncCall, AST::MethodCall
          init.is_a?(AST::Locatable) && init.heap_storage?
        when AST::Identifier
          !!init.symbol&.init_contents_heap
        when AST::CopyNode, AST::CloneNode
          true
        when AST::Cast
          init_value_contents_heap?(init.value)
        when AST::IfStatement
          then_tail = (init.then_branch || []).last
          else_tail = (init.else_branch || []).last
          tails = [then_tail, else_tail].compact
          tails.size == 2 && tails.all? { |t| init_value_contents_heap?(t) }
        when AST::MatchStatement
          cases = init.cases.map { |c| c.body.last }.compact
          default_tail = init.default_case&.last
          tails = cases + (default_tail ? [default_tail] : [])
          tails.any? && tails.all? { |t| init_value_contents_heap?(t) }
        else
          false
        end
      end

      # Walk an expression tree to find every BgBlock / BgStreamBlock and
      # union their lifetime-bound capture sources. Without this walk, a
      # BG buried inside a container literal escapes its captures' scope
      # when the surrounding binding is RETURNed / stored / passed (real
      # UAF, fuzz finding `lifetimed_return` store_in_field cell).
      #
      # Default-recurse: every AST node-with-sub-expressions is walked
      # generically via Struct.members. Opt-OUT only for the small finite
      # set of AST classes whose lifetime is determined by symbol /
      # return-type rather than by sub-expression containment (see
      # SemanticAnnotator::BG_SOURCE_OPAQUE_AST_NODES). New AST container types added later
      # propagate for free; missing-recursion bugs surface as compile-time
      # over-rejection rather than silent UAF.
      BgSourceWalkValue = T.type_alias do
        T.any(
          AST::Node,
          T::Array[BasicObject],
          T::Hash[BasicObject, BasicObject],
          Struct,
          T::Struct,
          NilClass,
          String,
          Symbol,
          Integer,
          Float,
          TrueClass,
          FalseClass,
          Type,
          SymbolEntry,
          Proc,
        )
      end

      sig { params(expr: BgSourceWalkValue).returns(T::Array[SymbolEntry]) }
      def collect_bg_sources_in_expr(expr)
        T.bind(self, SemanticAnnotator)

        return bg_sources_for_block(expr) if expr.is_a?(AST::BgBlock) || expr.is_a?(AST::BgStreamBlock)
        return [] if SemanticAnnotator::BG_SOURCE_OPAQUE_AST_NODES.include?(expr.class)
        return [] unless expr.is_a?(Struct)
        expr.members.flat_map do |m|
          v = expr[m]
          collect_bg_sources_walk(v)
        end
      end

      sig { params(v: BgSourceWalkValue).returns(T::Array[SymbolEntry]) }
      def collect_bg_sources_walk(v)
        T.bind(self, SemanticAnnotator)

        case v
        when Array then v.flat_map { |x| collect_bg_sources_walk(x) }
        when Hash  then v.values.flat_map { |x| collect_bg_sources_walk(x) }
        when Struct then collect_bg_sources_in_expr(v)
        else []
        end
      end

      sig { params(expr: BgSourceWalkValue).returns(T::Array[SymbolEntry]) }
      def bg_sources_for_block(expr)
        T.bind(self, SemanticAnnotator)

        analysis = expr.respond_to?(:capture_analysis) ? T.unsafe(expr).capture_analysis : nil
        return [] unless analysis && analysis.respond_to?(:capture_symbols)
        bg_lifetime_sources(analysis)
      end

      # Walk the capture-analysis SymbolEntries and pick the ones whose
      # storage / sync makes them lifetime-bounded sources for the BG
      # handle. See stamp_bg_handle_lifetime! for the criteria.
      #
      # A capture is a SOURCE (binds the BG handle's lifetime to the
      # capture's scope) when its underlying memory cannot independently
      # outlive the binding. The bound conditions are explicit because
      # each storage/sync combo has different reach semantics; the
      # critical previously-missing case is plain `@local` (or unannotated)
      # locals — captured by reference into the BG's fiber frame, so the
      # source binding's death = pointer-into-freed-memory.
      sig { params(analysis: CapabilityHelper::CaptureAnalysis).returns(T::Array[SymbolEntry]) }
      def bg_lifetime_sources(analysis)
        T.bind(self, SemanticAnnotator)

        analysis.capture_symbols.each_value.reject { |info|
          info && bg_capture_independent?(info)
        }.compact
      end

      # Default-deny inverse of the old explicit-include-list. A capture is
      # INDEPENDENT (free to outlive its source) only via one of the
      # explicit escape hatches encoded above; everything else binds the
      # BG handle's lifetime by default. New storage/sync/layout
      # combinations land here as compile-time RETURN-rejections, not
      # silent UAFs.
      sig { params(info: SymbolEntry).returns(T::Boolean) }
      def bg_capture_independent?(info)
        T.bind(self, SemanticAnnotator)

        # Arc-only (Group 1: @shared without inner sync) — refcounted, escapable.
        return true if SemanticAnnotator::STORAGE_OUTLIVES_DECLARING_SCOPE.include?(info.storage) && info.sync.nil?
        # @indirect:atomic — heap-pinned AtomicPtr cell with own lifetime
        # mechanism (M3.5 promotion).
        return true if info.atomic_ptr?
        # Any sync wrapper (Group 1 sync sigils — atomic, locked,
        # write_locked, local, versioned, always_mutable) captures the
        # binding by reference into the fiber frame; lifetime-bound
        # regardless of inner type. Excluded: pure data-access modes
        # listed in SemanticAnnotator::SYNC_DOES_NOT_BIND_CAPTURE.
        return false if info.sync && !SemanticAnnotator::SYNC_DOES_NOT_BIND_CAPTURE.include?(info.sync)
        # Rc storage: bound to declaring scope (refcount-shared but
        # captures borrow without bumping the count).
        return false if info.storage == :multiowned
        # No sync wrapper, no Rc: the TYPE's inherent escape class
        # decides. :value / :slice_rodata = value-copy = escapable.
        # Authoritative source: Type#escape_class.
        ti = info.respond_to?(:type) ? info.type : nil
        return false unless ti
        value_copy_capture?(ti)
      end

      # Thin wrapper that hands the annotator's schema-lookup closure to
      # `Type#bg_capture_is_value_copy?`. The Type predicate needs schema
      # access to resolve enum / union-without-heap / all-Copy struct
      # cases via lookup_type_schema; structs are always rejected (ref
      # capture into the fiber frame, even if every field is Copy).
      sig { params(t: Type).returns(T::Boolean) }
      def value_copy_capture?(t)
        T.bind(self, SemanticAnnotator)

        t.bg_capture_is_value_copy? { |name| lookup_type_schema(name) }
      end

      # Produce dotted-path lifetime roots. Wildcard and nil return [] because
      # there is no source-restricted path the return value must match.
      sig { params(func_node: AST::FunctionDef).returns(T::Array[T.any(String, Symbol)]) }
      def get_lifetime_paths(func_node)
        T.bind(self, SemanticAnnotator)

        rl = func_node.return_lifetime
        return [] if rl.nil?
        return [:wildcard] if rl == :wildcard
        sources = rl.is_a?(Array) ? rl : [rl]
        sources.filter_map do |source|
          path = get_path_to_root(source)
          path.join(".") unless path.empty?
        end
      end

      # Backward-compat shim: legacy single-binding callers got a single
      # string. Returns nil for multi-source / wildcard / no-lifetime
      # cases, matching the old contract for those shapes.
      sig { params(func_node: AST::FunctionDef).returns(T.nilable(String)) }
      def get_lifetime_path(func_node)
        T.bind(self, SemanticAnnotator)

        paths = get_lifetime_paths(func_node)
        return nil if paths.size != 1 || paths.first == :wildcard
        first = paths.first
        first.is_a?(String) ? first : nil
      end

      # Walk through GetField/GetIndex chains to find the root Identifier name.
      sig { params(node: T.nilable(AST::Node)).returns(T.nilable(String)) }
      def root_variable_name(node)
        T.bind(self, SemanticAnnotator)

        curr = T.let(node, T.nilable(AST::Node))
        while curr
          return curr.name if curr.is_a?(AST::Identifier)
          curr = if curr.respond_to?(:target)
                   T.unsafe(curr).target
                 elsif curr.respond_to?(:object)
                   T.unsafe(curr).object
                 else
                   nil
                 end
        end
        nil
      end

      # ── Ownership Graph Operations ─────────────────────────────────

      # Determine which allocator cleanup should use for this binding.
      # Sets provenance on the type_info; cleanup_alloc is now derived from provenance.
      sig { params(node: T.any(AST::VarDecl, AST::BindExpr)).returns(T.nilable(Symbol)) }
      def set_cleanup_alloc!(node)
        T.bind(self, SemanticAnnotator)

        ti = node.full_type!(context: "cleanup binding")
        return unless ti

        # Check if value comes from a stdlib function with explicit metadata
        val = node.value
        if val && (val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall))
          matched_def = val.matched_stdlib_def
          if matched_def
            # Borrow returns (lifetime:) need no cleanup -- the caller owns the data
            unless matched_def.intrinsic_lifetime.empty?
              val.storage = :borrow if val.respond_to?(:storage=)
              node.storage = :borrow if node.respond_to?(:storage=)
              return
            end
            ret_alloc = matched_def.return_alloc
            # For allocating methods without explicit return_alloc, the method's
            # alloc IS the return alloc (e.g. map.values() on sharded maps).
            ret_alloc ||= matched_def.intrinsic_alloc(IntrinsicAllocationKind::Alloc) if matched_def.emits_allocating?
            if ret_alloc
              if [:heap, :frame].include?(ret_alloc)
                val.storage = ret_alloc if val.respond_to?(:storage=)
              end
              return
            end
          end
        end

        alloc = ti.cleanup_allocator(->(name) { lookup_type_schema(name) })
        # Propagate provenance: prefer value's provenance, then computed alloc.
        val_ti = val.is_a?(AST::Locatable) ? val.full_type!(context: "cleanup value provenance") : nil
        val_ti = val_ti.is_a?(Type) ? val_ti : nil
        ti.apply_cleanup_placement!(value_type: val_ti, alloc: alloc)
        alloc
      end

      sig { params(name: String, node: T.nilable(AST::Node), type_info: Type::TypeInput).returns(T.nilable(T::Set[String])) }
      def og_declare(name, node, type_info)
        T.bind(self, SemanticAnnotator)

        entry = current_scope.resolve_entry(name) rescue nil
        kind = classify_og_kind(type_info, sync: entry&.sync)
        ti = type_info.is_a?(Type) ? type_info : Type.new(type_info)
        ownership_graph.declare(name, kind: kind, type_info: ti,
                    scope_depth: ownership_graph.scope_depth, line: node && node.respond_to?(:line) ? node.line : 0)
      end

      sig { params(node: AST::Node).returns(T::Boolean) }
      def share_consumes_source?(node)
        T.bind(self, SemanticAnnotator)

        return false if node.is_a?(AST::CopyNode)

        ti = node.full_type!(context: "share consume source")
        ti = Type.new(ti) if ti && !ti.is_a?(Type)
        return false if ti.is_a?(Type) && ti.shared?

        true
      end

      # Mark an identifier as moved if its type is non-Copy.
      # Skips generic type params (can't determine copyability at annotation time).
      # Skips when the binding is already marked moved with a more-specific
      # action (e.g., `:give` set by visit_GiveNode) — overwriting it with
      # `:move` would destroy the action info that the
      # USE_OF_MOVED_VALUE diagnostic uses to phrase "GAVE/TOOK/etc.".
      #
      # `consumer_param_type` is recorded on the OG node at TAKES sites so
      # the USE_OF_MOVED_VALUE fix-dropdown can skip suggesting an
      # `@shared` / `@multiowned` upgrade when the consumer's parameter
      # is a plain affine type that won't accept a refcounted handle.
      sig { params(node: AST::Node, action: Symbol, consumer_param_type: T.nilable(Type)).returns(T.nilable(T::Boolean)) }
      def move_if_not_copyable!(node, action: :move, consumer_param_type: nil)
        T.bind(self, SemanticAnnotator)

        return unless node.is_a?(AST::Identifier)
        vt = node.full_type!(context: "move candidate")
        return if current_function_type_param?(vt.resolved)
        return if vt.implicitly_copyable? { |t| lookup_type_schema(t) }
        existing = ownership_graph.nodes[node.name]
        if existing&.specific_move_action?
          # An earlier visitor (typically visit_GiveNode) already stamped
          # the move site with a more-specific action like `:give`. Don't
          # overwrite the action — but DO backfill the consumer's
          # parameter type when the call-arg loop has it and the earlier
          # visitor didn't, so the use-after-move fix-dropdown can still
          # filter `@shared` / `@multiowned` upgrades that won't help.
          if consumer_param_type && existing.move_consumer_param_type.nil?
            existing.move_consumer_param_type = consumer_param_type
          end
          node.was_moved = true
          return
        end
        og_set_moved(node.name, at_token: node.token, action: action, consumer_param_type: consumer_param_type)
        node.was_moved = true
      end

      sig { params(node: AST::Node, action: Symbol, consumer_param_type: T.nilable(Type)).returns(T.nilable(T::Boolean)) }
      def move_if_takes_ownership!(node, action: :takes, consumer_param_type: nil)
        T.bind(self, SemanticAnnotator)

        return unless node.is_a?(AST::Identifier)
        vt = node.full_type!(context: "TAKES ownership candidate")
        return if current_function_type_param?(vt.resolved)
        return if vt.primitive? || vt.id_handle?

        existing = ownership_graph.nodes[node.name]
        if existing&.specific_move_action?
          existing.move_consumer_param_type = consumer_param_type if consumer_param_type && existing.move_consumer_param_type.nil?
          node.was_moved = true
          return
        end
        og_set_moved(node.name, at_token: node.token, action: action, consumer_param_type: consumer_param_type)
        node.was_moved = true
      end

      # Reject storing a borrowed value into an owned container (struct, union, TAKES param).
      # Borrows can't outlive the scope they reference. Use COPY for owned data.
      sig { params(val_node: AST::Node, container_desc: String).returns(NilClass) }
      def reject_borrowed_value!(val_node, container_desc)
        T.bind(self, SemanticAnnotator)

        borrowed_name = nil
        if val_node.is_a?(AST::GetIndex)
          borrowed_name = "#{root_variable_name(val_node)}[index]"
        elsif val_node.is_a?(AST::Identifier) && ownership_graph[val_node.name]&.kind == :borrowed
          borrowed_name = val_node.name
        end
        return unless borrowed_name
        vti = val_node.full_type!(context: "borrowed container value")
        return if vti&.primitive?
        return if vti&.generic_instance?
        # Skip generic type parameters - can't determine borrowability at annotation time.
        return if current_function_type_param?(vti&.resolved)
        has_pointer = vti&.heap_ptr?
        return if !has_pointer && !vti&.struct?
        error!(val_node, :STORE_BORROWED_INTO_CONTAINER, name: borrowed_name, container: container_desc)
      end

      sig { params(type_info: Type::TypeInput, sync: T.nilable(Symbol)).returns(Symbol) }
      def classify_og_kind(type_info, sync: nil)
        T.bind(self, SemanticAnnotator)

        t = Type.new(type_info)
        if t.multiowned? || t.shared?
          :rc
        elsif sync
          :sync
        elsif t.implicitly_copyable? { |name| lookup_type_schema(name) }
          :value
        else
          :affine
        end
      end

      private :bg_capture_independent?,
        :collect_bg_sources_walk,
        :handle_assignment_path_move!,
        :reject_borrowed_index_assignment_move!
      private :bg_lifetime_sources
  private :bg_sources_for_block
  private :classify_og_kind
  private :collect_bg_sources_in_expr
  private :declare_assignment_graph_path!
  private :dest_scope_depth_for_target
  private :get_lifetime_paths
  private :get_path_to_root
  private :handle_assignment_identifier_move!
  private :init_value_contents_heap?
  private :reject_scoped_assignment_move!
  private :resolve_borrow_source
  private :share_consumes_source?
  private :value_copy_capture?

end
  end
end
