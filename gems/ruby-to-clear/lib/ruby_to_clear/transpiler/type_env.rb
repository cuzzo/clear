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
      "Proc" => "Any",
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
      metadata = SigMetadata.new(param_types: {}, return_type: untyped_type, type_params: [])

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
      return untyped_type unless type_node

      union_name = if @imported_union_names.include?("ReturnValue")
        "#{camel_type_name((@current_class || 'Local').split('::').last)}ReturnValue"
      else
        "ReturnValue"
      end
      convert_sorbet_type(type_node, union_name: union_name, emit_union: true)
    end

    def sig_param_types(call_node)
      keyword_hash = call_node.arguments&.arguments&.first
      return {} unless keyword_hash.is_a?(Prism::KeywordHashNode)

      old_in_sig = @in_function_signature
      @in_function_signature = true
      begin
        keyword_hash.elements.each_with_object({}) do |assoc, types|
          next unless assoc.is_a?(Prism::AssocNode)

          param_name = assoc.key.value.to_s
          types[param_name] = convert_sorbet_type(
            assoc.value,
            union_name: camel_type_name(param_name),
            emit_union: true
          )
        end
      ensure
        @in_function_signature = old_in_sig
      end
    end

    def convert_sorbet_type(node, union_name: nil, emit_union: false, map_key: false)
      res = convert_sorbet_type_raw(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      resolve_type_with_aliasable(res)
    end

    def convert_sorbet_type_raw(node, union_name: nil, emit_union: false, map_key: false)
      return untyped_type unless node

      case node
      when Prism::ConstantReadNode
        convert_sorbet_constant_read_type(node)
      when Prism::ConstantPathNode
        convert_sorbet_constant_path_type(node, emit_union: emit_union)
      when Prism::CallNode
        convert_sorbet_call_type(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when Prism::ArrayNode
        members = node.elements.map { |element| convert_sorbet_type(element) }
        return untyped_type if members.empty? || members.any? { |member| member == untyped_type }

        "Tuple<#{members.join(', ')}>"
      else
        untyped_type
      end
    end

    def convert_sorbet_constant_read_type(node)
      name = node.name.to_s
      # An explicit helper-config type mapping overrides alias expansion:
      # a project may alias Integer as a domain type (e.g. TokenInt) whose
      # translated representation is intentionally different (UInt64).
      if (configured = @helper_config.clear_type(name))
        return configured
      end
      if (type_alias = type_alias_for_name(name))
        return expand_non_emitted_type_alias(type_alias)
      end

      SORBET_CONSTANT_TYPES.fetch(name) { clear_constant_type_name(name) }
    end

    def convert_sorbet_constant_path_type(node, emit_union:)
      path = node.location.slice.strip
      if path == "AST::Node"
        if (type_alias = type_alias_for_path(path))
          return expand_non_emitted_type_alias(type_alias)
        end
        ensure_ast_node_union!(emit: emit_union)
        return "Node"
      end
      return @helper_config.clear_type(path) if @helper_config.clear_type(path)
      if (type_alias = type_alias_for_path(path))
        return expand_non_emitted_type_alias(type_alias)
      end

      return untyped_type if path == "T.untyped"

      SORBET_PATH_TYPES.fetch(path) { clear_constant_type_name(path) }
    end

    def convert_sorbet_call_type(node, union_name:, emit_union:, map_key:)
      proc_type = sorbet_proc_type(node, union_name: union_name, emit_union: emit_union)
      return proc_type if proc_type

      t_type = convert_t_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      return t_type if t_type

      collection_type = convert_collection_type_call(node, union_name: union_name, emit_union: emit_union)
      return collection_type if collection_type

      untyped_type
    end

    def convert_t_type_call(node, union_name:, emit_union:, map_key:)
      return nil unless node.receiver&.location&.slice == "T"

      case node.name.to_s
      when "nilable"
        convert_nilable_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when "any"
        convert_any_type_call(node, union_name: union_name, emit_union: emit_union, map_key: map_key)
      when "untyped", "anything"
        untyped_type
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
      optional_clear_type(inner)
    end

    def convert_any_type_call(node, union_name:, emit_union:, map_key:)
      args = node.arguments ? node.arguments.arguments : []
      non_nil_args = args.reject { |arg| arg.location.slice.strip == "NilClass" }
      has_nil = non_nil_args.length != args.length

      # Hash keys must stay scalar: CLEAR map keys cannot be unions, so the
      # String|Symbol pair keeps its historical String@symbol collapse there.
      type = if map_key && sorbet_string_symbol_union_args?(non_nil_args)
        "String@symbol"
      elsif non_nil_args.any? { |arg| sorbet_broad_any_type_node?(arg) }
        "Any"
      elsif non_nil_args.length == 1
        convert_sorbet_type(non_nil_args.first, union_name: union_name, emit_union: emit_union, map_key: map_key)
      else
        sorbet_union_from_any_args(non_nil_args, union_name: union_name, emit_union: emit_union) ||
          (sorbet_string_symbol_union_args?(non_nil_args) ? "String@symbol" : untyped_type)
      end

      has_nil && type != untyped_type ? optional_clear_type(type) : type
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

      # Function parameters are borrowed at the top level, but elements of a
      # Ruby Array still retain Ruby object identity. Keep reference-backed
      # element types reference-backed even while parsing a signature; using a
      # value element here makes parameter and return types disagree after
      # operations such as `uniq`/DISTINCT.
      base = inner.to_s.delete_prefix("?").split("@").first.to_s.delete_suffix("[]")
      inner = apply_multiowned_sigil(inner) if @aliasable_classes.include?(base)

      "#{collection_element_type(inner)}[]"
    end

    def convert_hash_type_call(node, union_name:, emit_union:)
      args = node.arguments ? node.arguments.arguments : []
      key = convert_sorbet_type(args[0], union_name: union_name ? "#{union_name}Key" : nil, emit_union: emit_union, map_key: true)
      value = convert_sorbet_type(args[1], union_name: union_name ? "#{union_name}Value" : nil, emit_union: emit_union)
      return "Any" if key == "Auto" || value == "Auto"

      "HashMap<#{map_element_type(key)}, #{map_element_type(value)}>"
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
      return_type = untyped_type
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

      return_type = fallible_return_type(return_type) if allocating_collection_return_type?(return_type)
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

      @generated_union_defs["Node"] = union_definition("Node", members) if emit && !@imported_union_names.include?("Node")
      "Node"
    end

    def sentinel_type_node?(node)
      return false unless node

      %w[TypeCapabilityUnset TypePlacementUnset].include?(node.location.slice.strip.split("::").last)
    end

    def type_alias_for_name(name)
      if @current_class
        namespace = @current_class.split("::")
        while namespace.any?
          scoped_key = "#{namespace.join('::')}::#{name}"
          return @type_aliases[scoped_key] if @type_aliases.key?(scoped_key)

          namespace.pop
        end
      end

      direct = @type_aliases[name.to_s]
      return direct if direct

      suffix = "::#{name}"
      is_known_class = @class_instance_field_types.key?(name.to_s) ||
                        @constructor_params.key?(name.to_s) ||
                        @aliasable_classes.include?(name.to_s)
      unless is_known_class
        suffix_matches = @type_aliases.keys.select { |key| key.end_with?(suffix) }
        return @type_aliases[suffix_matches.first] if suffix_matches.length == 1
      end

      nil
    end

    def type_alias_for_path(path)
      normalized = path.to_s.tr(".", "::")
      segments = normalized.split("::")
      candidates = [path.to_s, normalized]
      candidates << type_alias_key(segments.last) if @current_class && segments.any?
      candidates << type_alias_key(normalized) if @current_class

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
      return name.to_s unless current_class
      # Ruby modules are pure namespaces that CLEAR flattens away, so aliases
      # declared directly in a module keep their unqualified reference name.
      # Aliases owned by a class stay prefixed to avoid cross-class collisions.
      return camel_type_name(name) if @type_alias_module_namespaces.include?(current_class)

      camel_type_name("#{current_class}::#{name}")
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

    def transitive_includes(name, seen = Set.new)
      return [] if seen.include?(name)
      seen = seen | [name]

      direct = (@class_includes[name] || []) + (@mixin_includes[name] || [])
      direct.flat_map do |included|
        resolved = resolved_mixin_metadata_name(included, name)
        [included, resolved, *transitive_includes(resolved, seen)].uniq
      end.uniq
    end

    def resolve_qualified_class_name(class_name)
      return nil unless class_name
      class_name_str = class_name.to_s.delete_prefix("?").split("@").first.to_s.delete_suffix("[]")
      cache_key = [@current_class.to_s, class_name_str]
      if @metadata_finalized && @qualified_class_resolution_cache.key?(cache_key)
        return @qualified_class_resolution_cache[cache_key]
      end

      declared_names = (
        @class_instance_method_names.select { |_name, methods| methods.any? }.keys +
        @class_class_method_names.select { |_name, methods| methods.any? }.keys +
        @class_instance_field_types.select { |_name, fields| fields.any? }.keys +
        @struct_fields.select { |_name, fields| fields.any? }.keys
      ).uniq
      lexical = nil
      unless class_name_str.include?("::") || @current_class.to_s.empty?
        scope = @current_class.to_s.split("::")
        scope.pop
        scope.length.downto(1) do |length|
          candidate = (scope.first(length) + [class_name_str]).join("::")
          if declared_names.include?(candidate)
            lexical = candidate
            break
          end
        end
      end

      exact = lexical || (@constant_names.key?(class_name_str) ? class_name_str : nil) ||
        @type_aliases.keys.find { |k| k == class_name_str || k.end_with?("::#{class_name_str}") } ||
        @imported_class_names.find { |name| name.end_with?("::#{class_name_str}") }
      resolved = if exact
        exact
      else
        # Hashes with default procs acquire empty basename entries during
        # speculative lookups. Those are not declarations and must not make a
        # unique qualified symbol appear ambiguous (for example the nested
        # FunctionSignature::AnalysisFacts type versus an empty AnalysisFacts
        # lookup bucket).
        matches = declared_names.select do |name|
          name == class_name_str || name.end_with?("::#{class_name_str}") || name.end_with?(".#{class_name_str}")
        end
        matches.one? ? matches.first : class_name_str
      end
      @qualified_class_resolution_cache[cache_key] = resolved if @metadata_finalized
      resolved
    end

    def method_param_types_for(method_name, class_name = nil)
      if class_name
        class_name = resolve_qualified_class_name(class_name)
        [class_name, class_name.to_s.split("::").last].uniq.each do |c_name|
          scoped = scoped_method_key(c_name, method_name)
          return @method_param_types[scoped] if @method_param_types.key?(scoped)
        end

        if (includes = transitive_includes(class_name))
          includes.each do |inc|
            [inc, inc.to_s.split("::").last].uniq.each do |c_name|
              scoped_inc = scoped_method_key(c_name, method_name)
              return @method_param_types[scoped_inc] if @method_param_types.key?(scoped_inc)
            end
          end
        end
      end

      @method_param_types[method_name.to_s] || {}
    end

    def method_params_for(method_name, class_name = nil)
      if class_name
        class_name = resolve_qualified_class_name(class_name)
        scoped = scoped_method_key(class_name, method_name)
        if @method_params.key?(scoped)
          return qualify_method_param_aliases(@method_params[scoped], class_name)
        end

        if (includes = transitive_includes(class_name))
          includes.each do |inc|
            scoped_inc = scoped_method_key(inc, method_name)
            if @method_params.key?(scoped_inc)
              return qualify_method_param_aliases(@method_params[scoped_inc], class_name)
            end
          end
        end

        # Expanded mixin methods are emitted on the concrete receiver, while
        # their declaration signature remains owned by the source mixin. Use a
        # signature only when all matching declarations agree; ambiguity stays
        # unresolved instead of being guessed by the emitter.
        matching = @method_params.filter_map do |key, params|
          params if key.to_s.end_with?("##{method_name}")
        end
        canonical = matching.uniq do |params|
          params.map { |param| [param[:name], param[:kind], param[:type].to_s, param[:mutable], param[:default]&.location&.slice] }
        end
        return qualify_method_param_aliases(canonical.first, class_name) if canonical.one?
      end

      @method_params[method_name.to_s]
    end

    def qualify_method_param_aliases(params, class_name)
      params.map do |param|
        type = param[:type].to_s
        owners = [class_name.to_s, class_name.to_s.split("::").last].uniq
        qualified = owners.filter_map do |owner|
          candidate = "#{owner}::#{type}"
          candidate if @type_aliases.key?(candidate)
        end.first
        unless qualified
          local_aliases = owners.flat_map do |owner|
            @type_aliases.keys.grep(/\A#{Regexp.escape(owner)}::/)
          end.uniq
          suffix_matches = local_aliases.select do |candidate|
            type.delete_prefix("?").end_with?(candidate.split("::").last)
          end
          qualified = suffix_matches.first if suffix_matches.one?
        end
        next param unless !type.empty? && !type.include?("::") && qualified

        param.merge(type: qualified)
      end
    end

    def method_return_type_for(method_name, class_name = nil)
      if class_name
        class_name = resolve_qualified_class_name(class_name)
        [class_name, class_name.to_s.split("::").last].uniq.each do |c_name|
          scoped = scoped_method_key(c_name, method_name)
          return @method_return_types[scoped] if @method_return_types.key?(scoped)
        end

        if (includes = transitive_includes(class_name))
          includes.each do |inc|
            [inc, inc.to_s.split("::").last].uniq.each do |c_name|
              scoped_inc = scoped_method_key(c_name, method_name)
              return @method_return_types[scoped_inc] if @method_return_types.key?(scoped_inc)
            end
          end
        end

        owner = class_name
        %w[BindingLifecycleFacts BindingFlowFacts].each do |facts_class|
          ["#{owner}::#{facts_class}", facts_class].each do |facts_owner|
            field_type = @class_instance_field_types[facts_owner][method_name.to_s]
            return field_type if field_type
          end
        end
      end

      @method_return_types[method_name.to_s]
    end
    public :method_return_type_for

    def method_return_type_identity_for(method_name, class_name = nil)
      if class_name
        class_name = resolve_qualified_class_name(class_name)
        [class_name, class_name.to_s.split("::").last].uniq.each do |candidate|
          key = scoped_method_key(candidate, method_name)
          return @method_return_type_identities[key] if @method_return_type_identities.key?(key)
        end
        transitive_includes(class_name).each do |included|
          [included, included.to_s.split("::").last].uniq.each do |candidate|
            key = scoped_method_key(candidate, method_name)
            return @method_return_type_identities[key] if @method_return_type_identities.key?(key)
          end
        end
      end

      @method_return_type_identities[method_name.to_s]
    end

    def sorbet_union_from_any_args(args, union_name:, emit_union:)
      return nil unless union_name

      members = args.each_with_index.flat_map do |arg, index|
        type = convert_sorbet_type(arg, union_name: sorbet_union_member_context_name(union_name, arg, index), emit_union: emit_union)
        flattened_union_member_types(type)
      end
      return nil if members.length < 2
      return nil unless members.all? { |type| union_member_payload_type?(type) }

      register_union_type(union_name, members, emit: emit_union)
    end

    def flattened_union_member_types(type)
      text = type.to_s
      return [text] if text.start_with?("?")

      expanded = expand_non_emitted_type_alias(text).to_s
      # Locatable is the canonical representation of AST::Node, but a wider
      # union containing AST::Node must contain its concrete variants. CLEAR
      # unions are nominal and do not provide transitive IS_A through a nested
      # union payload.
      return @union_types[expanded] if expanded == "Locatable" && @union_types[expanded]
      return [expanded] if @closed_interface_unions.include?(expanded)

      @union_types[expanded] || [expanded]
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
      return untyped_type if normalized_members.empty?

      normalized_members = ((@union_types[clear_name] || []) + normalized_members).uniq
      @union_types[clear_name] = normalized_members
      @generated_union_defs[clear_name] = union_definition(clear_name, normalized_members) if emit
      @type_alias_union_deps[@type_alias_context.last] << clear_name if @type_alias_context.any?
      clear_name
    end

    def union_definition(name, members, visibility: "")
      seen = Hash.new(0)
      variants = members.map do |member|
        base_name = union_variant_name(member, name)
        seen[base_name] += 1
        variant_name = seen[base_name] == 1 ? base_name : "#{base_name}#{seen[base_name]}"

        "#{variant_name}: #{member}"
      end.join(", ")
      "#{visibility}UNION #{name} { #{variants} }"
    end

    def union_variant_name(type, union_name = nil)
      text = type.to_s
      configured = @configured_union_variants.dig(union_name.to_s, text) if union_name
      return configured if configured

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

      # CLEAR intentionally parses ?T[] as an array of optional elements.
      # Sorbet's T.nilable(T::Array[T]) and T.nilable(T::Set[T]) describe an
      # optional collection instead, which requires an explicit grouping.
      return "?(#{text})" if text.match?(/\[\](?:@\w+)*\z/)

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

    def union_definitions_for_alias(alias_name, type_alias, visibility: "")
      names = @type_alias_union_deps[alias_name].to_a
      names << type_alias if @union_types.key?(type_alias)
      names.sort_by { |name| [name == type_alias ? 1 : 0, name] }.filter_map do |name|
        next if @body_union_defs.include?(name)
        next if @imported_union_names.include?(name)

        @body_union_defs << name
        union_definition(name, @union_types[name], visibility: visibility)
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
