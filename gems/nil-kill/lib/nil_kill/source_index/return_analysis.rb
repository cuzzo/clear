# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def scoped_facts(method_record)
      old = @non_nil_locals
      old_maybe_nil = @maybe_nil_locals
      old_param_types = @current_param_types
      old_local_types = @current_local_types
      old_collection_builders = @current_collection_builders
      old_hash_shapes = @current_hash_shapes
      old_array_element_shapes = @current_array_element_shapes
      old_local_origins = @local_container_origins
      old_method_name = @current_method_name
      @non_nil_locals = Set.new(method_record["non_nil_params"])
      @maybe_nil_locals = Set.new
      self.current_param_types = method_record["params"].each_with_object({}) do |param, types|
        types[param["name"]] = param["type"] if NilKill.useful_type?(param["type"])
      end
      self.current_local_types = {}
      self.current_collection_builders = seed_param_collection_builders(method_record)
      self.current_hash_shapes = seed_param_hash_shapes(method_record)
      self.current_array_element_shapes = seed_param_array_element_shapes(method_record)
      @current_method_name = method_record["method"]
      @local_container_origins = method_record["params"].each_with_object({}) do |param, origins|
        origins[param["name"]] = TypedRecords::ContainerOriginRecord.new(
          kind: "method parameter",
          name: param["name"],
          param_type: param["type"],
          path: method_record["path"],
          line: method_record["line"],
        )
      end
      yield
    ensure
      @non_nil_locals = old
      @maybe_nil_locals = old_maybe_nil
      self.current_param_types = old_param_types
      self.current_local_types = old_local_types
      self.current_collection_builders = old_collection_builders
      self.current_hash_shapes = old_hash_shapes
      self.current_array_element_shapes = old_array_element_shapes
      @local_container_origins = old_local_origins
      @current_method_name = old_method_name
    end

    def method_record(node, scope)
      sig = sig_above(node.location.start_line)
      method_params = params(node, sig)
      noreturn_candidate = !contains_explicit_return?(node.body) && noreturn_body?(node.body)
      SourceIndex.register_noreturn_method(node.name) if noreturn_candidate
      SourceIndex.register_noreturn_method(node.name) if sig && /returns\(\s*T\.noreturn\s*\)/.match?(sig)
      TypedRecords::MethodRecord.new(
        path: @rel,
        line: node.location.start_line,
        end_line: node.location.end_line,
        owner: scope.join("::"),
        method_name: node.name.to_s,
        method_kind: node.receiver.is_a?(Syntax::SelfNode) ? "class" : "instance",
        has_sig: !sig.nil?,
        sig: sig,
        params: method_params,
        scope: scope,
        non_nil_params: non_nil_sig_params(sig),
        uses_yield: @warm_only ? false : uses_yield?(node.body),
        untraceable_params: @warm_only ? [] : untraceable_param_names(node),
        protocols: @warm_only ? {} : param_protocols(node),
        noreturn_candidate: noreturn_candidate,
      ).to_source_index_hash
    end

    def contains_explicit_return?(node)
      return false unless node
      return false if nested_scope_node?(node)
      return true if return_node?(node)
      node.respond_to?(:child_nodes) && node.compact_child_nodes.any? { |child| contains_explicit_return?(child) }
    end

    def noreturn_body?(node)
      case node
      when nil
        false
      when Syntax::StatementsNode
        body = node.body || []
        return false if body.empty?
        noreturn_body?(body.last)
      when Syntax::BeginNode
        noreturn_body?(node.statements)
      when Syntax::IfNode
        noreturn_body?(node.statements) && noreturn_body?(node.subsequent)
      when Syntax::ElseNode
        noreturn_body?(node.statements)
      when Syntax::CaseNode
        conditions = node.conditions || []
        return false if conditions.empty?
        conditions.all? { |condition| noreturn_body?(condition.respond_to?(:statements) ? condition.statements : nil) } &&
          noreturn_body?(node.else_clause)
      when Syntax::RescueNode
        noreturn_body?(node.statements) && noreturn_body?(node.subsequent)
      when Syntax::EnsureNode
        noreturn_body?(node.statements)
      when Syntax::CallNode
        noreturn_call?(node)
      else
        false
      end
    end

    def noreturn_call?(node)
      return true if %i[raise fail exit abort].include?(node.name)
      # T.absurd marks unreachable exhaustiveness arms (Sorbet idiom). It
      # raises at runtime, so any branch ending in T.absurd is noreturn.
      return true if node.name == :absurd && node.receiver&.slice == "T"
      return true if SourceIndex.noreturn_methods.include?(node.name.to_s)
      known_return_type(node.name.to_s, node: node, allow_rbi: false) == "T.noreturn"
    end

    def analyze_return_origin(node, record)
      old_param_types = @current_param_types
      old_local_types = @current_local_types
      old_collection_builders = @current_collection_builders
      old_hash_shapes = @current_hash_shapes
      old_array_element_shapes = @current_array_element_shapes
      old_method_name = @current_method_name
      old_class_name = @current_class_name
      self.current_param_types = record["params"].each_with_object({}) do |param, types|
        types[param["name"]] = param["type"] if NilKill.useful_type?(param["type"])
      end
      self.current_local_types = {}
      self.current_collection_builders = seed_param_collection_builders(record)
      self.current_hash_shapes = seed_param_hash_shapes(record)
      self.current_array_element_shapes = seed_param_array_element_shapes(record)
      @current_method_name = record["method"]
      @current_class_name = record["class"] if record["class"] && !record["class"].empty?
      collect_local_type_facts(node.body)
      explicit_expressions = explicit_return_expressions(node.body)
      implicit_expr = implicit_return_expression(node.body)
      implicit_present = !return_node?(implicit_expr)
      expressions = explicit_expressions.dup
      expressions << implicit_expr if implicit_present
      sources = []
      blockers = []
      expressions.compact.each do |expr|
        sources.concat(return_sources_for(expr, blockers))
      end
      hash_shape = hash_shape_for_return_expressions(expressions)
      array_element_shape = array_element_shape_for_return_expressions(expressions)
      if expressions.empty? || sources.empty?
        blockers << "no return expression found"
      end
      type_sources = sources.filter_map { |source| source["type"] }
      candidate = NilKill.static_sorbet_type(type_sources)
      candidate = "T.untyped" if candidate == "NilClass" && sources.any? { |source| source["kind"] == "call_untyped" || source["kind"] == "unknown" }
      useful = NilKill.useful_type?(candidate)
      confidence =
        if useful && !NilKill.weak_type?(candidate) && blockers.empty? && sources.none? { |source| source["kind"] == "call_untyped" }
          "strong"
        elsif useful
          "weak"
        else
          "blocked"
      end
      TypedRecords::ReturnOriginRecord.new(
        path: record["path"],
        line: record["line"],
        end_line: record["end_line"],
        owner: record["class"],
        method_name: record["method"],
        method_kind: record["kind"],
        implicit: explicit_expressions.empty?,
        return_syntax: return_syntax(explicit_expressions, implicit_present),
        control_shape: return_control_shape(explicit_expressions, implicit_expr, implicit_present),
        candidate_type: useful ? candidate : "T.untyped",
        confidence: confidence,
        sources: sources,
        blockers: blockers.uniq,
        hash_shape: hash_shape,
        array_element_shape: array_element_shape,
      ).to_source_index_hash
    ensure
      self.current_param_types = old_param_types
      self.current_local_types = old_local_types
      self.current_collection_builders = old_collection_builders
      self.current_hash_shapes = old_hash_shapes
      self.current_array_element_shapes = old_array_element_shapes
      @current_method_name = old_method_name
      @current_class_name = old_class_name
    end

    def collect_local_type_facts(node)
      return unless node
      return if nested_scope_node?(node)
      if node.is_a?(Syntax::IfNode)
        collect_branch_local_type_facts(node)
        return
      end
      update_local_fact(node) if node.is_a?(Syntax::LocalVariableWriteNode)
      update_collection_builder_call(node) if node.is_a?(Syntax::CallNode)
      node.compact_child_nodes.each { |child| collect_local_type_facts(child) } if node.respond_to?(:child_nodes)
    end

    def collect_branch_local_type_facts(node)
      before = @current_local_types.dup
      before_builders = dup_collection_builders(@current_collection_builders)
      before_shapes = dup_hash_shapes(@current_hash_shapes)
      before_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = before.dup
      self.current_collection_builders = dup_collection_builders(before_builders)
      self.current_hash_shapes = dup_hash_shapes(before_shapes)
      self.current_array_element_shapes = dup_hash_shapes(before_array_shapes)
      collect_local_type_facts(node.statements)
      then_types = @current_local_types.dup
      then_builders = dup_collection_builders(@current_collection_builders)
      then_shapes = dup_hash_shapes(@current_hash_shapes)
      then_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = before.dup
      self.current_collection_builders = dup_collection_builders(before_builders)
      self.current_hash_shapes = dup_hash_shapes(before_shapes)
      self.current_array_element_shapes = dup_hash_shapes(before_array_shapes)
      collect_local_type_facts(node.subsequent)
      else_types = @current_local_types.dup
      else_builders = dup_collection_builders(@current_collection_builders)
      else_shapes = dup_hash_shapes(@current_hash_shapes)
      else_array_shapes = dup_hash_shapes(@current_array_element_shapes)

      self.current_local_types = merge_branch_local_types(before, then_types, else_types)
      self.current_collection_builders = merge_branch_collection_builders(before_builders, then_builders, else_builders)
      self.current_hash_shapes = merge_branch_hash_shapes(before_shapes, then_shapes, else_shapes)
      self.current_array_element_shapes = merge_branch_hash_shapes(before_array_shapes, then_array_shapes, else_array_shapes)
    end

    def merge_branch_local_types(before, then_types, else_types)
      names = (before.keys | then_types.keys | else_types.keys)
      names.each_with_object({}) do |name, merged|
        if then_types.key?(name) && else_types.key?(name)
          type = NilKill.static_sorbet_type([then_types[name], else_types[name]].compact)
          merged[name] = NilKill.useful_type?(type) ? type : "T.untyped"
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def seed_param_collection_builders(record)
      record["params"].each_with_object({}) do |param, builders|
        type = param["type"].to_s
        info = collection_type_info(type)
        next unless info
        next unless info["element"].to_s.include?("T.untyped") || info["key"].to_s.include?("T.untyped") || info["value"].to_s.include?("T.untyped")
        builders[param["name"]] = collection_builder(info["kind"])
      end
    end

    def seed_param_hash_shapes(record)
      record["params"].each_with_index.each_with_object({}) do |(param, idx), shapes|
        shape = inferred_param_hash_shape(record["method"], param["name"], idx)
        shapes[param["name"]] = shape if shape && !shape["poisoned"]
      end
    end

    def seed_param_array_element_shapes(record)
      record["params"].each_with_index.each_with_object({}) do |(param, idx), shapes|
        shape = inferred_param_array_element_shape(record["method"], param["name"], idx)
        shapes[param["name"]] = shape if shape && !shape["poisoned"]
      end
    end

    def inferred_param_hash_shape(method_name, param_name, idx)
      shapes = [
        @inferred_param_hash_shapes[[method_name.to_s, "positional", idx.to_s]],
        @inferred_param_hash_shapes[[method_name.to_s, "keyword", param_name.to_s]],
      ].compact
      return nil if shapes.empty?
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def inferred_param_array_element_shape(method_name, param_name, idx)
      shapes = [
        @inferred_param_array_element_shapes[[method_name.to_s, "positional", idx.to_s]],
        @inferred_param_array_element_shapes[[method_name.to_s, "keyword", param_name.to_s]],
      ].compact
      return nil if shapes.empty?
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def dup_collection_builders(builders)
      builders.transform_values do |builder|
        TypedRecords::CollectionBuilderRecord.from(builder).deep_dup
      end
    end

    def collection_builder(kind)
      TypedRecords::CollectionBuilderRecord.new(kind: kind)
    end

    def merge_branch_collection_builders(before, then_builders, else_builders)
      names = (before.keys | then_builders.keys | else_builders.keys)
      names.each_with_object({}) do |name, merged|
        if then_builders.key?(name) && else_builders.key?(name)
          merged[name] = merge_collection_builders(then_builders[name], else_builders[name])
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def merge_collection_builders(left, right)
      return collection_builder("unknown").merge("poisoned" => true) unless left["kind"] == right["kind"]
      TypedRecords::CollectionBuilderRecord.new(
        kind: left["kind"],
        types: (Array(left["types"]) + Array(right["types"])).uniq,
        key_types: (Array(left["key_types"]) + Array(right["key_types"])).uniq,
        value_types: (Array(left["value_types"]) + Array(right["value_types"])).uniq,
        poisoned: left["poisoned"] || right["poisoned"],
      )
    end

    def dup_hash_shapes(shapes)
      shapes.transform_values { |shape| dup_hash_shape(shape) }
    end

    def dup_hash_shape(shape)
      TypedRecords::HashShapeRecord.from(shape)&.deep_dup
    end

    def merge_branch_hash_shapes(before, then_shapes, else_shapes)
      names = (before.keys | then_shapes.keys | else_shapes.keys)
      names.each_with_object({}) do |name, merged|
        if then_shapes.key?(name) && else_shapes.key?(name)
          merged[name] = merge_hash_record_shapes(then_shapes[name], else_shapes[name])
        elsif before.key?(name)
          merged[name] = before[name]
        end
      end
    end

    def merge_hash_record_shapes(left, right)
      TypedRecords::HashShapeRecord.from(left).merge_shape(right)
    end

    def merge_nested_hash_shape_maps(left, right)
      TypedRecords::HashShapeRecord.merge_shape_maps(
        TypedRecords::HashShapeRecord.shape_map_from(left),
        TypedRecords::HashShapeRecord.shape_map_from(right),
      )
    end

    def hash_shape_for_return_expressions(expressions)
      record_expressions = expressions.compact.reject { |expr| nil_return_expression?(expr) }
      shapes = record_expressions.filter_map { |expr| hash_shape_for_expression(expr) }
      return nil if shapes.empty? || shapes.size != record_expressions.size
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def hash_shape_for_expression(expr)
      case expr
      when :bare_return
        nil
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        hash_shape_for_expression(implicit_return_expression(expr))
      else
        if return_node?(expr)
          args = expr.respond_to?(:arguments) ? expr.arguments : nil
          values = args&.arguments || []
          return hash_shape_for_expression(values.first || :bare_return)
        end
        case expr
        when Syntax::IfNode
          left = hash_shape_for_expression(implicit_return_expression(expr.statements))
          right = expr.subsequent ? hash_shape_for_expression(implicit_return_expression(expr.subsequent)) : nil
          return nil unless left && right
          merge_hash_record_shapes(left, right)
        else
          hash_shape_for_value(expr)
        end
      end
    end

    def nil_return_expression?(expr)
      return true if expr == :bare_return
      if return_node?(expr)
        args = expr.respond_to?(:arguments) ? expr.arguments : nil
        values = args&.arguments || []
        return true if values.empty?
        return nil_return_expression?(values.first)
      end
      case expr
      when Syntax::NilNode
        true
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        nil_return_expression?(implicit_return_expression(expr))
      else
        false
      end
    end

    def array_element_shape_for_return_expressions(expressions)
      record_expressions = expressions.compact.reject { |expr| nil_return_expression?(expr) }
      shapes = record_expressions.filter_map { |expr| array_element_shape_for_expression(expr) }
      return nil if shapes.empty? || shapes.size != record_expressions.size
      shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
    end

    def array_element_shape_for_expression(expr)
      case expr
      when :bare_return
        nil
      when Syntax::StatementsNode, Syntax::BeginNode, Syntax::ElseNode, Syntax::ParenthesesNode
        array_element_shape_for_expression(implicit_return_expression(expr))
      else
        if return_node?(expr)
          args = expr.respond_to?(:arguments) ? expr.arguments : nil
          values = args&.arguments || []
          return array_element_shape_for_expression(values.first || :bare_return)
        end
        case expr
        when Syntax::IfNode
          left = array_element_shape_for_expression(implicit_return_expression(expr.statements))
          right = expr.subsequent ? array_element_shape_for_expression(implicit_return_expression(expr.subsequent)) : nil
          return nil unless left && right
          merge_hash_record_shapes(left, right)
        else
          array_element_shape_for_value(expr)
        end
      end
    end

    def update_collection_builder_call(node)
      receiver = node.receiver
      if receiver.is_a?(Syntax::LocalVariableReadNode) && @current_collection_builders.key?(receiver.name.to_s)
        update_receiver_collection_builder(node, receiver.name.to_s)
      end
      poison_escaped_collection_builders(node)
    end

    def update_receiver_collection_builder(node, name)
      builder = @current_collection_builders[name]
      args = node.arguments&.arguments || []
      handled = true
      case node.name.to_s
      when "<<", "push", "add"
        add_collection_type(builder, args.first)
        add_array_element_shape(name, args.first) if builder["kind"] == "array"
      when "concat"
        add_array_collection_types(builder, args.first)
        add_array_element_shapes(name, args.first) if builder["kind"] == "array"
      when "[]="
        return unless args.size >= 2
        add_hash_collection_types(builder, args[0], args[-1])
        add_hash_shape_key(name, args[0], args[-1]) if builder["kind"] == "hash"
      when "merge!"
        add_hash_literal_collection_types(builder, args.first)
        merge_hash_shape_literal(name, args.first) if builder["kind"] == "hash"
      else
        handled = false
      end
      return unless handled
      @current_local_types[name] = synthesized_collection_builder_type(builder)
    end

    def add_array_element_shape(name, expr)
      shape = hash_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_array_element_shapes[name]
      @current_array_element_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def add_array_element_shapes(name, expr)
      shape = array_element_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_array_element_shapes[name]
      @current_array_element_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def add_hash_shape_key(name, key_expr, value_expr)
      key = hash_key_name(key_expr)
      type = expression_type(value_expr)
      return unless key && (NilKill.useful_type?(type) || type == "NilClass")
      shape = @current_hash_shapes[name] ||= TypedRecords::HashShapeRecord.empty
      shape["keys"][key] ||= []
      shape["keys"][key] |= [type]
    end

    def merge_hash_shape_literal(name, expr)
      shape = hash_shape_for_value(expr)
      return unless shape && !shape["poisoned"]
      current = @current_hash_shapes[name]
      @current_hash_shapes[name] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def poison_escaped_collection_builders(node)
      return if node.receiver
      return if node.name.to_s == @current_method_name
      return if known_return_type(node.name.to_s, node: node, allow_rbi: false)
      (node.arguments&.arguments || []).each do |arg|
        next unless arg.is_a?(Syntax::LocalVariableReadNode)
        builder = @current_collection_builders[arg.name.to_s]
        next unless builder
        builder["poisoned"] = true; @ep[0] += 1
        @current_local_types.delete(arg.name.to_s)
        @current_hash_shapes.delete(arg.name.to_s)
        @current_array_element_shapes.delete(arg.name.to_s)
      end
      (node.arguments&.arguments || []).each do |arg|
        next unless arg.is_a?(Syntax::LocalVariableReadNode)
        next unless @current_hash_shapes.key?(arg.name.to_s) || @current_array_element_shapes.key?(arg.name.to_s)
        @current_hash_shapes.delete(arg.name.to_s)
        @current_array_element_shapes.delete(arg.name.to_s)
      end
    end

    def add_collection_type(builder, expr)
      return unless builder && expr
      type = expression_type(expr)
      if NilKill.useful_type?(type) || type == "NilClass"
        builder["types"] |= [type]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_array_collection_types(builder, expr)
      return unless builder && expr
      if expr.is_a?(Syntax::ArrayNode)
        expr.elements.each { |elem| add_collection_type(builder, elem) }
        return
      end
      type = expression_type(expr)
      info = collection_type_info(type)
      if info && info["kind"] == "array" && NilKill.useful_type?(info["element"])
        builder["types"] |= [info["element"]]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_hash_collection_types(builder, key_expr, value_expr)
      return unless builder
      key_type = expression_type(key_expr)
      value_type = expression_type(value_expr)
      if (NilKill.useful_type?(key_type) || key_type == "NilClass") && (NilKill.useful_type?(value_type) || value_type == "NilClass")
        builder["key_types"] |= [key_type]; @ep[0] += 1
        builder["value_types"] |= [value_type]; @ep[0] += 1
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def add_hash_literal_collection_types(builder, expr)
      return unless builder && expr
      if expr.is_a?(Syntax::HashNode) || expr.is_a?(Syntax::KeywordHashNode)
        expr.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          add_hash_collection_types(builder, assoc.key, assoc.value)
        end
      else
        builder["poisoned"] = true; @ep[0] += 1
      end
    end

    def builder_has_evidence?(builder)
      builder && (!Array(builder["types"]).empty? || !Array(builder["key_types"]).empty? ||
        !Array(builder["value_types"]).empty? || builder["poisoned"])
    end

    def synthesized_collection_builder_type(builder)
      return nil unless builder
      return nil if builder["poisoned"]
      case builder["kind"]
      when "array"
        elem = NilKill.static_sorbet_type(builder["types"])
        elem = "T.untyped" unless NilKill.useful_type?(elem)
        "T::Array[#{elem}]"
      when "hash"
        key = NilKill.static_sorbet_type(builder["key_types"])
        value = NilKill.static_sorbet_type(builder["value_types"])
        key = "T.untyped" unless NilKill.useful_type?(key)
        value = "T.untyped" unless NilKill.useful_type?(value)
        "T::Hash[#{key}, #{value}]"
      when "set"
        elem = NilKill.static_sorbet_type(builder["types"])
        elem = "T.untyped" unless NilKill.useful_type?(elem)
        "T::Set[#{elem}]"
      end
    end

    def explicit_return_expressions(node)
      results = []
      collect_explicit_returns(node, results)
      results
    end

    def collect_explicit_returns(node, results)
      return unless node
      return if nested_scope_node?(node)
      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        results << (values.first || :bare_return)
        return
      end
      node.compact_child_nodes.each { |child| collect_explicit_returns(child, results) } if node.respond_to?(:child_nodes)
    end

    def implicit_return_expression(node)
      case node
      when Syntax::StatementsNode
        node.body&.last
      when Syntax::BeginNode
        implicit_return_expression(node.statements)
      when Syntax::ElseNode
        implicit_return_expression(node.statements)
      when Syntax::ParenthesesNode
        implicit_return_expression(node.body)
      else
        node
      end
    end

    def return_syntax(explicit_expressions, implicit_present)
      explicit = !explicit_expressions.empty?
      return "mixed" if explicit && implicit_present
      return "explicit" if explicit
      "implicit"
    end

    def return_control_shape(explicit_expressions, implicit_expr, implicit_present)
      return "branching" if explicit_expressions.size > 1
      return "branching" if !explicit_expressions.empty? && implicit_present
      return "branching" if explicit_expressions.any? { |expr| branching_return_expression?(expr) }
      return "branching" if implicit_present && branching_return_expression?(implicit_expr)
      "branchless"
    end

    def branching_return_expression?(node)
      case node
      when nil, :bare_return
        false
      when Syntax::IfNode, Syntax::CaseNode, Syntax::RescueNode
        true
      else
        node.respond_to?(:child_nodes) && node.compact_child_nodes.any? { |child| branching_return_expression?(child) }
      end
    end

    def return_sources_for(node, blockers)
      if node == :bare_return
        return [TypedRecords::ReturnSourceRecord.new(kind: "nil", return_type: "NilClass", line: nil, code: "return")]
      end
      return [] unless node
      line = node.location.start_line
      code = node.slice

      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        return return_sources_for(values.first || :bare_return, blockers)
      end

      if node.is_a?(Syntax::StatementsNode) || node.is_a?(Syntax::BeginNode) ||
          node.is_a?(Syntax::ElseNode) || node.is_a?(Syntax::ParenthesesNode)
        return return_sources_for(implicit_return_expression(node), blockers)
      end

      if node.is_a?(Syntax::InstanceVariableReadNode)
        ivar_type = ivar_expression_type(node.name.to_s)
        if NilKill.useful_type?(ivar_type)
          return [TypedRecords::ReturnSourceRecord.new(kind: "ivar_typed", return_type: ivar_type, line: line, code: code)]
        end
        blockers << "untyped instance variable #{code} at #{@rel}:#{line}"
        return [TypedRecords::ReturnSourceRecord.new(kind: "ivar_read", line: line, code: code)]
      end
      if node.is_a?(Syntax::ClassVariableReadNode) || node.is_a?(Syntax::GlobalVariableReadNode)
        blockers << "untyped instance variable #{code} at #{@rel}:#{line}"
        return [TypedRecords::ReturnSourceRecord.new(kind: "ivar_read", line: line, code: code)]
      end

      if node.is_a?(Syntax::IfNode)
        sources = []
        sources.concat(return_sources_for(implicit_return_expression(node.statements), blockers))
        if node.subsequent
          sources.concat(return_sources_for(implicit_return_expression(node.subsequent), blockers))
        else
          sources << TypedRecords::ReturnSourceRecord.new(kind: "nil", return_type: "NilClass", line: line, code: "implicit else")
        end
        blockers << "conditional return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::UnlessNode)
        sources = []
        sources.concat(return_sources_for(implicit_return_expression(node.statements), blockers))
        if node.respond_to?(:else_clause) && node.else_clause
          sources.concat(return_sources_for(implicit_return_expression(node.else_clause), blockers))
        else
          sources << TypedRecords::ReturnSourceRecord.new(kind: "nil", return_type: "NilClass", line: line, code: "implicit else")
        end
        blockers << "unless return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::CaseNode)
        sources = []
        node.conditions.each do |condition|
          sources.concat(return_sources_for(implicit_return_expression(condition.statements), blockers)) if condition.respond_to?(:statements)
        end
        sources.concat(return_sources_for(implicit_return_expression(node.else_clause), blockers)) if node.respond_to?(:else_clause)
        blockers << "case return without exhaustive static branch type at #{@rel}:#{line}" if sources.empty?
        return sources
      end

      if node.is_a?(Syntax::WhileNode) || node.is_a?(Syntax::UntilNode)
        return [TypedRecords::ReturnSourceRecord.new(kind: "nil", return_type: "NilClass", line: line, code: code)]
      end

      if node.is_a?(Syntax::CallNode)
        callee = node.name.to_s
        if assignment_call?(node)
          arg = assignment_value_expression(node)
          arg_type = expression_type(arg)
          if NilKill.useful_type?(arg_type)
            return [TypedRecords::ReturnSourceRecord.new(kind: "assignment", callee: callee, return_type: arg_type, line: line, code: code)]
          end
          blockers << "assignment #{callee} has unknown RHS at #{@rel}:#{line}"
          return [TypedRecords::ReturnSourceRecord.new(
            kind: "unknown",
            line: line,
            code: code,
            unknown_reasons: unknown_expression_reasons(arg),
          )]
        end
        if node.safe_navigation?
          ret = known_return_type(callee, node: node, allow_rbi: rbi_return_candidate?(node))
          if ret && NilKill.useful_type?(ret)
            return [TypedRecords::ReturnSourceRecord.new(
              kind: "safe_call",
              callee: callee,
              return_type: nilable_type(ret),
              line: line,
              code: code,
              stdlib: statically_provable_call?(node),
            )]
          end
          blockers << "safe navigation return may be nil at #{@rel}:#{line}"
          return [
            TypedRecords::ReturnSourceRecord.new(kind: "nil", return_type: "NilClass", line: line, code: code),
            TypedRecords::ReturnSourceRecord.new(kind: "call_untyped", callee: callee, line: line, code: code),
          ]
        end
        ret = known_return_type(callee, node: node, allow_rbi: rbi_return_candidate?(node))
        if ret && NilKill.useful_type?(ret)
          return [TypedRecords::ReturnSourceRecord.new(
            kind: "typed_call",
            callee: callee,
            return_type: ret,
            line: line,
            code: code,
            stdlib: statically_provable_call?(node),
          )]
        end
        expr_type = expression_type(node)
        if NilKill.useful_type?(expr_type)
          return [TypedRecords::ReturnSourceRecord.new(kind: "static", callee: callee, return_type: expr_type, line: line, code: code)]
        end
        blockers << "untyped callee #{callee} at #{@rel}:#{line}"
        return [TypedRecords::ReturnSourceRecord.new(kind: "call_untyped", callee: callee, line: line, code: code)]
      end

      # `@x = v` / `x = v` / `CONST = v` as the return expression: the
      # returned value IS the RHS, so type it as the RHS.
      if node.is_a?(Syntax::InstanceVariableWriteNode) || node.is_a?(Syntax::LocalVariableWriteNode) ||
         node.is_a?(Syntax::ClassVariableWriteNode) || node.is_a?(Syntax::GlobalVariableWriteNode) ||
         node.is_a?(Syntax::ConstantWriteNode)
        return return_sources_for(node.value, blockers)
      end

      type = expression_type(node)
      if type
        return [TypedRecords::ReturnSourceRecord.new(kind: type == "NilClass" ? "nil" : "static", return_type: type, line: line, code: code)]
      end

      blockers << "unknown return expression #{node.class.name.split("::").last} at #{@rel}:#{line}"
      [TypedRecords::ReturnSourceRecord.new(
        kind: "unknown",
        line: line,
        code: code,
        unknown_reasons: unknown_expression_reasons(node),
      )]
    end

    def assignment_call?(node)
      setter_call?(node) || index_assignment_call?(node)
    end

    def setter_call?(node)
      # Comparisons (`==`, `!=`, `<=`, `>=`, `===`) also end with `=`;
      # without excluding them `1 != 2` is misread as an assignment.
      return false unless node.is_a?(Syntax::CallNode)
      name = node.name.to_s
      return false unless name.end_with?("=")
      return false if %w[== != <= >= ===].include?(name)
      (node.arguments&.arguments || []).size == 1
    end

    def index_assignment_call?(node)
      node.is_a?(Syntax::CallNode) && node.name == :[]= && (node.arguments&.arguments || []).size >= 2
    end

    def assignment_value_expression(node)
      args = node.arguments&.arguments || []
      args.last
    end

    def return_node?(node)
      node.is_a?(Syntax::ReturnNode)
    end

    def nested_scope_node?(node)
      node.is_a?(Syntax::DefNode) || node.is_a?(Syntax::ClassNode) || node.is_a?(Syntax::ModuleNode)
    end

    def rbi_return_candidate?(node)
      return false unless node.is_a?(Syntax::CallNode)
      # A global-variable receiver (`$stderr.puts`) is dynamically
      # reassignable, so its RBI nominal return is unsound to narrow on.
      return false if node.receiver.is_a?(Syntax::GlobalVariableReadNode)
      node.receiver || %w[! == puts print warn raise].include?(node.name.to_s)
    end

    def rbi_return_source?(node)
      node.is_a?(Syntax::CallNode) && NilKill.rbi_return_type(node.name.to_s, receiver_type_for_call(node))
    end

    # rbi_return_source? needs the external sorbet RBI payload, which is
    # absent under isolated test/CI tmp dirs. A call whose return is
    # provable from core Ruby semantics on a known receiver type
    # (propagated_core_return_type, e.g. Array[String]#join -> String)
    # is statically provable without any payload -- grade it the same.
    def statically_provable_call?(node)
      rbi_return_source?(node) || NilKill.useful_type?(propagated_core_return_type(node))
    end

    def known_return_type(method_name, node: nil, allow_rbi: true)
      propagated = propagated_core_return_type(node)
      return propagated if NilKill.useful_type?(propagated)
      static = @static_return_types[method_name.to_s]
      return static if NilKill.useful_type?(static)
      types = @method_return_types[method_name].compact.uniq
      return types.first if types.size == 1 && NilKill.useful_type?(types.first)
      return nil unless allow_rbi
      NilKill.rbi_return_type(method_name, receiver_type_for_call(node))
    end

    def propagated_core_return_type(node)
      return nil unless node.is_a?(Syntax::CallNode)
      receiver_type = receiver_type_for_call(node)
      case node.name.to_s
      when "[]"
        collection_index_return_type(node, receiver_type)
      when "each", "each_pair", "each_value", "each_key"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "<<", "push", "concat", "merge!", "add"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "map"
        collection_map_return_type(node, receiver_type)
      when "filter_map"
        collection_filter_map_return_type(node, receiver_type)
      when "compact"
        collection_compact_return_type(receiver_type)
      when "select", "reject"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "length", "size"
        collection_receiver_type?(receiver_type) || receiver_type == "String" ? "Integer" : nil
      when "empty?", "any?", "all?", "none?", "one?", "include?", "key?", "has_key?", "value?", "has_value?"
        collection_receiver_type?(receiver_type) || receiver_type == "String" ? "T::Boolean" : nil
      when "join"
        array_receiver_type?(receiver_type) ? "String" : nil
      when "to_s"
        node.receiver ? "String" : nil
      when "to_i"
        node.receiver ? "Integer" : nil
      when "to_sym"
        node.receiver ? "Symbol" : nil
      when "to_a"
        collection_receiver_type?(receiver_type) ? receiver_type : nil
      when "to_h"
        receiver_type.to_s.match?(/\AT::(?:Hash|Array)\b/) ? receiver_type : nil
      when "!", "!=", "==", "<", ">", "<=", ">=", "eql?", "equal?", "===", "frozen?", "respond_to?", "kind_of?", "instance_of?"
        "T::Boolean"
      when "<=>"
        node.receiver ? "T.nilable(Integer)" : nil
      when "hash"
        node.receiver ? "Integer" : nil
      when "inspect"
        node.receiver ? "String" : nil
      when "freeze", "dup", "clone", "itself", "tap"
        receiver_type if NilKill.useful_type?(receiver_type)
      when "+", "-", "*", "/", "%"
        # Receiver-typed for stdlib numerics, String, Array (where defined).
        # Skip for unknown receivers so we don't over-claim.
        case receiver_type.to_s
        when "Integer", "Float", "Rational", "Complex", "String" then receiver_type
        else
          array_receiver_type?(receiver_type) ? receiver_type : nil
        end
      else
        nil
      end
    end

    def receiver_type_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      expression_type(node.receiver)
    end

    def nilable_type(type)
      return type if type == "NilClass"
      return type if type.start_with?("T.nilable(")
      "T.nilable(#{type})"
    end

  end
end
