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

      sig { params(owner_name: String, member_name: String).returns(String) }
      def self.function_name(owner_name, member_name)
        "__inherent_#{owner_name.gsub(/[^A-Za-z0-9_]/, "_")}_#{member_name}"
      end

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

      sig do
        params(
          declarations: DeclarationIndex,
          resolutions: T::Array[ImplementationResolution],
          program: AST::Program,
        ).void
      end
      def prepare_implementation_members!(declarations, resolutions, program)
        T.bind(self, ResolutionSession)

        resolutions.each do |resolution|
          member_names = T.let(Set.new, T::Set[String])
          resolution.declaration.members.each do |member|
            source_name = member.name
            if member_names.include?(source_name)
              error!(member, :IMPLEMENTATION_DUPLICATE_MEMBER,
                owner: resolution.owner.name, name: source_name)
            end
            member_names.add(source_name)
            prepare_implementation_member!(member, resolution, source_name)
            declarations.function_declarations << member
            declarations.body_statements << member
            program.statements << member
          end
        end
      end

      sig do
        params(
          member: AST::FunctionDef,
          resolution: ImplementationResolution,
          source_name: String,
        ).void
      end
      def prepare_implementation_member!(member, resolution, source_name)
        T.bind(self, ResolutionSession)

        inherited = resolution.bindings.map do |binding|
          AST::GenericParamDecl.new(
            token: binding.local_param.token,
            name: binding.local_param.name,
            bounds: binding.owner_param.bounds,
          )
        end
        inherited_names = inherited.map(&:name).to_set
        member.generic_params.each do |param|
          if inherited_names.include?(param.name)
            error!(param.token || member, :IMPLEMENTATION_MEMBER_SHADOWS_OWNER,
              owner: resolution.owner.name, name: param.name, member: source_name)
          end
        end

        member.generic_params = inherited + member.generic_params
        member.type_params = member.generic_params.map(&:name)
        member.implementation_owner = resolution.owner.name
        member.source_name = source_name
        member[:name] = ImplementationRegistration.function_name(resolution.owner.name, source_name)
        prepare_method_receiver!(member, resolution) if member.is_method
        validate_member_type_parameter_references!(member)
      end
      private :prepare_implementation_member!

      sig { params(member: AST::FunctionDef).void }
      def validate_member_type_parameter_references!(member)
        T.bind(self, ResolutionSession)

        declared = member.type_params.map(&:to_sym).to_set
        types = member.params.map(&:type)
        types << member.return_type if member.return_type
        types.compact.each do |type|
          unbound_type_parameter_names(type).each do |name|
            next if declared.include?(name)
            error!(member, :GENERIC_UNKNOWN_TYPE_ARG, type: name)
          end
        end
      end
      private :validate_member_type_parameter_references!

      sig { params(type: Type, seen: T::Set[String]).returns(T::Set[Symbol]) }
      def unbound_type_parameter_names(type, seen = Set.new)
        key = type.semantic_type_key
        return Set.new if seen.include?(key)

        seen = seen.dup.add(key)
        nested = T.let([], T::Array[Type])
        nested.concat(type.generic_args) if type.generic_instance?
        nested << T.must(type.element_type) if type.array? && type.element_type
        if type.map?
          nested << type.key_type if type.key_type
          nested << type.value_type if type.value_type
        end
        nested << T.must(type.wrapped_type) if type.optional? && type.wrapped_type
        nested << T.must(type.payload_type) if type.error_union? && type.payload_type
        nested << type.tense_type if type.tense? && type.tense_type

        names = nested.each_with_object(Set.new) do |child, out|
          out.merge(unbound_type_parameter_names(child, seen))
        end
        resolved = type.resolved
        names.add(resolved) if resolved.to_s.match?(/\A[A-Z]\z/)
        names
      end
      private :unbound_type_parameter_names

      sig { params(member: AST::FunctionDef, resolution: ImplementationResolution).void }
      def prepare_method_receiver!(member, resolution)
        T.bind(self, ResolutionSession)

        receiver = member.params.first
        unless receiver&.name == "self"
          error!(member, :IMPLEMENTATION_METHOD_NEEDS_SELF,
            owner: resolution.owner.name, name: member.source_name)
        end
        receiver = T.must(receiver)
        return unless receiver.type.any?

        args = resolution.bindings.map { |binding| Type.new(binding.local_param.name.to_sym) }
        receiver.type = if args.empty?
          Type.new(resolution.owner.name.to_sym)
        else
          Type.generic_instance_of(resolution.owner.name.to_sym, args)
        end
      end
      private :prepare_method_receiver!

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
