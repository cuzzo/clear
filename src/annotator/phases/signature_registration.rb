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

        reject_duplicate_program_signatures!(declarations)
        declarations.function_declarations.each { |node| register_function_signature(node) }
        declarations.extern_function_declarations.each { |node| register_extern_function_signature(node) }

        clear_synthetic_function_definitions!
        declarations.union_method_declarations.each { |node| validate_union_methods!(node) }
        synthetic_function_definitions.each { |node| register_function_signature(node) }
      end

      sig { params(node: AST::FunctionDef).returns(SymbolEntry) }
      def register_function_signature(node)
        T.bind(self, SemanticAnnotator)

        reject_duplicate_function_binding!(node)
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
          if Schemas.struct?(type_schema) || Schemas.resource?(type_schema)
            reject_duplicate_extern_method!(node, type_schema)
            type_schema.methods[node.name] = signature
          end
        else
          reject_duplicate_extern_function!(node)
          current_scope.declare(node.name, nil, signature, false, false, nil, :static)
        end
        stamp_type!(node, :Void)
      end

      sig { params(declarations: DeclarationIndex).void }
      def reject_duplicate_program_signatures!(declarations)
        T.bind(self, SemanticAnnotator)

        seen = T.let({}, T::Hash[String, AST::Node])
        declarations.function_declarations.each do |node|
          reject_duplicate_seen_signature!(node, seen, "function")
        end
        declarations.extern_function_declarations.each do |node|
          label = node.owner_type ? "extern method" : "function"
          reject_duplicate_seen_signature!(node, seen, label)
        end
      end
      private :reject_duplicate_program_signatures!

      sig { params(node: T.any(AST::FunctionDef, AST::ExternFnDecl), seen: T::Hash[String, AST::Node], label: String).void }
      def reject_duplicate_seen_signature!(node, seen, label)
        T.bind(self, SemanticAnnotator)

        key = node.is_a?(AST::ExternFnDecl) && node.owner_type ? "#{node.owner_type}.#{node.name}" : node.name
        if seen.key?(key)
          error!(node, :DUPLICATE_DECLARATION, label: label, name: key)
        end
        seen[key] = node
      end
      private :reject_duplicate_seen_signature!

      sig { params(node: AST::FunctionDef).void }
      def reject_duplicate_function_binding!(node)
        T.bind(self, SemanticAnnotator)

        return unless duplicate_signature_binding?(current_scope.local_entry(node.name))
        error!(node, :DUPLICATE_FUNCTION_DECLARATION, name: node.name)
      end
      private :reject_duplicate_function_binding!

      sig { params(node: AST::ExternFnDecl).void }
      def reject_duplicate_extern_function!(node)
        T.bind(self, SemanticAnnotator)

        return unless duplicate_signature_binding?(current_scope.local_entry(node.name))
        error!(node, :DUPLICATE_FUNCTION_DECLARATION, name: node.name)
      end
      private :reject_duplicate_extern_function!

      sig { params(entry: T.nilable(SymbolEntry)).returns(T::Boolean) }
      def duplicate_signature_binding?(entry)
        return false unless entry

        signature = entry.fn_signature
        return !signature.intrinsic if signature

        entry.reg.is_a?(AST::FunctionDef) || entry.reg.is_a?(AST::ExternFnDecl)
      end
      private :duplicate_signature_binding?

      sig { params(node: AST::ExternFnDecl, type_schema: Scope::ScopeTypeSchema).void }
      def reject_duplicate_extern_method!(node, type_schema)
        T.bind(self, SemanticAnnotator)

        return unless type_schema.methods.key?(node.name)
        owner = node.owner_type || "<unknown>"
        error!(node, :DUPLICATE_EXTERN_METHOD_DECLARATION, owner: owner, name: node.name)
      end
      private :reject_duplicate_extern_method!
          private :register_extern_function_signature
      private :register_function_signature

end
  end
end
