# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "declaration_index"

module Annotator
  module Phases
    class ConformanceResolution < T::Struct
      const :declaration, AST::ConformanceDef
      const :protocol, AST::ProtocolDef
      const :owner_name, String
      const :owner_generic_params, T::Array[AST::GenericParamDecl]
      const :associated_types, T::Hash[Symbol, Type]
      const :members, T::Hash[String, AST::FunctionDef]
    end

    module ConformanceRegistration
      extend T::Sig

      sig { params(protocol_name: String, owner_name: String, member_name: String).returns(String) }
      def conformance_function_name(protocol_name, owner_name, member_name)
        parts = [protocol_name, owner_name, member_name].map { |part| part.gsub(/[^A-Za-z0-9_]/, "_") }
        "__conformance_#{parts.join('_')}"
      end
      private :conformance_function_name

      sig { params(declarations: DeclarationIndex).returns(T::Array[ConformanceResolution]) }
      def resolve_conformance_declarations!(declarations)
        T.bind(self, ResolutionSession)
        local_structs = declarations.type_declarations.filter_map do |node|
          [node.name, node] if node.is_a?(AST::StructDef)
        end.to_h
        local_protocols = declarations.type_declarations.filter_map do |node|
          node.name if node.is_a?(AST::ProtocolDef)
        end.to_set
        seen = T.let(Set.new, T::Set[String])

        declarations.conformance_declarations.map do |declaration|
          protocol_name = conformance_base_name(declaration.protocol_type)
          owner_name = conformance_base_name(declaration.owner_type)
          protocol = protocols[protocol_name]
          error!(declaration, :CONFORMANCE_UNKNOWN_PROTOCOL, protocol: protocol_name) unless protocol
          local_owner = local_structs[owner_name]
          owner_params = conformance_owner_params(owner_name, local_owner)
          error!(declaration, :CONFORMANCE_UNKNOWN_OWNER, owner: owner_name) unless owner_params
          unless local_owner || local_protocols.include?(protocol_name)
            error!(declaration, :CONFORMANCE_ORPHAN, protocol: protocol_name, owner: owner_name)
          end
          key = "#{protocol_name}:#{owner_name}"
          error!(declaration, :CONFORMANCE_DUPLICATE, protocol: protocol_name, owner: owner_name) if seen.include?(key)
          seen.add(key)

          validate_conformance_arity!(declaration, protocol, owner_name, owner_params)
          associated = conformance_associated_types(declaration, protocol)
          members = collect_conformance_members!(declaration, protocol, owner_name)
          stamp_type!(declaration, :Void)
          ConformanceResolution.new(
            declaration: declaration,
            protocol: protocol,
            owner_name: owner_name,
            owner_generic_params: owner_params,
            associated_types: associated,
            members: members,
          )
        end
      end

      sig do
        params(
          declarations: DeclarationIndex,
          resolutions: T::Array[ConformanceResolution],
          program: AST::Program,
        ).void
      end
      def prepare_conformance_members!(declarations, resolutions, program)
        T.bind(self, ResolutionSession)
        resolutions.each do |resolution|
          resolution.members.each_value do |member|
            source_name = member.name
            inherited_names = resolution.declaration.binders.map(&:name).to_set
            member.generic_params.each do |parameter|
              if inherited_names.include?(parameter.name)
                error!(parameter.token || member, :IMPLEMENTATION_MEMBER_SHADOWS_OWNER,
                  owner: resolution.owner_name, name: parameter.name, member: source_name)
              end
            end
            member.generic_params = resolution.declaration.binders + member.generic_params
            member.type_params = member.generic_params.map(&:name)
            member.implementation_owner = resolution.owner_name
            member.conformance_protocol = resolution.protocol.name
            member.source_name = source_name
            member[:name] = conformance_function_name(
              resolution.protocol.name, resolution.owner_name, source_name,
            )
            prepare_conformance_receiver!(member, resolution) if member.is_method
            validate_member_type_parameter_references!(member)
            declarations.function_declarations << member
            declarations.body_statements << member
            program.statements << member
          end
        end
      end

      sig { params(member: AST::FunctionDef, resolution: ConformanceResolution).void }
      def prepare_conformance_receiver!(member, resolution)
        T.bind(self, ResolutionSession)

        receiver = member.params.first
        unless receiver&.name == "self"
          error!(member, :IMPLEMENTATION_METHOD_NEEDS_SELF,
            owner: resolution.owner_name, name: member.source_name)
        end
        receiver = T.must(receiver)
        receiver.type = resolution.declaration.owner_type if receiver.type.any?
      end
      private :prepare_conformance_receiver!

      sig { params(type: Type).returns(String) }
      def conformance_base_name(type)
        type.generic_instance? ? type.generic_base.to_s : type.resolved.to_s
      end
      private :conformance_base_name

      sig do
        params(
          declaration: AST::ConformanceDef,
          protocol: AST::ProtocolDef,
          owner_name: String,
          owner_params: T::Array[AST::GenericParamDecl],
        ).void
      end
      def validate_conformance_arity!(declaration, protocol, owner_name, owner_params)
        T.bind(self, ResolutionSession)

        protocol_args = declaration.protocol_type.generic_args
        owner_args = declaration.owner_type.generic_args
        if protocol_args.length != protocol.associated_types.length
          error!(declaration, :CONFORMANCE_PROTOCOL_ARITY, protocol: protocol.name,
            expected: protocol.associated_types.length, got: protocol_args.length)
        end
        if owner_args.length != owner_params.length
          error!(declaration, :CONFORMANCE_OWNER_ARITY, owner: owner_name,
            expected: owner_params.length, got: owner_args.length)
        end
        validate_conformance_binders!(declaration)
        validate_generic_bounds!(declaration.binders)
      end
      private :validate_conformance_arity!

      sig do
        params(owner_name: String, local_owner: T.nilable(AST::StructDef))
          .returns(T.nilable(T::Array[AST::GenericParamDecl]))
      end
      def conformance_owner_params(owner_name, local_owner)
        T.bind(self, ResolutionSession)

        return local_owner.generic_params if local_owner

        entry = current_scope.resolve_type_entry(owner_name.to_sym)
        schema = entry&.schema
        return schema.generic_params if schema.is_a?(Schemas::StructSchema)
        return [] if ResolutionSession::BUILTIN_TYPE_PARAMETER_NAMES.include?(owner_name.to_sym)

        nil
      end
      private :conformance_owner_params

      sig { params(declaration: AST::ConformanceDef).void }
      def validate_conformance_binders!(declaration)
        T.bind(self, ResolutionSession)

        seen = T.let(Set.new, T::Set[Symbol])
        declaration.binders.each do |binder|
          name = binder.name.to_sym
          if seen.include?(name)
            error!(binder.token || declaration, :GENERIC_DUP_TYPE_PARAM_KIND,
              param: binder.name, kind: "conformance", name: conformance_base_name(declaration.owner_type))
          end
          if ResolutionSession::BUILTIN_TYPE_PARAMETER_NAMES.include?(name)
            error!(binder.token || declaration, :GENERIC_TYPE_PARAM_SHADOWS, param: binder.name)
          end
          if current_scope.resolve_type_entry(name)
            error!(binder.token || declaration, :GENERIC_TYPE_PARAM_SHADOWS_NOMINAL,
              param: binder.name)
          end
          seen.add(name)
        end
      end
      private :validate_conformance_binders!

      sig { params(declaration: AST::ConformanceDef, protocol: AST::ProtocolDef).returns(T::Hash[Symbol, Type]) }
      def conformance_associated_types(declaration, protocol)
        protocol.associated_types.each_with_index.to_h do |associated, index|
          [associated.name.to_sym, T.must(declaration.protocol_type.generic_args[index])]
        end
      end
      private :conformance_associated_types

      sig do
        params(
          declaration: AST::ConformanceDef,
          protocol: AST::ProtocolDef,
          owner_name: String,
        ).returns(T::Hash[String, AST::FunctionDef])
      end
      def collect_conformance_members!(declaration, protocol, owner_name)
        T.bind(self, ResolutionSession)

        members = T.let({}, T::Hash[String, AST::FunctionDef])
        declaration.members.each do |member|
          error!(member, :IMPLEMENTATION_DUPLICATE_MEMBER,
            owner: "#{protocol.name} FOR #{owner_name}", name: member.name) if members.key?(member.name)
          members[member.name] = member
        end
        members
      end
      private :collect_conformance_members!
    end
  end
end
