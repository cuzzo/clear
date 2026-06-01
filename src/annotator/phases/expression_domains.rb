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

      sig { params(node: AST::FuncCall).returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
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

      sig { params(node: AST::MethodCall).returns(T.nilable(T::Hash[Symbol, T::Boolean])) }
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

      sig { params(parent: AST::FuncCall, arg: T.untyped).void }
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

        sig = FunctionSignature.unwrap(semantic_root_scope.locals[node.name]&.type)
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
        node.instance_variable_set(:@extern_method, true)
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
        return unless alloc_kind && current_fn_ctx

        if alloc_kind == :heap
          current_fn_ctx.heap_count += 1
        else
          current_fn_ctx.frame_count += 1
        end
      end
      private :record_extern_method_alloc!

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_intrinsic_method_call!(node)
        T.bind(self, SemanticAnnotator)

        intrinsic_defs = STD_LIB[node.name]
        return false unless intrinsic_defs

        definitions = intrinsic_defs.is_a?(Hash) ? [intrinsic_defs] : intrinsic_defs
        method_overloads = definitions.select { |definition| definition[:is_method] }
        return false if method_overloads.empty?

        ufcs_args = [node.object] + node.args
        return false unless find_matching_intrinsic(method_overloads, ufcs_args)

        visit_IntrinsicFunc(node, ufcs_args)
        record_predicate_call_site!(node)
        true
      end
      private :resolve_intrinsic_method_call!
    end
  end
end
