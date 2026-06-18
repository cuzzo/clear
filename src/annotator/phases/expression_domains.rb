# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/schemas"
require_relative "../helpers/function_signature"
require_relative "../helpers/with_match_check"

module Annotator
  module Phases
    module ExpressionDomains
      extend T::Sig

      sig { params(node: AST::FuncCall).void }
      def visit_FuncCall(node)
        T.bind(self, SemanticAnnotator)

        # Struct literal args are temporary call arguments; rodata strings are
        # valid for the call lifetime and are copied by the callee if needed.
        node.args.each { |arg| arg.instance_variable_set(:@is_call_arg, true) if arg.is_a?(AST::StructLit) }
        node.args.each { |arg| annotate_call_argument!(node, arg) }

        if node.name == "native_call"
          stamp_type!(node, :Any)
          return
        end

        resolve_call(node, node.args)
        record_predicate_call_site!(node)
        record_named_call_site!(node)
        record_held_lock_call_site!(node)
        nil
      end

      sig { params(node: AST::MethodCall).void }
      def visit_MethodCall(node)
        T.bind(self, SemanticAnnotator)

        visit(node.object)
        node.args.each { |arg| visit(arg) }

        if resolve_collection_method(node)
          record_predicate_call_site!(node)
          return
        end

        return if resolve_extern_method_call!(node)
        return if resolve_intrinsic_method_call!(node)

        # Fall through to UFCS: obj.method(args) -> method(obj, args).
        resolve_call(node, [node.object] + node.args)
        record_predicate_call_site!(node)
        record_call_site(node.name) if node.name.is_a?(String)
      end

      sig { params(node: AST::StaticCall).void }
      def visit_StaticCall(node)
        T.bind(self, SemanticAnnotator)

        node.args.each { |arg| visit(arg) }

        # `File` in `File::open(...)` is a TYPE reference, not a runtime
        # value. The codebase's established marker for a type-position
        # identifier is :Type (cf. comptime type args in function_analysis).
        stamp_type!(node.type_name, Type.new(:Type))

        type_name = node.type_name.name.to_sym
        schema = lookup_type_schema(type_name)

        unless schema
          error!(node, :STATIC_UNKNOWN_TYPE, type: type_name)
          return
        end

        unless schema.kind == :resource
          error!(node, :STATIC_NOT_RESOURCE, type: type_name)
        end

        static_methods = schema.static_methods || {}
        method_def = FunctionSignature.unwrap(IntrinsicRegistry.lookup(static_methods, T.unsafe(node).method_name))

        unless method_def
          available = static_methods.keys.join(", ")
          available = "(none)" if available.empty?
          method_tok = node.type_name.token
          if method_tok
            anchor = anchor_at(
              method_tok.line,
              method_tok.column + node.type_name.name.to_s.length + 2
            )
            emit_typo_suggestion!(
              anchor, node.method_name, static_methods.keys,
              "Type Error: No static method '#{node.method_name}' on '#{type_name}'. Available: #{available}.",
              "static method of #{type_name}",
              category: :type, cascade: true
            )
          else
            error!(node, :STATIC_UNKNOWN_METHOD, method: node.method_name, type: type_name, available: available)
          end
          return
        end

        expected_args = method_def.intrinsic_arg_specs
        if node.args.length != expected_args.length
          error!(node, :STATIC_ARITY, type: type_name, method: node.method_name, expected: expected_args.length, got: node.args.length)
        end

        node.args.zip(expected_args).each_with_index do |(arg, expected), i|
          next if expected && intrinsic_arg_matches?(expected, arg)

          actual = arg.resolved_type
          next if actual == :Any

          error!(node, :STATIC_ARG_TYPE, index: i + 1, type: type_name, method: node.method_name, expected: expected&.type || :Any, got: actual)
        end

        node.zig_pattern = method_def.intrinsic_pattern
        stamp_type!(node, method_def.return_def.resolve(nil, node.args, self))
        node.matched_stdlib_def = method_def
        node.matched_signature = method_def if node.respond_to?(:matched_signature=)
        method_allocates = method_def.emits_allocating?
        node.stdlib_allocates = method_allocates
        node.mutates_receiver = method_def.mutates_receiver?
        node.can_fail = node.can_fail || method_def.can_fail
        node.error_kind = method_def.intrinsic_error_kind
        node.error_type = method_def.intrinsic_error_type
        current_fn_ctx&.record_alloc_use! if method_allocates || method_def.can_fail
      end

      sig { params(node: T.any(AST::FuncCall, AST::MethodCall), args: T::Array[AST::Node], matched_def: T.nilable(FunctionSignature)).returns(T.nilable(Type)) }
      def visit_IntrinsicFunc(node, args, matched_def: nil)
        T.bind(self, SemanticAnnotator)

        definitions = IntrinsicRegistry.overloads(STD_LIB, node.name)

        matched_def ||= find_matching_intrinsic(definitions, args)

        unless matched_def
          sigs = definitions.map(&:intrinsic_args_label).join(" or ")
          arg_types = args.map { |arg| arg.resolved_type }.join(", ")
          error!(node, :INTRINSIC_NO_OVERLOAD, name: node.name, args: arg_types, candidates: sigs)
          return
        end

        unless matched_def.intrinsic_varargs?
          verify_function_signature!(node, matched_def.intrinsic_call_validation_signature, args)
        end

        reject_when = matched_def.intrinsic_reject_when
        first_arg = args.first
        if reject_when && first_arg && reject_arg_type_matches?(first_arg, reject_when)
          reason = matched_def.intrinsic_reject_error ||
                   "#{node.name}() is not valid for #{first_arg.resolved_type}"
          error!(node, :INTRINSIC_REJECTED, detail: reason)
          return
        end

        stamp_type!(node, matched_def.return_def.resolve(nil, args, self))

        node.zig_pattern = matched_def.intrinsic_pattern
        node.matched_stdlib_def = matched_def
        node.matched_signature = matched_def if node.respond_to?(:matched_signature=)
        matched_allocates = matched_def.emits_allocating?
        node.stdlib_allocates = matched_allocates
        node.mutates_receiver = matched_def.mutates_receiver?
        node.can_fail = node.can_fail || matched_def.can_fail || matched_allocates
        node.error_kind = matched_def.intrinsic_error_kind if matched_def.intrinsic_error_kind
        node.error_type = matched_def.intrinsic_error_type if matched_def.intrinsic_error_type
        current_fn_ctx&.record_alloc_use! if matched_allocates || matched_def.can_fail || matched_def.needs_rt
        record_effect(EffectTracker::SUSPENDS) if matched_def.intrinsic_suspends?

        if matched_def.mutates_receiver? && node.is_a?(AST::MethodCall)
          mark_chain_needs_mut_ref!(node.object)
          root = chain_root_name(node.object)
          mark_var_mutated(root) if root
        end

        narrow_collection_type!(matched_def, args)
        nil
      end

      sig { params(parent: AST::FuncCall, arg: AST::Node).void }
      def annotate_call_argument!(parent, arg)
        T.bind(self, SemanticAnnotator)

        visit(arg)
        promote_to_expr_if!(parent, arg) if arg.is_a?(AST::IfStatement)
        promote_to_expr_match!(parent, arg) if arg.is_a?(AST::MatchStatement)
      end
      private :annotate_call_argument!

      sig { params(node: AST::FuncCall).void }
      def record_named_call_site!(node)
        T.bind(self, SemanticAnnotator)
        return unless node.name.is_a?(String)

        record_call_site(node.name)
        return if node.args.empty?

        arg_family_sets = node.args.map { |arg| WithMatchCheck.family_of_arg_set(arg) }
        node.arg_families = arg_family_sets
        record_call_arg_families(node.name, arg_family_sets) if current_fn_ctx&.name

        sig = FunctionSignature.unwrap(semantic_root_scope.resolve_entry(node.name)&.type)
        if sig && sig.requires && !sig.requires.empty?
          node.collapsed_errors = collapse_errors_for_call(sig, node.args)
        end
      end
      private :record_named_call_site!

      sig { params(node: AST::FuncCall).void }
      def record_held_lock_call_site!(node)
        T.bind(self, SemanticAnnotator)
        held_lock_types = semantic_held_lock_types
        return if held_lock_types.empty?
        return unless semantic_function_nodes.key?(node.name)

        fn_name = current_fn_ctx&.name || "<top>"
        record_held_call!(fn_name, node.name, held_lock_types, node.token)
      end
      private :record_held_lock_call_site!

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_extern_method_call!(node)
        T.bind(self, SemanticAnnotator)

        obj_type = node.object.full_type!(context: "method receiver")
        return false unless obj_type

        resolved = obj_type.is_a?(Type) ? obj_type.resolved : obj_type.to_s.to_sym
        base = obj_type.is_a?(Type) && obj_type.generic_instance? ? obj_type.generic_base : resolved
        type_schema = lookup_type_schema(base)
        return false unless (Schemas.struct?(type_schema) || Schemas.resource?(type_schema)) && type_schema.methods&.key?(node.name)

        method_sig = type_schema.methods[node.name]
        node.extern_call = true
        node.extern_effects = method_sig.extern_effects if method_sig.extern_effects
        stamp_type!(node, method_sig.return_type)
        record_effect(EffectTracker::EXTERN)
        record_extern_method_alloc!(method_sig)
        record_predicate_call_site!(node)
        true
      end
      private :resolve_extern_method_call!

      sig { params(method_sig: FunctionSignature).void }
      def record_extern_method_alloc!(method_sig)
        T.bind(self, SemanticAnnotator)

        alloc_kind = method_sig.extern_effects&.dig(:alloc)
        fn_ctx = current_fn_ctx
        return unless alloc_kind && fn_ctx

        if alloc_kind == :heap
          fn_ctx.record_heap_use!
        else
          fn_ctx.record_frame_use!
        end
      end
      private :record_extern_method_alloc!

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_intrinsic_method_call!(node)
        T.bind(self, SemanticAnnotator)

        intrinsic_defs = STD_LIB[node.name]
        return false unless intrinsic_defs

        definitions = IntrinsicRegistry.overloads(STD_LIB, node.name)
        method_overloads = definitions.select { |definition| definition.intrinsic_contract.behavior.is_method }
        return false if method_overloads.empty?

        ufcs_args = [node.object] + node.args
        matched_def = find_matching_intrinsic(method_overloads, ufcs_args)
        return false unless matched_def

        visit_IntrinsicFunc(node, ufcs_args, matched_def: matched_def)
        record_predicate_call_site!(node)
        true
      end
      private :resolve_intrinsic_method_call!
    end
  end
end
