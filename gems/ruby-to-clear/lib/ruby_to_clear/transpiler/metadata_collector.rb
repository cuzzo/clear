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
          if @collecting_imported_metadata
            @type_aliases[alias_key] ||= type_alias
          else
            @type_aliases[alias_key] = type_alias
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
          defaults = field_entries.each_with_object({}) do |(field, _type, default), out|
            out[field] = default unless default.nil?
          end
          register_constructor_fields(namespace, name, fields, defaults)
        elsif (fields = struct_new_field_names(node.superclass))
          register_constructor_fields(namespace, name, fields)
        end
      when Prism::ConstantWriteNode
        if (fields = struct_new_field_names(node.value))
          register_constructor_fields(namespace, node.name.to_s, fields)
        end
      end

      node.child_nodes.each { |child| collect_struct_fields_from_node(child, namespace) if child }
    end

    def register_constructor_fields(namespace, name, fields, defaults = {})
      @struct_fields[name] ||= fields
      @struct_field_defaults[name] ||= defaults
      if namespace.any?
        qualified = (namespace + [name]).join("::")
        @struct_fields[qualified] ||= fields
        @struct_field_defaults[qualified] ||= defaults
      end
    end
    end
  end
end
