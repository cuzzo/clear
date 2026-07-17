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
        T.bind(self, ResolutionSession)

        reject_duplicate_program_signatures!(declarations)
        declarations.function_declarations.each { |node| register_function_signature(node) }
        declarations.extern_function_declarations.each { |node| register_extern_function_signature(node) }

        clear_synthetic_function_definitions!
        declarations.union_method_declarations.each { |node| validate_union_methods!(node) }
        synthetic_function_definitions.each { |node| register_function_signature(node) }
      end

      sig { params(node: AST::FunctionDef).returns(SymbolEntry) }
      def register_function_signature(node)
        T.bind(self, ResolutionSession)

        if node.is_method && node.implementation_owner.nil?
          error!(node, :TOP_LEVEL_METHOD_REQUIRES_IMPLEMENTATION, name: node.source_name)
        end
        validate_type_param_list!(node, node.type_params, "function") if node.type_params.any?
        validate_generic_bounds!(node.generic_params)
        reject_duplicate_function_binding!(node)
        signature = SignatureRegistry.function_signature(
          node,
          return_lifetime: get_lifetime_path(node)
        )
        entry = current_scope.declare(node.name, nil, signature, false, false, nil, :static)
        if node.implementation_owner && node.conformance_protocol.nil?
          register_implementation_member_signature!(node, signature)
        end
        entry
      end

      sig { params(node: AST::FunctionDef, signature: FunctionSignature).void }
      def register_implementation_member_signature!(node, signature)
        T.bind(self, ResolutionSession)

        owner_name = T.must(node.implementation_owner)
        schema = T.cast(current_scope.resolve_type_definition(owner_name.to_sym), Schemas::StructSchema)
        members = node.is_method ? schema.methods : schema.static_methods
        members[node.source_name] = signature
      end
      private :register_implementation_member_signature!

      sig { params(node: AST::ExternFnDecl).void }
      def register_extern_function_signature(node)
        T.bind(self, ResolutionSession)

        validate_c_extern_signature!(node) if node.extern_source.abi == :c
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

      sig { params(node: AST::ExternFnDecl).void }
      def validate_c_extern_signature!(node)
        T.bind(self, ResolutionSession)

        unless node.return_type
          error!(node, :C_EXTERN_UNSUPPORTED_TYPE,
            position: "return", type: "implicit Any", reason: "C functions require an explicit ABI return type")
        end
        validate_c_boundary_type!(node, node.return_type, "return", return_position: true)
        node.params.each do |param|
          validate_c_boundary_type!(node, param.type, "parameter #{param.name}", return_position: false)
        end
      end
      private :validate_c_extern_signature!

      sig { params(node: AST::ExternFnDecl, type: Type, position: String, return_position: T::Boolean).void }
      def validate_c_boundary_type!(node, type, position, return_position:)
        T.bind(self, ResolutionSession)

        reason = c_boundary_rejection(type, return_position: return_position)
        return unless reason
        error!(node, :C_EXTERN_UNSUPPORTED_TYPE,
          position: position, type: Type.surface_name(type), reason: reason)
      end
      private :validate_c_boundary_type!

      sig { params(type: Type, return_position: T::Boolean).returns(T.nilable(String)) }
      def c_boundary_rejection(type, return_position:)
        return "CLEAR error unions do not have a C ABI; return a status code explicitly" if type.error_union?
        return "futures and streams cannot cross a synchronous C ABI" if type.future? || type.stream?
        return "abstract Any/Number values have no fixed C representation" if type.any? || type.resolved == :Number
        return "ordinary String is a slice header; use String@c" if type.string? && !type.c_string?
        return "maps, Tuples, and managed collections have no portable C ABI" if type.map? || type.tuple? ||
          (type.array? && !type.fixed? && !type.c_array_view?)
        return "C cannot return an array by value; return a pointer plus a count" if return_position && type.fixed?
        if type.fn_type?
          fn = type.function_type
          return "callback function types must use CALLCONV C" unless fn&.abi == :c
          return nil
        end
        if type.optional?
          inner = T.must(type.wrapped_type)
          return nil if inner.c_string? || inner.c_array_view? || (!inner.primitive? && !inner.array? && !inner.map?)
          return "nullable scalar values are not C pointers; use an explicit status/out contract"
        end
        return "ownership, synchronization, and boxed wrappers change the declared C layout" if
          !type.layout.nil? || ![nil, :affine].include?(type.ownership) || type.any_sync?

        nil
      end
      private :c_boundary_rejection

      sig { params(declarations: DeclarationIndex).void }
      def reject_duplicate_program_signatures!(declarations)
        T.bind(self, ResolutionSession)

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
        T.bind(self, ResolutionSession)

        key = node.is_a?(AST::ExternFnDecl) && node.owner_type ? "#{node.owner_type}.#{node.name}" : node.name
        if seen.key?(key)
          error!(node, :DUPLICATE_DECLARATION, label: label, name: key)
        end
        seen[key] = node
      end
      private :reject_duplicate_seen_signature!

      sig { params(node: AST::FunctionDef).void }
      def reject_duplicate_function_binding!(node)
        T.bind(self, ResolutionSession)

        return unless duplicate_signature_binding?(current_scope.local_entry(node.name))
        error!(node, :DUPLICATE_FUNCTION_DECLARATION, name: node.name)
      end
      private :reject_duplicate_function_binding!

      sig { params(node: AST::ExternFnDecl).void }
      def reject_duplicate_extern_function!(node)
        T.bind(self, ResolutionSession)

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
        T.bind(self, ResolutionSession)

        methods = type_schema.methods
        return unless methods.is_a?(Hash) && methods.key?(node.name)
        owner = node.owner_type || "<unknown>"
        error!(node, :DUPLICATE_EXTERN_METHOD_DECLARATION, owner: owner, name: node.name)
      end
      private :reject_duplicate_extern_method!
          private :register_extern_function_signature
      private :register_function_signature

end
  end
end
