# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/schemas"
require_relative "declaration_index"

module Annotator
  module Phases
    module TypeRegistration
      extend T::Sig

      sig { params(declarations: DeclarationIndex).void }
      def register_type_declarations(declarations)
        T.bind(self, SemanticAnnotator)
        declarations.type_declarations.each { |node| register_type_declaration(node) }
      end

      sig { params(node: TypeDeclaration).void }
      def register_type_declaration(node)
        T.bind(self, SemanticAnnotator)
        case node
        when AST::StructDef
          register_struct_declaration(node)
        when AST::ExternStructDecl
          register_extern_struct_declaration(node)
        when AST::EnumDef
          register_enum_declaration(node)
        when AST::UnionDef
          register_union_declaration(node)
        end
      end

      sig { params(node: AST::ExternStructDecl).void }
      def register_extern_struct_declaration(node)
        T.bind(self, SemanticAnnotator)
        schema = if node.close_method && node.from_module
          Schemas::ResourceSchema.new(
            close_zig: "{0}.#{node.close_method}()",
            fields: node.field_decls,
            type_params: type_params(node.type_params),
            extern_module: node.from_module,
            as_type: node.as_type,
          )
        else
          Schemas::StructSchema.new(
            fields: node.field_decls,
            type_params: type_params(node.type_params),
            extern_module: node.from_module,
            as_type: node.as_type,
          )
        end

        current_scope.declare_type(node.name.to_sym, schema)
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::StructDef).void }
      def register_struct_declaration(node)
        T.bind(self, SemanticAnnotator)
        validate_type_param_list!(node, node.type_params, "struct") if node.type_params&.any?
        stamp_field_defaults!(node.field_decls)

        current_scope.declare_type(node.name.to_sym, Schemas::StructSchema.new(
          fields: node.field_decls,
          type_params: type_params(node.type_params),
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::EnumDef).void }
      def register_enum_declaration(node)
        T.bind(self, SemanticAnnotator)
        current_scope.declare_type(node.name.to_sym, Schemas::EnumSchema.new(
          variants: node.variants.to_set,
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::UnionDef).void }
      def register_union_declaration(node)
        T.bind(self, SemanticAnnotator)
        validate_type_param_list!(node, node.type_params, "union") if node.type_params&.any?
        if node.type_params&.any? && node.variants.any? { |_, variant| Schemas.inline_struct?(variant) }
          error!(node, :UNION_INLINE_IN_GENERIC)
        end

        register_inline_struct_variants!(node)
        current_scope.declare_type(node.name.to_sym, Schemas::UnionSchema.new(
          variants: node.variants,
          type_params: type_params(node.type_params),
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(fields: T::Hash[String, AST::StructField]).void }
      def stamp_field_defaults!(fields)
        T.bind(self, SemanticAnnotator)
        fields.each_value do |field|
          default = field.default
          next unless default
          stamp_type!(default, field.type)
        end
      end
      private :stamp_field_defaults!

      sig { params(node: AST::UnionDef).void }
      def register_inline_struct_variants!(node)
        T.bind(self, SemanticAnnotator)
        node.variants.each do |variant_name, variant_data|
          next unless Schemas.inline_struct?(variant_data)

          synthetic_name = :"#{node.name}_#{variant_name}"
          current_scope.declare_type(synthetic_name, Schemas::StructSchema.new(
            fields: variant_data.fields.transform_values { |type| AST::StructField.new(type: type) }
          ))

          entries = inline_struct_deinit_entries(variant_data)
          variant_data.deinit_entries = entries if entries.any?
        end
      end
      private :register_inline_struct_variants!

      sig { params(variant_data: Schemas::InlineStructVariant).returns(T::Array[Schemas::InlineStructDeinitEntry]) }
      def inline_struct_deinit_entries(variant_data)
        variant_data.fields.each_with_object(T.let([], T::Array[Schemas::InlineStructDeinitEntry])) do |(field_name, field_type), entries|
          field_type_info = field_type
          field = field_name.to_s

          if field_type_info.indirect?
            entries << Schemas::InlineStructDeinitEntry.indirect(
              field: field,
              zig_type: Type.new(field_type_info.resolved).zig_type
            )
          elsif field_type_info.string? || field_type_info.collection?
            entries << Schemas::InlineStructDeinitEntry.uniform(field: field, zig_type: field_type_info.zig_type)
          elsif field_type_info.array? && !field_type_info.string?
            elem_zig_type = Type.new(field_type_info.element_type).zig_type
            entries << Schemas::InlineStructDeinitEntry.array(field: field, elem_zig_type: elem_zig_type)
          end
        end
      end
      private :inline_struct_deinit_entries

      sig { params(params: T.nilable(T::Array[String])).returns(T.nilable(T::Array[Symbol])) }
      def type_params(params)
        params&.any? ? params.map(&:to_sym) : nil
      end
      private :type_params
    end
  end
end
