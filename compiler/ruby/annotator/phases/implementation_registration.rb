# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "declaration_index"

module Annotator
  module Phases
    class OwnerGenericBinding < T::Struct
      const :position, Integer
      const :local_param, AST::GenericParamDecl
      const :owner_param, AST::GenericParamDecl
    end

    class ImplementationResolution < T::Struct
      const :declaration, AST::ImplementationDef
      const :owner, AST::StructDef
      const :bindings, T::Array[OwnerGenericBinding]
    end

    module ImplementationRegistration
      extend T::Sig

      sig { params(declarations: DeclarationIndex).returns(T::Array[ImplementationResolution]) }
      def resolve_implementation_declarations!(declarations)
        T.bind(self, ResolutionSession)

        local_structs = T.let({}, T::Hash[String, AST::StructDef])
        declarations.type_declarations.each do |node|
          local_structs[node.name] = node if node.is_a?(AST::StructDef)
        end

        seen = T.let({}, T::Hash[String, AST::ImplementationDef])
        declarations.implementation_declarations.map do |implementation|
          owner = local_structs[implementation.owner_name]
          unless owner
            code = current_scope.resolve_type_entry(implementation.owner_name.to_sym) ?
              :IMPLEMENTATION_NONLOCAL_OWNER : :IMPLEMENTATION_UNKNOWN_OWNER
            error!(implementation.owner_token, code, owner: implementation.owner_name)
          end
          previous = seen[implementation.owner_name]
          error!(implementation.owner_token, :IMPLEMENTATION_DUPLICATE,
            owner: implementation.owner_name) if previous
          seen[implementation.owner_name] = implementation

          validate_implementation_file!(implementation, owner)
          bindings = resolve_owner_generic_bindings!(implementation, owner)
          stamp_type!(implementation, :Void)
          ImplementationResolution.new(
            declaration: implementation,
            owner: owner,
            bindings: bindings,
          )
        end
      end

      sig { params(implementation: AST::ImplementationDef, owner: AST::StructDef).void }
      def validate_implementation_file!(implementation, owner)
        T.bind(self, ResolutionSession)

        implementation_file = implementation.token.file
        owner_file = owner.token.file
        return if implementation_file == owner_file

        error!(implementation.owner_token, :IMPLEMENTATION_WRONG_FILE,
          owner: owner.name,
          implementation_file: implementation_file || "<source>",
          owner_file: owner_file || "<source>")
      end
      private :validate_implementation_file!

      sig do
        params(
          implementation: AST::ImplementationDef,
          owner: AST::StructDef,
        ).returns(T::Array[OwnerGenericBinding])
      end
      def resolve_owner_generic_bindings!(implementation, owner)
        T.bind(self, ResolutionSession)

        binders = implementation.binders
        owner_params = owner.generic_params
        if binders.length != owner_params.length
          error!(implementation.owner_token, :IMPLEMENTATION_BINDER_ARITY,
            owner: owner.name, expected: owner_params.length, got: binders.length,
            expected_params: owner_params.map(&:name).join(", "))
        end

        seen = T.let(Set.new, T::Set[String])
        binders.each do |binder|
          error!(binder.token || implementation, :IMPLEMENTATION_BINDER_HAS_BOUND,
            name: binder.name) unless binder.bounds.empty?
          error!(binder.token || implementation, :IMPLEMENTATION_BINDER_DUPLICATE,
            name: binder.name, owner: owner.name) if seen.include?(binder.name)
          if ResolutionSession::BUILTIN_TYPE_PARAMETER_NAMES.include?(binder.name.to_sym) ||
              current_scope.resolve_type_entry(binder.name.to_sym)
            error!(binder.token || implementation, :IMPLEMENTATION_BINDER_SHADOWS_TYPE,
              name: binder.name)
          end
          seen.add(binder.name)
        end

        binders.each_with_index.map do |binder, index|
          OwnerGenericBinding.new(
            position: index,
            local_param: binder,
            owner_param: T.must(owner_params[index]),
          )
        end
      end
      private :resolve_owner_generic_bindings!
    end
  end
end
