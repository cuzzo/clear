# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module LocalAnalyzer
    private

    def collect_written_variables(node, parameter_names = Set.new, exclude_defs: false)
      written = Set.new
      walk = ->(n) do
        return unless n
        if exclude_defs && n.is_a?(Prism::DefNode)
          return
        end
        return if n.is_a?(Prism::BlockNode)

        if n.respond_to?(:name) && n.class.name.start_with?("Prism::LocalVariable") &&
           (n.class.name.end_with?("WriteNode") || n.class.name.end_with?("TargetNode"))
          written << n.name.to_s
        end
        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      written
    end

    def collect_predeclared_local_variables(node, parameter_names = Set.new)
      names = Set.new
      collect_predeclared_from_statement_list(
        statement_list_body(node),
        parameter_names.to_set,
        names,
        parameter_names.to_set
      )
      names
    end

    def predeclare_child_scope?(node)
      node.is_a?(Prism::IfNode) ||
        node.is_a?(Prism::CaseNode) ||
        node.is_a?(Prism::WhileNode) ||
        node.is_a?(Prism::UntilNode) ||
        node.is_a?(Prism::BeginNode)
    end

    def collect_predeclared_from_statement_list(statements, parameter_names, names, declared_so_far)
      statements.each_with_index do |stmt, index|
        if predeclare_child_scope?(stmt)
          needed = control_flow_locals_read_after(stmt, statements[(index + 1)..] || [], parameter_names, declared_so_far)
          names.merge(needed)
          declared_so_far.merge(needed)
          collect_predeclared_from_child_statement_lists(stmt, parameter_names, names, declared_so_far.dup)
        else
          collect_predeclared_from_child_statement_lists(stmt, parameter_names, names, declared_so_far.dup)
        end

        declared_so_far.merge(current_scope_local_declarations(stmt) - parameter_names)
      end
    end

    def control_flow_locals_read_after(stmt, later_statements, parameter_names, declared_so_far)
      written = collect_written_variables(stmt, parameter_names, exclude_defs: true) - parameter_names
      return Set.new if written.empty?

      reads_after = collect_read_variables_from_nodes(later_statements)
      (written & reads_after) - declared_so_far
    end

    def collect_predeclared_from_child_statement_lists(node, parameter_names, names, declared_so_far)
      case node
      when Prism::IfNode, Prism::UnlessNode
        collect_predeclared_from_statement_list(statement_list_body(node.statements), parameter_names, names, declared_so_far.dup)
        consequent = node.consequent
        if consequent.is_a?(Prism::IfNode)
          collect_predeclared_from_statement_list([consequent], parameter_names, names, declared_so_far.dup)
        elsif consequent
          collect_predeclared_from_statement_list(statement_list_body(consequent.statements), parameter_names, names, declared_so_far.dup)
        end
      when Prism::CaseNode
        node.conditions.each do |condition|
          collect_predeclared_from_statement_list(statement_list_body(condition.statements), parameter_names, names, declared_so_far.dup)
        end
        collect_predeclared_from_statement_list(statement_list_body(node.consequent&.statements), parameter_names, names, declared_so_far.dup)
      when Prism::WhileNode, Prism::UntilNode, Prism::BeginNode
        collect_predeclared_from_statement_list(statement_list_body(node.statements), parameter_names, names, declared_so_far.dup)
      end
    end

    def statement_list_body(node)
      return [] unless node
      return node.body if node.respond_to?(:body) && node.body

      []
    end

    def collect_read_variables_from_nodes(nodes)
      reads = Set.new
      walk = lambda do |n|
        return unless n
        return if n.is_a?(Prism::DefNode) || n.is_a?(Prism::BlockNode)

        if n.is_a?(Prism::LocalVariableReadNode)
          reads << n.name.to_s
          return
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end
      nodes.each { |node| walk.call(node) }
      reads
    end

    def current_scope_local_declarations(stmt)
      case stmt
      when Prism::LocalVariableWriteNode,
           Prism::LocalVariableOperatorWriteNode,
           Prism::LocalVariableOrWriteNode,
           Prism::LocalVariableAndWriteNode
        Set[stmt.name.to_s]
      when Prism::MultiWriteNode
        stmt.lefts.filter_map do |target|
          target.name.to_s if target.is_a?(Prism::LocalVariableTargetNode)
        end.to_set
      else
        Set.new
      end
    end

    def collect_local_variable_type_annotations(node)
      types = {}
      old_local_types = @local_types
      @local_types = {}
      walk = ->(n) do
        return unless n
        return if n.is_a?(Prism::DefNode) || n.is_a?(Prism::BlockNode)

        if n.is_a?(Prism::IfNode)
          runtime_is_a = runtime_is_a_predicate(n.predicate)
          if runtime_is_a
            walk.call(n.predicate)
            with_narrowing_context(runtime_is_a) { walk.call(n.statements) }
            walk.call(n.consequent)
            return
          end
        end

        if n.is_a?(Prism::LocalVariableWriteNode)
          type = if (typed_value = sorbet_typed_value(n.value))
            typed_value[1]
          else
            inferred_clear_type(n.value)
          end
          record_collected_local_type(types, n.name.to_s, type)
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      types
    ensure
      @local_types = old_local_types
    end

    def record_collected_local_type(types, name, type)
      return unless concrete_predeclared_type?(type)

      if types.key?(name) && types[name] != type
        types[name] = nil
        @local_types.delete(name)
      else
        types[name] = type
        @local_types[name] = type
      end
    end

    def concrete_predeclared_type?(type)
      type && !["Auto", "Any", "Void"].include?(type.to_s)
    end

    def predeclared_local_declaration(name, type)
      return "MUTABLE #{name} = NIL;" unless concrete_predeclared_type?(type)

      default = default_value_for_type(type)
      return "MUTABLE #{name} = NIL;" if default == "NIL" && !type.to_s.start_with?("?")

      "MUTABLE #{name}: #{type} = #{default};"
    end

    def predeclare_local_variable?(type)
      return true unless concrete_predeclared_type?(type)

      default = default_value_for_type(type)
      !(default == "NIL" && !type.to_s.start_with?("?"))
    end

    def default_value_for_type(type)
      raw_text = type.to_s
      return "Set[]" if raw_text.end_with?("[]@set")
      return "[]" if raw_text.end_with?("[]")
      return "NIL" if raw_text.start_with?("?")

      text = expand_clear_type_alias(raw_text).to_s
      return "Set[]" if text.end_with?("[]@set")
      return "[]" if text.end_with?("[]")
      return "NIL" if text.start_with?("?")
      return "NIL" if text == "Void"
      return function_default_value(text) if function_clear_type?(text)
      return "FALSE" if text == "Bool"
      return "0.0" if %w[Float32 Float64].include?(text)
      return "0" if text.match?(/\A(?:U?Int|Byte)\d*\z/)
      return "\"\"" if text == "String"
      return "{}" if text.start_with?("HashMap<")

      "NIL"
    end

    def function_clear_type?(type)
      function_clear_type_parts(type) != nil
    end

    def function_default_value(type)
      parts = function_clear_type_parts(type)
      return "NIL" unless parts

      params, return_type = parts
      param_names = params.map.with_index { |param, index| "arg#{index}: #{function_type_param_type(param)}" }
      body = if return_type == "Void"
        "{}"
      elsif return_type.start_with?("?")
        "CAST(NIL AS #{return_type})"
      else
        default_value_for_type(return_type)
      end
      "%(#{param_names.join(', ')}) -> #{body}"
    end

    def function_type_param_type(param)
      text = param.to_s.strip
      return text unless text.include?(":")

      text.split(":", 2).last.strip
    end

    def function_clear_type_parts(type)
      text = type.to_s.strip
      return nil unless text.start_with?("FN(")

      close_index = matching_paren_index(text, 2)
      return nil unless close_index

      rest = text[(close_index + 1)..].to_s.strip
      return nil unless rest.start_with?("->")

      return_type = rest.delete_prefix("->").strip
      return nil if return_type.empty?

      params_text = text[3...close_index].to_s.strip
      params = params_text.empty? ? [] : split_top_level_clear_list(params_text)
      [params, return_type]
    end

    def matching_paren_index(text, open_index)
      depth = 0
      text.chars.each_with_index do |char, index|
        next if index < open_index

        case char
        when "("
          depth += 1
        when ")"
          depth -= 1
          return index if depth.zero?
        end
      end
      nil
    end

    def split_top_level_clear_list(text)
      parts = []
      current = +""
      paren_depth = 0
      angle_depth = 0
      bracket_depth = 0

      text.each_char do |char|
        case char
        when "("
          paren_depth += 1
        when ")"
          paren_depth -= 1 if paren_depth.positive?
        when "<"
          angle_depth += 1
        when ">"
          angle_depth -= 1 if angle_depth.positive?
        when "["
          bracket_depth += 1
        when "]"
          bracket_depth -= 1 if bracket_depth.positive?
        when ","
          if paren_depth.zero? && angle_depth.zero? && bracket_depth.zero?
            parts << current.strip
            current.clear
            next
          end
        end

        current << char
      end

      parts << current.strip unless current.strip.empty?
      parts
    end

    def mutates_instance_state?(node, method_name = nil)
      return true if method_name && @current_mutating_instance_method_names.include?(method_name.to_s)

      directly_mutates_instance_state?(node)
    end

    def directly_mutates_instance_state?(node)
      found = false
      walk = ->(n) do
        return if found || n.nil?
        return if n.is_a?(Prism::DefNode) || n.is_a?(Prism::BlockNode)

        case n
        when Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableOrWriteNode,
             Prism::InstanceVariableAndWriteNode
          found = true
          return
        when Prism::CallNode
          if n.receiver.is_a?(Prism::SelfNode) && ruby_setter_method_name?(n.name.to_s)
            found = true
            return
          end
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end

      if node.is_a?(Prism::StatementsNode)
        node.body.each { |stmt| walk.call(stmt) }
      else
        walk.call(node)
      end
      found
    end

    def ruby_setter_method_name?(name)
      name.match?(/\A[A-Za-z_]\w*=\z/)
    end

    def calls_mutating_instance_method?(node, mutating_names)
      found = false
      walk = ->(n) do
        return if found || n.nil?
        return if n.is_a?(Prism::DefNode) || n.is_a?(Prism::BlockNode)

        if n.is_a?(Prism::CallNode) &&
           (n.receiver.nil? || n.receiver.is_a?(Prism::SelfNode)) &&
           mutating_names.include?(n.name.to_s)
          found = true
          return
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end

      if node.is_a?(Prism::StatementsNode)
        node.body.each { |stmt| walk.call(stmt) }
      else
        walk.call(node)
      end
      found
    end

    def recursive_method_call?(node, method_name)
      found = false
      walk = ->(n) do
        return if found || n.nil?
        return if n.is_a?(Prism::DefNode) || n.is_a?(Prism::LambdaNode)

        if n.is_a?(Prism::CallNode) && n.name.to_s == method_name
          found = true
          return
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end

      if node.is_a?(Prism::StatementsNode)
        node.body.each { |stmt| walk.call(stmt) }
      else
        walk.call(node)
      end
      found
    end

    def extract_parameter_names(def_node)
      names = Set.new
      return names unless def_node.parameters

      params = def_node.parameters
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      names << params.rest.name.to_s if params.rest && params.rest.respond_to?(:name)
      params.posts.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      params.keywords.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      names << params.keyword_rest.name.to_s if params.keyword_rest && params.keyword_rest.respond_to?(:name)
      names << params.block.name.to_s if params.block && params.block.respond_to?(:name)

      names
    end

    def type_predicate_argument(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "is_a?"

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1

      static_type_name(args.first)
    end

    def schema_helper_type_predicate(node)
      return nil unless node.is_a?(Prism::CallNode)

      expected_type = SCHEMA_HELPER_TYPE_PREDICATES[node.name.to_s]
      return nil unless expected_type

      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      return nil unless receiver.location.slice.strip == "Schemas"

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1
      return nil unless args.first.is_a?(Prism::LocalVariableReadNode)

      {
        receiver_name: args.first.name.to_s,
        receiver_code: visit(args.first),
        expected_type: expected_type,
      }
    end

    def parameter_type_predicate_receiver(node, param_names)
      return nil unless type_predicate_argument(node)
      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      name = receiver.name.to_s
      param_names.include?(name) ? name : nil
    end

    def exact_clear_type_match?(declared_type, expected_type)
      return false unless declared_type && declared_type != "Auto" && declared_type != "Any"

      declared_type.to_s == expected_type.to_s
    end

    def runtime_union_narrowing_candidate?(declared_type, expected_type)
      declared = declared_type.to_s.delete_prefix("?")
      expected = runtime_is_a_expected_type(declared, expected_type).to_s
      return false if declared.empty? || expected.empty?

      members = @union_types[declared]
      if members
        expected_names = runtime_union_target_names(expected)
        return members.any? do |member|
          member_names = runtime_union_target_names(member)
          !(member_names & expected_names).empty?
        end
      end

      return true if declared == "Node" && !expected.end_with?(".Node")
      return false unless declared.end_with?(".Node")

      namespace = declared.delete_suffix(".Node")
      expected.start_with?("#{namespace}.")
    end

    def runtime_is_a_expected_type(receiver_type, expected_type)
      declared = receiver_type.to_s.delete_prefix("?")
      expected = clear_type_expr(expected_type).to_s
      members = @union_types[declared]
      return expected unless members

      if expected == "HashMap<Any>"
        concrete = members.find { |member| member.to_s.start_with?("HashMap<") }
        return concrete if concrete
      elsif expected == "Any[]"
        concrete = members.find { |member| member.to_s.end_with?("[]") }
        return concrete if concrete
      end

      expected
    end

    def runtime_union_target_names(type)
      text = clear_type_expr(type).to_s
      [text, text.split(".").last].compact.uniq
    end

    def infer_function_type_bindings(body_node, param_names, param_types, declared_type_params = [])
      candidates = []
      declared_type_params = declared_type_params.to_set
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode)
        return if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

        if (param_name = parameter_type_predicate_receiver(node, param_names))
          expected_type = clear_type_expr(type_predicate_argument(node))
          declared_type = param_types[param_name]
          declared_type_param = declared_type_params.include?(declared_type) ? declared_type : nil
          next if declared_type && declared_type != "Auto" && declared_type_param.nil?

          unless exact_clear_type_match?(declared_type, expected_type) ||
                 runtime_union_narrowing_candidate?(declared_type, expected_type)
            candidates << [param_name, declared_type_param]
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(body_node)

      unique_candidates = candidates.each_with_object([]) do |candidate, unique|
        unique << candidate unless unique.any? { |existing| existing.first == candidate.first }
      end
      unique_candidates.each_with_index.to_h do |(param_name, declared_type_param), index|
        [param_name, declared_type_param || function_type_param_name(param_name, index, unique_candidates.length)]
      end
    end

    def function_type_param_name(param_name, index, total)
      return "T" if total == 1

      suffix = param_name.split(/[^A-Za-z0-9]+/).reject(&:empty?).map { |part| part[0].upcase + part[1..].to_s }.join
      suffix = (index + 1).to_s if suffix.empty?
      "T#{suffix}"
    end

    def current_type_param_for_receiver(receiver_name)
      @current_function_type_bindings[receiver_name.to_s]
    end

    def static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_name

      name = receiver_name.to_s
      (@local_types && @local_types[name]) || (@param_types && @param_types[name])
    end

    public :current_type_param_for_receiver, :runtime_union_narrowing_candidate?,
           :runtime_is_a_expected_type, :static_clear_type_for_receiver

    private

    def string_receiver?(receiver)
      return false unless receiver
      return true if inferred_shape(receiver) == "string"

      if receiver.is_a?(Prism::LocalVariableReadNode)
        return string_like_clear_type?(static_clear_type_for_receiver(receiver.name.to_s))
      end

      false
    end

    def string_like_clear_type?(type)
      return false if type.nil?

      normalized = type.to_s.delete_prefix("?")
      return false if normalized.include?("@symbol")

      base = normalized.split("@").first
      return false if base.end_with?("[]") || normalized.start_with?("HashMap<")

      normalized.start_with?("String")
    end

    def array_element_clear_type(type)
      text = expand_non_emitted_type_alias(type).to_s
      return nil unless text.end_with?("[]")

      text.delete_suffix("[]")
    end

    def hash_map_type_parts(type)
      text = expand_non_emitted_type_alias(type).to_s.delete_prefix("?")
      return nil unless text.start_with?("HashMap<") && text.end_with?(">")

      split_top_level_clear_list(text.delete_prefix("HashMap<").delete_suffix(">"))
    end

    def map_key_clear_type(type)
      parts = hash_map_type_parts(type)
      return nil unless parts&.length == 2

      collection_element_type(parts.first)
    end

    def map_value_clear_type(type)
      parts = hash_map_type_parts(type)
      return nil unless parts

      return collection_element_type(parts.first) if parts.length == 1
      return collection_element_type(parts[1]) if parts.length == 2

      nil
    end

    def clear_type_shape(type)
      return nil unless type

      text = type.to_s.delete_prefix("?")
      return "set" if set_like_clear_type?(text)
      return "array" if text.end_with?("[]")
      return "hash" if text.start_with?("HashMap<")
      return "string" if text.start_with?("String")
      return "scanner" if text == "CompilerRegexScanner"

      nil
    end

    def function_like_clear_type?(type)
      expand_clear_type_alias(type).to_s.delete_prefix("?").start_with?("FN(")
    end

    def expand_clear_type_alias(type)
      current = type.to_s.delete_prefix("?")
      seen = Set.new
      loop do
        break if current.empty? || seen.include?(current)

        seen << current
        aliased = type_alias_for_path(current) || type_alias_for_name(current) || @type_aliases[current]
        break unless aliased

        current = aliased.to_s.delete_prefix("?")
      end
      current
    end

    def expand_non_emitted_type_alias(type, seen = Set.new)
      text = type.to_s
      optional = text.start_with?("?")
      base = text.delete_prefix("?")
      return text if @union_types.key?(base)

      aliased = type_alias_for_path(base) || type_alias_for_name(base) || @type_aliases[base]
      if aliased && !seen.include?(base)
        seen = seen.dup
        seen << base
        expanded = expand_non_emitted_type_alias(aliased, seen)
        return optional ? optional_clear_type(expanded) : expanded
      end

      expand_generic_type_aliases(text, seen)
    end

    def expand_generic_type_aliases(type, seen = Set.new)
      text = type.to_s
      optional = text.start_with?("?")
      base = text.delete_prefix("?")

      normalized = if base.start_with?("HashMap<") && base.end_with?(">")
        inner = base.delete_prefix("HashMap<").delete_suffix(">")
        parts = split_top_level_clear_list(inner)
        "HashMap<#{parts.map { |part| expand_non_emitted_type_alias(part.strip, seen) }.join(', ')}>"
      elsif base.end_with?("[]@set")
        "#{expand_non_emitted_type_alias(base.delete_suffix('[]@set'), seen)}[]@set"
      elsif base.end_with?("[]")
        "#{expand_non_emitted_type_alias(base.delete_suffix('[]'), seen)}[]"
      elsif base.start_with?("Tuple<") && base.end_with?(">")
        inner = base.delete_prefix("Tuple<").delete_suffix(">")
        "Tuple<#{split_top_level_clear_list(inner).map { |part| expand_non_emitted_type_alias(part.strip, seen) }.join(', ')}>"
      elsif (parts = function_clear_type_parts(base))
        params, return_type = parts
        "FN(#{params.map { |param| expand_non_emitted_type_alias(param.strip, seen) }.join(', ')}) -> #{expand_non_emitted_type_alias(return_type, seen)}"
      else
        base
      end

      optional ? optional_clear_type(normalized) : normalized
    end

    def set_like_clear_type?(type)
      type.to_s.delete_prefix("?").end_with?("@set")
    end

    def set_receiver?(receiver)
      set_like_clear_type?(clear_type_for_receiver_node(receiver))
    end

    def clear_type_for_receiver_node(node)
      case node
      when Prism::SelfNode
        @current_class
      when Prism::LocalVariableReadNode
        name = node.name.to_s
        renamed = @renames[name]
        (renamed && static_clear_type_for_receiver(renamed)) || static_clear_type_for_receiver(name)
      when Prism::InstanceVariableReadNode
        return nil unless @current_class

        @class_instance_field_types[@current_class][node.name.to_s.delete_prefix("@")]
      when Prism::CallNode
        if sorbet_call?(node, "must")
          type = inferred_clear_type(node)
          return type if type
        end

        if node.name.to_s == "[]" && node.receiver
          receiver_type = clear_type_for_receiver_node(node.receiver)
          element_type = array_element_clear_type(receiver_type)
          return element_type if element_type

          value_type = map_value_clear_type(receiver_type)
          return value_type if value_type
        end

        if node.name.to_s == "fetch" && node.receiver
          receiver_type = clear_type_for_receiver_node(node.receiver)
          element_type = array_element_clear_type(receiver_type)
          return element_type if element_type

          value_type = map_value_clear_type(receiver_type)
          return value_type if value_type
        end

        if node.receiver && node.name.to_s == "keys"
          key_type = map_key_clear_type(clear_type_for_receiver_node(node.receiver))
          return "#{key_type}[]" if key_type
        end

        if node.receiver && node.name.to_s == "values"
          value_type = map_value_clear_type(clear_type_for_receiver_node(node.receiver))
          return "#{value_type}[]" if value_type
        end

        if constant_constructor_call?(node)
          name = constructor_output_name(node.receiver)
          return name if name && !name.empty?
        end

        return nil unless node.arguments.nil? || node.arguments.arguments.empty?

        if node.receiver.nil? &&
           @inside_instance_method &&
           @current_instance_field_names.include?(node.name.to_s)
          return @class_instance_field_types[@current_class][node.name.to_s]
        end

        receiver_type = clear_type_for_receiver_node(node.receiver)
        if receiver_type
          field_type = class_instance_field_type(receiver_type, node.name.to_s)
          return field_type if field_type

          return_type = method_return_type_for(node.name.to_s, receiver_type)
          return return_type if return_type
        elsif node.receiver.nil? && (@inside_instance_method || @inside_class_method)
          return_type = method_return_type_for(node.name.to_s, @current_class)
          return return_type if return_type
        end

        nil
      end
    end
    public :clear_type_for_receiver_node

    private

    def sorbet_call?(node, name = nil)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver&.location&.slice == "T"

      name.nil? || node.name.to_s == name.to_s
    end

    def sorbet_unwrapped_value(node)
      return nil unless sorbet_call?(node)

      case node.name.to_s
      when "let", "cast", "must", "unsafe"
        node.arguments&.arguments&.first
      end
    end

    def sorbet_cast_expression(node)
      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2

      value_node = args[0]
      source_type = inferred_clear_type(value_node)
      target_type = convert_sorbet_type(args[1])
      union_payload_cast_code(visit(value_node), source_type, target_type)
    end

    def union_payload_cast_code(source_code, source_type, target_type)
      source_text = source_type.to_s
      target_text = target_type.to_s
      return nil if source_text.empty? || target_text.empty?

      optional_source = source_text.start_with?("?")
      union_type = source_text.delete_prefix("?")
      members = @union_types[union_type]
      return nil unless members

      target_optional = target_text.start_with?("?")
      target_payload = target_text.delete_prefix("?")
      member = members.find do |candidate|
        candidate_payload = expand_non_emitted_type_alias(candidate).to_s.delete_prefix("?")
        candidate.to_s == target_payload || candidate_payload == target_payload
      end
      return nil unless member

      fallback = target_optional ? "NIL" : default_value_for_type(target_payload)
      variant = union_variant_name(member)
      helper = union_payload_cast_helper_name(source_text, target_text)
      @generated_cast_helper_defs[helper] ||= union_payload_cast_helper_definition(
        helper,
        source_text,
        union_type,
        target_text,
        target_payload,
        variant,
        fallback,
        optional_source
      )
      "#{helper}(#{source_code})"
    end

    def union_payload_match_code(source_code, union_type, variant, payload_name, fallback)
      "PARTIAL MATCH #{source_code} START\n" \
        "  #{union_type}.#{variant} AS #{payload_name} -> #{payload_name},\n" \
        "  DEFAULT -> #{fallback}\n" \
        "END"
    end

    def union_payload_cast_helper_name(source_type, target_type)
      "cast#{cast_helper_type_suffix(source_type)}To#{cast_helper_type_suffix(target_type)}"
    end

    def cast_helper_type_suffix(type)
      type.to_s
        .gsub(/\A\?/, "Optional ")
        .gsub("@", " ")
        .gsub(/[^A-Za-z0-9]+/, " ")
        .split
        .map { |part| part[0].upcase + part[1..].to_s }
        .join
    end

    def union_payload_cast_helper_definition(helper, source_type, union_type, target_type, target_payload, variant, fallback, optional_source)
      _ = union_type
      _ = variant
      subject = optional_source ? "value?" : "value"
      lines = [
        "FN #{helper}(value: #{source_type}) RETURNS #{target_type} ->"
      ]

      if optional_source
        lines << "  IF value != NIL THEN"
        lines << "    IF #{subject} IS_A #{target_payload} AS cast_payload THEN"
        lines << "      RETURN cast_payload;"
        lines << "    END"
        lines << "  END"
      else
        lines << "  IF #{subject} IS_A #{target_payload} AS cast_payload THEN"
        lines << "    RETURN cast_payload;"
        lines << "  END"
      end

      lines << "  RETURN #{fallback};"
      lines << "END"
      lines.join("\n")
    end

    def cast_binding_name(prefix, source_code)
      base = source_code.to_s.gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      base = "value" if base.empty?
      "#{prefix}_#{base}"
    end

    def sorbet_typed_value(node)
      return nil unless sorbet_call?(node)
      return nil unless ["let", "cast"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2

      [args.first, expand_non_emitted_type_alias(convert_sorbet_type(args[1]))]
    end

    def inferred_shape(node)
      return nil unless node

      if (typed_value = sorbet_typed_value(node))
        return inferred_shape(typed_value.first)
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_shape(unwrapped)
      end

      case node
      when Prism::ArrayNode
        "array"
      when Prism::HashNode, Prism::KeywordHashNode
        "hash"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "string"
      when Prism::SymbolNode
        "symbol"
      when Prism::IntegerNode, Prism::FloatNode
        "numeric"
      when Prism::NilNode
        "nil"
      when Prism::TrueNode, Prism::FalseNode
        "bool"
      when Prism::LocalVariableReadNode
        name = node.name.to_s
        @local_shapes[name] || clear_type_shape(static_clear_type_for_receiver(name))
      when Prism::CallNode
        inferred_call_shape(node) || clear_type_shape(inferred_clear_type(node))
      end
    end

    def inferred_call_shape(node)
      receiver_name = registry_receiver_name(node.receiver)
      receiver_shape = node.receiver ? registry_receiver_shape(node.receiver) : nil

      case node.name.to_s
      when "readlines"
        return "array" if receiver_name == "File"
      when "compilerRegexCapture", "regexCapture"
        return "string"
      when "[]"
        if node.receiver
          element_type = array_element_clear_type(clear_type_for_receiver_node(node.receiver))
          return clear_type_shape(element_type) if element_type
        end

        return "string" if receiver_shape == "scanner"
      when "split", "lines"
        return "array" if receiver_shape == "string"
      when "match"
        args = node.arguments ? node.arguments.arguments : []
        return "scanner" if receiver_shape == "string" && args.length == 1 && regex_value_node?(args.first)
      when "keys", "values"
        return "array" if receiver_shape == "hash"
      when "map", "collect", "select", "filter", "reject", "filter_map", "flat_map", "sort_by"
        return "array" if receiver_shape == "array"
      end

      nil
    end

    def sorbet_type_alias_value(node, alias_name: nil)
      return nil unless sorbet_call?(node, "type_alias")
      return nil unless node.block&.body.is_a?(Prism::StatementsNode)

      body = node.block.body.body
      return nil unless body.length == 1
      if alias_name.to_s == "Node" && body.first.is_a?(Prism::ConstantReadNode) && body.first.name.to_s == "Locatable"
        return ensure_ast_node_union!(emit: false) || "Node"
      end

      with_type_alias_context(alias_name) do
        convert_sorbet_type(body.first, union_name: alias_name, emit_union: false)
      end
    end

    def inferred_clear_type(node)
      return nil unless node

      if sorbet_call?(node, "must")
        args = node.arguments ? node.arguments.arguments : []
        value_type = inferred_clear_type(args.first)
        return value_type.to_s.delete_prefix("?") if value_type
      end

      if (typed_value = sorbet_typed_value(node))
        return typed_value[1] unless typed_value[1] == "Auto"

        return inferred_clear_type(typed_value.first)
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_clear_type(unwrapped)
      end

      case node
      when Prism::LocalVariableReadNode
        name = node.name.to_s
        renamed = @renames[name]
        (renamed && static_clear_type_for_receiver(renamed)) || static_clear_type_for_receiver(name)
      when Prism::CallNode
        return "Int64" if node.name.to_s == "to_i"
        return "String@symbol" if node.name.to_s == "to_sym"

        if node.name.to_s == "call" && node.receiver
          receiver_type = clear_type_for_receiver_node(node.receiver)
          if (parts = function_clear_type_parts(receiver_type))
            return parts[1]
          end
        end

        if node.name.to_s == "[]" && node.receiver && string_receiver?(node.receiver)
          return "String"
        end

        if node.name.to_s == "[]" && node.receiver
          receiver_type = clear_type_for_receiver_node(node.receiver)
          element_type = array_element_clear_type(receiver_type)
          return element_type if element_type

          value_type = map_value_clear_type(receiver_type)
          return optional_clear_type(value_type) if value_type
        end

        if node.name.to_s == "fetch" && node.receiver
          receiver_type = clear_type_for_receiver_node(node.receiver)
          element_type = array_element_clear_type(receiver_type)
          return element_type if element_type

          value_type = map_value_clear_type(receiver_type)
          return value_type if value_type
        end

        if node.receiver && node.name.to_s == "keys"
          key_type = map_key_clear_type(clear_type_for_receiver_node(node.receiver))
          return "#{key_type}[]" if key_type
        end

        if node.receiver && node.name.to_s == "values"
          value_type = map_value_clear_type(clear_type_for_receiver_node(node.receiver))
          return "#{value_type}[]" if value_type
        end

        if node.name.to_s == "match" && node.receiver && string_receiver?(node.receiver)
          args = node.arguments ? node.arguments.arguments : []
          return "?CompilerRegexScanner" if args.length == 1 && regex_value_node?(args.first) && @helper_config.helper?(:regex_match_data)
        end

        if (!node.arguments || node.arguments.arguments.empty?) &&
           (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
           @inside_instance_method &&
           @current_instance_field_names.include?(node.name.to_s)
          return @class_instance_field_types[@current_class][node.name.to_s]
        end

        if constant_constructor_call?(node)
          name = constructor_output_name(node.receiver)
          return name if name && !name.empty?
        end

        receiver = node.receiver
        if receiver
          receiver_type = clear_type_for_receiver_node(receiver)
          if receiver_type
            field_type = class_instance_field_type(receiver_type, node.name.to_s)
            return field_type if field_type
          end

          return method_return_type_for(node.name.to_s, receiver_type) if receiver_type

          if (receiver_class = constant_receiver_name(receiver))
            return method_return_type_for(node.name.to_s, receiver_class)
          end
        elsif receiver.nil? || @inside_instance_method || @inside_class_method
          method_return_type_for(node.name.to_s, @current_class)
        end
      when Prism::ArrayNode
        "Any[]"
      when Prism::HashNode, Prism::KeywordHashNode
        "HashMap<Any, Any>"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "String"
      when Prism::SymbolNode
        "String@symbol"
      when Prism::IntegerNode
        "Int64"
      when Prism::FloatNode
        "Float64"
      when Prism::TrueNode, Prism::FalseNode
        "Bool"
      when Prism::NilNode
        "Void"
      end
    end
    end
  end
end
