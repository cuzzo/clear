# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../helpers/function_signature"

module Annotator
  module Phases
    # Portable declaration records used by body analysis, incremental caches,
    # and eventual worker processes. These records intentionally contain only
    # MessagePack-safe values: no AST nodes, Type objects, scopes, registries,
    # callbacks, or process-local identities.
    class ParameterInterface < T::Struct
      const :name, String
      const :type_key, String
      const :mutable, T::Boolean
      const :takes, T::Boolean
      const :comptime, T::Boolean
      const :required, T::Boolean
      const :sync, T.nilable(String)
    end

    class FunctionInterface < T::Struct
      const :name, String
      const :parameters, T::Array[ParameterInterface]
      const :return_type_key, String
      const :return_lifetime, T::Array[String]
      const :visibility, T.nilable(String)
      const :type_parameters, T::Array[String]
      const :generic_bounds, T::Hash[String, T::Array[String]]
      const :requires, T::Hash[String, T::Array[String]]
      const :reentrant, T::Boolean
      const :extern, T::Boolean
      const :owner_type, T.nilable(String)
      const :intrinsic, T::Boolean
    end

    class TypeInterface < T::Struct
      const :name, String
      const :kind, String
      const :type_parameters, T::Array[String]
      const :members, T::Hash[String, T.nilable(String)]
    end

    class ProgramInterface
      extend T::Sig

      sig { returns(T::Hash[String, FunctionInterface]) }
      attr_reader :functions
      sig { returns(T::Hash[String, TypeInterface]) }
      attr_reader :types

      sig do
        params(
          functions: T::Hash[String, FunctionInterface],
          types: T::Hash[String, TypeInterface]
        ).void
      end
      def initialize(functions:, types:)
        @functions = T.let(functions.sort.to_h.freeze, T::Hash[String, FunctionInterface])
        @types = T.let(types.sort.to_h.freeze, T::Hash[String, TypeInterface])
        freeze
      end

      sig { returns(ProgramInterface) }
      def self.empty
        new(functions: {}, types: {})
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "functions" => @functions.transform_values do |function|
            {
              "name" => function.name,
              "parameters" => function.parameters.map do |parameter|
                {
                  "name" => parameter.name,
                  "type_key" => parameter.type_key,
                  "mutable" => parameter.mutable,
                  "takes" => parameter.takes,
                  "comptime" => parameter.comptime,
                  "required" => parameter.required,
                  "sync" => parameter.sync
                }
              end,
              "return_type_key" => function.return_type_key,
              "return_lifetime" => function.return_lifetime,
              "visibility" => function.visibility,
              "type_parameters" => function.type_parameters,
              "generic_bounds" => function.generic_bounds,
              "requires" => function.requires,
              "reentrant" => function.reentrant,
              "extern" => function.extern,
              "owner_type" => function.owner_type,
              "intrinsic" => function.intrinsic
            }
          end,
          "types" => @types.transform_values do |type|
            {
              "name" => type.name,
              "kind" => type.kind,
              "type_parameters" => type.type_parameters,
              "members" => type.members
            }
          end
        }
      end

      sig do
        params(
          function_names: T::Array[String],
          root_scope: Scope,
          declarations: DeclarationIndex
        ).returns(ProgramInterface)
      end
      def self.capture(function_names:, root_scope:, declarations:)
        functions = T.let({}, T::Hash[String, FunctionInterface])
        function_names.sort.each do |name|
          signature = FunctionSignature.unwrap(root_scope.resolve_entry(name)&.type)
          functions[name] = function_interface(name, signature) if signature
        end

        types = T.let({}, T::Hash[String, TypeInterface])
        declarations.type_declarations.each do |declaration|
          interface = type_interface(declaration)
          types[interface.name.to_s] = interface
        end
        new(functions: functions, types: types)
      end

      sig { params(name: String, signature: FunctionSignature).returns(FunctionInterface) }
      def self.function_interface(name, signature)
        parameters = signature.params.map do |parameter|
          ParameterInterface.new(
            name: parameter.name.to_s,
            type_key: parameter.type.semantic_type_key,
            mutable: parameter.mutable == true,
            takes: parameter.takes == true,
            comptime: parameter.comptime == true,
            required: parameter.required == true,
            sync: parameter.sync&.to_s
          )
        end
        bounds = T.let({}, T::Hash[String, T::Array[String]])
        signature.generic_bounds.each do |parameter, entries|
          bounds[parameter.to_s] = entries.map(&:semantic_type_key).freeze
        end
        requires = T.let({}, T::Hash[String, T::Array[String]])
        signature.requires.each do |parameter, capabilities|
          requires[parameter] = capabilities.map(&:to_s).sort.freeze
        end

        FunctionInterface.new(
          name: name,
          parameters: parameters.freeze,
          return_type_key: signature.return_type.semantic_type_key,
          return_lifetime: signature.return_lifetime.map(&:to_s).freeze,
          visibility: signature.visibility&.to_s,
          type_parameters: signature.type_params.map(&:to_s).freeze,
          generic_bounds: bounds.freeze,
          requires: requires.freeze,
          reentrant: signature.reentrant,
          extern: signature.extern,
          owner_type: signature.owner_type,
          intrinsic: signature.intrinsic
        ).freeze
      end
      private_class_method :function_interface

      sig { params(declaration: TypeDeclaration).returns(TypeInterface) }
      def self.type_interface(declaration)
        TypeInterface.new(
          name: declaration.name.to_s,
          kind: declaration_kind(declaration),
          type_parameters: declaration_type_parameters(declaration).freeze,
          members: declaration_members(declaration).freeze
        ).freeze
      end
      private_class_method :type_interface

      sig { params(declaration: TypeDeclaration).returns(String) }
      def self.declaration_kind(declaration)
        case declaration
        when AST::StructDef then "struct"
        when AST::ExternStructDecl then "extern_struct"
        when AST::EnumDef then "enum"
        when AST::UnionDef then "union"
        when AST::ProtocolDef then "protocol"
        else T.absurd(declaration)
        end
      end
      private_class_method :declaration_kind

      sig { params(declaration: TypeDeclaration).returns(T::Array[String]) }
      def self.declaration_type_parameters(declaration)
        case declaration
        when AST::StructDef, AST::ExternStructDecl, AST::UnionDef
          declaration.type_params.map(&:to_s)
        when AST::ProtocolDef
          declaration.associated_types.map(&:name)
        when AST::EnumDef
          []
        else
          T.absurd(declaration)
        end
      end
      private_class_method :declaration_type_parameters

      sig { params(declaration: TypeDeclaration).returns(T::Hash[String, T.nilable(String)]) }
      def self.declaration_members(declaration)
        members = T.let({}, T::Hash[String, T.nilable(String)])
        case declaration
        when AST::StructDef, AST::ExternStructDecl
          declaration.field_decls.each { |name, field| members[name] = field.type.semantic_type_key }
        when AST::EnumDef
          declaration.variants.each { |name| members[name.to_s] = nil }
        when AST::UnionDef
          declaration.variants.each do |name, payload|
            members[name.to_s] = payload.is_a?(Type) ? payload.semantic_type_key : nil
          end
        when AST::ProtocolDef
          declaration.requirements.each do |requirement|
            members[requirement.name] = requirement.return_type.semantic_type_key
          end
        else
          T.absurd(declaration)
        end
        members.sort.to_h
      end
      private_class_method :declaration_members
    end
  end
end
