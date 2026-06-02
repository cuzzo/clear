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
        signature = FunctionSignature.new(
          params: node.params.map { |param| function_param(param) },
          return_type: node.return_type || Type.new(:Any),
          return_lifetime: return_lifetime,
          visibility: node.visibility,
          reentrant: node.reentrant == :reentrant
        )
        signature.requires = node.requires
        signature
      end

      sig { params(node: AST::ExternFnDecl).returns(FunctionSignature) }
      def self.extern_function_signature(node)
        FunctionSignature.new(
          params: node.params.map { |param| extern_param(param) },
          return_type: node.return_type || Type.new(:Any),
          visibility: :pub,
          extern: true,
          module_alias: node.from_module,
          extern_effects: extern_effects(node),
          fn_type_params: fn_type_params(node),
          type_params: fn_type_params(node).any? ? fn_type_params(node) : nil,
          owner_type: node.owner_type,
          owner_type_params: owner_type_params(node)
        )
      end

      sig { params(param: AST::Param).returns(AST::Param) }
      def self.function_param(param)
        AST::Param.new(
          name: param.name,
          type: param.type,
          required: param.default.nil?,
          default: param.default,
          mutable: param.mutable,
          takes: param.takes || false,
          sync: param.type&.any_sync? ? param.type.sync : nil
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

      sig { params(node: AST::ExternFnDecl).returns(T::Hash[Symbol, Symbol]) }
      def self.extern_effects(node)
        node.effects || {}
      end
      private_class_method :extern_effects

      sig { params(node: AST::ExternFnDecl).returns(T::Array[Symbol]) }
      def self.fn_type_params(node)
        T.cast(node.fn_type_params || [], T::Array[Symbol])
      end
      private_class_method :fn_type_params

      sig { params(node: AST::ExternFnDecl).returns(T::Array[Symbol]) }
      def self.owner_type_params(node)
        T.cast(node.owner_type_params || [], T::Array[Symbol])
      end
      private_class_method :owner_type_params
    end
  end
end
