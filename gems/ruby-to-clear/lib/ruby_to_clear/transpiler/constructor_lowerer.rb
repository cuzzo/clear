# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module ConstructorLowerer
    private

    def struct_new_field_names(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "new"
      receiver = node.receiver
      return nil unless receiver.nil? || receiver.location.slice.strip == "Struct"

      args = node.arguments ? node.arguments.arguments : []
      fields = args.take_while { |arg| arg.is_a?(Prism::SymbolNode) }.map { |arg| arg.value.to_s }
      fields.empty? ? nil : fields
    end

    def struct_new_superclass?(node)
      !!struct_new_field_names(node)
    end

    def constructor_output_name(receiver)
      return @current_class if receiver.nil? && @current_class

      receiver.location.slice.strip.split("::").last
    end

    def constructor_receiver_class_name(receiver)
      return @current_class if receiver.nil? && @current_class
      return nil unless receiver

      raw = receiver.location.slice.strip
      candidates = [raw]
      candidates << raw.split("::").last if raw.include?("::")
      candidates.find { |name| @constructor_params[name] } || candidates.last
    end

    def constructor_function_name(class_name)
      "#{class_function_prefix(class_name.to_s.split('::').last)}__new"
    end

    def keyword_constructor_entries(keyword_hash)
      keyword_hash.elements.map do |assoc|
        unless assoc.is_a?(Prism::AssocNode)
          return raise_unsupported("Constructor keyword splats are not supported", keyword_hash)
        end

        key = if assoc.key.is_a?(Prism::SymbolNode)
          assoc.key.value.to_s
        elsif assoc.key.is_a?(Prism::StringNode)
          assoc.key.content
        else
          return raise_unsupported("Constructor keyword names must be static", assoc.key)
        end

        [key, visit(assoc.value)]
      end
    end

    def keyword_constructor_node_entries(keyword_hash)
      keyword_hash.elements.map do |assoc|
        unless assoc.is_a?(Prism::AssocNode)
          return raise_unsupported("Constructor keyword splats are not supported", keyword_hash)
        end

        key = if assoc.key.is_a?(Prism::SymbolNode)
          assoc.key.value.to_s
        elsif assoc.key.is_a?(Prism::StringNode)
          assoc.key.content
        else
          return raise_unsupported("Constructor keyword names must be static", assoc.key)
        end

        [key, assoc.value]
      end
    end

    def keyword_constructor_pairs(keyword_hash)
      entries = keyword_constructor_entries(keyword_hash)
      return entries if entries.is_a?(String)

      entries.map { |key, value| "#{key}: #{value}" }
    end

    def constructor_field_type(receiver, field_name)
      names = []
      names << @current_class if receiver.nil? && @current_class
      names << receiver.location.slice.strip if receiver&.respond_to?(:location)
      names << constructor_output_name(receiver) if receiver
      names.uniq.each do |name|
        type = @class_instance_field_types[name][field_name]
        return type if type
      end

      nil
    end

    def constructor_field_value(receiver, field_name, value_node)
      code = visit(value_node)
      field_type = constructor_field_type(receiver, field_name)
      needs_copy = stored_borrowed_value?(value_node) ||
        (copyable_storage_type?(field_type) && !immediate_copy_safe_node?(value_node))
      if needs_copy && !code.start_with?("COPY ")
        code = "COPY #{code}"
      end
      wrap_argument_for_parameter_type(code, value_node, field_type)
    end

    def immediate_copy_safe_node?(node)
      node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode) ||
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::NilNode) ||
        node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode) ||
        node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
    end

    def constructor_from_arguments(receiver, arguments_node)
      fields = constructor_field_names(receiver)
      return nil unless fields

      class_name = constructor_output_name(receiver)
      defaults = constructor_field_defaults(receiver) || {}
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.last if args.last.is_a?(Prism::KeywordHashNode)
      positional_args = keyword_hash ? args[0...-1] : args

      assoc_pairs = []
      provided_fields = []
      positional_args.each_with_index do |arg, idx|
        field_name = fields[idx] || "field_#{idx}"
        provided_fields << field_name
        assoc_pairs << "#{field_name}: #{constructor_field_value(receiver, field_name, arg)}"
      end

      if keyword_hash
        keyword_entries = keyword_constructor_node_entries(keyword_hash)
        return keyword_entries if keyword_entries.is_a?(String) && keyword_entries.include?("# [UNSUPPORTED:")

        keyword_entries.each do |field_name, value_node|
          provided_fields << field_name
          assoc_pairs << "#{field_name}: #{constructor_field_value(receiver, field_name, value_node)}"
        end
      end

      fields.each do |field_name|
        next if provided_fields.include?(field_name)
        next unless defaults.key?(field_name)

        assoc_pairs << "#{field_name}: #{defaults[field_name]}"
      end

      assoc_pairs.empty? ? "#{class_name}{}" : "#{class_name}{ #{assoc_pairs.join(', ')} }"
    end

    def constructor_call_from_keywords(receiver, arguments_node)
      param_infos = constructor_parameter_info(receiver)
      return nil unless param_infos

      args = arguments_from_keywords(param_infos, arguments_node)
      return nil unless args && args.none?(&:nil?)

      class_name = constructor_receiver_class_name(receiver)
      return nil unless class_name

      "#{constructor_function_name(class_name)}(#{args.join(', ')})"
    end

    def constructor_call_from_positional(receiver, arguments_node)
      return nil unless constructor_parameter_info(receiver)

      param_infos = constructor_parameter_info(receiver)
      args = arguments_node ? arguments_node.arguments.each_with_index.map { |arg, idx| argument_for_parameter(arg, param_infos[idx]) } : []
      return nil if args.any?(&:nil?)

      class_name = constructor_receiver_class_name(receiver)
      return nil unless class_name

      "#{constructor_function_name(class_name)}(#{args.join(', ')})"
    end

    def struct_field_names_for(class_name)
      return nil unless class_name

      names = [class_name.to_s, class_name.to_s.split("::").last].uniq
      names.each do |name|
        fields = @struct_fields[name]
        return fields if fields
      end

      nil
    end

    def struct_type_name(class_name)
      class_name.to_s.split("::").last
    end

    def struct_with_call(node, receiver_type)
      return nil unless node.name.to_s == "with"
      return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

      class_name = receiver_type || @current_class
      fields = struct_field_names_for(class_name)
      return nil unless fields

      args = node.arguments ? node.arguments.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return nil unless keyword_hash
      return unsupported_expression(node, "T::Struct#with only supports keyword overrides") unless args.length == 1

      entries = keyword_constructor_entries(keyword_hash)
      return entries if entries.is_a?(String) && entries.include?("# [UNSUPPORTED:")

      overrides = entries.to_h
      unknown_fields = overrides.keys - fields
      unless unknown_fields.empty?
        return unsupported_expression(node, "T::Struct#with unknown fields: #{unknown_fields.join(', ')}")
      end

      pairs = fields.map do |field|
        value = overrides.key?(field) ? overrides[field] : "self.#{field}"
        "#{field}: #{value}"
      end
      "#{struct_type_name(class_name)}{ #{pairs.join(', ')} }"
    end

    def constructor_parameter_info(receiver)
      names = []
      names << @current_class if receiver.nil? && @current_class
      names << receiver.location.slice.strip if receiver
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @constructor_params[name] if @constructor_params[name]
      end

      nil
    end
    end
  end
end
