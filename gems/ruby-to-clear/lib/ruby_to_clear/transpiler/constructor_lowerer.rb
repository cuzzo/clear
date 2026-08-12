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
      return [] if args.length == 1 && args.first.is_a?(Prism::NilNode)

      fields = args.take_while { |arg| arg.is_a?(Prism::SymbolNode) }.map { |arg| arg.value.to_s }
      fields.empty? ? nil : fields
    end

    def struct_new_superclass?(node)
      !!struct_new_field_names(node)
    end

    def constructor_output_name(receiver)
      return clear_type_name_for_emit(@current_class) if receiver.nil? && @current_class

      raw = receiver.location.slice.strip
      raw = type_alias_for_path(raw).to_s if type_alias_for_path(raw)
      @helper_config.clear_type(raw) || clear_type_name_for_emit(raw)
    end

    def constructor_receiver_class_name(receiver)
      return @current_class if receiver.nil? && @current_class
      return nil unless receiver

      raw = receiver.location.slice.strip
      raw = type_alias_for_path(raw).to_s if type_alias_for_path(raw)
      mapped = @helper_config.clear_type(raw)
      return mapped if mapped

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
      if receiver&.respond_to?(:location) && (aliased_name = type_alias_for_path(receiver.location.slice.strip))
        names << aliased_name.to_s
        names << aliased_name.to_s.split("::").last
      end
      names << constructor_output_name(receiver) if receiver
      names.uniq.each do |name|
        type = @class_instance_field_types[name][field_name]
        return type if type
      end

      nil
    end

    def constructor_field_value(receiver, field_name, value_node)
      field_type = constructor_field_type(receiver, field_name)
      if value_node.is_a?(Prism::OrNode) && field_type.to_s.start_with?("?")
        return constructor_optional_or_value(value_node, field_type)
      end

      code = visit(value_node)
      needs_copy = stored_borrowed_value?(value_node) ||
        (copyable_storage_type?(field_type) && !immediate_copy_safe_node?(value_node))
      # Retained identity v4: an @multiowned field is a keep edge - the
      # compiler's keep-analysis derives retain/move/wrap from the source,
      # and a written COPY would force an identity fork instead. That also
      # covers the COPY the constructor-placeholder param wrap injects on a
      # bare param read (an explicit `.dup` still forks).
      if field_type.to_s.include?("@multiowned")
        needs_copy = false
        if value_node.is_a?(Prism::LocalVariableReadNode) && code == "COPY #{value_node.name}"
          code = code.delete_prefix("COPY ")
        end
      end
      if needs_copy && !code.start_with?("COPY ")
        code = "COPY #{code}"
      end
      wrap_argument_for_parameter_type(code, value_node, field_type)
    end

    def constructor_optional_or_value(node, field_type)
      source = next_generated_local("optional_or_source")
      result = next_generated_local("optional_or_result")
      left = expression_argument_code(node.left)
      right = expression_argument_code(node.right)
      left_value = "COPY #{source}"
      right_value = right
      right_value = "COPY #{right_value}" if stored_borrowed_value?(node.right) && !right_value.start_with?("COPY ")
      "( { MUTABLE #{source}: #{field_type} = #{left}; " \
        "MUTABLE #{result}: #{field_type} = NIL; " \
        "IF #{source} != NIL THEN #{result} = #{left_value}; " \
        "ELSE #{result} = #{right_value}; END #{result} } )"
    end

    def immediate_copy_safe_node?(node)
      return conditional_immediate_copy_safe?(node) if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)

      node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode) ||
        node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::NilNode) ||
        node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode) ||
        node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode)
    end

    def conditional_immediate_copy_safe?(node)
      return false unless node.statements&.body&.length == 1
      return false unless immediate_copy_safe_node?(node.statements.body.first)

      subsequent = node.subsequent
      return true unless subsequent
      return conditional_immediate_copy_safe?(subsequent) if subsequent.is_a?(Prism::IfNode) || subsequent.is_a?(Prism::UnlessNode)
      return false unless subsequent.is_a?(Prism::ElseNode)

      subsequent.statements&.body&.length == 1 && immediate_copy_safe_node?(subsequent.statements.body.first)
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

        default_source = defaults[field_name]
        default = default_source.is_a?(Prism::Node) ? visit(default_source) : default_source
        field_type = constructor_field_type(receiver, field_name).to_s
        if default == "NIL" && !field_type.empty? && field_type != "Any" && !field_type.start_with?("?")
          default = default_value_for_type(field_type)
        end
        assoc_pairs << "#{field_name}: #{default}"
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

      propagate_known_fallible_call("#{constructor_function_name(class_name)}(#{args.join(', ')})", "new", class_name)
    end

    def constructor_call_from_positional(receiver, arguments_node)
      return nil unless constructor_parameter_info(receiver)

      param_infos = constructor_parameter_info(receiver)
      args = arguments_node ? arguments_node.arguments.each_with_index.map { |arg, idx| argument_for_parameter(arg, param_infos[idx]) } : []
      return nil if args.any?(&:nil?)

      class_name = constructor_receiver_class_name(receiver)
      return nil unless class_name

      propagate_known_fallible_call("#{constructor_function_name(class_name)}(#{args.join(', ')})", "new", class_name)
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
      if receiver
        raw_name = receiver.location.slice.strip
        names << raw_name
        if (aliased_name = type_alias_for_path(raw_name))
          names << aliased_name.to_s
          names << aliased_name.to_s.split("::").last
        end
      end
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)
      names = names.uniq

      names.each do |name|
        return qualify_method_param_aliases(@constructor_params[name], name) if @constructor_params[name]
      end

      return nil unless receiver && @source_path

      # The class's initialize is defined in a file this unit doesn't itself
      # require (even a real, resolvable dependency reached only via the
      # compiler entrypoint's global load order, e.g. `Edit` in
      # fixable_error.rb). Resolve it lazily, bounded to constructor calls
      # only - see index_declared_owners_in_dir's comment for why this must
      # not be folded into the shared constant_namespace_metadata_candidates
      # path that every constant reference goes through.
      #
      # Dir tiers are the OUTER loop and name spellings the inner one -
      # every candidate name is tried at the nearest tier before escalating
      # to a wider one, and the very first name that resolves to a file ends
      # the search entirely (whether or not that file turns out to define a
      # keyword initializer). A Struct.new-based class, for example, resolves
      # to a real file but never populates @constructor_params; retrying
      # with another name spelling from progressively wider ancestor tiers
      # would just re-scan larger and larger directory trees for a class
      # that will never yield keyword params.
      constructor_lookup_ancestor_dirs(@source_path).each do |dir|
        index_declared_owners_in_dir(dir)

        names.each do |name|
          declared = @declared_owner_source_paths[name]
          next unless declared && declared.size == 1

          path = declared.first
          collect_metadata_from_file(path)
          return nil unless @constructor_params[name]

          # require_type_dependency (called by the constant_constructor_
          # call? branch before this resolves) already looked for this file
          # via the cheap tiers and found nothing, so the REQUIRE for it
          # wouldn't otherwise be emitted - register it ourselves, same as
          # require_type_dependency/require_method_dependency do for their
          # own discoveries.
          @required_files << clear_require_path_for_file(path)
          return qualify_method_param_aliases(@constructor_params[name], name)
        end
      end

      nil
    end

    def typed_ir_constructor_parameter_info(receiver)
      return constructor_parameter_info(receiver) if constructor_parameter_info(receiver)

      raw_name = receiver.location.slice.strip.delete_prefix("::")
      owner = [raw_name, raw_name.split("::").last].uniq.find do |candidate|
        @struct_fields.key?(candidate)
      end
      return nil unless owner

      @struct_fields.fetch(owner).map do |field|
        {
          name: field,
          type: class_instance_field_type(owner, field) || "Any"
        }
      end
    end
  end
end
end
