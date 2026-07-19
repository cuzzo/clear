# typed: strict
require "sorbet-runtime"
require_relative "../protocol_projection_resolver"

require_relative "../../ast/ast"
require_relative "../../ast/schemas"
require_relative "declaration_index"

module Annotator
  module Phases
    module TypeRegistration
      extend T::Sig
      include Annotator::ProtocolProjectionIssueEmission

      sig { params(declarations: DeclarationIndex).void }
      def register_type_declarations(declarations)
        T.bind(self, ResolutionSession)
        structs = declarations.type_declarations.filter_map do |node|
          node if node.is_a?(AST::StructDef)
        end
        resolve_recursive_struct_layouts!(structs)
        declarations.type_declarations.each do |node|
          register_protocol_declaration(node) if node.is_a?(AST::ProtocolDef)
        end
        declarations.type_declarations.each do |node|
          next if node.is_a?(AST::ProtocolDef)
          register_type_declaration(node)
        end
      end
      private :register_type_declarations

      sig { params(node: AST::ProtocolDef).void }
      def register_protocol_declaration(node)
        T.bind(self, ResolutionSession)
        if protocol_declared?(node.name) || current_scope.resolve_type_entry(node.name.to_sym)
          error!(node.name_token, :DUPLICATE_DECLARATION, label: "protocol", name: node.name)
        end

        seen_associated = T.let(Set.new, T::Set[String])
        node.associated_types.each do |associated|
          error!(associated.token || node, :GENERIC_DUPLICATE_TYPE_PARAM,
            param: associated.name, struct: node.name) if seen_associated.include?(associated.name)
          error!(associated.token || node, :IMPLEMENTATION_BINDER_HAS_BOUND,
            name: associated.name) unless associated.bounds.empty?
          seen_associated.add(associated.name)
        end

        seen_requirements = T.let(Set.new, T::Set[String])
        node.requirements.each do |requirement|
          if seen_requirements.include?(requirement.name)
            error!(requirement, :IMPLEMENTATION_DUPLICATE_MEMBER,
              owner: node.name, name: requirement.name)
          end
          seen_requirements.add(requirement.name)
          stamp_type!(requirement, :Void)
        end
        register_protocol!(node)
        stamp_type!(node, :Void)
      end
      private :register_protocol_declaration

      class RecursiveFieldEdge < T::Struct
        const :owner, Symbol
        const :target, Symbol
        const :field_name, String
        const :type, Type
      end

      sig { params(structs: T::Array[AST::StructDef]).void }
      def resolve_recursive_struct_layouts!(structs)
        T.bind(self, ResolutionSession)
        names = structs.map { |node| node.name.to_sym }.to_set
        edges = T.let([], T::Array[RecursiveFieldEdge])
        structs.each do |node|
          node.field_decls.each do |field_name, field|
            target = inline_recursive_target(field.type, names)
            edges << RecursiveFieldEdge.new(
              owner: node.name.to_sym,
              target: target,
              field_name: field_name,
              type: field.type,
            ) if target
          end
        end

        recursive_components(names, edges).each do |component|
          internal = edges.select { |edge| component.include?(edge.owner) && component.include?(edge.target) }
          next if internal.empty?

          labels = internal.map { |edge| "#{edge.owner}.#{edge.field_name}" }.join(", ")
          fixes = recursive_layout_fixes(internal)
          owner_node = T.must(structs.find { |node| node.name.to_sym == T.must(internal.first).owner })
          if internal.length == 1
            fixable!(owner_node,
              code: :RECURSIVE_LAYOUT_REQUIRES_INDIRECT, edge: labels,
              category: :type, level: :error, fixes: fixes, raise_in_collector: true)
          else
            fixable!(owner_node,
              code: :RECURSIVE_LAYOUT_AMBIGUOUS, edges: labels,
              category: :type, level: :error, fixes: fixes, raise_in_collector: true)
          end
        end
      end
      private :resolve_recursive_struct_layouts!

      sig { params(edges: T::Array[RecursiveFieldEdge]).returns(T::Array[Fix]) }
      def recursive_layout_fixes(edges)
        T.bind(self, ResolutionSession)
        source = diagnostic_source_code
        return [] unless source

        choices = [
          ["@node", "Store this edge in the compiler-managed graph slot map"],
          ["@boxed", "Make this a unique owned heap edge"],
          ["@multiowned", "Use local reference-counted shared identity"],
          ["@shared", "Use cross-execution atomic shared identity"],
          ["@link", "Make this a non-owning link to an independently owned node"],
        ]
        fixes = T.let([], T::Array[Fix])
        edges.each do |edge|
          span = recursive_field_suffix_span(source, edge)
          next unless span
          choices.each do |capability, description|
            fixes << Fix.new(
              description: fix_description(:CHOOSE_RECURSIVE_LAYOUT,
                description: description,
                edge: "#{edge.owner}.#{edge.field_name}",
                capability: capability),
              confidence: :interactive,
              edits: [Edit.new(span: span, replacement: capability)],
            )
          end
        end
        fixes
      end
      private :recursive_layout_fixes

      sig { params(source: String, edge: RecursiveFieldEdge).returns(T.nilable(Span)) }
      def recursive_field_suffix_span(source, edge)
        pattern = /\b#{Regexp.escape(edge.field_name)}\s*:\s*\??#{Regexp.escape(edge.target.to_s)}\b/
        match = pattern.match(source)
        return nil unless match
        insert_offset = match.end(0)
        prefix = T.must(source[0...insert_offset])
        line = prefix.count("\n") + 1
        last_newline = prefix.rindex("\n")
        col = insert_offset - (last_newline || -1)
        Span.new(file: nil, line: line, col: col, length: 0)
      end
      private :recursive_field_suffix_span

      sig { params(type: Type, names: T::Set[Symbol]).returns(T.nilable(Symbol)) }
      def inline_recursive_target(type, names)
        t = type
        return nil if t.indirect? || t.any_rc? || t.node_reference? || t.link?
        t = T.must(t.wrapped_type) while t.optional?
        return nil if t.indirect? || t.any_rc? || t.node_reference? || t.link?
        return nil if t.collection? || (t.array? && !t.fixed?)
        target = t.resolved.to_sym
        names.include?(target) ? target : nil
      end
      private :inline_recursive_target

      sig { params(names: T::Set[Symbol], edges: T::Array[RecursiveFieldEdge]).returns(T::Array[T::Set[Symbol]]) }
      def recursive_components(names, edges)
        adjacency = T.let(Hash.new { |h, k| h[k] = T.let([], T::Array[Symbol]) }, T::Hash[Symbol, T::Array[Symbol]])
        edges.each { |edge| T.must(adjacency[edge.owner]) << edge.target }
        index = T.let(0, Integer)
        indices = T.let({}, T::Hash[Symbol, Integer])
        low = T.let({}, T::Hash[Symbol, Integer])
        stack = T.let([], T::Array[Symbol])
        on_stack = T.let(Set.new, T::Set[Symbol])
        result = T.let([], T::Array[T::Set[Symbol]])

        visit = T.let(nil, T.nilable(T.proc.params(node: Symbol).void))
        visit = Kernel.lambda do |node|
          indices[node] = index
          low[node] = index
          index += 1
          stack << node
          on_stack.add(node)
          T.must(adjacency[node]).each do |target|
            unless indices.key?(target)
              T.must(visit).call(target)
              low[node] = [T.must(low[node]), T.must(low[target])].min
            else
              low[node] = [T.must(low[node]), T.must(indices[target])].min if on_stack.include?(target)
            end
          end
          next unless low[node] == indices[node]

          component = T.let(Set.new, T::Set[Symbol])
          Kernel.loop do
            member = T.must(stack.pop)
            on_stack.delete(member)
            component.add(member)
            break if member == node
          end
          self_loop = T.must(adjacency[node]).include?(node)
          result << component if component.length > 1 || self_loop
        end
        names.each { |name| visit.call(name) unless indices.key?(name) }
        result
      end
      private :recursive_components

      sig { params(node: TypeDeclaration).void }
      def register_type_declaration(node)
        T.bind(self, ResolutionSession)
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
        T.bind(self, ResolutionSession)
        schema = if node.close_method && node.from_module
          close_plan = if node.extern_source.abi == :c
            Schemas::ResourceClosePlan.c_function(node.close_method)
          else
            Schemas::ResourceClosePlan.method(node.close_method)
          end
          Schemas::ResourceSchema.new(
            close_plan: close_plan,
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

        existing = current_scope.resolve_type_entry(node.name.to_sym)
        if existing && equivalent_extern_type_schema?(existing.schema, schema)
          stamp_type!(node, :Void)
          return
        end

        declare_type_schema!(node, node.name.to_sym, schema)
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::StructDef).void }
      def register_struct_declaration(node)
        T.bind(self, ResolutionSession)
        validate_type_param_list!(node, node.type_params, "struct") if node.type_params.any?
        validate_generic_bounds!(node.generic_params)
        node.field_decls.each_value do |field|
          resolve_declaration_projections!(node, field.type, node.generic_params)
        end
        node.field_decls.each_value do |field|
          error!(node, :COLLECTION_HINT_VALUE_ONLY) if field.type.preallocation_hint?
        end
        stamp_field_defaults!(node.field_decls)

        declare_type_schema!(node, node.name.to_sym, Schemas::StructSchema.new(
          fields: node.field_decls,
          type_params: type_params(node.type_params),
          generic_params: node.generic_params,
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(params: T::Array[AST::GenericParamDecl]).void }
      def validate_generic_bounds!(params)
        T.bind(self, ResolutionSession)

        params.each do |param|
          param.bounds.each do |bound|
            next if protocol_declared?(bound.type.resolved.to_s)
            error!(bound.token || param.token, :GENERIC_UNKNOWN_PROTOCOL,
              protocol: Type.surface_name(bound.type))
          end
        end
      end
      private :validate_generic_bounds!

      sig do
        params(
          node: AST::Locatable,
          type: Type,
          parameters: T::Array[AST::GenericParamDecl],
        ).void
      end
      def resolve_declaration_projections!(node, type, parameters)
        T.bind(self, ResolutionSession)
        result = Annotator::ProtocolProjectionResolver.new(protocols).resolve(
          type.shape.expression,
          parameters,
        )
        issue = result.issues.first
        emit_protocol_projection_issue!(node, issue) if issue
        type.replace_shape!(type.shape.with_expression(result.expression))
      end
      private :resolve_declaration_projections!

      sig { params(node: AST::EnumDef).void }
      def register_enum_declaration(node)
        T.bind(self, ResolutionSession)
        declare_type_schema!(node, node.name.to_sym, Schemas::EnumSchema.new(
          variants: node.variants,
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::UnionDef).void }
      def register_union_declaration(node)
        T.bind(self, ResolutionSession)
        validate_type_param_list!(node, node.type_params, "union") if node.type_params.any?
        if node.type_params.any? && node.variants.any? { |_, variant| Schemas.inline_struct?(variant) }
          error!(node, :UNION_INLINE_IN_GENERIC)
        end

        register_inline_struct_variants!(node)
        declare_type_schema!(node, node.name.to_sym, Schemas::UnionSchema.new(
          variants: node.variants,
          type_params: type_params(node.type_params),
          visibility: node.visibility || :package,
        ))
        stamp_type!(node, :Void)
      end

      sig { params(fields: T::Hash[String, AST::StructField]).void }
      def stamp_field_defaults!(fields)
        T.bind(self, ResolutionSession)
        fields.each_value do |field|
          default = field.default
          next unless default
          stamp_type!(default, field.type)
        end
      end
      private :stamp_field_defaults!

      sig { params(node: AST::UnionDef).void }
      def register_inline_struct_variants!(node)
        T.bind(self, ResolutionSession)
        node.variants.each do |variant_name, variant_data|
          next unless Schemas.inline_struct?(variant_data)

          synthetic_name = :"#{node.name}_#{variant_name}"
          declare_type_schema!(node, synthetic_name, Schemas::StructSchema.new(
            fields: variant_data.fields.transform_values { |type| AST::StructField.new(type: type) }
          ))

          entries = inline_struct_deinit_entries(variant_data)
          variant_data.deinit_entries = entries if entries.any?
        end
      end
      private :register_inline_struct_variants!

      sig { params(node: TypeDeclaration, name: Symbol, schema: Scope::ScopeTypeSchema).void }
      def declare_type_schema!(node, name, schema)
        T.bind(self, ResolutionSession)

        if current_scope.resolve_type_entry(name)
          error!(node, :DUPLICATE_DECLARATION, label: "type", name: name)
        end
        current_scope.declare_type(name, schema)
      end
      private :declare_type_schema!

      sig { params(existing: Scope::ScopeTypeSchema, incoming: Scope::ScopeTypeSchema).returns(T::Boolean) }
      def equivalent_extern_type_schema?(existing, incoming)
        return false unless existing.class == incoming.class
        return false unless extern_type_schema?(existing) && extern_type_schema?(incoming)
        return false unless T.unsafe(existing).extern_module == T.unsafe(incoming).extern_module
        return false unless T.unsafe(existing).as_type == T.unsafe(incoming).as_type
        return false unless T.unsafe(existing).type_params == T.unsafe(incoming).type_params
        return false unless equivalent_struct_fields?(T.unsafe(existing).fields, T.unsafe(incoming).fields)

        if existing.is_a?(Schemas::ResourceSchema) && incoming.is_a?(Schemas::ResourceSchema)
          return existing.close_plan == incoming.close_plan
        end

        true
      end
      private :equivalent_extern_type_schema?

      sig { params(schema: Scope::ScopeTypeSchema).returns(T::Boolean) }
      def extern_type_schema?(schema)
        (schema.is_a?(Schemas::StructSchema) || schema.is_a?(Schemas::ResourceSchema)) &&
          !T.unsafe(schema).extern_module.nil?
      end
      private :extern_type_schema?

      sig { params(left: T::Hash[String, AST::StructField], right: T::Hash[String, AST::StructField]).returns(T::Boolean) }
      def equivalent_struct_fields?(left, right)
        return false unless left.keys.sort == right.keys.sort

        left.all? do |name, left_field|
          right_field = right[name]
          right_field &&
            left_field.type.to_s == right_field.type.to_s &&
            left_field.borrowed == right_field.borrowed &&
            left_field.default.nil? == right_field.default.nil?
        end
      end
      private :equivalent_struct_fields?

      sig { params(variant_data: Schemas::InlineStructVariant).returns(T::Array[Schemas::InlineStructDeinitEntry]) }
      def inline_struct_deinit_entries(variant_data)
        variant_data.fields.each_with_object(T.let([], T::Array[Schemas::InlineStructDeinitEntry])) do |(field_name, field_type), entries|
          field_type_info = field_type
          field = field_name.to_s

          if T.unsafe(field_type_info).indirect?
            entries << Schemas::InlineStructDeinitEntry.indirect(
              field: field,
              zig_type: Type.new(T.unsafe(field_type_info).resolved).zig_type
            )
          elsif T.unsafe(field_type_info).string? || T.unsafe(field_type_info).collection?
            entries << Schemas::InlineStructDeinitEntry.uniform(field: field, zig_type: T.unsafe(field_type_info).zig_type)
          elsif T.unsafe(field_type_info).array? && !T.unsafe(field_type_info).string?
            elem_zig_type = Type.new(T.unsafe(field_type_info).element_type).zig_type
            entries << Schemas::InlineStructDeinitEntry.array(field: field, elem_zig_type: elem_zig_type)
          end
        end
      end
      private :inline_struct_deinit_entries

      sig { params(params: T::Array[T.any(String, Symbol)]).returns(T::Array[Symbol]) }
      def type_params(params)
        params.map(&:to_sym)
      end
      private :type_params
          private :register_enum_declaration
      private :register_extern_struct_declaration
      private :register_struct_declaration
      private :register_type_declaration
      private :register_union_declaration

end
  end
end
