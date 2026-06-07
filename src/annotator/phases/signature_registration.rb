# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/schemas"
require_relative "../helpers/function_signature"
require_relative "declaration_index"
require_relative "signature_registry"

module Annotator
  module Phases
    module SignatureRegistration
      extend T::Sig

      sig { params(declarations: DeclarationIndex).void }
      def register_program_signatures(declarations)
        T.bind(self, SemanticAnnotator)

        declarations.function_declarations.each { |node| register_function_signature(node) }
        declarations.extern_function_declarations.each { |node| register_extern_function_signature(node) }

        synthetic_fns = synthetic_function_definitions
        synthetic_fns.clear
        declarations.union_method_declarations.each { |node| validate_union_methods!(node) }
        synthetic_fns.each { |node| register_function_signature(node) }
      end

      sig { params(node: AST::FunctionDef).returns(SymbolEntry) }
      def register_function_signature(node)
        T.bind(self, SemanticAnnotator)

        signature = SignatureRegistry.function_signature(
          node,
          return_lifetime: get_lifetime_path(node)
        )
        current_scope.declare(node.name, nil, signature, false, false, nil, :static)
      end

      sig { params(node: AST::ExternFnDecl).void }
      def register_extern_function_signature(node)
        T.bind(self, SemanticAnnotator)

        signature = SignatureRegistry.extern_function_signature(node)
        if node.owner_type
          type_schema = current_scope.resolve_type_definition(node.owner_type.to_sym)
          type_schema.methods[node.name] = signature if Schemas.struct?(type_schema) || Schemas.resource?(type_schema)
        else
          current_scope.declare(node.name, nil, signature, false, false, nil, :static)
        end
        stamp_type!(node, :Void)
      end
    end
  end
end
