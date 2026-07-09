# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module TypeEnv
    SigMetadata = Struct.new(:param_types, :return_type, :type_params, keyword_init: true)

    SORBET_CONSTANT_TYPES = {
      "Integer" => "Int64",
      "Float" => "Float64",
      "String" => "String",
      "StringScanner" => "Scanner",
      "Symbol" => "String@symbol",
      "NilClass" => "Void",
      "Boolean" => "Bool",
      "TrueClass" => "Bool",
      "FalseClass" => "Bool",
      "BasicObject" => "Any",
      "T" => "Auto",
    }.freeze

    SORBET_PATH_TYPES = {
      "T::Boolean" => "Bool",
      "T::Array" => "Any",
      "T::Hash" => "Any",
      "T::Set" => "Any",
      "T.untyped" => "Auto",
    }.freeze

    private

    def parse_sig(sig_call_node)
      metadata = SigMetadata.new(param_types: {}, return_type: "Auto", type_params: [])

      sig_call_chain(sig_call_node).each do |call_node|
        apply_sig_metadata(metadata, call_node)
      end

      [metadata.param_types, metadata.return_type, metadata.type_params]
    end

    def sig_call_chain(sig_call_node)
      body_node = sig_call_node&.block&.body
      return [] unless body_node.is_a?(Prism::StatementsNode)

      body_node.body.flat_map { |stmt| call_receiver_chain(stmt) }
    end

    def call_receiver_chain(node)
      chain = []
      current = node
      while current.is_a?(Prism::CallNode)
        chain << current
        current = current.receiver
      end
      chain
    end

    def apply_sig_metadata(metadata, call_node)
      case call_node.name.to_s
      when "void"
        metadata.return_type = "Void"
      when "returns"
        metadata.return_type = sig_return_type(call_node)
      when "params"
        metadata.param_types.merge!(sig_param_types(call_node))
      when "type_parameters"
        metadata.type_params = sorbet_type_parameter_names(call_node)
      end
    end

    def sig_return_type(call_node)
      type_node = call_node.arguments&.arguments&.first
      return "Auto" unless type_node

      convert_sorbet_type(type_node, union_name: "ReturnValue", emit_union: true)
    end

    def sig_param_types(call_node)
      keyword_hash = call_node.arguments&.arguments&.first
      return {} unless keyword_hash.is_a?(Prism::KeywordHashNode)

      keyword_hash.elements.each_with_object({}) do |assoc, types|
        next unless assoc.is_a?(Prism::AssocNode)

        param_name = assoc.key.value.to_s
        types[param_name] = convert_sorbet_type(
          assoc.value,
          union_name: camel_type_name(param_name),
          emit_union: true
        )
      end
    end

    def convert_sorbet_type(node, union_name: nil, emit_union: false, map_key: false)
      return "Auto" unless node

      case node
      when Prism::ConstantReadNode
        convert_sorbet_constant_read_type(node)
      when Prism::ConstantPathNode
        convert_sorbet_constant_path_type(node, emit_union: emit_union)
      when Prism::CallNode
        convert_sorbet_call_type(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when Prism::ArrayNode
        members = node.elements.map { |element| convert_sorbet_type(element) }
        return "Auto" if members.empty? || members.any? { |member| member == "Auto" }

        "Tuple<#{members.join(', ')}>"
      else
        "Auto"
      end
    end

    def convert_sorbet_constant_read_type(node)
      name = node.name.to_s
      if (type_alias = type_alias_for_name(name))
        return expand_non_emitted_type_alias(type_alias)
      end

      @helper_config.clear_type(name) || SORBET_CONSTANT_TYPES.fetch(name, name)
    end

    def convert_sorbet_constant_path_type(node, emit_union:)
      path = node.location.slice.strip
      if (type_alias = type_alias_for_path(path))
        return expand_non_emitted_type_alias(type_alias)
      end

      if path == "AST::Node"
        ensure_ast_node_union!(emit: emit_union)
        return "Node"
      end

      SORBET_PATH_TYPES.fetch(path) { path.split("::").last }
    end

    def convert_sorbet_call_type(node, union_name:, emit_union:, map_key:)
      proc_type = sorbet_proc_type(node, union_name: union_name, emit_union: emit_union)
      return proc_type if proc_type

      t_type = convert_t_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      return t_type if t_type

      collection_type = convert_collection_type_call(node, union_name: union_name, emit_union: emit_union)
      return collection_type if collection_type

      "Auto"
    end

    def convert_t_type_call(node, union_name:, emit_union:, map_key:)
      return nil unless node.receiver&.location&.slice == "T"

      case node.name.to_s
      when "nilable"
        convert_nilable_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when "any"
        convert_any_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when "untyped", "anything"
        "Auto"
      when "type_parameter"
        convert_type_parameter_call(node)
      end
    end

    def convert_nilable_type_call(node, union_name:, emit_union:, map_key:)
      inner = convert_sorbet_type(
        node.arguments&.arguments&.first,
        union_name: union_name,
        emit_union: emit_union,
        map_key: map_key
      )
      return "Auto" if inner == "Auto"

      optional_clear_type(inner)
    end

    def convert_any_type_call(node, union_name:, emit_union:, map_key:)
      args = node.arguments ? node.arguments.arguments : []
      non_nil_args = args.reject { |arg| arg.location.slice.strip == "NilClass" }
      has_nil = non_nil_args.length != args.length

      type = if map_key && sorbet_string_symbol_union_args?(non_nil_args)
        "String"
      elsif non_nil_args.any? { |arg| sorbet_broad_any_type_node?(arg) }
        "Any"
      elsif non_nil_args.length == 1
        convert_sorbet_type(non_nil_args.first, union_name: union_name, emit_union: emit_union, map_key: map_key)
      else
        sorbet_union_from_any_args(non_nil_args, union_name: union_name, emit_union: emit_union) || "Auto"
      end

      has_nil && type != "Auto" ? optional_clear_type(type) : type
    end

    def convert_type_parameter_call(node)
      arg = node.arguments&.arguments&.first
      return nil unless arg.is_a?(Prism::SymbolNode)

      camel_type_name(arg.value.to_s)
    end

    def convert_collection_type_call(node, union_name:, emit_union:)
      return nil unless node.name.to_s == "[]"

      case node.receiver&.location&.slice
      when "T::Array", "Array"
        convert_array_type_call(node, union_name: union_name, emit_union: emit_union)
      when "T::Hash", "Hash"
        convert_hash_type_call(node, union_name: union_name, emit_union: emit_union)
      when "T::Set", "Set"
        convert_set_type_call(node, union_name: union_name, emit_union: emit_union)
      when "T::Enumerable", "Enumerable"
        convert_enumerable_type_call(node, union_name: union_name, emit_union: emit_union)
      end
    end

    def convert_array_type_call(node, union_name:, emit_union:)
      inner = convert_collection_item_type(node, union_name: union_name, emit_union: emit_union)
      return "Any[]" if inner == "Auto"

      "#{collection_element_type(inner)}[]"
    end

    def convert_hash_type_call(node, union_name:, emit_union:)
      args = node.arguments ? node.arguments.arguments : []
      key = convert_sorbet_type(args[0], union_name: union_name ? "#{union_name}Key" : nil, emit_union: emit_union, map_key: true)
      value = convert_sorbet_type(args[1], union_name: union_name ? "#{union_name}Value" : nil, emit_union: emit_union)
      return "Any" if key == "Auto" || value == "Auto"

      "HashMap<#{collection_element_type(key)}, #{collection_element_type(value)}>"
    end

    def convert_set_type_call(node, union_name:, emit_union:)
      inner = convert_collection_item_type(node, union_name: union_name, emit_union: emit_union)
      return "Any" if inner == "Auto"

      "#{collection_element_type(inner)}[]@set"
    end

    def convert_enumerable_type_call(node, union_name:, emit_union:)
      inner = convert_collection_item_type(node, union_name: union_name, emit_union: emit_union)
      return "Any" if inner == "Auto"

      "#{collection_element_type(inner)}[]"
    end

    def convert_collection_item_type(node, union_name:, emit_union:)
      convert_sorbet_type(
        node.arguments&.arguments&.first,
        union_name: union_name ? "#{union_name}Item" : nil,
        emit_union: emit_union
      )
    end

    def sorbet_string_symbol_union_args?(args)
      names = args.map do |arg|
        case arg.class.name.split("::").last
        when "ConstantReadNode"
          arg.name.to_s
        when "ConstantPathNode"
          arg.location.slice.strip
        end
      end
      names.compact.sort == ["String", "Symbol"]
    end

    def sorbet_broad_any_type_node?(node)
      return true if node.is_a?(Prism::ConstantReadNode) && node.name.to_s == "Object"
      return true if node.is_a?(Prism::ConstantPathNode) && node.location.slice.strip == "T.untyped"
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver&.location&.slice == "T"

      ["untyped", "anything"].include?(node.name.to_s)
    end

    def sorbet_proc_type(node, union_name:, emit_union:)
      return nil unless node.is_a?(Prism::CallNode)

      params = []
      return_type = "Auto"
      found_proc = false
      current = node

      while current.is_a?(Prism::CallNode)
        case current.name.to_s
        when "proc"
          found_proc = current.receiver&.location&.slice == "T"
        when "params"
          params = sorbet_proc_param_types(current, union_name: union_name, emit_union: emit_union)
        when "returns"
          arg = current.arguments&.arguments&.first
          return_type = convert_sorbet_type(arg, union_name: union_name ? "#{union_name}Return" : nil, emit_union: emit_union)
        when "void"
          return_type = "Void"
        end
        current = current.receiver
      end

      return nil unless found_proc

      "FN(#{params.join(', ')}) -> #{return_type}"
    end

    def sorbet_proc_param_types(node, union_name:, emit_union:)
      args = node.arguments ? node.arguments.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      values = if keyword_hash
        keyword_hash.elements.filter_map { |assoc| assoc.value if assoc.is_a?(Prism::AssocNode) }
      else
        args
      end

      values.each_with_index.map do |value, index|
        convert_sorbet_type(value, union_name: union_name ? "#{union_name}Param#{index + 1}" : nil, emit_union: emit_union)
      end
    end

    def sorbet_type_parameter_names(node)
      args = node.arguments ? node.arguments.arguments : []
      args.filter_map do |arg|
        next camel_type_name(arg.value.to_s) if arg.is_a?(Prism::SymbolNode)
        next camel_type_name(arg.content) if arg.is_a?(Prism::StringNode)
      end
    end

    def ensure_ast_node_union!(emit:)
      members = @union_types["Node"]
      return nil unless members && members.any?

      @generated_union_defs["Node"] = union_definition("Node", members) if emit
      "Node"
    end

    def sentinel_type_node?(node)
      return false unless node

      %w[TypeCapabilityUnset TypePlacementUnset].include?(node.location.slice.strip.split("::").last)
    end

    def type_alias_for_name(name)
      if @current_class
        scoped_key = "#{@current_class}::#{name}"
        return @type_aliases[scoped_key] if @type_aliases.key?(scoped_key)
      end

      @type_aliases[name.to_s]
    end

    def type_alias_for_path(path)
      normalized = path.to_s.tr(".", "::")
      segments = normalized.split("::")
      candidates = [path.to_s, normalized]
      candidates << type_alias_key(segments.last) if @current_class && segments.any?

      if segments.length > 1
        1.upto(segments.length - 1) do |index|
          candidates << segments[index..].join("::")
        end
      end

      candidates.uniq.each do |candidate|
        return @type_aliases[candidate] if @type_aliases.key?(candidate)
      end

      nil
    end

    def type_alias_key(name, current_class = @current_class)
      current_class ? "#{current_class}::#{name}" : name.to_s
    end

    def type_alias_clear_name(name, current_class = @current_class)
      current_class ? camel_type_name("#{current_class}::#{name}") : name.to_s
    end

    def with_current_class(class_name)
      old_class = @current_class
      @current_class = class_name
      yield
    ensure
      @current_class = old_class
    end

    def scoped_method_key(class_name, method_name)
      class_name ? "#{class_name}##{method_name}" : method_name.to_s
    end

    def method_param_types_for(method_name, class_name = nil)
      if class_name
        scoped = scoped_method_key(class_name, method_name)
        return @method_param_types[scoped] if @method_param_types.key?(scoped)
      end

      @method_param_types[method_name.to_s] || {}
    end

    def method_params_for(method_name, class_name = nil)
      if class_name
        scoped = scoped_method_key(class_name, method_name)
        return @method_params[scoped] if @method_params.key?(scoped)
      end

      @method_params[method_name.to_s]
    end

    def method_return_type_for(method_name, class_name = nil)
      if class_name
        scoped = scoped_method_key(class_name, method_name)
        return @method_return_types[scoped] if @method_return_types.key?(scoped)
      end

      @method_return_types[method_name.to_s]
    end

    def sorbet_union_from_any_args(args, union_name:, emit_union:)
      return nil unless union_name

      members = args.each_with_index.map do |arg, index|
        convert_sorbet_type(arg, union_name: sorbet_union_member_context_name(union_name, arg, index), emit_union: emit_union)
      end
      return nil if members.length < 2
      return nil unless members.all? { |type| union_member_payload_type?(type) }

      register_union_type(union_name, members, emit: emit_union)
    end

    def union_member_payload_type?(type)
      text = type.to_s
      return false if text.empty? || text == "Auto" || text == "Any"
      return false if text == "Void"

      true
    end

    def register_union_type(name, members, emit:)
      clear_name = camel_type_name(name)
      normalized_members = members.map { |member| clear_type_expr(member) }.uniq
      return "Auto" if normalized_members.empty?

      normalized_members = ((@union_types[clear_name] || []) + normalized_members).uniq
      @union_types[clear_name] = normalized_members
      @generated_union_defs[clear_name] = union_definition(clear_name, normalized_members) if emit
      @type_alias_union_deps[@type_alias_context.last] << clear_name if @type_alias_context.any?
      clear_name
    end

    def union_definition(name, members)
      seen = Hash.new(0)
      variants = members.map do |member|
        base_name = union_variant_name(member)
        seen[base_name] += 1
        variant_name = seen[base_name] == 1 ? base_name : "#{base_name}#{seen[base_name]}"

        "#{variant_name}: #{member}"
      end.join(", ")
      "UNION #{name} { #{variants} }"
    end

    def union_variant_name(type)
      text = type.to_s
      return "StringValue" if text == "String"
      return "SymbolValue" if text == "String@symbol"
      return "Int64Value" if text == "Int64"
      return "Float64Value" if text == "Float64"
      return "BoolValue" if text == "Bool"
      return "ArrayValue" if text.include?("[]")
      return "HashMapValue" if text.start_with?("HashMap<")
      return "FunctionValue" if text.start_with?("FN(") || text.include?(" -> ")
      return "OptionalValue" if text.start_with?("?")

      raw_name = text.split(".").last
      return raw_name if raw_name.match?(/\A[A-Za-z_]\w*\z/)

      camel_type_name(raw_name)
    end

    def optional_clear_type(type)
      text = type.to_s
      return text if text.start_with?("?")
      return "Auto" if text == "Auto"

      "?#{text}"
    end

    def sorbet_union_member_context_name(parent_name, arg, index)
      suffix = case arg
      when Prism::ConstantReadNode
        camel_type_name(arg.name.to_s)
      when Prism::ConstantPathNode
        camel_type_name(arg.location.slice.strip.split("::").last)
      when Prism::CallNode
        receiver_name = arg.receiver ? arg.receiver.location.slice.strip : ""
        if arg.name.to_s == "[]"
          case receiver_name
          when "T::Array", "Array" then "Array"
          when "T::Hash", "Hash" then "Hash"
          when "T::Set", "Set" then "Set"
          when "T::Enumerable", "Enumerable" then "Enumerable"
          else "Member#{index + 1}"
          end
        elsif arg.receiver&.location&.slice == "T" && arg.name.to_s == "any"
          "Union"
        else
          "Member#{index + 1}"
        end
      else
        "Member#{index + 1}"
      end

      "#{parent_name}#{suffix}"
    end

    def union_definitions_for_alias(alias_name, type_alias)
      names = @type_alias_union_deps[alias_name].to_a
      names << type_alias if @union_types.key?(type_alias)
      names.sort_by { |name| [name == type_alias ? 1 : 0, name] }.filter_map do |name|
        next if @body_union_defs.include?(name)

        @body_union_defs << name
        union_definition(name, @union_types[name])
      end
    end

    def with_type_alias_context(alias_name)
      if alias_name
        @type_alias_context << alias_name
      end
      yield
    ensure
      @type_alias_context.pop if alias_name
    end

    def camel_type_name(name)
      parts = name.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?)
      return "Value" if parts.empty?

      parts.map { |part| part[0].upcase + part[1..].to_s }.join
    end
    end
  end
end
