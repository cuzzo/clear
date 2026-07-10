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
      walk = lambda do |current|
        return unless current

        if current.is_a?(Prism::ModuleNode)
          unless declaration_comment?(current, "ruby-to-clear: no-expand")
          name = current.constant_path.location.slice.strip
          short_name = name.split("::").last
          body_nodes = current.body&.body || []
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
          @mixin_methods[short_name].concat(methods) unless short_name == name
          @mixin_includes[name].concat(includes)
          @mixin_includes[short_name].concat(includes) unless short_name == name
          fields = with_current_class(name) { collect_instance_fields(current) }
          @mixin_fields[name].merge!(fields)
          @mixin_fields[short_name].merge!(fields) unless short_name == name
          end
        end

        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
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

    def expanded_mixin_method_pairs(module_name, seen = Set.new)
      return [] if seen.include?(module_name)

      next_seen = seen | [module_name]
      inherited = @mixin_includes[module_name].flat_map do |included|
        expanded_mixin_method_pairs(included, next_seen)
      end
      inherited + @mixin_methods[module_name]
    end

    def expanded_mixin_fields(module_name, seen = Set.new)
      return {} if seen.include?(module_name)

      next_seen = seen | [module_name]
      inherited = @mixin_includes[module_name].each_with_object({}) do |included, fields|
        fields.merge!(expanded_mixin_fields(included, next_seen))
      end
      inherited.merge(@mixin_fields[module_name])
    end

    def included_mixin_fields(body_nodes)
      body_nodes.filter_map { |stmt| included_module_name(stmt) }.each_with_object({}) do |name, fields|
        fields.merge!(expanded_mixin_fields(name))
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
        class_name = node.constant_path.location.slice.strip
        @imported_class_names << class_name if @collecting_imported_metadata
        collect_type_aliases_from_node(node.body, class_name)
        return
      end

      if node.is_a?(Prism::ConstantWriteNode)
        alias_key = type_alias_key(node.name.to_s, current_class)
        alias_name = type_alias_clear_name(node.name.to_s, current_class)
        if (type_alias = with_current_class(current_class) { sorbet_type_alias_value(node.value, alias_name: alias_name) })
          @type_aliases[alias_key] = type_alias
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

      if node.is_a?(Prism::ClassNode)
        class_name = node.constant_path.location.slice.strip
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
          end
          last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"

          collect_method_signature_metadata_from_node(stmt, current_class)
        end
        return
      end

      node.child_nodes.each { |child| collect_method_signature_metadata_from_node(child, current_class) if child }
    end

    def collect_method_params_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ClassNode)
        class_name = node.constant_path.location.slice.strip
        @imported_class_names << class_name if @collecting_imported_metadata
        node.child_nodes.each { |child| collect_method_params_from_node(child, class_name) if child }
        return
      end

      if node.is_a?(Prism::DefNode)
        params = method_parameter_info(node.parameters)
        param_types = method_param_types_for(node.name.to_s, current_class)
        params.each { |info| info[:type] ||= param_types[info[:name]] }
        if current_class && node.name.to_s == "initialize"
          @constructor_params[current_class] ||= params if params.any?
          @constructor_params[current_class.split("::").last] ||= params if params.any?
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
      infos
    end

    def collect_struct_fields_from_node(node, namespace = [])
      return unless node

      case node
      when Prism::ModuleNode
        collect_struct_fields_from_node(node.body, namespace + [node.constant_path.location.slice.strip.split("::").last])
        return
      when Prism::ClassNode
        name = node.constant_path.location.slice.strip.split("::").last
        if t_struct_class?(node)
          body_nodes = node.body&.body || []
          field_entries = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
          fields = field_entries.map(&:first)
          field_types = field_entries.to_h { |field, type, _default| [field, concrete_struct_type(type)] }
          defaults = field_entries.each_with_object({}) do |(field, _type, default), out|
            out[field] = default unless default.nil?
          end
          register_constructor_fields(namespace, name, fields, defaults, field_types)
        elsif (fields = struct_new_field_names(node.superclass))
          field_types = fields.to_h { |field| [field, "Any"] }
          register_constructor_fields(namespace, name, fields, {}, field_types)
        end
      when Prism::ConstantWriteNode
        if (fields = struct_new_field_names(node.value))
          @imported_class_names << node.name.to_s if @collecting_imported_metadata
          if @collecting_imported_metadata
            block_nodes = node.value.block&.body&.body || []
            block_nodes.each do |stmt|
              if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
                @imported_instance_method_names[node.name.to_s] << stmt.name.to_s
              end
            end
          end
          block_nodes = node.value.block&.body&.body.to_a
          mixin_fields = included_mixin_fields(block_nodes)
          all_fields = fields + (mixin_fields.keys - fields)
          field_types = all_fields.to_h { |field| [field, mixin_fields.fetch(field, "Any")] }
          include_names = block_nodes.filter_map { |stmt| included_module_name(stmt) }
          field_types["token"] = "Token" if fields.include?("token") && include_names.include?("Locatable")
          field_types.merge!(struct_new_block_field_types(node.value.block, fields, node.name.to_s))
          defaults = fields.to_h { |field| [field, "NIL"] }
          defaults.merge!(struct_new_block_initializer_defaults(node.value.block, fields, node.name.to_s))
          register_constructor_fields(namespace, node.name.to_s, all_fields, defaults, field_types)
          register_struct_new_block_methods(namespace, node.name.to_s, node.value.block)
        end
      end

      node.child_nodes.each { |child| collect_struct_fields_from_node(child, namespace) if child }
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
      fields.each do |field|
        merge_class_instance_field_type(class_name, field, field_types.fetch(field, "Any"))
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
      register_class_method_metadata(name, instance_methods, mutating_methods)
      if namespace.any?
        register_class_method_metadata((namespace + [name]).join("::"), instance_methods, mutating_methods)
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
          if field_set.include?(method_name) && return_type && return_type != "Auto"
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
      types.merge(field_type_overrides)
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

        defaults[predicate_field] = with_current_class(class_name) { visit(args.last) }
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
    end
  end
end
