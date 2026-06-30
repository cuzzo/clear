# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module Destructuring
      extend T::Sig

      class DestructureRhsFacts < T::Struct
        const :value_type, Type
        const :element_type, Type
      end

      sig { params(node: AST::DestructuringAssignment).void }
      def visit_DestructuringAssignment(node)
        T.bind(self, SemanticAnnotator)

        visit(node.value)
        rhs = destructure_rhs_facts(node)
        validate_destructure_shape!(node, rhs)
        validate_destructure_copyable!(node, rhs)

        node.targets.each_with_index do |target, index|
          if destructure_discard?(target)
            stamp_type!(target, rhs.element_type)
            next
          end

          target_value_type = destructure_value_type_at(node, index, rhs.element_type)
          if current_scope.entry?(target.name)
            finalize_destructure_assignment_target!(node, target, target_value_type)
          else
            finalize_destructure_declaration_target!(node, target, target_value_type)
          end
        end

        stamp_type!(node, :Void)
      end

      sig { params(target: AST::DestructureTarget).returns(T::Boolean) }
      def destructure_discard?(target)
        target.name == "_"
      end

      sig { params(node: AST::DestructuringAssignment).returns(DestructureRhsFacts) }
      def destructure_rhs_facts(node)
        T.bind(self, SemanticAnnotator)

        value_type = node.value.full_type!(context: "destructuring assignment value").success_type
        element_type = value_type.element_type || Type.new(:Any)
        DestructureRhsFacts.new(value_type: value_type, element_type: element_type)
      end

      sig { params(node: AST::DestructuringAssignment, rhs: DestructureRhsFacts).void }
      def validate_destructure_shape!(node, rhs)
        value_type = rhs.value_type
        unless value_type.fixed? && value_type.array?
          error!(node, :DESTRUCTURE_REQUIRES_FIXED_SHAPE, got: value_type.to_s)
        end
        if value_type.capacity != node.targets.length
          error!(node, :DESTRUCTURE_ARITY_MISMATCH, targets: node.targets.length, values: value_type.capacity)
        end
      end

      sig { params(node: AST::DestructuringAssignment, rhs: DestructureRhsFacts).void }
      def validate_destructure_copyable!(node, rhs)
        T.bind(self, SemanticAnnotator)

        copyable = rhs.element_type.implicitly_copyable? { |t| lookup_type_schema(t) }
        return if copyable

        error!(node, :DESTRUCTURE_REQUIRES_COPYABLE_RHS, got: rhs.value_type.to_s)
      end

      sig { params(node: AST::DestructuringAssignment, index: Integer, fallback: Type).returns(Type) }
      def destructure_value_type_at(node, index, fallback)
        value = node.value
        if value.is_a?(AST::ListLit) && value.items[index]
          return value.items[index].full_type!(context: "destructuring literal element")
        end

        fallback
      end

      sig { params(node: AST::DestructuringAssignment, target: AST::DestructureTarget, value_type: Type).void }
      def finalize_destructure_declaration_target!(node, target, value_type)
        T.bind(self, SemanticAnnotator)

        validate_type_annotation!(target, target.type) if target.type
        final_type = target.type || value_type
        validate_destructure_target_type!(node, final_type, value_type)
        stamp_type!(target, final_type)
        current_scope.declare(target.name, target, final_type, target.mutable, false)
        record_capture_local!(target.name.to_s)
        target.symbol = current_scope.local_entry!(target.name)
        classify_ownership!(T.must(target.symbol))
        og_declare(target.name, target, final_type)
      end

      sig { params(node: AST::DestructuringAssignment, target: AST::DestructureTarget, value_type: Type).void }
      def finalize_destructure_assignment_target!(node, target, value_type)
        T.bind(self, SemanticAnnotator)

        scope = current_scope
        unless ownership_graph.can_write?(target.name)
          error!(node, :ASSIGN_WHILE_BORROWED, name: target.name)
        end
        if scope.is_immutable?(target.name)
          fix = build_declare_mutable_fix(target.name, scope)
          if fix
            fixable!(node,
              code: :ASSIGN_VAR_IMMUTABLE,
              name: target.name,
              category: :ownership,
              level: :error,
              fixes: [fix])
          else
            error!(node, :ASSIGN_VAR_IMMUTABLE, name: target.name)
          end
        end

        validate_type_annotation!(target, target.type) if target.type
        target_type = scope.resolve_type(target.name)
        validate_destructure_target_type!(node, target_type, value_type)
        stamp_type!(target, target_type)
        target.symbol = scope.entry_for_write(target.name)
        mark_var_mutated(target.name)
        og_set_live(target.name)
      end

      sig { params(node: AST::DestructuringAssignment, target_type: Type::TypeInput, value_type: Type).void }
      def validate_destructure_target_type!(node, target_type, value_type)
        return if target_type.nil? || target_type == :Any || value_type.resolved == :Any
        return if target_type == :NIL
        return if Type.new(target_type).accepts?(value_type)

        error!(node, :TYPE_MISMATCH_ASSIGN, got: value_type.resolved, expected: target_type)
      end

      private :destructure_discard?
      private :destructure_rhs_facts
      private :destructure_value_type_at
      private :finalize_destructure_assignment_target!
      private :finalize_destructure_declaration_target!
      private :validate_destructure_copyable!
      private :validate_destructure_shape!
      private :validate_destructure_target_type!
    end
  end
end
