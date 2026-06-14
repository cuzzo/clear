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
          reentrant: node.declared_plain_reentrant?,
          requires: node.requires
        )
      end

      sig { params(node: AST::ExternFnDecl).returns(FunctionSignature) }
      def self.extern_function_signature(node)
        FunctionSignature.new(
          params: node.params.map { |param| extern_param(param) },
          return_type: node.annotation_return_type,
          visibility: :pub,
          extern: true,
          module_alias: node.from_module,
          extern_effects: extern_effects(node),
          fn_type_params: fn_type_params(node),
          type_params: fn_type_params(node),
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

      sig { params(node: AST::ExternFnDecl).returns(T::Hash[Symbol, Symbol]) }
      def self.extern_effects(node)
        node.effects || {}
      end
      private_class_method :extern_effects

      sig { params(node: AST::ExternFnDecl).returns(T::Array[Symbol]) }
      def self.fn_type_params(node)
        node.fn_type_params
      end
      private_class_method :fn_type_params

      sig { params(node: AST::ExternFnDecl).returns(T::Array[Symbol]) }
      def self.owner_type_params(node)
        node.owner_type_params
      end
      private_class_method :owner_type_params
    end
  end
end
