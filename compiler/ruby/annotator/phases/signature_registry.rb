# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../helpers/function_signature"

module Annotator
  module Phases
    class SignatureRegistry
      extend T::Sig

      sig { params(node: AST::FunctionDef, return_lifetime: T.nilable(String)).returns(FunctionSignature) }
      def self.function_signature(node, return_lifetime:)
        FunctionSignature.new(
          params: node.params.map { |param| function_param(param) },
          return_type: node.annotation_return_type,
          return_lifetime: return_lifetime,
          visibility: node.visibility,
          fn_type_params: node.type_params.map(&:to_sym),
          type_params: node.type_params.map(&:to_sym),
          generic_bounds: generic_bounds(node.generic_params),
          reentrant: node.reentrance_kind == :reentrant || node.effects_decl == :reentrant,
          requires: node.requires
        )
      end

      sig { params(params: T::Array[AST::GenericParamDecl]).returns(FunctionSignature::GenericBounds) }
      def self.generic_bounds(params)
        params.each_with_object({}) do |param, bounds|
          bounds[param.name.to_sym] = param.bounds.map(&:type)
        end
      end
      private_class_method :generic_bounds

      sig { params(node: AST::ExternFnDecl).returns(FunctionSignature) }
      def self.extern_function_signature(node)
        params = node.params.nil? ? [] : node.params
        FunctionSignature.new(
          params: params.map { |param| extern_param(param) },
          return_type: node.annotation_return_type,
          return_lifetime: extern_lifetime_paths(node),
          visibility: :pub,
          extern: true,
          module_alias: node.from_module,
          extern_effects: extern_effects(node),
          extern_source: node.extern_source,
          fn_type_params: node.fn_type_params.dup,
          type_params: node.fn_type_params.dup,
          owner_type: node.owner_type,
          owner_type_params: node.owner_type_params.dup
        )
      end

      sig { params(node: AST::ExternFnDecl).returns(T::Array[FunctionSignature::LifetimeSource]) }
      def self.extern_lifetime_paths(node)
        lifetime = node.return_lifetime
        return [] if lifetime.nil?
        return [:wildcard] if lifetime == :wildcard

        paths = T.let([], T::Array[FunctionSignature::LifetimeSource])
        T.cast(lifetime, T::Array[AST::Node]).each do |source|
          next unless source.is_a?(AST::Identifier)

          identifier = source
          paths << identifier.name.to_s
        end
        paths
      end
      private_class_method :extern_lifetime_paths

      sig { params(param: AST::Param).returns(AST::Param) }
      def self.function_param(param)
        AST::Param.new(
          name: param.name,
          type: param.type,
          required: param.default.nil?,
          default: param.default,
          mutable: param.mutable,
          takes: param.takes || false,
          sync: param.type.any_sync? ? param.type.sync : nil
        )
      end
      private_class_method :function_param

      sig { params(param: AST::Param).returns(AST::Param) }
      def self.extern_param(param)
        AST::Param.new(
          name: param.name,
          type: param.type,
          required: param.default.nil?,
          mutable: param.mutable || false,
          comptime: param.comptime || false
        )
      end
      private_class_method :extern_param

      sig { params(node: AST::ExternFnDecl).returns(FunctionSignature::ExternEffects) }
      def self.extern_effects(node)
        node.effects || {}
      end
      private_class_method :extern_effects

    end
  end
end
