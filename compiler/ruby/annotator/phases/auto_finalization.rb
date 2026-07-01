# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "../helpers/auto_inference"
require_relative "../helpers/function_signature"

module Annotator
  module Phases
    module AutoFinalization
      extend T::Sig

      sig { params(program: AST::Program).void }
      def finalize_auto_types!(program)
        T.bind(self, SemanticAnnotator)

        run_auto_inference!(program)
      end

      sig { params(program: AST::Program, resolved_slots: AutoUnifier::ResultMap).void }
      def apply_auto_resolution_stamps!(program, resolved_slots)
        T.bind(self, SemanticAnnotator)

        touched_functions = restamp_auto_resolution_slots!(resolved_slots)
        touched_functions.each { |fn| restamp_auto_function_signature!(fn) }
        restamp_stale_auto_nodes!(program)
      end
      private :apply_auto_resolution_stamps!

      sig { params(resolved_slots: AutoUnifier::ResultMap).returns(T::Set[AST::FunctionDef]) }
      def restamp_auto_resolution_slots!(resolved_slots)
        T.bind(self, SemanticAnnotator)

        touched_functions = T.let(Set.new, T::Set[AST::FunctionDef])
        resolved_slots.each_value do |resolution|
          slot = resolution.slot
          case slot.kind
          when :param
            restamp_auto_param!(slot, resolution.type)
            touched_functions << T.cast(slot.decl_node, AST::FunctionDef)
          when :return
            restamp_auto_return!(slot, resolution.type)
            touched_functions << T.cast(slot.decl_node, AST::FunctionDef)
          when :local, :list_element, :map_key, :map_value
            restamp_auto_local!(slot)
          end
        end
        touched_functions
      end
      private :restamp_auto_resolution_slots!

      sig { params(slot: AutoConstraintCollector::Slot, type: AutoConstraintCollector::ObservedType).void }
      def restamp_auto_param!(slot, type)
        fn = T.cast(slot.decl_node, AST::FunctionDef)
        param = fn.params.fetch(T.must(slot.index))
        concrete = Type.new(type)
        param.type = concrete
        param.symbol.type = Type.new(concrete) if param.symbol
      end
      private :restamp_auto_param!

      sig { params(slot: AutoConstraintCollector::Slot, type: AutoConstraintCollector::ObservedType).void }
      def restamp_auto_return!(slot, type)
        fn = T.cast(slot.decl_node, AST::FunctionDef)
        concrete = Type.new(type)
        fn.return_type = concrete
      end
      private :restamp_auto_return!

      sig { params(slot: AutoConstraintCollector::Slot).void }
      def restamp_auto_local!(slot)
        T.bind(self, SemanticAnnotator)

        decl = T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode)
        concrete = Type.new(T.cast(decl.type, Type))
        decl.type = concrete
        stamp_type!(decl, concrete)

        symbol = decl.symbol
        if symbol
          symbol.type = Type.new(concrete)
          symbol.sync = concrete.sync
          symbol.layout = concrete.layout
        end

        value = decl.value
        return unless value
        current_value_type = auto_finalization_node_type(value)
        return unless slot.shape || current_value_type.auto? || current_value_type.untyped?
        stamp_type!(value, concrete)
        value.coerced_type = concrete
      end
      private :restamp_auto_local!

      sig { params(fn: AST::FunctionDef).void }
      def restamp_auto_function_signature!(fn)
        T.bind(self, SemanticAnnotator)

        signature = FunctionSignature.new(
          params: fn.params,
          return_type: fn.return_type,
          return_lifetime: fn.return_lifetime,
          visibility: fn.visibility,
          type_params: fn.type_params.map(&:to_sym),
          reentrant: fn.declared_plain_reentrant?
        )
        FunctionSignature.sync_from_function_def!(signature, fn)
        stamp_type!(fn, signature)
        entry = semantic_root_scope.local_entry(fn.name)
        entry.type = Type.new(signature) if entry
      end
      private :restamp_auto_function_signature!

      sig { params(program: AST::Program).void }
      def restamp_stale_auto_nodes!(program)
        T.bind(self, SemanticAnnotator)

        nodes = T.let([], T::Array[AST::Locatable])
        AST.each_locatable(program, descend_functions: true) { |node| nodes << node }

        nodes.reverse_each do |node|
          next if restamp_binary_type_after_auto!(node)
          next unless stale_auto_node_type?(auto_finalization_node_type(node))

          symbol_type = concrete_symbol_type_for(node)
          if symbol_type
            stamp_type!(node, symbol_type)
            next
          end

          call_type = concrete_function_call_type_for(node)
          if call_type
            stamp_type!(node, call_type)
            next
          end

          program_type = concrete_program_type_for(node)
          stamp_type!(node, program_type) if program_type
        end
      end
      private :restamp_stale_auto_nodes!

      sig { params(node: AST::Locatable).returns(Type) }
      def auto_finalization_node_type(node)
        return Type.new(:Untyped) unless node.typed?

        node.full_type!(context: "auto finalization node")
      end
      private :auto_finalization_node_type

      sig { params(type: Type).returns(T::Boolean) }
      def stale_auto_node_type?(type)
        type.untyped? || type.auto?
      end
      private :stale_auto_node_type?

      sig { params(node: AST::Locatable).returns(T.nilable(Type)) }
      def concrete_symbol_type_for(node)
        symbol = node.symbol
        return nil unless symbol
        symbol_type = symbol.type
        return nil if stale_auto_node_type?(symbol_type)
        Type.new(symbol_type)
      end
      private :concrete_symbol_type_for

      sig { params(node: AST::Locatable).returns(T.nilable(Type)) }
      def concrete_function_call_type_for(node)
        T.bind(self, SemanticAnnotator)

        return nil unless node.is_a?(AST::FuncCall)
        entry = semantic_root_scope.resolve_entry(node.name)
        signature = FunctionSignature.unwrap(entry&.type)
        return nil unless signature
        return_type = signature.return_type
        return nil if stale_auto_node_type?(return_type)
        Type.new(return_type)
      end
      private :concrete_function_call_type_for

      sig { params(node: AST::Locatable).returns(T::Boolean) }
      def restamp_binary_type_after_auto!(node)
        T.bind(self, SemanticAnnotator)

        return false unless node.is_a?(AST::BinaryOp)
        left_type = auto_finalization_node_type(node.left)
        right_type = auto_finalization_node_type(node.right)
        return false if stale_auto_node_type?(left_type) || stale_auto_node_type?(right_type)
        result = Type.binary_op(node.op, left_type, right_type)
        error!(node, :TYPE_ERROR_GENERIC, detail: result.error) if result.error
        result_type = T.cast(result.type, Type)
        return false if stale_auto_node_type?(result_type)
        stamp_type!(node, Type.new(result_type))
        true
      end
      private :restamp_binary_type_after_auto!

      sig { params(node: AST::Locatable).returns(T.nilable(Type)) }
      def concrete_program_type_for(node)
        return nil unless node.is_a?(AST::Program)
        last_stmt = node.statements.reverse.find { |stmt| stmt.is_a?(AST::Locatable) }
        return nil unless last_stmt
        stmt_type = auto_finalization_node_type(last_stmt)
        return nil if stale_auto_node_type?(stmt_type)
        Type.new(stmt_type)
      end
      private :concrete_program_type_for

    end
  end
end
