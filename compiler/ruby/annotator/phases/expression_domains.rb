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
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        normalize_explicit_mutable_arguments!(node)
        node.args.each { |arg| annotate_call_argument!(node, arg) }

        if node.name == "native_call"
          stamp_type!(node, :Any)
          return
        end

        if resolve_user_protocol_function_call!(node)
          record_predicate_call_site!(node)
          record_named_call_site!(node)
          return
        end

        resolve_call(node, node.args)
        record_predicate_call_site!(node)
        record_named_call_site!(node)
        record_held_lock_call_site!(node)
        nil
      end

      sig { params(node: AST::FuncCall).returns(T::Boolean) }
      def resolve_user_protocol_function_call!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        return false if lookup_scope_for(node.name)

        matches = T.let([], T::Array[[AST::ProtocolDef, AST::ProtocolRequirement, Type, Integer]])
        node.args.each_with_index do |argument, index|
          receiver = argument.full_type!(context: "protocol function dispatch")
          user_protocol_names_for_receiver(receiver).each do |name|
            next if name == "Map"

            protocol = semantic_protocol(name)
            requirement = protocol&.requirements&.find do |candidate|
              !candidate.is_method && candidate.name == node.name &&
                candidate.params[index]&.type&.resolved == :Self
            end
            matches << [protocol, requirement, receiver, index] if protocol && requirement
          end
        end
        matches.uniq! { |protocol, requirement, _receiver| [protocol.name, requirement.name] }
        return false if matches.empty?
        if matches.length > 1
          error!(node, :GENERIC_PROTOCOL_FUNCTION_AMBIGUOUS,
            name: node.name, protocols: matches.map { |match| match.first.name }.join(", "))
        end

        protocol, requirement, receiver, receiver_index = T.must(matches.first)
        signature = protocol_requirement_signature(protocol, requirement, receiver)
        verify_function_signature!(node, signature, node.args)
        node.matched_signature = signature
        node.protocol_name = protocol.name
        node.protocol_operation = requirement.name.to_sym
        node.protocol_receiver_index = receiver_index
        stamp_resolved_call_result!(node, signature.return_type)
        record_effect(EffectTracker::REENTRANT) if signature.reentrant
        current_fn_ctx&.mark_runtime_used!
        true
      end
      private :resolve_user_protocol_function_call!

      sig { params(node: AST::MethodCall).void }
      def visit_MethodCall(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        normalize_explicit_mutable_arguments!(node)
        visit(node.object)
        node.args.each { |arg| visit(arg) }

        reject_legacy_foreign_slice_view!(node)
        reject_direct_observable_method_access!(node)

        if resolve_protocol_method_call!(node)
          return
        end

        if resolve_collection_method(node)
          validate_indirect_collection_insertion!(node)
          receiver_type = node.object.full_type!(context: "@node collection receiver")
          element_type = receiver_type.element_type
          if element_type&.node_reference? && ["append", "push", "insert"].include?(node.name) && node.args.any?
            value_arg = T.must(node.args.last)
            actual_type = value_arg.full_type!(context: "@node collection insertion")
            value_arg.coerced_type = element_type if !actual_type.node_reference? && element_type.accepts?(actual_type)
          end
          reject_mutating_borrowed_receiver!(node)
          record_predicate_call_site!(node)
          return
        end

        if resolve_extern_method_call!(node)
          reject_mutating_borrowed_receiver!(node)
          return
        end
        if resolve_inherent_method_call!(node)
          reject_mutating_borrowed_receiver!(node)
          return
        end
        if resolve_intrinsic_method_call!(node)
          validate_indirect_collection_insertion!(node)
          reject_mutating_borrowed_receiver!(node)
          return
        end

        if semantic_root_scope.resolve_entry(node.name)
          error!(node, :DOT_CALL_REQUIRES_METHOD, name: node.name)
        end
        error!(node, :UNKNOWN_INHERENT_METHOD,
          name: node.name, type: Type.surface_name(node.object.full_type!(context: "method receiver")))
      end

      sig { params(node: T.any(AST::FuncCall, AST::MethodCall, AST::StaticCall)).void }
      def normalize_explicit_mutable_arguments!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        node.args.each_with_index do |argument, index|
          next unless argument.is_a?(AST::MutableBorrow)

          node.mark_explicit_mutable_argument!(index, argument.token)
          node.args[index] = argument.target
        end
      end
      private :normalize_explicit_mutable_arguments!

      sig { params(node: AST::MutableBorrow).void }
      def visit_MutableBorrow(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        error!(node, :MUTABLE_MARKER_REQUIRES_CALL)
      end

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_protocol_method_call!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        receiver = node.object.full_type!(context: "protocol method receiver")
        return true if resolve_user_protocol_method_call!(node, receiver)
        return false unless map_requires_protocol_lowering?(receiver)
        require_generic_map_access_scope!(node.object, receiver)

        operation = {"put" => :put, "delete" => :delete, "contains?" => :contains,
                     "count" => :count, "length" => :count,
                     "empty?" => :empty, "any?" => :any}[node.name]
        unless operation
          error!(node, :GENERIC_MAP_METHOD_UNKNOWN,
            name: node.name, available: "put, delete, contains?, count, length, empty?, any?")
        end
        operation = T.must(operation)
        expected_arity = %i[count empty any].include?(operation) ? 0 : (operation == :put ? 2 : 1)
        if node.args.length != expected_arity
          error!(node, :GENERIC_MAP_METHOD_ARITY,
            name: node.name, expected: expected_arity, actual: node.args.length)
        end

        key_type = protocol_map_associated_type(receiver, :Key)
        value_type = protocol_map_associated_type(receiver, :Value)
        verify_generic_map_receiver_mutability!(node, receiver, operation)
        verify_protocol_method_argument!(node, 0, key_type) if expected_arity.positive?
        verify_protocol_method_argument!(node, 1, value_type) if operation == :put

        consume_generic_map_value!(T.must(node.args[1]), value_type) if operation == :put

        result = case operation
        when :contains, :empty, :any then Type.new(:Bool)
        when :count then Type.new(:Int64)
        else Type.new(:Void)
        end
        node.protocol_operation = operation
        stamp_type!(node, result)
        if operation == :put
          current_fn_ctx&.record_heap_use!
          current_fn_ctx&.record_alloc_use!
          record_effect(EffectTracker::HEAP)
          node.can_fail = true
        end
        true
      end
      private :resolve_protocol_method_call!

      sig { params(node: AST::MethodCall, receiver: Type, operation: Symbol).void }
      def verify_generic_map_receiver_mutability!(node, receiver, operation)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        mutates = %i[put delete].include?(operation)
        return unless mutates

        params = T.let([
          AST::Param.new(name: "receiver", type: receiver, required: true, mutable: true, takes: false)
        ], T::Array[AST::Param])
        node.args.each_with_index do |argument, index|
          params << AST::Param.new(
            name: "arg#{index + 1}",
            type: argument.full_type!(context: "generic map method argument"),
            required: true,
            mutable: false,
            takes: false,
          )
        end
        verify_function_signature!(node,
          FunctionSignature.new(params: params, return_type: Type.new(:Void)),
          [node.object] + node.args)
      end
      private :verify_generic_map_receiver_mutability!

      sig { params(node: AST::MethodCall, receiver: Type).returns(T::Boolean) }
      def resolve_user_protocol_method_call!(node, receiver)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        protocol_names = user_protocol_names_for_receiver(receiver)
        return false if protocol_names.empty?

        matches = protocol_names.filter_map do |name|
          protocol = semantic_protocol(name)
          requirement = protocol&.requirements&.find { |candidate| candidate.is_method && candidate.name == node.name }
          [protocol, requirement] if protocol && requirement
        end
        if matches.length > 1
          error!(node, :GENERIC_PROTOCOL_METHOD_AMBIGUOUS,
            name: node.name, protocols: matches.map { |match| match.first.name }.join(", "))
        end
        if matches.empty?
          available = protocol_names.flat_map do |name|
            semantic_protocol(name)&.requirements&.select(&:is_method)&.map(&:name) || []
          end.uniq.sort
          error!(node, :GENERIC_PROTOCOL_METHOD_UNKNOWN,
            name: node.name, protocols: protocol_names.join(" & "),
            available: available.empty? ? "none" : available.join(", "))
        end

        protocol, requirement = T.must(matches.first)
        signature = protocol_requirement_signature(protocol, requirement, receiver)
        verify_function_signature!(node, signature, [node.object] + node.args)
        node.matched_signature = signature
        node.protocol_name = protocol.name
        node.protocol_operation = requirement.name.to_sym
        stamp_resolved_call_result!(node, signature.return_type)
        record_effect(EffectTracker::REENTRANT) if signature.reentrant
        current_fn_ctx&.mark_runtime_used!
        record_predicate_call_site!(node)
        true
      end
      private :resolve_user_protocol_method_call!

      sig { params(receiver: Type).returns(T::Array[String]) }
      def user_protocol_names_for_receiver(receiver)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        bounded = generic_parameter_protocol_names(receiver.resolved).reject { |name| name == "Map" }
        return bounded unless bounded.empty?

        semantic_protocols.keys.select do |name|
          !conformance_match(name, receiver).nil?
        end
      end
      private :user_protocol_names_for_receiver

      sig do
        params(
          protocol: AST::ProtocolDef,
          requirement: AST::ProtocolRequirement,
          receiver: Type,
        ).returns(FunctionSignature)
      end
      def protocol_requirement_signature(protocol, requirement, receiver)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        substitutions = protocol.associated_types.each_with_object({Self: receiver}) do |associated, table|
          table[associated.name.to_sym] = Type.new(TypeProjectionExpression.new(
            owner: receiver.resolved,
            member: associated.name.to_sym,
            protocol: protocol.name.to_sym,
          ))
        end
        FunctionSignature.new(
          params: requirement.params.map do |param|
            AST::Param.new(
              name: param.name,
              type: apply_type_subst(param.type, substitutions),
              required: true,
              mutable: param.mutable,
              takes: param.takes,
            )
          end,
          return_type: apply_type_subst(requirement.return_type, substitutions),
          reentrant: requirement.effects_decl == :reentrant,
        )
      end
      private :protocol_requirement_signature

      sig { params(node: AST::MethodCall, index: Integer, expected: Type).void }
      def verify_protocol_method_argument!(node, index, expected)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        argument = T.must(node.args[index])
        actual = argument.full_type!(context: "Map protocol method argument")
        return if expected.accepts?(actual)

        error!(argument, :GENERIC_MAP_METHOD_ARGUMENT,
          name: node.name, position: index + 1,
          expected: Type.surface_name(expected), actual: Type.surface_name(actual))
      end
      private :verify_protocol_method_argument!

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_inherent_method_call!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        receiver_type = node.object.full_type!(context: "inherent method receiver")
        owner = receiver_type.generic_instance? ? receiver_type.generic_base : receiver_type.resolved
        schema = lookup_type_schema(owner)
        return false unless Schemas.struct?(schema)
        return false unless schema.methods.key?(node.name)

        source_name = node.name
        node.source_method_name = source_name
        node[:name] = ImplementationRegistration.function_name(owner.to_s, source_name)
        resolve_call(node, [node.object] + node.args)
        reject_mutating_borrowed_receiver!(node)
        record_predicate_call_site!(node)
        record_call_site(node.name)
        true
      end
      private :resolve_inherent_method_call!

      sig { params(node: AST::MethodCall).void }
      def reject_legacy_foreign_slice_view!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        receiver_type = node.object.full_type!(context: "foreign view receiver")
        return unless receiver_type.c_array_view? && node.name == "view"

        error!(node, :FOREIGN_VIEW_REQUIRES_WITH)
      end
      private :reject_legacy_foreign_slice_view!

      sig { params(node: AST::MethodCall).void }
      def reject_direct_observable_method_access!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        receiver_type = node.object.full_type!(context: "observable method receiver")
        return unless receiver_type.future? && receiver_type.observable?
        root = AST.root_identifier(node.object)
        if root.is_a?(AST::Identifier)
          emit_direct_view_access_finding!(node, root.name, permission: "VIEW")
        else
          error!(node, :DIRECT_VIEW_ACCESS_REQUIRES_WITH, name: "observable", permission: "VIEW")
        end
      end
      private :reject_direct_observable_method_access!

      sig { params(node: AST::MethodCall).void }
      def reject_mutating_borrowed_receiver!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return unless node.mutates_receiver

        root = root_variable_name(node.object)
        return unless root
        return if ownership_graph.can_write?(root)
        error!(node, :ASSIGN_WHILE_BORROWED, name: root)
      end

      sig { params(node: AST::StaticCall).void }
      def visit_StaticCall(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        normalize_explicit_mutable_arguments!(node)
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

        if Schemas.struct?(schema) && schema.static_methods.key?(node.method_name)
          resolve_inherent_static_call!(node, type_name)
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
        stamp_type!(node, method_def.return_def.resolve(nil, node.args))
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

      sig { params(node: AST::StaticCall, owner: Symbol).void }
      def resolve_inherent_static_call!(node, owner)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        call = AST::FuncCall.new(
          node.token,
          ImplementationRegistration.function_name(owner.to_s, node.method_name),
          node.args,
        )
        node.explicit_mutable_argument_tokens.each do |index, token|
          call.mark_explicit_mutable_argument!(index, token)
        end
        resolve_call(call, node.args)
        AST.copy_pipeline_rewrite_metadata!(call, node, include_call_metadata: true)
        node.inherent_call = call
        record_predicate_call_site!(call)
        record_named_call_site!(call)
      end
      private :resolve_inherent_static_call!

      sig { params(node: T.any(AST::FuncCall, AST::MethodCall), args: T::Array[AST::Node], matched_def: T.nilable(FunctionSignature)).returns(T.nilable(Type)) }
      def visit_IntrinsicFunc(node, args, matched_def: nil)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

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

        stamp_type!(node, matched_def.return_def.resolve(nil, args))

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
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        arg.is_a?(AST::StructLit) ? with_struct_literal_call_argument { visit(arg) } : visit(arg)
        promote_to_expr_if!(parent, arg) if arg.is_a?(AST::IfStatement)
        promote_to_expr_match!(parent, arg) if arg.is_a?(AST::MatchStatement)
      end
      private :annotate_call_argument!

      sig { params(node: AST::FuncCall).void }
      def record_named_call_site!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
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
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        held_lock_types = semantic_held_lock_types
        return if held_lock_types.empty?
        return unless semantic_function_nodes.key?(node.name)

        fn_name = current_fn_ctx&.name || "<top>"
        record_held_call!(fn_name, node.name, held_lock_types, node.token)
      end
      private :record_held_lock_call_site!

      sig { params(node: AST::MethodCall).returns(T::Boolean) }
      def resolve_extern_method_call!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        obj_type = node.object.full_type!(context: "method receiver")
        return false unless obj_type

        resolved = obj_type.is_a?(Type) ? obj_type.resolved : obj_type.to_s.to_sym
        base = obj_type.is_a?(Type) && obj_type.generic_instance? ? obj_type.generic_base : resolved
        type_schema = lookup_type_schema(base)
        return false unless (Schemas.struct?(type_schema) || Schemas.resource?(type_schema)) && type_schema.methods&.key?(node.name)

        method_sig = type_schema.methods[node.name]
        return false unless method_sig.extern
        node.extern_call = true
        node.extern_effects = method_sig.extern_effects if method_sig.extern_effects
        node.extern_source = method_sig.extern_source if node.respond_to?(:extern_source=)
        stamp_type!(node, method_sig.return_type)
        record_effect(EffectTracker::EXTERN)
        record_extern_method_alloc!(method_sig)
        record_predicate_call_site!(node)
        true
      end
      private :resolve_extern_method_call!

      sig { params(method_sig: FunctionSignature).void }
      def record_extern_method_alloc!(method_sig)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

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
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        intrinsic_defs = STD_LIB[node.name]
        return false unless intrinsic_defs

        definitions = IntrinsicRegistry.overloads(STD_LIB, node.name)
        method_overloads = definitions.select { |definition| definition.intrinsic_contract.behavior.is_method }
        return false if method_overloads.empty?

        receiver_type = node.object.full_type!(context: "intrinsic method receiver")
        implicit_safe_nav = receiver_type.optional? && node.object.respond_to?(:safe_nav_chain) &&
          node.object.safe_nav_chain == true
        resolution_receiver = node.object
        if implicit_safe_nav
          resolution_receiver = node.object.dup
          stamp_type!(resolution_receiver, T.must(receiver_type.wrapped_type))
        end

        ufcs_args = [resolution_receiver] + node.args
        matched_def = find_matching_intrinsic(method_overloads, ufcs_args)
        unless matched_def
          sigs = method_overloads.map(&:intrinsic_args_label).join(" or ")
          arg_types = ufcs_args.map { |arg| arg.resolved_type }.join(", ")
          error!(node, :INTRINSIC_NO_OVERLOAD,
            name: node.name, args: arg_types, candidates: sigs)
        end

        visit_IntrinsicFunc(node, ufcs_args, matched_def: matched_def)
        navigation = node.object.is_a?(AST::OptionalUnwrap) || implicit_safe_nav
        if navigation
          result = node.full_type!(context: "safe-navigation intrinsic method result")
          unless result.optional?
            stamp_type!(node, Type.optional_of(result))
            node.safe_nav_chain = true
          end
        end

        resolved_receiver_type = implicit_safe_nav ? T.must(receiver_type.wrapped_type) : receiver_type
        element_type = resolved_receiver_type.element_type
        if element_type&.node_reference? && ["append", "push", "insert"].include?(node.name) && node.args.any?
          value_arg = T.must(node.args.last)
          actual_type = value_arg.full_type!(context: "@node collection insertion")
          value_arg.coerced_type = element_type if !actual_type.node_reference? && element_type.accepts?(actual_type)
        end
        record_predicate_call_site!(node)
        true
      end
      private :resolve_intrinsic_method_call!
    end
  end
end
