# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module MetadataCollector
    private

    def underscore_constant_name(name)
      name.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
    end

    def collect_mixin_metadata(node)
      walk = lambda do |current, namespace = []|
        return unless current

        if current.is_a?(Prism::ClassNode)
          raw_name = current.constant_path.location.slice.strip
          name = qualified_metadata_name(raw_name, namespace)
          short_name = name.split("::").last
          body_nodes = current.body&.body || []
          includes = body_nodes.filter_map { |stmt| included_module_name(stmt) }
          @class_includes[name].concat(includes)
          @class_includes[short_name].concat(includes) unless short_name == name
        end

        if current.is_a?(Prism::ModuleNode)
          raw_name = current.constant_path.location.slice.strip
          name = qualified_metadata_name(raw_name, namespace)
          short_name = name.split("::").last
          body_nodes = current.body&.body || []
          unless declaration_comment?(current, "ruby-to-clear: no-expand")
            methods = []
            includes = []
            last_sig = nil
            body_nodes.each do |stmt|
              if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
                last_sig = stmt
                next
              end
              if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
                methods << [last_sig, stmt]
              elsif (included = included_module_name(stmt))
                includes << included
              end
              last_sig = nil
            end
            @mixin_methods[name].concat(methods)
            @mixin_includes[name].concat(includes)
          end

          # no-expand suppresses method copying, not the storage contract
          # supplied by the mixin. Dropping these fields erases annotator
          # state from every generated AST node.
          fields = with_current_class(name) { collect_instance_fields(current) }
          @mixin_fields[name].merge!(fields)
        end

        child_namespace = if current.is_a?(Prism::ClassNode) || current.is_a?(Prism::ModuleNode)
          qualified_metadata_name(current.constant_path.location.slice.strip, namespace).split("::")
        else
          namespace
        end
        current.child_nodes.each { |child| walk.call(child, child_namespace) if child }
      end
      walk.call(node)
    end

    def qualified_metadata_name(raw_name, namespace)
      raw = raw_name.to_s.delete_prefix("::")
      return raw if raw.include?("::") || namespace.empty?

      (namespace + [raw]).join("::")
    end

    def resolved_mixin_metadata_name(name, scope = nil)
      raw = name.to_s.delete_prefix("::")
      return raw if raw.include?("::")

      scope_parts = scope.to_s.split("::")
      scope_parts.pop unless scope_parts.empty? || @mixin_fields.key?(scope.to_s)
      scope_parts.length.downto(1) do |length|
        candidate = (scope_parts.first(length) + [raw]).join("::")
        return candidate if @mixin_fields.key?(candidate) || @mixin_methods.key?(candidate) || @mixin_includes.key?(candidate)
      end

      raw
    end

    def locally_owned_class_names(node)
      names = Set.new
      walk = lambda do |current|
        return unless current

        if current.is_a?(Prism::ClassNode)
          class_name = current.constant_path.location.slice.strip
          if t_struct_class?(current) || struct_new_superclass?(current.superclass) || class_defines_storage_constructor?(current)
            names << class_name
          end
        elsif current.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(current.value)
          names << current.name.to_s
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      names
    end

    def class_defines_storage_constructor?(node)
      body_nodes = node.body&.body || []
      initialize_def = body_nodes.find do |stmt|
        stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.name.to_s == "initialize"
      end
      return false unless initialize_def

      contains_instance_variable_write?(initialize_def.body)
    end

    def contains_instance_variable_write?(node)
      return false unless node
      return true if node.is_a?(Prism::InstanceVariableWriteNode)
      return false if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)

      node.child_nodes.any? { |child| child && contains_instance_variable_write?(child) }
    end

    def included_module_name(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil? && node.name.to_s == "include"
      return nil if declaration_comment?(node, "ruby-to-clear: skip")

      arg = node.arguments&.arguments&.first
      case arg
      when Prism::ConstantReadNode then arg.name.to_s
      when Prism::ConstantPathNode then arg.location.slice.strip
      end
    end

    def module_static_body_nodes(body_nodes)
      instance_defs = body_nodes.each_index.select do |index|
        stmt = body_nodes[index]
        stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
      end.to_set
      skipped = instance_defs.dup
      instance_defs.each do |index|
        previous = index - 1
        if previous >= 0 && body_nodes[previous].is_a?(Prism::CallNode) && body_nodes[previous].name.to_s == "sig"
          skipped << previous
        end
      end
      body_nodes.each_with_index.reject do |(stmt, index)|
        skipped.include?(index) || included_module_name(stmt)
      end.map(&:first)
    end

    def expanded_mixin_method_pairs(module_name, seen = Set.new, scope = @current_class)
      resolved_name = resolved_mixin_metadata_name(module_name, scope)
      return [] if seen.include?(resolved_name)

      next_seen = seen | [resolved_name]
      inherited = @mixin_includes[resolved_name].flat_map do |included|
        expanded_mixin_method_pairs(included, next_seen, resolved_name)
      end
      inherited + @mixin_methods[resolved_name]
    end

    def expanded_mixin_fields(module_name, seen = Set.new, scope = @current_class)
      resolved_name = resolved_mixin_metadata_name(module_name, scope)
      return {} if seen.include?(resolved_name)

      next_seen = seen | [resolved_name]
      inherited = @mixin_includes[resolved_name].each_with_object({}) do |included, fields|
        fields.merge!(expanded_mixin_fields(included, next_seen, resolved_name))
      end
      inherited.merge(@mixin_fields[resolved_name])
    end

    def included_mixin_fields(body_nodes, scope = @current_class)
      body_nodes.filter_map { |stmt| included_module_name(stmt) }.each_with_object({}) do |name, fields|
        fields.merge!(expanded_mixin_fields(name, Set.new, scope))
      end
    end

    def expand_mixin_body_nodes(body_nodes)
      include_names = body_nodes.filter_map { |stmt| included_module_name(stmt) }
      return body_nodes if include_names.empty?

      local_names = body_nodes.filter_map do |stmt|
        stmt.name.to_s if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
      end.to_set
      if @current_class
        local_names.merge(@class_instance_method_names[@current_class].map { |name| name.to_s.delete_suffix("!") })
      end
      expanded = include_names.flat_map { |name| expanded_mixin_method_pairs(name) }
      expanded.each do |sig, _fn|
        next unless sig

        param_types, return_type = with_current_class(@current_class) { parse_sig(sig) }
        sig_call_chain(sig).each do |call_node|
          if call_node.name.to_s == "params"
            keyword_hash = call_node.arguments&.arguments&.first
            next unless keyword_hash.is_a?(Prism::KeywordHashNode)

            keyword_hash.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              next unless sorbet_signature_union_expression?(assoc.value)

              type_name = param_types[assoc.key.value.to_s].to_s.delete_prefix("?")
              @imported_union_names.delete(type_name) if @union_types.key?(type_name)
            end
          elsif call_node.name.to_s == "returns"
            value = call_node.arguments&.arguments&.first
            next unless sorbet_signature_union_expression?(value)

            type_name = return_type.to_s.delete_prefix("?")
            @imported_union_names.delete(type_name) if @union_types.key?(type_name)
          end
        end
      end
      seen_names = local_names.dup
      expanded_nodes = expanded.reverse_each.each_with_object([]) do |(sig, fn), nodes|
        next if seen_names.include?(fn.name.to_s)

        seen_names << fn.name.to_s
        nodes.unshift(fn)
        nodes.unshift(sig) if sig
      end
      result = body_nodes.reject { |stmt| included_module_name(stmt) } + expanded_nodes
      if @current_class
        @class_instance_method_names[@current_class].merge(collect_instance_method_names_from_body_nodes(result))
        @class_mutating_instance_method_names[@current_class].merge(
          collect_mutating_instance_method_names_from_body_nodes(result)
        )
        @current_instance_method_names = @class_instance_method_names[@current_class].dup
        @current_mutating_instance_method_names = @class_mutating_instance_method_names[@current_class].dup
      end
      result
    end

    def sorbet_signature_union_expression?(node)
      return false unless node.is_a?(Prism::CallNode)
      return true if node.receiver&.location&.slice == "T" && node.name.to_s == "any"
      return false unless node.receiver&.location&.slice == "T" && node.name.to_s == "nilable"

      sorbet_signature_union_expression?(node.arguments&.arguments&.first)
    end

    def suppress_imported_method_overrides(body_nodes)
      imported = @imported_instance_method_names[@current_class]
      return body_nodes if imported.empty?

      skipped = Set.new
      body_nodes.each_with_index do |stmt, index|
        next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && imported.include?(stmt.name.to_s)

        skipped << index
        previous = index - 1
        if previous >= 0 && body_nodes[previous].is_a?(Prism::CallNode) && body_nodes[previous].name.to_s == "sig"
          skipped << previous
        end
      end
      body_nodes.each_with_index.reject { |_stmt, index| skipped.include?(index) }.map(&:first)
    end

    def collect_type_aliases_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ClassNode)
        raw_class_name = node.constant_path.location.slice.strip
        class_name = if current_class && !raw_class_name.include?("::")
          "#{current_class}::#{raw_class_name}"
        else
          raw_class_name
        end
        @imported_class_names << class_name if @collecting_imported_metadata
        collect_type_aliases_from_node(node.body, class_name)
        return
      end

      if node.is_a?(Prism::ModuleNode)
        raw_module_name = node.constant_path.location.slice.strip
        module_name = if current_class && !raw_module_name.include?("::")
          "#{current_class}::#{raw_module_name}"
        else
          raw_module_name
        end
        @type_alias_module_namespaces << module_name
        collect_type_aliases_from_node(node.body, module_name)
        return
      end

      if node.is_a?(Prism::ConstantWriteNode)
        alias_key = type_alias_key(node.name.to_s, current_class)
        alias_name = type_alias_clear_name(node.name.to_s, current_class)
        if (type_alias = with_current_class(current_class) { sorbet_type_alias_value(node.value, alias_name: alias_name) })
          if declaration_comment?(node, "ruby-to-clear: aliasable") || declaration_comment?(node, "@aliasable")
            type_alias = apply_multiowned_sigil(type_alias)
          end
          @type_aliases[alias_key] = type_alias
          if @collecting_imported_metadata && @union_types.key?(alias_name)
            @imported_union_names << alias_name
          end
        elsif node.value.is_a?(Prism::ConstantReadNode) || node.value.is_a?(Prism::ConstantPathNode)
          # Ruby constants frequently reopen or re-export a nominal type.
          # Preserve that declaration edge so constructor and method
          # resolution can follow it before lowering.
          @type_aliases[alias_key] = with_current_class(current_class) do
            convert_sorbet_type(node.value, emit_union: false)
          end
        end
      end

      node.child_nodes.each { |child| collect_type_aliases_from_node(child, current_class) if child }
    end

    def collect_ast_node_variants_from_node(node, namespace = [])
      return unless node

      case node
      when Prism::ModuleNode
        name = node.constant_path.location.slice.strip.split("::").last
        collect_ast_node_variants_from_node(node.body, namespace + [name])
        return
      when Prism::ClassNode
        name = node.constant_path.location.slice.strip.split("::").last
        register_ast_node_variant(name) if namespace.last == "AST" && class_includes_locatable?(node)
      when Prism::ConstantWriteNode
        register_ast_node_variant(node.name.to_s) if namespace.last == "AST" && struct_value_includes_locatable?(node.value)
      end

      node.child_nodes.each { |child| collect_ast_node_variants_from_node(child, namespace) if child }
    end

    def register_ast_node_variant(name)
      return if name.to_s.empty? || name.to_s == "Node"

      members = (@union_types["Node"] ||= [])
      members << name.to_s unless members.include?(name.to_s)
    end

    def class_includes_locatable?(node)
      body = node.body
      return false unless body.respond_to?(:body)

      body.body.any? { |stmt| include_locatable_call?(stmt) }
    end

    def struct_value_includes_locatable?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless struct_new_field_names(node)

      body = node.block&.body
      return false unless body.respond_to?(:body)

      body.body.any? { |stmt| include_locatable_call?(stmt) }
    end

    def include_locatable_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil? && node.name.to_s == "include"

      arg = node.arguments&.arguments&.first
      case arg
      when Prism::ConstantReadNode
        arg.name.to_s == "Locatable"
      when Prism::ConstantPathNode
        arg.location.slice.strip == "AST::Locatable"
      else
        false
      end
    end

    def collect_method_signature_metadata_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ModuleNode)
        raw_module_name = node.constant_path.location.slice.strip
        module_name = if current_class && !raw_module_name.include?("::")
          "#{current_class}::#{raw_module_name}"
        else
          raw_module_name
        end
        collect_method_signature_metadata_from_node(node.body, module_name)
        return
      end

      if node.is_a?(Prism::ClassNode)
        raw_class_name = node.constant_path.location.slice.strip
        class_name = if current_class && !raw_class_name.include?("::")
          "#{current_class}::#{raw_class_name}"
        else
          raw_class_name
        end
        @imported_class_names << class_name if @collecting_imported_metadata
        collect_method_signature_metadata_from_node(node.body, class_name)
        return
      end

      if node.is_a?(Prism::StatementsNode)
        last_sig = nil
        node.body.each do |stmt|
          if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
            last_sig = stmt
            next
          end

          if stmt.is_a?(Prism::DefNode) && last_sig
            params, return_type = with_current_class(current_class) { parse_sig(last_sig) }
            key = scoped_method_key(current_class, stmt.name.to_s)
            @method_param_types[key] ||= params unless params.empty?
            @method_return_types[key] ||= return_type unless return_type == "Auto"
            identity = sig_return_type_identity(last_sig)
            @method_return_type_identities[key] ||= identity if identity
          end
          if stmt.is_a?(Prism::DefNode) &&
              (ruby_body_raises?(stmt.body) || declaration_comment?(stmt, "ruby-to-clear: fallible"))
            @inherently_fallible_methods << scoped_method_key(current_class, stmt.name.to_s)
            if current_class && stmt.receiver.nil? && stmt.name.to_s == "initialize"
              @inherently_fallible_methods << scoped_method_key(current_class, "new")
            end
          end
          last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"

          collect_method_signature_metadata_from_node(stmt, current_class)
        end
        return
      end

      node.child_nodes.each { |child| collect_method_signature_metadata_from_node(child, current_class) if child }
    end

    def ruby_body_raises?(node)
      return false unless node
      return false if node.is_a?(Prism::DefNode)
      return true if node.is_a?(Prism::CallNode) && ruby_raise_call?(node)
      if node.is_a?(Prism::CallNode) &&
         node.receiver&.location&.slice == "File" &&
         %w[read readlines binread write binwrite size delete mtime readlink symlink glob].include?(node.name.to_s)
        return true
      end

      node.child_nodes.any? { |child| ruby_body_raises?(child) }
    end

    def sig_return_type_identity(sig_node)
      call = sig_call_chain(sig_node).find { |candidate| candidate.name.to_s == "returns" }
      return "Void" if sig_call_chain(sig_node).any? { |candidate| candidate.name.to_s == "void" }

      type_node = call&.arguments&.arguments&.first
      return nil unless type_node

      semantic_type_identity(type_node)
    end

    def semantic_type_identity(node)
      if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        return node.location.slice.strip.delete_prefix("::")
      end
      return nil unless node.is_a?(Prism::CallNode)

      if node.receiver&.location&.slice == "T" && node.name.to_s == "nilable"
        inner = semantic_type_identity(node.arguments&.arguments&.first)
        return inner && "?#{inner}"
      end
      if node.name.to_s == "[]" && %w[T::Array Array].include?(node.receiver&.location&.slice)
        inner = semantic_type_identity(node.arguments&.arguments&.first)
        return inner && "#{inner}[]"
      end

      node.location.slice.strip
    end

    def collect_method_params_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ModuleNode)
        raw_module_name = node.constant_path.location.slice.strip
        module_name = if current_class && !raw_module_name.include?("::")
          "#{current_class}::#{raw_module_name}"
        else
          raw_module_name
        end
        node.child_nodes.each { |child| collect_method_params_from_node(child, module_name) if child }
        return
      end

      if node.is_a?(Prism::ClassNode)
        raw_class_name = node.constant_path.location.slice.strip
        class_name = if current_class && !raw_class_name.include?("::")
          "#{current_class}::#{raw_class_name}"
        else
          raw_class_name
        end
        @imported_class_names << class_name if @collecting_imported_metadata
        body_nodes = node.body&.body || []
        has_initializer = body_nodes.any? do |statement|
          statement.is_a?(Prism::DefNode) && statement.receiver.nil? && statement.name.to_s == "initialize"
        end
        if !has_initializer && node.superclass.nil?
          @constructor_params[class_name] ||= []
          @constructor_params[class_name.split("::").last] ||= []
        end
        node.child_nodes.each { |child| collect_method_params_from_node(child, class_name) if child }
        return
      end

      if node.is_a?(Prism::DefNode)
        params = method_parameter_info(node.parameters)
        param_types = method_param_types_for(node.name.to_s, current_class)
        mutable_params = collect_mutated_parameter_receivers(node.body, param_types)
        params.each { |info| info[:mutable] = mutable_params.include?(info[:name]) }
        params.each { |info| info[:type] ||= param_types[info[:name]] }
        if current_class && node.name.to_s == "initialize"
          # An explicit initializer is authoritative. This must replace a
          # default zero-argument shape recorded from an earlier reopening of
          # the same Ruby class.
          @constructor_params[current_class] = params
          basename = current_class.split("::").last
          if basename == current_class
            @constructor_params[basename] = params
          else
            @constructor_params[basename] ||= params
          end
        else
          @method_params[scoped_method_key(current_class, node.name.to_s)] ||= params if params.any?
        end
      end

      node.child_nodes.each { |child| collect_method_params_from_node(child, current_class) if child }
    end

    def collect_regex_constants_from_node(node)
      return unless node

      if node.is_a?(Prism::ConstantWriteNode) && regex_value_node?(node.value)
        @regex_constants << node.name.to_s
      end

      node.child_nodes.each { |child| collect_regex_constants_from_node(child) if child }
    end

    def collect_enum_variant_names_from_node(node, namespace = [])
      return unless node

      if node.is_a?(Prism::ModuleNode)
        raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
        parts = raw_name.split("::")
        module_namespace = parts.length > 1 ? parts : namespace + parts
        collect_enum_variant_names_from_node(node.body, module_namespace)
        return
      end

      if node.is_a?(Prism::ClassNode)
        raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
        parts = raw_name.split("::")
        class_namespace = parts.length > 1 ? parts : namespace + parts
        qualified_name = class_namespace.join("::")
        emitted_name = clear_type_name_for_emit(qualified_name)
        if t_enum_class?(node)
          t_enum_variants(node).each do |variant|
            emitted = "#{emitted_name}.#{variant}"
            @constant_names["#{qualified_name}::#{variant}"] = emitted
            @constant_names["#{raw_name}::#{variant}"] ||= emitted
            @constant_names["#{parts.last}::#{variant}"] ||= emitted
          end
        end
        collect_enum_variant_names_from_node(node.body, class_namespace)
        return
      end

      node.child_nodes.each { |child| collect_enum_variant_names_from_node(child, namespace) if child }
    end

    def method_parameter_info(parameters_node)
      return [] unless parameters_node

      infos = []
      parameters_node.requireds.each do |param|
        infos << { name: param.name.to_s, default: nil, kind: :positional } if param.respond_to?(:name)
      end
      parameters_node.optionals.each do |param|
        infos << { name: param.name.to_s, default: param.value, kind: :positional } if param.respond_to?(:name)
      end
      if parameters_node.rest&.respond_to?(:name)
        infos << { name: parameters_node.rest.name.to_s, default: nil, kind: :rest }
      end
      parameters_node.keywords.each do |param|
        infos << { name: param.name.to_s, default: param.respond_to?(:value) ? param.value : nil, kind: :keyword } if param.respond_to?(:name)
      end
      if parameters_node.keyword_rest&.respond_to?(:name)
        infos << { name: parameters_node.keyword_rest.name.to_s, default: nil, kind: :keyword_rest }
      end
      if parameters_node.block&.respond_to?(:name)
        infos << { name: parameters_node.block.name.to_s, default: nil, kind: :block }
      end
      infos
    end

    def collect_struct_fields_from_node(node, namespace = [])
      return unless node

      case node
      when Prism::ModuleNode
        collect_struct_fields_from_node(node.body, namespace + [node.constant_path.location.slice.strip.split("::").last])
        return
      when Prism::ClassNode
        raw_name = node.constant_path.location.slice.strip.delete_prefix("::")
        raw_parts = raw_name.split("::")
        name = raw_parts.last
        class_namespace = raw_parts.length > 1 ? raw_parts : namespace + [name]
        declaration_namespace = class_namespace[0...-1]
        if declaration_comment?(node, "ruby-to-clear: value")
          @value_classes << name
          @value_classes << class_namespace.join("::")
          @value_classes << class_namespace.join(".")
        end
        unless t_struct_class?(node) || t_enum_class?(node) || struct_new_superclass?(node.superclass)
          @aliasable_classes << name
          @aliasable_classes << class_namespace.join("::")
          @aliasable_classes << class_namespace.join(".")
        end
        if t_struct_class?(node)
          body_nodes = node.body&.body || []
          field_entries = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
          fields = field_entries.map(&:first)
          field_types = field_entries.to_h { |field, type, _default| [field, concrete_struct_type(type)] }
          mixin_fields = included_mixin_fields(body_nodes, class_namespace.join("::"))
          fields.concat(mixin_fields.keys - fields)
          field_types = mixin_fields.merge(field_types)
          defaults = field_entries.each_with_object({}) do |(field, _type, default), out|
            out[field] = default unless default.nil?
          end
          register_constructor_fields(declaration_namespace, name, fields, defaults, field_types)
        elsif (fields = struct_new_field_names(node.superclass))
          type_fn = lambda do |type_str|
            if declaration_comment?(node, "ruby-to-clear: aliasable") || declaration_comment?(node, "@aliasable")
              ["Int64", "Bool", "Float64", "String@symbol", "Void"].include?(type_str) ? type_str : apply_multiowned_sigil(type_str)
            else
              type_str
            end
          end
          field_types = fields.to_h { |field| [field, type_fn.call("Any")] }
          register_constructor_fields(declaration_namespace, name, fields, {}, field_types)
        end

        # Constants and reopened record classes inside a Ruby class belong to
        # that class's namespace. Passing the parent's namespace here loses
        # metadata for patterns such as `Lexer::Token = Struct.new(...)` and
        # makes the reopening emit `value()` instead of `self.value`.
        collect_struct_fields_from_node(node.body, class_namespace)
        return
      when Prism::ConstantWriteNode
        if (fields = struct_new_field_names(node.value))
          if @collecting_imported_metadata
            imported_name = (namespace + [node.name.to_s]).join("::")
            @imported_class_names << imported_name
            @imported_class_names << node.name.to_s
          end
          if @collecting_imported_metadata
            block_nodes = node.value.block&.body&.body || []
            block_nodes.each do |stmt|
              if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
                @imported_instance_method_names[node.name.to_s] << stmt.name.to_s
              end
            end
          end
          block_nodes = node.value.block&.body&.body.to_a
          mixin_fields = included_mixin_fields(block_nodes, namespace.join("::"))
          attribute_fields = block_nodes.flat_map do |stmt|
            next [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
              %w[attr_reader attr_accessor attr_writer].include?(stmt.name.to_s)

            (stmt.arguments&.arguments || []).filter_map do |argument|
              argument.value.to_s if argument.is_a?(Prism::SymbolNode)
            end
          end
          custom_field_types = node.value.block ? collect_instance_fields(node.value.block) : {}
          all_fields = fields + ((mixin_fields.keys + attribute_fields + custom_field_types.keys).uniq - fields)
          field_types = all_fields.to_h do |field|
            type = if node.name.to_s == "ListLit" && field == "items"
              "Node[]"
            elsif node.name.to_s == "HashLit" && field == "pairs"
              "Node[]"
            else
              custom_field_types.fetch(field, "Any")
            end
            [field, mixin_fields.fetch(field, type)]
          end
          include_names = block_nodes.filter_map { |stmt| included_module_name(stmt) }
          @class_includes[node.name.to_s].concat(include_names).uniq!
          if namespace.any?
            qualified_owner = (namespace + [node.name.to_s]).join("::")
            @class_includes[qualified_owner].concat(include_names).uniq!
          end
          field_types["token"] = "Token" if fields.include?("token") && include_names.include?("Locatable")
          struct_new_block_field_types(node.value.block, all_fields, node.name.to_s).each do |field, type|
            # A T.let-backed ivar describes storage. A same-named getter may
            # deliberately expose a narrower computed result and must not
            # rewrite that storage contract.
            field_types[field] = type if field_types[field].nil? || field_types[field] == "Any"
          end
          # Explicit source metadata is authoritative, including for fields
          # with legacy name-based defaults such as HashLit#pairs.  Applying
          # these a second time after inference keeps a concrete `{K}T` map
          # override from being silently replaced by the old `[]Node`
          # heuristic.
          field_types.merge!(struct_new_field_type_overrides(node.value.block, all_fields.to_set))
          if declaration_comment?(node, "ruby-to-clear: aliasable") || declaration_comment?(node, "@aliasable")
            field_types.transform_values! do |type_str|
              ["Int64", "Bool", "Float64", "String@symbol", "Void"].include?(type_str) ? type_str : apply_multiowned_sigil(type_str)
            end
          end
          defaults = all_fields.to_h { |field| [field, "NIL"] }
          defaults.merge!(struct_new_block_initializer_defaults(node.value.block, all_fields, node.name.to_s))
          register_constructor_fields(namespace, node.name.to_s, all_fields, defaults, field_types)
          register_struct_new_block_methods(namespace, node.name.to_s, node.value.block)
        end
      end

      node.child_nodes.each { |child| collect_struct_fields_from_node(child, namespace) if child }
    end

    def declared_type_owner_names(node)
      local_names = []
      walk = lambda do |current, namespace|
        return unless current

        if current.is_a?(Prism::ModuleNode) || current.is_a?(Prism::ClassNode)
          raw_name = current.constant_path.location.slice.strip.delete_prefix("::")
          qualified = raw_name.include?("::") ? raw_name : (namespace + [raw_name]).join("::")
          local_names << qualified if current.is_a?(Prism::ClassNode)
          walk.call(current.body, qualified.split("::"))
          next
        end
        if current.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(current.value)
          local_names << (namespace + [current.name.to_s]).join("::")
        end
        current.child_nodes.each { |child| walk.call(child, namespace) if child }
      end
      walk.call(node, [])

      local_names.uniq
    end

    def configure_local_emitted_type_names!(node)
      local_names = declared_type_owner_names(node)

      local_names.group_by { |name| name.split("::").last }.each do |basename, owners|
        imported_collision = @imported_class_names.any? do |name|
          name.include?("::") && name.split("::").last == basename && !owners.include?(name)
        end
        next unless imported_collision || owners.length > 1

        owners.each do |owner|
          emitted = owner.split("::").join
          @emitted_type_names[owner] = emitted
        end
        @local_emitted_type_names_by_basename[basename] = @emitted_type_names[owners.first] if owners.one?
      end
    end

    # Preserve the public type names chosen while an imported file would be
    # emitted on its own. A downstream file can otherwise see both AST::Node
    # and MIR::Node, correctly observe the collision, but still spell the MIR
    # dependency as `Node` even though mir.clear declared it as `MIRNode`.
    def configure_imported_emitted_type_names!(node)
      owners = declared_type_owner_names(node)
      owners.group_by { |name| name.split("::").last }.each do |basename, basename_owners|
        collision_owners = @imported_class_names | @metadata_cycle_type_owners
        dependency_collision = collision_owners.any? do |name|
          name.include?("::") && name.split("::").last == basename && !basename_owners.include?(name)
        end
        next unless dependency_collision || basename_owners.length > 1

        basename_owners.each do |owner|
          @emitted_type_names[owner] ||= owner.split("::").join
        end
      end

      emitted_members = owners.each_with_object({}) do |owner, mapping|
        emitted = @emitted_type_names[owner]
        mapping[owner.split("::").last] = emitted if emitted
      end
      unless emitted_members.empty?
        @union_types.each do |name, members|
          @union_types[name] = members.map { |member| emitted_members.fetch(member.to_s, member) }.uniq
        end
      end
    end

    def register_constructor_fields(namespace, name, fields, defaults = {}, field_types = {})
      @struct_fields[name] ||= fields
      @struct_field_defaults[name] ||= defaults
      register_class_field_metadata(name, fields, field_types)
      if namespace.any?
        qualified = (namespace + [name]).join("::")
        @struct_fields[qualified] ||= fields
        @struct_field_defaults[qualified] ||= defaults
        register_class_field_metadata(qualified, fields, field_types)
      end
    end

    def register_class_field_metadata(class_name, fields, field_types)
      @class_instance_field_names[class_name].merge(fields)
      configured_fields = @helper_config.struct_fields[class_name.to_s] ||
        @helper_config.struct_fields[class_name.to_s.split("::").last] || {}
      fields.each do |field|
        type = configured_fields.fetch(field.to_s) { field_types.fetch(field, "Any") }
        merge_class_instance_field_type(class_name, field, type)
      end
    end

    def merge_class_instance_field_type(class_name, field, type)
      normalized_type = type.to_s.empty? ? "Any" : type.to_s
      existing = @class_instance_field_types[class_name][field]
      return if existing && existing != "Any" && normalized_type == "Any"

      @class_instance_field_types[class_name][field] = normalized_type
    end

    def register_struct_new_block_methods(namespace, name, block_node)
      body_nodes = block_node&.body&.body || []
      return if body_nodes.empty?

      instance_methods = collect_instance_method_names_from_body_nodes(body_nodes)
      mutating_methods = collect_mutating_instance_method_names_from_body_nodes(body_nodes)
      class_methods = body_nodes.filter_map do |stmt|
        clear_function_name(stmt.name.to_s) if stmt.is_a?(Prism::DefNode) && stmt.receiver.is_a?(Prism::SelfNode)
      end
      register_class_method_metadata(name, instance_methods, mutating_methods)
      @class_class_method_names[name].merge(class_methods)
      if namespace.any?
        qualified = (namespace + [name]).join("::")
        register_class_method_metadata(qualified, instance_methods, mutating_methods)
        @class_class_method_names[qualified].merge(class_methods)
      end
    end

    def struct_new_block_field_types(block_node, fields, class_name)
      body_nodes = block_node&.body&.body || []
      field_set = fields.to_set
      types = {}
      field_type_overrides = struct_new_field_type_overrides(block_node, field_set)
      last_sig = nil
      body_nodes.each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          next
        end

        if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && last_sig
          param_types, return_type = with_current_class(class_name) { parse_sig(last_sig) }
          method_name = stmt.name.to_s
          if method_name == "initialize"
            extract_parameter_names(stmt).each do |parameter_name|
              next unless field_set.include?(parameter_name)

              parameter_type = param_types[parameter_name]
              types[parameter_name] ||= parameter_type if parameter_type && parameter_type != "Auto"
            end
          elsif field_set.include?(method_name) && return_type && return_type != "Auto"
            types[method_name] = return_type
          elsif method_name.end_with?("=")
            field_name = method_name.delete_suffix("=")
            if field_set.include?(field_name)
              value_name = extract_parameter_names(stmt).first
              value_type = param_types[value_name] if value_name
              types[field_name] ||= value_type if value_type && value_type != "Auto"
            end
          end
        end
        last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
      end
      inferred_collection_field_types(block_node, field_set).each do |field, type|
        types[field] ||= type
      end
      inferred_runtime_tested_field_types(block_node, field_set).each do |field, type|
        types[field] ||= type
      end
      inferred_emittable_child_field_types(block_node, field_set).each do |field, type|
        types[field] ||= type
      end
      types.merge(field_type_overrides)
    end

    def inferred_emittable_child_field_types(block_node, field_set)
      types = {}
      walk = lambda do |node, in_child_exprs = false|
        return unless node

        if node.is_a?(Prism::DefNode)
          in_child_exprs = node.name.to_s == "child_exprs"
        end
        if in_child_exprs && node.is_a?(Prism::CallNode) &&
           node.receiver.nil? && field_set.include?(node.name.to_s)
          field_name = node.name.to_s
          types[field_name] = %w[items args parts].include?(field_name) ? "Emittable[]" : "Emittable"
        end
        node.child_nodes.each { |child| walk.call(child, in_child_exprs) if child }
      end
      walk.call(block_node)
      types
    end

    def inferred_runtime_tested_field_types(block_node, field_set)
      types = {}
      walk = lambda do |node|
        return unless node
        return if node != block_node && (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))

        if node.is_a?(Prism::CallNode) && node.name.to_s == "is_a?"
          receiver = node.receiver
          field_name = if receiver.is_a?(Prism::CallNode) && receiver.receiver.nil?
            receiver.name.to_s
          elsif receiver.is_a?(Prism::InstanceVariableReadNode)
            receiver.name.to_s.delete_prefix("@")
          end
          expected = node.arguments&.arguments&.first
          if field_name && field_set.include?(field_name) &&
             (expected.is_a?(Prism::ConstantReadNode) || expected.is_a?(Prism::ConstantPathNode))
            expected_name = clear_type_expr(expected.location.slice.strip).to_s.split("::").last
            union_name = @closed_interface_unions.find do |candidate|
              @union_types[candidate].any? do |member|
                clear_type_expr(member).to_s.split("::").last == expected_name
              end
            end
            types[field_name] ||= union_name if union_name
          end
        end
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      types
    end

    def inferred_collection_field_types(block_node, field_set)
      types = {}
      walk = lambda do |node|
        return unless node
        return if node != block_node && (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))

        if node.is_a?(Prism::CallNode) && node.name.to_s == "each"
          receiver = node.receiver
          field_name = if receiver.is_a?(Prism::CallNode) && receiver.receiver.nil?
            receiver.name.to_s
          elsif receiver.is_a?(Prism::InstanceVariableReadNode)
            receiver.name.to_s.delete_prefix("@")
          end
          if field_name && field_set.include?(field_name)
            element_type = narrowed_each_element_type(node) || "Any"
            types[field_name] ||= "#{element_type}[]"
          end
        end
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      types
    end

    def narrowed_each_element_type(each_call)
      block = each_call.block
      parameter = block&.parameters&.parameters&.requireds&.first
      return nil unless parameter&.respond_to?(:name)

      parameter_name = parameter.name.to_s
      found = nil
      walk = lambda do |node|
        return unless node && found.nil?
        if node.is_a?(Prism::CallNode) && node.name.to_s == "is_a?" &&
           node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           node.receiver.name.to_s == parameter_name
          expected = node.arguments&.arguments&.first
          if expected.is_a?(Prism::ConstantReadNode) || expected.is_a?(Prism::ConstantPathNode)
            found = expected.location.slice.strip
            return
          end
        end
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block.body)
      found
    end

    def struct_new_block_initializer_defaults(block_node, fields, class_name)
      body_nodes = block_node&.body&.body || []
      initialize_def = body_nodes.find do |stmt|
        stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.name.to_s == "initialize"
      end
      return {} unless initialize_def

      field_set = fields.to_set
      (initialize_def.body&.body || []).each_with_object({}) do |stmt, defaults|
        next unless stmt.is_a?(Prism::IfNode) && stmt.consequent.nil?

        predicate_field = nil_guarded_self_index_field(stmt.predicate)
        next unless predicate_field && field_set.include?(predicate_field)

        assignment = stmt.statements&.body&.first
        next unless stmt.statements&.body&.length == 1
        next unless assignment.is_a?(Prism::CallNode) && assignment.name.to_s == "[]="
        next unless assignment.receiver.is_a?(Prism::SelfNode)

        args = assignment.arguments ? assignment.arguments.arguments : []
        next unless args.length == 2 && args.first.is_a?(Prism::SymbolNode)
        next unless args.first.value.to_s == predicate_field

        begin
          defaults[predicate_field] = with_current_class(class_name) { visit(args.last) }
        rescue TranspilationError
          # A default expression may depend on constructor metadata declared
          # later in the imported file. Keep collecting the static field shape;
          # calls which omit this field will still fail closed.
          next
        end
      end
    end

    def nil_guarded_self_index_field(predicate)
      return nil unless predicate.is_a?(Prism::CallNode) && predicate.name.to_s == "nil?"

      index_call = predicate.receiver
      return nil unless index_call.is_a?(Prism::CallNode) && index_call.name.to_s == "[]"
      return nil unless index_call.receiver.is_a?(Prism::SelfNode)

      args = index_call.arguments ? index_call.arguments.arguments : []
      return nil unless args.length == 1 && args.first.is_a?(Prism::SymbolNode)

      args.first.value.to_s
    end

    def struct_new_field_type_overrides(block_node, field_set)
      return {} unless block_node&.location

      block_node.location.slice.scan(/#\s*ruby-to-clear:\s*field-type\s+([A-Za-z_]\w*)\s*=\s*([^\s#]+)/).to_h.filter do |field, _type|
        field_set.include?(field)
      end
    end

    def register_class_method_metadata(class_name, instance_methods, mutating_methods)
      @class_instance_method_names[class_name].merge(instance_methods)
      @class_mutating_instance_method_names[class_name].merge(mutating_methods)
    end

    def refine_struct_field_types_from_constructor_calls(node)
      candidates = Hash.new { |hash, key| hash[key] = Hash.new { |fields, field| fields[field] = Set.new } }
      walk = lambda do |current, owner = nil, local_types = {}|
        return unless current

        if current.is_a?(Prism::ModuleNode) || current.is_a?(Prism::ClassNode)
          raw_name = current.constant_path.location.slice.strip
          nested_owner = if owner && !raw_name.include?("::")
            "#{owner}::#{raw_name}"
          else
            raw_name
          end
          walk.call(current.body, nested_owner, local_types)
          next
        end

        if current.is_a?(Prism::DefNode)
          parameter_types = method_param_types_for(current.name.to_s, owner)
          walk.call(current.body, owner, local_types.merge(parameter_types))
          next
        end

        if current.is_a?(Prism::CallNode) && current.name.to_s == "new" &&
           (current.receiver.is_a?(Prism::ConstantReadNode) || current.receiver.is_a?(Prism::ConstantPathNode))
          raw_name = current.receiver.location.slice.strip
          names = [raw_name, raw_name.split("::").last].uniq
          struct_owner = names.find { |name| @struct_fields.key?(name) }
          if struct_owner
            fields = @struct_fields.fetch(struct_owner)
            args = current.arguments&.arguments || []
            unless args.any? { |arg| arg.is_a?(Prism::KeywordHashNode) }
              args.each_with_index do |argument, index|
                field = fields[index]
                next unless field

                type = static_declaration_expression_type(argument, local_types)
                candidates[struct_owner][field] << type if type && !%w[Any Auto].include?(type)
              end
            end
          end
        end
        current.child_nodes.each { |child| walk.call(child, owner, local_types) if child }
      end
      walk.call(node)

      candidates.each do |owner, fields|
        matching_owners = @class_instance_field_types.keys.select do |candidate|
          candidate == owner || candidate.end_with?("::#{owner}") || owner.end_with?("::#{candidate}")
        end
        matching_owners << owner unless matching_owners.include?(owner)
        fields.each do |field, types|
          next unless types.one?

          matching_owners.each do |matching_owner|
            existing = @class_instance_field_types[matching_owner][field]
            next if existing && !%w[Any Auto].include?(existing.to_s)

            merge_class_instance_field_type(matching_owner, field, types.first)
          end
        end
      end
    end

    def static_declaration_expression_type(node, local_types = {})
      return nil unless node
      case node
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "String@symbol"
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Int64"
      when Prism::FloatNode then "Float64"
      when Prism::TrueNode, Prism::FalseNode then "Bool"
      when Prism::ArrayNode
        members = node.elements.filter_map { |element| static_declaration_expression_type(element, local_types) }.uniq
        members.one? ? "#{collection_element_type(members.first)}[]" : nil
      when Prism::LocalVariableReadNode
        local_types[node.name.to_s]
      when Prism::CallNode
        if sorbet_call?(node, "let") || sorbet_call?(node, "cast")
          type_node = node.arguments&.arguments&.at(1)
          return convert_sorbet_type(type_node) if type_node
        end
        if constant_constructor_call?(node)
          return constructor_output_name(node.receiver)
        end
        method_return_type_for(node.name.to_s, constant_receiver_name(node.receiver)) if node.receiver
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        node.location.slice.strip.split("::").last
      end
    rescue StandardError
      nil
    end

    # Sorbet `sealed!` on a module is the closed-set marker: only same-file
    # classes may include it, so the includers form a closed union. Each such
    # module becomes a runtime-dispatchable CLEAR union of its variants.
    def sealed_interface_union_names(node)
      names = []
      walk = lambda do |current|
        return unless current

        if current.is_a?(Prism::ModuleNode)
          body = current.body&.body || []
          if body.any? { |stmt| stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name.to_s == "sealed!" }
            names << current.constant_path.location.slice.strip.split("::").last
          end
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      names.uniq
    end

    # Fallibility is transitive: a method that calls a fallible method is itself
    # fallible, so its own call sites must propagate the error too. The base set
    # (allocation + explicit raise) is seeded; this walks the call graph to a
    # fixpoint. No-receiver calls resolve to a same-owner method or a free
    # function — precise without needing receiver-type inference. A
    # `ConstantName.method(...)` call additionally resolves to that literal
    # constant name as owner - still no type inference needed, since the
    # receiver text IS the class name for this common "ClassName.class_method"
    # shape (real corpus case: FunctionSignature#initialize calling
    # `FunctionSignature.copy_requires_for_import(...)` and `IntrinsicArgSpec.
    # list_from_registry(...)` directly - both raise, but neither was a
    # no-receiver call, so `initialize`/`new` never joined @inherently_
    # fallible_methods, and an external call site like FunctionSignature#dup's
    # `FunctionSignature.new(...)` never got wrapped in TRY even though the
    # constructor's own body-lowering correctly detected and TRY-wrapped the
    # exact same fallibility internally).
    # Accumulates this file's call-graph edges into the shared set. Imported
    # files contribute their edges too (collect_metadata_from_file calls this),
    # so the single fixpoint below sees cross-file chains: without it, an
    # imported method that is fallible only TRANSITIVELY stayed invisible
    # (only its DIRECT `raise` was seeded), and call sites in the root file
    # never wrapped it in TRY. Real corpus case: `Type#initialize` in
    # ast/type.rb is fallible only through the methods it calls, so
    # `function_signature.rb`'s `bounds.map { |b| Type.new(b) }` emitted a
    # bare `SELECT type__new(...)` instead of `SELECT TRY (type__new(...))`
    # ("SELECT expression returns !Type. Preserve that effect explicitly with
    # SELECT:!" - 97 files across 5 SCC groups).
    def collect_fallibility_edges!(node)
      walk = lambda do |current, owner|
        return unless current

        case current
        when Prism::ModuleNode, Prism::ClassNode
          inner = qualified_metadata_name(
            current.constant_path.location.slice.strip,
            owner.to_s.split("::")
          )
          (current.body&.body || []).each { |child| walk.call(child, inner) }
          return
        when Prism::DefNode
          caller_key = scoped_method_key(owner, current.name.to_s)
          same_owner_call_names(current.body).each do |callee|
            @fallibility_edges << [caller_key, scoped_method_key(owner, callee)]
          end
          constant_receiver_call_names(current.body).each do |callee_owner, callee|
            @fallibility_edges << [caller_key, scoped_method_key(callee_owner, callee)]
          end
          return
        end
        current.child_nodes.each { |child| walk.call(child, owner) if child }
      end
      walk.call(node, nil)
    end

    def propagate_transitive_fallibility!(node)
      collect_fallibility_edges!(node)
      edges = @fallibility_edges

      changed = true
      while changed
        changed = false
        edges.each do |caller_key, callee_key|
          next if @inherently_fallible_methods.include?(caller_key)
          next unless @inherently_fallible_methods.include?(callee_key)

          @inherently_fallible_methods << caller_key
          changed = true
        end
        # The initial seeding pass mirrors a directly-raising `initialize`
        # onto its class's implicit `new` (Ruby never writes `def new`
        # explicitly, so `new` has no edges of its own to converge through
        # the fixpoint above) - but that mirroring only runs once, before
        # this fixpoint, so an `initialize` that becomes fallible ONLY
        # transitively (via the edges above, not a direct raise) never gets
        # its own `new` mirrored. Re-check every fixpoint iteration so
        # transitively-fallible constructors propagate to their call sites
        # exactly like directly-raising ones do.
        @inherently_fallible_methods.dup.each do |key|
          owner, method = key.split("#", 2)
          next unless method == "initialize"

          new_key = scoped_method_key(owner, "new")
          next if @inherently_fallible_methods.include?(new_key)

          @inherently_fallible_methods << new_key
          changed = true
        end
      end
    end

    # Bare calls and explicit `self.foo(...)` calls both dispatch within the
    # current owner. Keeping them on the same canonical owner-qualified key as
    # signatures and call lowering prevents singleton methods (`def self.foo`)
    # from being recorded as unrelated free functions.
    def same_owner_call_names(body)
      names = []
      walk = lambda do |current|
        return unless current
        return if current.is_a?(Prism::DefNode) || current.is_a?(Prism::ModuleNode) || current.is_a?(Prism::ClassNode)

        if current.is_a?(Prism::CallNode) &&
           (current.receiver.nil? || current.receiver.is_a?(Prism::SelfNode))
          names << current.name.to_s
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(body)
      names.uniq
    end

    # [[owner, callee], ...] for every `ConstantName.method(...)` call reached
    # syntactically from body - the receiver text is used directly as the
    # owner, so this only covers the common "ClassName.class_method" shape
    # (a ConstantReadNode/ConstantPathNode receiver), never a variable or
    # expression receiver, matching same_owner_call_names' own "no type
    # inference" scoping.
    def constant_receiver_call_names(body)
      pairs = []
      walk = lambda do |current|
        return unless current
        return if current.is_a?(Prism::DefNode) || current.is_a?(Prism::ModuleNode) || current.is_a?(Prism::ClassNode)

        if current.is_a?(Prism::CallNode) &&
           (current.receiver.is_a?(Prism::ConstantReadNode) || current.receiver.is_a?(Prism::ConstantPathNode))
          owner = current.receiver.location.slice.strip.delete_prefix("::")
          pairs << [owner, current.name.to_s]
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(body)
      pairs.uniq
    end

    def synthesize_closed_interface_union!(node, interface_name)
      variants = []
      walk = lambda do |current, namespace|
        return unless current

        case current
        when Prism::ModuleNode
          name = current.constant_path.location.slice.strip
          walk.call(current.body, namespace + [name.split("::").last])
          return
        when Prism::ClassNode
          name = current.constant_path.location.slice.strip
          includes = (current.body&.body || []).filter_map { |stmt| included_module_name(stmt) }
          if includes.any? { |included| interface_include_reaches?(included, interface_name, Set.new, namespace.join("::")) }
            variants << (namespace + [name.split("::").last]).join("::")
          end
        when Prism::ConstantWriteNode
          if struct_new_field_names(current.value)
            includes = (current.value.block&.body&.body || []).filter_map { |stmt| included_module_name(stmt) }
            if includes.any? { |included| interface_include_reaches?(included, interface_name, Set.new, namespace.join("::")) }
              variants << (namespace + [current.name.to_s]).join("::")
            end
          end
        end

        current.child_nodes.each { |child| walk.call(child, namespace) if child }
      end
      walk.call(node, [])
      members = variants.map { |name| clear_type_expr(name) }
        .select { |name| name.to_s.match?(/\A[A-Z][A-Za-z0-9_]*\z/) }
        .uniq
      return if members.empty?

      @union_types[interface_name] = members
      @closed_interface_unions << interface_name
      @generated_union_defs[interface_name] = union_definition(interface_name, members)
    end

    def interface_include_reaches?(included, target, seen = Set.new, scope = nil)
      resolved = resolved_mixin_metadata_name(included, scope)
      return true if resolved.to_s.split("::").last == target
      return false if seen.include?(resolved)

      next_seen = seen | [resolved]
      (@mixin_includes[resolved] || []).any? do |nested|
        interface_include_reaches?(nested, target, next_seen, resolved)
      end
    end
    end
  end
end
