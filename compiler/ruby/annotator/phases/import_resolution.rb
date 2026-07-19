# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/schemas"
require_relative "../../compiler/entrypoint"

module Annotator
  module Phases
    module ImportResolution
      extend T::Sig

      sig { params(node: AST::RequireNode).void }
      def visit_RequireNode(node)
        T.bind(self, ResolutionSession)
        importer = active_importer
        unless importer
          error!(node, :REQUIRE_NEEDS_IMPORTER)
        end

        mod = if node.kind == :package
          importer.compile_package(node.path, caller_dir: import_source_dir)
        else
          importer.compile_file(node.path, caller_dir: import_source_dir)
        end
        mod = T.must(mod)
        stamp_type!(node, :Void)

        same_dir = (node.kind != :package) && (mod.source_dir == import_source_dir)

        mod.global_scope.visible_entries.each do |name, entry|
          sig = entry.fn_signature
          next unless sig
          next if sig.module_alias
          next if name == Compiler::Entrypoint::NAME

          vis = sig.visibility || :package
          importable = (vis == :pub) || (vis == :package && same_dir)
          next unless importable

          imported_sig = sig.import_copy(module_alias: node.namespace)
          current_scope.declare(name, nil, imported_sig, false, false, nil, :static)
        end

        mod.global_scope.types.each do |type_name, type_entry|
          schema = type_entry.schema
          vis = schema.visibility || :package
          next if vis == :private
          next unless (vis == :pub) || (vis == :package && same_dir)
          imported_schema = clone_imported_schema(schema)
          current_scope.declare_type(type_name, imported_schema)
          import_inline_struct_variants!(type_name, imported_schema) if imported_schema.is_a?(Schemas::UnionSchema)
        end
        nil
      end
      private :visit_RequireNode

      sig { params(union_name: Symbol, schema: Schemas::UnionSchema).void }
      def import_inline_struct_variants!(union_name, schema)
        T.bind(self, ResolutionSession)
        schema.variants.each do |variant_name, variant|
          next unless variant.is_a?(Schemas::InlineStructVariant)

          synthetic_name = :"#{union_name}_#{variant_name}"
          current_scope.declare_type(synthetic_name, Schemas::StructSchema.new(
            fields: variant.fields.transform_values { |type| AST::StructField.new(type: Type.new(type)) }
          ))
        end
      end
      private :import_inline_struct_variants!

      sig { params(schema: Scope::ScopeTypeSchema).returns(Scope::ScopeTypeSchema) }
      def clone_imported_schema(schema)
        case schema
        when Schemas::EnumSchema
          clone_enum_schema(schema)
        when Schemas::ResourceSchema
          clone_resource_schema(schema)
        when Schemas::StructSchema
          clone_struct_schema(schema)
        when Schemas::UnionSchema
          clone_union_schema(schema)
        end
      end
      private :clone_imported_schema

      sig { params(schema: Schemas::EnumSchema).returns(Schemas::EnumSchema) }
      def clone_enum_schema(schema)
        variants = T.let([], T::Array[String])
        schema.variants.each do |variant|
          variants << variant.to_s
        end
        Schemas::EnumSchema.new(variants: variants, visibility: schema.visibility)
      end
      private :clone_enum_schema

      sig { params(schema: Schemas::StructSchema).returns(Schemas::StructSchema) }
      def clone_struct_schema(schema)
        Schemas::StructSchema.new(
          fields: clone_struct_fields(schema.fields),
          type_params: schema.type_params.dup,
          methods: clone_struct_methods(schema.methods),
          visibility: schema.visibility,
          extern_module: schema.extern_module,
          as_type: schema.as_type
        )
      end
      private :clone_struct_schema

      sig { params(schema: Schemas::ResourceSchema).returns(Schemas::ResourceSchema) }
      def clone_resource_schema(schema)
        Schemas::ResourceSchema.new(
          close_plan: clone_resource_close_plan(schema.close_plan),
          static_methods: clone_static_methods(schema.static_methods),
          fields: clone_struct_fields(schema.fields),
          type_params: schema.type_params.dup,
          extern_module: schema.extern_module,
          as_type: schema.as_type,
          visibility: schema.visibility,
          methods: clone_resource_methods(schema.methods)
        )
      end
      private :clone_resource_schema

      sig { params(schema: Schemas::UnionSchema).returns(Schemas::UnionSchema) }
      def clone_union_schema(schema)
        variants = T.let({}, Schemas::UnionSchema::VariantInputMap)
        schema.variants.each do |name, variant|
          variants[name] = clone_union_variant(variant)
        end
        Schemas::UnionSchema.new(
          variants: variants,
          type_params: schema.type_params.dup,
          visibility: schema.visibility
        )
      end
      private :clone_union_schema

      sig { params(fields: T::Hash[String, AST::StructField]).returns(T::Hash[String, AST::StructField]) }
      def clone_struct_fields(fields)
        copied = T.let({}, T::Hash[String, AST::StructField])
        fields.each do |name, field|
          copied[name] = AST::StructField.new(
            type: Type.new(field.type),
            default: field.default,
            borrowed: field.borrowed
          )
        end
        copied
      end
      private :clone_struct_fields

      sig { params(methods: Schemas::StructSchema::MethodsMap).returns(Schemas::StructSchema::MethodsMap) }
      def clone_struct_methods(methods)
        copied = T.let({}, Schemas::StructSchema::MethodsMap)
        methods.each do |name, method_sig|
          copied[name] = method_sig.import_copy(module_alias: method_sig.module_alias)
        end
        copied
      end
      private :clone_struct_methods

      sig { params(methods: Schemas::ResourceSchema::MethodsMap).returns(Schemas::ResourceSchema::MethodsMap) }
      def clone_resource_methods(methods)
        copied = T.let({}, Schemas::ResourceSchema::MethodsMap)
        methods.each do |name, method_sig|
          copied[name] = method_sig.import_copy(module_alias: method_sig.module_alias)
        end
        copied
      end
      private :clone_resource_methods

      sig { params(methods: Schemas::ResourceSchema::StaticMethodsMap).returns(Schemas::ResourceSchema::StaticMethodsMap) }
      def clone_static_methods(methods)
        copied = T.let({}, Schemas::ResourceSchema::StaticMethodsMap)
        methods.each do |name, spec|
          copied[name] = spec.dup
        end
        copied
      end
      private :clone_static_methods

      sig { params(plan: Schemas::ResourceClosePlan).returns(Schemas::ResourceClosePlan) }
      def clone_resource_close_plan(plan)
        Schemas::ResourceClosePlan.new(
          actions: plan.actions.map do |action|
            Schemas::ResourceCloseAction.new(
              call_kind: action.call_kind,
              name: action.name,
              field_path: action.field_path.dup,
              runtime_heap_alloc_args: action.runtime_heap_alloc_args
            )
          end
        )
      end
      private :clone_resource_close_plan

      sig { params(variant: Schemas::UnionSchema::VariantValue).returns(Schemas::UnionSchema::VariantValue) }
      def clone_union_variant(variant)
        case variant
        when nil
          nil
        when Type
          Type.new(variant)
        when Schemas::InlineStructVariant
          clone_inline_struct_variant(variant)
        end
      end
      private :clone_union_variant

      sig { params(variant: Schemas::InlineStructVariant).returns(Schemas::InlineStructVariant) }
      def clone_inline_struct_variant(variant)
        fields = T.let({}, Schemas::InlineStructVariant::FieldInputMap)
        variant.fields.each do |name, field_type|
          fields[name] = Type.new(field_type)
        end
        Schemas::InlineStructVariant.new(
          fields: fields,
          deinit_entries: variant.deinit_entries.dup
        )
      end
      private :clone_inline_struct_variant
    end
  end
end
