# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def collect_type_normalizers!(def_node, record)
      body = def_node.respond_to?(:body) ? def_node.body : nil
      return unless body
      param_names = Array(record["params"]).map { |p| p["name"].to_s }
      assigns = {}
      each_ast(body) do |n|
        assigns[n.name.to_s] ||= n.value if n.is_a?(Syntax::LocalVariableWriteNode)
      end
      each_ast(body) do |n|
        next unless n.is_a?(Syntax::CallNode) && %i[is_a? kind_of?].include?(n.name) && n.receiver
        args = (n.arguments && n.arguments.arguments) || []
        next unless args.size == 1 && args.first.slice == "Type"
        kind, name = classify_origin(n.receiver, param_names, assigns, 0)
        @type_normalizers << TypedRecords::TypeNormalizerRecord.new(
          path: @rel,
          line: n.location.start_line,
          owner: record["class"],
          method_name: record["method"],
          code: n.slice.split("\n").first.to_s.strip[0, 120],
          origin_kind: kind,
          origin_name: name,
        ).to_source_index_hash
      end
    end

    HIDDEN_ENUM_COMPARISONS = %i[== != ===].freeze
    HIDDEN_ENUM_MEMBERSHIP = %i[include? member? key?].freeze

    def collect_hidden_enum_observations!(def_node, record)
      body = def_node.respond_to?(:body) ? def_node.body : nil
      return unless body
      params = Array(record["params"]).each_with_object({}) { |param, index| index[param["name"].to_s] = param }
      each_ast(body) do |node|
        case node
        when Syntax::CaseNode
          slot = hidden_enum_slot_for(node.predicate, record, params)
          values = node.conditions.flat_map { |condition| hidden_enum_literal_values(condition.conditions) }
          record_hidden_enum_observation(slot, values, node, "case")
        when Syntax::CallNode
          if HIDDEN_ENUM_COMPARISONS.include?(node.name)
            args = node.arguments&.arguments || []
            next unless args.size == 1
            left_slot = hidden_enum_slot_for(node.receiver, record, params)
            right_slot = hidden_enum_slot_for(args.first, record, params)
            record_hidden_enum_observation(left_slot, hidden_enum_literal_values([args.first]), node, node.name.to_s)
            record_hidden_enum_observation(right_slot, hidden_enum_literal_values([node.receiver]), node, node.name.to_s)
          elsif HIDDEN_ENUM_MEMBERSHIP.include?(node.name)
            args = node.arguments&.arguments || []
            next unless args.size == 1
            slot = hidden_enum_slot_for(args.first, record, params)
            record_hidden_enum_observation(slot, hidden_enum_literal_values([node.receiver]), node, node.name.to_s)
          end
        end
      end
    end

    def hidden_enum_slot_for(node, record, params)
      case node
      when Syntax::LocalVariableReadNode
        param = params[node.name.to_s]
        return nil unless param
        TypedRecords::HiddenEnumSlotRecord.new(
          key: ["param", record["path"], record["class"], record["kind"], record["method"], record["line"], node.name].join("\0"),
          kind: "param",
          path: record["path"],
          line: record["line"],
          owner: record["class"],
          method_name: record["method"],
          method_kind: record["kind"],
          slot: node.name.to_s,
          slot_type: param["type"].to_s,
        )
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode
        TypedRecords::HiddenEnumSlotRecord.new(
          key: ["state", record["path"], record["class"], node.name].join("\0"),
          kind: "state",
          path: record["path"],
          line: node.location.start_line,
          owner: record["class"],
          method_name: nil,
          method_kind: nil,
          slot: node.name.to_s,
          slot_type: "",
        )
      end
    end

    def record_hidden_enum_observation(slot, values, site, kind)
      values = values.select { |value| value["value"].to_s.size <= 80 && !value["value"].to_s.empty? }
      return unless slot && !values.empty?
      site_record = TypedRecords::HiddenEnumSiteRecord.new(
        path: @rel,
        line: site.location.start_line,
        kind: kind,
        code: site.slice.lines.first.to_s.strip[0, 160],
      )
      @hidden_enum_observations << TypedRecords::HiddenEnumObservationRecord.new(
        slot: slot,
        values: values,
        site: site_record,
      ).to_source_index_hash
    end

    def hidden_enum_literal_values(nodes)
      Array(nodes).flat_map do |node|
        case node
        when Syntax::SymbolNode
          [TypedRecords::HiddenEnumValueRecord.new(kind: "Symbol", value: ":#{node.value}")]
        when Syntax::StringNode
          if node.is_a?(Syntax::InterpolatedStringNode)
            []
          else
            [TypedRecords::HiddenEnumValueRecord.new(kind: "String", value: node.unescaped.inspect)]
          end
        when Syntax::ArrayNode
          hidden_enum_literal_values(node.elements)
        when Syntax::ParenthesesNode
          hidden_enum_literal_values([node.body])
        else
          []
        end
      end
    end

    def each_ast(node, &blk)
      return unless node.is_a?(Syntax::Node)
      yield node
      node.compact_child_nodes.each { |c| each_ast(c, &blk) }
    end

    def collect_return_usage_sites!(root)
      collect_return_usage_site_context(root, :statement, nil, nil, @return_usage_sites, direct_usage: false)
      collect_return_usage_site_context(root, :statement, nil, nil, @return_direct_usage_sites, direct_usage: true)
    end

    def collect_return_usage_site_context(node, context, current_method, current_handler, sites, direct_usage:)
      return unless node
      case node
      when Syntax::DefNode
        collect_return_usage_site_context(node.body, :return, node.name, nil, sites, direct_usage: direct_usage)
      when Syntax::StatementsNode
        body = node.body || []
        body.each_with_index do |child, idx|
          child_context = idx == body.length - 1 ? context : :statement
          collect_return_usage_site_context(child, child_context, current_method, current_handler, sites, direct_usage: direct_usage)
        end
      when Syntax::ReturnNode
        node.child_nodes.compact.each do |child|
          collect_return_usage_site_context(child, :return, current_method, current_handler, sites, direct_usage: direct_usage)
        end
      when Syntax::ArgumentsNode
        arg_context = direct_usage ? :return : context
        node.child_nodes.compact.each do |child|
          collect_return_usage_site_context(child, arg_context, current_method, current_handler, sites, direct_usage: direct_usage)
        end
      when Syntax::IfNode
        collect_return_usage_site_context(node.predicate, :value, current_method, current_handler, sites, direct_usage: direct_usage) if node.respond_to?(:predicate)
        collect_return_usage_site_context(node.statements, context, current_method, current_handler, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.subsequent, context, current_method, current_handler, sites, direct_usage: direct_usage)
      when Syntax::ElseNode
        collect_return_usage_site_context(node.statements, context, current_method, current_handler, sites, direct_usage: direct_usage)
      when Syntax::BeginNode
        handler_line = node.rescue_clause&.location&.start_line
        if handler_line
          @rescue_handlers << TypedRecords::RescueHandlerRecord.new(
            path: @rel,
            line: handler_line,
            kind: "rescue",
            method_name: current_method&.to_s,
          ).to_source_index_hash
        end

        # Rescue clauses themselves are NOT protected by the handler they are part of
        collect_return_usage_site_context(node.statements, context, current_method, handler_line, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.rescue_clause, :statement, current_method, nil, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.else_clause, context, current_method, handler_line, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.ensure_clause, context, current_method, handler_line, sites, direct_usage: direct_usage)
      when Syntax::RescueNode
        collect_return_usage_site_context(node.statements, :statement, current_method, current_handler, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.subsequent, :statement, current_method, current_handler, sites, direct_usage: direct_usage)
      when Syntax::RescueModifierNode
        handler_line = node.location.start_line
        @rescue_handlers << TypedRecords::RescueHandlerRecord.new(
          path: @rel,
          line: handler_line,
          kind: "rescue_modifier",
          method_name: current_method&.to_s,
        ).to_source_index_hash
        collect_return_usage_site_context(node.expression, context, current_method, handler_line, sites, direct_usage: direct_usage)
        collect_return_usage_site_context(node.rescue_expression, context, current_method, current_handler, sites, direct_usage: direct_usage)
      when Syntax::CallNode
        name = node.name.to_s
        unless name.empty?
          sites << TypedRecords::ReturnUsageSiteRecord.new(
            path: @rel,
            line: node.location.start_line,
            name: name,
            context: context.to_s,
            current_method: current_method&.to_s,
            handler_line: current_handler,
            code: node.slice.lines.first.to_s.strip[0, 160],
          ).to_source_index_hash
        end
        node.child_nodes.compact.each do |child|
          collect_return_usage_site_context(child, :value, current_method, current_handler, sites, direct_usage: direct_usage)
        end
      else
        node.child_nodes.compact.each do |child|
          collect_return_usage_site_context(child, :value, current_method, current_handler, sites, direct_usage: direct_usage)
        end if node.respond_to?(:child_nodes)
      end
    end

    def collect_hash_record_escape_sites!(root)
      each_ast(root) do |node|
        next unless node.is_a?(Syntax::HashNode)
        reason = hash_record_escape_reason(root, node)
        next unless reason
        @hash_record_escape_sites << TypedRecords::HashRecordEscapeSiteRecord.new(
          path: @rel,
          line: node.location.start_line,
          code: node.slice.strip,
          escapes_collection: true,
          reason: reason,
        ).to_source_index_hash
      end
    end

    def hash_record_escape_reason(root, hash_node)
      return "array_literal" if hash_literal_in_array_literal?(root, hash_node)
      return "collection_append_or_index_write" if value_in_collection_append_or_index_write?(root, hash_node)
      writer = enclosing_local_write_for(root, hash_node)
      return nil unless writer
      name = writer.name.to_s
      escape_uses_of_local?(root, name) ? "local_alias_escape" : nil
    end

    def value_in_collection_append_or_index_write?(root, target)
      each_node(root) do |node|
        if node.is_a?(Syntax::CallNode) && COLLECTION_APPEND_METHODS.include?(node.name.to_s)
          args = node.arguments&.arguments || []
          return true if args.any? { |arg| arg.equal?(target) }
        end
        if node.is_a?(Syntax::IndexOperatorWriteNode) || node.is_a?(Syntax::IndexAndWriteNode) ||
            node.is_a?(Syntax::IndexOrWriteNode)
          return true if node.respond_to?(:value) && node.value.equal?(target)
        end
        if node.is_a?(Syntax::CallNode) && node.name.to_s == "[]=" && node.arguments
          last = node.arguments.arguments.last
          return true if last && last.equal?(target)
        end
      end
      false
    end

    def enclosing_local_write_for(root, target)
      found = nil
      each_node(root) do |node|
        found = node if node.is_a?(Syntax::LocalVariableWriteNode) && node.value.equal?(target)
      end
      found
    end

    def escape_uses_of_local?(root, name)
      each_node(root) do |node|
        next unless node.is_a?(Syntax::CallNode)
        args = node.arguments&.arguments || []
        return true if args.any? { |arg| arg.is_a?(Syntax::LocalVariableReadNode) && arg.name.to_s == name }
      end
      each_node(root) do |node|
        next unless node.is_a?(Syntax::ArrayNode)
        return true if node.elements.any? { |element| element.is_a?(Syntax::LocalVariableReadNode) && element.name.to_s == name }
      end
      false
    end

    def each_node(root)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node
        yield node
        stack.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
      end
    end

    def hash_literal_in_array_literal?(root, target)
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node
        return true if node.is_a?(Syntax::ArrayNode) && node_contains?(node, target)
        stack.concat(node.child_nodes.compact) if node.respond_to?(:child_nodes)
      end
      false
    end

    def node_contains?(node, target)
      return false unless node
      return true if node.equal?(target)
      return false unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.any? { |child| node_contains?(child, target) }
    end

    # A local receiver is resolved through its in-method assignment
    # exactly once (depth 1) so `ti = node.type_info; ti.is_a?(Type)`
    # keys to `.type_info`.
    def classify_origin(node, param_names, assigns, depth)
      case node
      when Syntax::InstanceVariableReadNode
        ["ivar", node.slice]
      when Syntax::LocalVariableReadNode
        nm = node.name.to_s
        return ["param", nm] if param_names.include?(nm)
        if depth.zero? && (rhs = assigns[nm])
          return classify_origin(rhs, param_names, assigns, depth + 1)
        end
        ["local", nil]
      when Syntax::CallNode
        if node.name == :[]
          key = node.arguments && node.arguments.arguments && node.arguments.arguments.first
          k = case key
              when Syntax::SymbolNode then ":#{key.value}"
              when Syntax::StringNode then ":#{key.unescaped}"
              end
          ["hashkey", k]
        elsif ((node.arguments && node.arguments.arguments) || []).any?
          ["call", node.name.to_s]
        elsif node.receiver
          ["attr", node.name.to_s]
        else
          ["call", node.name.to_s]
        end
      else
        ["local", nil]
      end
    end


  end
end
