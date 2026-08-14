# frozen_string_literal: true

module RubyToClear
  module MethodRegistry
    UNSAFE_VALUE_BLOCK_NODES = %w[
      ReturnNode BreakNode NextNode YieldNode SuperNode ForwardingSuperNode
      EnsureNode
    ].freeze

    CallContext = Struct.new(
      :ruby_name,
      :receiver_code,
      :receiver_kind,
      :receiver_name,
      :receiver_shape,
      :node,
      :transpiler,
      keyword_init: true
    )

    BlockLowering = Struct.new(
      :parameter_names,
      :value_lines,
      :effect_lines,
      :source_location,
      keyword_init: true
    ) do
      def value_code
        return value_lines.first if value_lines.length == 1

        "{\n#{value_lines.join("\n")}\n}"
      end

      def effect_code
        effect_lines.join("\n")
      end

      def multiline_effect?
        effect_lines.length > 1 || effect_lines.any? { |line| line.include?("\n") }
      end
    end

    REGISTRY = {}

    def self.register(ruby_name, receiver: :any, &block)
      REGISTRY[[receiver.to_s, ruby_name.to_s]] = block
    end

    def self.registered_name?(ruby_name)
      REGISTRY.keys.any? { |_receiver, name| name == ruby_name.to_s }
    end

    def self.translate(ruby_name, receiver, node, transpiler, receiver_kind: nil, receiver_name: nil, receiver_shape: nil)
      context = CallContext.new(
        ruby_name: ruby_name.to_s,
        receiver_code: receiver,
        receiver_kind: receiver_kind&.to_s,
        receiver_name: receiver_name&.to_s,
        receiver_shape: receiver_shape&.to_s,
        node: node,
        transpiler: transpiler
      )
      handler = lookup(context)
      return nil unless handler

      call_handler(handler, context)
    end

    def self.lookup(context)
      REGISTRY[[context.receiver_name, context.ruby_name]] ||
        REGISTRY[[context.receiver_kind, context.ruby_name]] ||
        REGISTRY[[context.receiver_shape, context.ruby_name]] ||
        (context.receiver_code || context.ruby_name == "respond_to?" ? REGISTRY[["any", context.ruby_name]] : nil)
    end

    def self.call_handler(handler, context)
      if handler.arity == 1
        handler.call(context)
      else
        handler.call(context.receiver_code, context.node, context.transpiler)
      end
    end

    def self.unsupported(transpiler, node, message)
      transpiler.unsupported_expression(node, message)
    end

    def self.argument_nodes(context)
      context.node.arguments ? context.node.arguments.arguments : []
    end

    def self.arguments(context)
      argument_nodes(context).map { |arg| context.transpiler.visit(arg) }
    end

    def self.method_receiver(transpiler, receiver)
      transpiler.method_receiver_code(receiver)
    end

    def self.static_first_argument_name(context)
      arg = argument_nodes(context).first
      case arg
      when Prism::ConstantReadNode
        arg.name.to_s
      when Prism::ConstantPathNode
        arg.location.slice.strip
      when Prism::SymbolNode
        arg.value.to_s
      when Prism::StringNode
        arg.content
      end
    end

    def self.regex_node?(node)
      node.is_a?(Prism::RegularExpressionNode) ||
        node.is_a?(Prism::InterpolatedRegularExpressionNode)
    end

    def self.static_call(context, clear_name, min:, max: min)
      args = arguments(context)
      unless args.length >= min && args.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(context.transpiler, context.node, "#{context.receiver_name}.#{context.ruby_name} expects #{expected} arguments")
      end
      "#{clear_name}(#{args.join(', ')})"
    end

    def self.package_call(context, package, clear_name, min:, max: min, fallible: false)
      args = arguments(context)
      unless args.length >= min && args.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(context.transpiler, context.node, "#{context.receiver_name}.#{context.ruby_name} expects #{expected} arguments")
      end

      context.transpiler.require_package(package)
      context.transpiler.mark_current_function_fallible! if fallible
      call = "#{clear_name}(#{args.join(', ')})"
      fallible ? "TRY (#{call})" : call
    end

    def self.fs_call(context, clear_name, min:, max: min, fallible: false)
      package_call(context, "fs", clear_name, min: min, max: max, fallible: fallible)
    end

    def self.path_call(context, clear_name, min:, max: min)
      package_call(context, "path", clear_name, min: min, max: max)
    end

    def self.unsupported_result?(value)
      value.is_a?(String) && (value.include?("# [UNSUPPORTED:") || value.include?("unsupportedRuby("))
    end

    def self.pipeline_source(receiver)
      receiver.include?(" OR ") ? "(#{receiver})" : receiver
    end

    def self.block_required_parameter_names(node, block_node, transpiler, method_label, min:, max:)
      params = block_node.parameters&.parameters
      requireds = params&.requireds || []

      if params && (params.optionals.any? || params.rest || params.posts.any? ||
                    params.keywords.any? || params.keyword_rest || params.block)
        return unsupported(transpiler, node, "#{method_label} block parameter shape is not supported")
      end

      unless requireds.length >= min && requireds.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(transpiler, node, "#{method_label} block expects #{expected} required parameters")
      end

      destructured_each_with_index = method_label == "each_with_index" &&
        requireds.length == 2 && requireds.first.is_a?(Prism::MultiTargetNode) &&
        requireds.first.lefts.all? { |param| param.respond_to?(:name) } &&
        requireds.last.respond_to?(:name)
      unless requireds.all? { |param| param.respond_to?(:name) } || destructured_each_with_index
        return unsupported(transpiler, node, "#{method_label} block parameter destructuring is not supported")
      end

      raw_names = if destructured_each_with_index
        ["destructured_0", requireds.last.name.to_s]
      else
        requireds.map { |param| param.name.to_s }
      end
      raw_names.map.with_index { |name, index| transpiler.clear_lambda_parameter_name(name, index) }
    end

    def self.pipeline_block_aliases(param_names)
      case param_names.length
      when 0
        {}
      when 1
        { param_names[0] => "_" }
      when 2
        { param_names[0] => "_._0", param_names[1] => "_._1" }
      else
        {}
      end
    end

    def self.unsafe_value_block_node(block_node, allow_next: false, allow_yield: false, allow_break: false, allow_return: false)
      found = nil
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)
        return if found
        return if node != block_node && node.is_a?(Prism::BlockNode)

        node_name = node.class.name.split("::").last
        if allow_next && node_name == "NextNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if allow_yield && node_name == "YieldNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if allow_break && node_name == "BreakNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if allow_return && node_name == "ReturnNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if UNSAFE_VALUE_BLOCK_NODES.include?(node_name)
          found = node_name
          return
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      found
    end

    def self.block_contains_node_name?(block_node, expected)
      found = false
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node) && !found
        return if node != block_node && node.is_a?(Prism::BlockNode)

        found = true if node.class.name.split("::").last == expected
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      found
    end

    def self.block_contains_assignment?(block_node)
      found = false
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node) && !found
        return if node != block_node && node.is_a?(Prism::BlockNode)

        node_name = node.class.name.split("::").last
        call_assignment = node.is_a?(Prism::CallNode) &&
          (node.name.to_s == "[]=" || node.name.to_s.end_with?("="))
        found = true if node_name.end_with?("WriteNode", "TargetNode") || call_assignment
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      found
    end

    def self.statement_code?(code)
      return true if code.end_with?(";") || code.lstrip.start_with?("#")

      stripped = code.lstrip
      return false if stripped.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*=/) && stripped.rstrip.end_with?("END)")
      return true if stripped.start_with?("IF ", "COMPTIME IF ", "WHILE ", "FOR ", "MATCH ", "PARTIAL MATCH ", "TEST ", "WHEN ")
      # One OR MORE `decl = ...;` lines may precede the block keyword: an each
      # loop emits both its hoisted collection and its index before the WHILE.
      return true if stripped.match?(/\A(?:(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=\n]+)?\s*=[^\n]*;\n\s*)+(?:IF|COMPTIME IF|WHILE|FOR|MATCH|PARTIAL MATCH|TEST|WHEN) /)

      false
    end

    def self.statement_line(code, transpiler = nil)
      return transpiler.statement_code(code) if transpiler

      statement_code?(code) ? code : "#{code};"
    end

    def self.indent_block_line(code)
      code.split("\n").map { |line| "  #{line}" }.join("\n")
    end

    def self.lower_literal_block(node, block_node, transpiler, method_label, min_params:, max_params:, rename:, allow_next: false, allow_yield: false, allow_break: false, allow_return: false, local_types: nil)
      unless block_node.is_a?(Prism::BlockNode)
        return unsupported(transpiler, node, "Unsupported #{method_label} block type: #{block_node.class.name}")
      end

      param_names = block_required_parameter_names(node, block_node, transpiler, method_label, min: min_params, max: max_params)
      return param_names if unsupported_result?(param_names)

      requireds = block_node.parameters&.parameters&.requireds || []
      aliases = if method_label == "each_with_index" && requireds.first.is_a?(Prism::MultiTargetNode)
        requested_aliases = rename.call(param_names)
        element_code = requested_aliases.fetch(param_names.first, param_names.first)
        destructured = requireds.first.lefts.each_with_index.to_h do |param, index|
          [param.name.to_s, "#{element_code}[#{index}]"]
        end
        index_name = param_names.last
        destructured[requireds.last.name.to_s] = requested_aliases.fetch(index_name, index_name)
        destructured
      else
        raw_names = requireds.map { |param| param.name.to_s }
        requested_aliases = rename.call(param_names)
        raw_names.zip(param_names).to_h do |raw_name, clear_name|
          [raw_name, requested_aliases.fetch(clear_name, clear_name)]
        end
      end
      transpiler.with_block_local_scope do
        transpiler.with_local_types(local_types ? local_types.call(param_names) : {}) do
          transpiler.with_renames(aliases) do
            if (unsafe = unsafe_value_block_node(block_node, allow_next: allow_next, allow_yield: allow_yield, allow_break: allow_break, allow_return: allow_return))
              next unsupported(transpiler, node, "#{method_label} block contains unsupported #{unsafe}")
            end

            lowering = lower_block_body(block_node, transpiler)
            lowering.parameter_names = param_names if lowering.is_a?(BlockLowering)
            lowering
          end
        end
      end
    end

    def self.lower_block_body(block_node, transpiler)
      body = block_node.body
      unless body.is_a?(Prism::StatementsNode) && body.body.any?
        return unsupported(transpiler, block_node, "Pipeline block must contain at least one expression")
      end

      statements = body.body
      source_location = block_node.location

      rendered_pairs = statements.map do |stmt|
        [stmt, transpiler.visit(stmt)]
      end.reject { |_stmt, code| code.to_s.strip.empty? }
      statements = rendered_pairs.map(&:first)
      rendered = rendered_pairs.map(&:last)
      value_rendered = statements.map.with_index do |stmt, index|
        value_if = if index == statements.length - 1 &&
                      (stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode))
          begin
            stmt.is_a?(Prism::IfNode) ? transpiler.expression_if_code(stmt) : transpiler.expression_argument_code(stmt)
          rescue Transpiler::TranspilationError
            # Effect-only blocks may end in a statement IF whose branches are
            # intentionally multi-statement. Keep its statement rendering;
            # value consumers will still reject the non-expression shape.
            nil
          end
        end
        value_case = index == statements.length - 1 && stmt.is_a?(Prism::CaseNode) &&
          stmt.conditions.all? { |condition| condition.statements&.body&.length == 1 } &&
          (!stmt.consequent || stmt.consequent.statements&.body&.length == 1) &&
          !block_contains_assignment?(stmt) &&
          !%w[ReturnNode BreakNode NextNode YieldNode LocalVariableWriteNode InstanceVariableWriteNode
              ClassVariableWriteNode ConstantWriteNode MultiWriteNode].any? do |name|
            block_contains_node_name?(stmt, name)
          end
        if value_if
          value_if
        elsif value_case
          transpiler.expression_argument_code(stmt)
        else
          rendered[index]
        end
      end
      if statements.empty?
        return BlockLowering.new(
          parameter_names: [],
          value_lines: ["NIL"],
          effect_lines: [],
          source_location: source_location
        )
      end

      guarded_value = guarded_next_value_sequence(statements, transpiler, value_rendered)
      guarded_narrowing = transpiler.pipeline_guarded_narrowing_expression(statements)
      value_lines = if guarded_narrowing
        [guarded_narrowing]
      elsif guarded_value
        [guarded_value]
      else
        value_rendered.map.with_index do |code, index|
          final = index == rendered.length - 1
          line = final ? code : statement_line(code, transpiler)
          line = "(#{line})" if final &&
            (statements[index].is_a?(Prism::IfNode) || statements[index].is_a?(Prism::UnlessNode))
          indent_block_line(line)
        end
      end

      effect_rendered = statements.map.with_index do |stmt, index|
        stmt.is_a?(Prism::CaseNode) ? transpiler.statement_node_code(stmt) : rendered[index]
      end
      effect_lines = guarded_next_effect_sequence(statements, transpiler, effect_rendered) || effect_rendered.map do |code|
        indent_block_line(statement_line(code, transpiler))
      end

      if statements.length == 1
        value = if statements.first.is_a?(Prism::IfNode) || statements.first.is_a?(Prism::UnlessNode)
          "(#{value_rendered.first})"
        else
          rendered.first
        end
        value_lines = [value]
        effect_lines = [statement_line(effect_rendered.first, transpiler)]
      end

      BlockLowering.new(
        parameter_names: [],
        value_lines: value_lines,
        effect_lines: effect_lines,
        source_location: source_location
      )
    end

    def self.guarded_next_effect_sequence(statements, transpiler, rendered = nil)
      guard = statements.first
      return nil unless guard.is_a?(Prism::IfNode) || guard.is_a?(Prism::UnlessNode)
      return nil if guard.consequent
      branch = guard.statements&.body || []
      return nil unless branch.length == 1 && branch.first.is_a?(Prism::NextNode)

      predicate = transpiler.visit(guard.predicate)
      predicate = "!(#{predicate})" if guard.is_a?(Prism::UnlessNode)
      lines = [indent_block_line("IF #{predicate} THEN\n  CONTINUE;\nEND")]
      remainder = rendered ? rendered.drop(1) : statements.drop(1).map { |statement| transpiler.visit(statement) }
      lines.concat(remainder.map { |code| indent_block_line(statement_line(code, transpiler)) })
      lines
    end

    def self.guarded_next_value_sequence(statements, transpiler, rendered = nil)
      return nil if statements.length < 2
      return nil unless statements.any? { |statement| guarded_next_value_node(statement) }

      guarded_next_value_sequence_code(statements, transpiler, rendered)
    end

    def self.guarded_next_value_node(statement)
      return nil unless statement.is_a?(Prism::IfNode) || statement.is_a?(Prism::UnlessNode)
      return nil if statement.consequent

      branch = statement.statements&.body || []
      return nil unless branch.length == 1 && branch.first.is_a?(Prism::NextNode)

      branch.first
    end

    def self.guarded_next_value_sequence_code(statements, transpiler, rendered = nil)
      statement = statements.first
      code = rendered ? rendered.first : transpiler.visit(statement)
      return code if statements.length == 1

      if (next_node = guarded_next_value_node(statement))
        next_args = next_node.arguments&.arguments || []
        return nil if next_args.length > 1

        next_value = next_args.empty? ? "NIL" : transpiler.visit(next_args.first)
        remainder = guarded_next_value_sequence_code(statements.drop(1), transpiler, rendered&.drop(1))
        predicate = transpiler.visit(statement.predicate)
        predicate = "!(#{predicate})" if statement.is_a?(Prism::UnlessNode)
        return "(IF #{predicate} THEN #{next_value} ELSE #{remainder} END)"
      end

      remainder = guarded_next_value_sequence_code(statements.drop(1), transpiler, rendered&.drop(1))
      setup = statement_line(code, transpiler)
      "{ MUTABLE rtoc_value_block_marker = 0; #{setup} #{parenthesize_bare_expression_if(remainder)} }"
    end

    # A value block's own parser (parse_value_block_expr) treats a LEADING
    # IF/COMPTIME IF token as a forced statement (VALUE_BLOCK_STATEMENT_
    # KEYWORDS), routing it through parse_if_chain's statement-form parsing
    # - which requires every branch to be a `;`-terminated statement list,
    # not the bare single-expression-per-branch shape an expression-IF
    # (if_expression_code's output) actually has. The result was a real
    # parser error ("Expected `;`... got 'ELSE_IF'") whenever a bare
    # expression-IF ended up as a value block's trailing content - exactly
    # what happens here when `remainder` (the rest of a guarded-next
    # sequence) is itself an if/elsif/else Ruby expression. Parenthesizing
    # it routes parsing through parse_expression -> parse_if_expr instead
    # (the expression-position IF parser, which correctly accepts bare
    # single-expression branches), sidestepping the value-block keyword
    # dispatch entirely - the same reason `(IF ... END)` already parses
    # fine directly after RETURN while a bare `IF ... END` inside `{ }`
    # does not.
    def self.parenthesize_bare_expression_if(code)
      return code unless code.to_s.lstrip.start_with?("IF ", "COMPTIME IF ")

      "(#{code})"
    end

    def self.render_block_value(block_node, transpiler)
      lowering = lower_block_body(block_node, transpiler)
      return lowering if unsupported_result?(lowering)

      lowering.value_code
    end

    def self.render_effect_block(lowering)
      if lowering.multiline_effect?
        "{\n#{lowering.effect_code}\n}"
      else
        "{ #{lowering.effect_code} }"
      end
    end

    def self.pipeline_value_stage(receiver, stage_name, node, transpiler, method_label)
      # A `return` inside the block returns from the ENCLOSING METHOD in Ruby,
      # which a `|> SELECT` pipeline stage cannot express - the value has to be
      # produced by a statement loop that a RETURN can escape. Mirrors the
      # nonlocal_return branch hash.each already uses (real corpus:
      # mir/fsm_transform/emit.rb's `prior.map { |c| ...; return nil if m.nil?;
      # m }`, previously rejected as "map block contains unsupported
      # ReturnNode").
      if stage_name == "SELECT" && node.block &&
         block_contains_node_name?(node.block, "ReturnNode")
        return nonlocal_return_map_code(receiver, node, transpiler, method_label)
      end

      block_body = block_value_expression(receiver, node, transpiler, method_label)
      return block_body if unsupported_result?(block_body)

      if stage_name == "SELECT" && (result_type = allocating_map_result_type(node, transpiler))
        return imperative_array_map_code(pipeline_source(receiver), block_body, result_type)
      end

      "#{pipeline_source(receiver)} |> #{stage_name} #{block_body}"
    end

    # `xs.map { |x| ...; return nil if cond; v }` becomes a statement FOR loop
    # accumulating into a fresh list, so the block's RETURN keeps its Ruby
    # meaning (leave the enclosing function) instead of being reinterpreted as
    # a per-element value.
    def self.nonlocal_return_map_code(receiver, node, transpiler, method_label)
      item = transpiler.next_generated_local("map_item")
      out = transpiler.next_generated_local("map_results")
      element_type = array_element_type_for_receiver(node, transpiler)
      lowering = lower_literal_block(
        node,
        node.block,
        transpiler,
        method_label,
        min_params: 1,
        max_params: 1,
        rename: ->(param_names) { { param_names.first => item } },
        allow_next: true,
        allow_break: true,
        allow_return: true,
        local_types: lambda do |param_names|
          element_type && param_names.first ? { param_names.first => element_type } : {}
        end
      )
      return lowering if unsupported_result?(lowering)

      # value_lines is the block rendered as [statement, ..., final_expression];
      # keep the statements as-is and append the final expression's value
      # instead of discarding it.
      # When the block's final statement is itself a `return`, no element is
      # ever produced - every iteration leaves the enclosing function - so
      # there is nothing to accumulate and the loop is statements only.
      block_statements = node.block.is_a?(Prism::BlockNode) ? (node.block.body&.body || []) : []
      if block_statements.last.is_a?(Prism::ReturnNode)
        # effect_code, not value_code: the block is pure statements here, and
        # only the statement rendering terminates them with `;`.
        return "( { MUTABLE #{out} = List[];\n" \
          "FOR #{item} IN #{pipeline_source(receiver)} DO\n#{lowering.effect_code}\nEND\n#{out} } )"
      end

      statements = lowering.value_lines[0...-1].join("\n")
      # A bare `List[]` has no element type for CLEAR to infer from an empty
      # literal, so declare it from the block's own result type (same
      # inference hash_transform_result_type uses, with the block parameter
      # bound to the element type so a nested pipeline resolves correctly).
      raw_result_type = nonlocal_return_map_raw_result_type(node, transpiler, element_type)
      result_type = raw_result_type&.delete_prefix("?")
      value = lowering.value_lines.last.to_s.strip
      # The guard clause is what skips the nil case, so the accumulated
      # element is always present - but CLEAR does not narrow the optional
      # across a `RETURN`-style guard, so unwrap explicitly at the append.
      value = "UNWRAP (#{value})" if raw_result_type.to_s.start_with?("?")
      appended = indent_block_line("&#{out}.append(COPY #{value});")
      loop_body = [statements, appended].reject { |part| part.to_s.strip.empty? }.join("\n")
      declaration = result_type ? "MUTABLE #{out}: []#{result_type} = List[]" : "MUTABLE #{out} = List[]"
      "( { #{declaration};\n" \
        "FOR #{item} IN #{pipeline_source(receiver)} DO\n#{loop_body}\nEND\n#{out} } )"
    end

    def self.nonlocal_return_map_raw_result_type(node, transpiler, element_type)
      statements = node.block.is_a?(Prism::BlockNode) ? node.block.body&.body : nil
      return nil unless statements&.any?

      param_name = node.block.parameters&.parameters&.requireds&.first
      param_name = param_name.name.to_s if param_name.respond_to?(:name)
      scope = {}
      scope[param_name] = element_type if element_type && param_name
      inferred = transpiler.with_local_types(scope) do
        # The block's final expression is usually a local assigned earlier in
        # the same block (`m = lookup(c); ...; m`), so bind each assignment's
        # inferred type as we go - otherwise the last expression resolves
        # against an empty scope and yields nothing usable.
        statements[0...-1].each do |statement|
          next unless statement.is_a?(Prism::LocalVariableWriteNode)

          assigned = transpiler.inferred_clear_type(statement.value).to_s
          next if assigned.empty? || assigned == "Auto"

          transpiler.note_local_type(statement.name.to_s, assigned)
        end
        transpiler.inferred_clear_type(statements.last)
      end
      text = inferred.to_s
      return nil if text.empty? || text == "Auto" || text == "Any"

      text
    end

    def self.tuple_cast_result_type(code)
      match = code.to_s.match(/\A(?:COPY )?CAST\(.* AS (Tuple<.+>)\)\z/m)
      match && match[1]
    end

    def self.imperative_tuple_map_code(source, value, tuple_type, predicate: nil)
      append = "&rtoc_tuple_results.append(COPY #{value});"
      append = "IF #{predicate} THEN #{append} END" if predicate
      "( { MUTABLE rtoc_tuple_results = CAST([] AS #{tuple_type}[]); " \
        "#{source} |> EACH { #{append} }; rtoc_tuple_results } )"
    end

    def self.allocating_map_result_type(node, transpiler)
      return nil unless node.block.is_a?(Prism::BlockArgumentNode)
      expression = node.block.expression
      return nil unless expression.is_a?(Prism::SymbolNode)

      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s
      element_type = transpiler.array_element_clear_type(receiver_type)
      return nil unless element_type

      result_element = transpiler.method_return_type_for(expression.value.to_s, element_type).to_s
      return nil if result_element.empty? || result_element == "Auto" || result_element == "Any"
      return nil unless transpiler.copyable_storage_type?(result_element)

      "#{transpiler.collection_element_type(result_element)}[]"
    end

    def self.imperative_array_map_code(source, value, result_type)
      "( { MUTABLE rtoc_map_results = CAST([] AS #{result_type}); " \
        "#{source} |> EACH { &rtoc_map_results.append(COPY #{value}); }; rtoc_map_results } )"
    end

    def self.pipeline_effect_stage(receiver, source, node, transpiler, method_label)
      if node.block.is_a?(Prism::BlockArgumentNode)
        callback = transpiler.visit(node.block.expression)
        return "FOR rtoc_each_val IN #{source} DO\n  #{callback}(rtoc_each_val);\nEND"
      end

      lowering = block_effect_lowering(node, transpiler, method_label)
      return lowering if unsupported_result?(lowering)

      body = materialize_mutable_block_parameter(lowering.effect_code, "_", transpiler)
      "FOR _ IN #{source} DO\n#{body}\nEND"
    end

    def self.for_each_effect_loop(source, node, transpiler, method_label, element_type: nil)
      item_name = transpiler.next_generated_local("each_item")
      lowering = lower_literal_block(
        node,
        node.block,
        transpiler,
        method_label,
        min_params: 1,
        max_params: 1,
        rename: ->(param_names) { { param_names.first => item_name } },
        allow_next: true,
        allow_yield: true,
        allow_break: true,
        allow_return: true,
        local_types: lambda do |param_names|
          element_type && param_names.first ? { param_names.first => element_type } : {}
        end
      )
      return lowering if unsupported_result?(lowering)

      body = materialize_mutable_block_parameter(lowering.effect_code, item_name, transpiler)
      "FOR #{item_name} IN #{source} DO\n#{body}\nEND"
    end

    # FOR/pipeline element aliases are read-only views. A Ruby block may pass
    # its element to a parameter inferred as MUTABLE, in which case CLEAR
    # requires an independently mutable binding. Copy once at block entry and
    # consistently route all reads/writes through that binding.
    def self.materialize_mutable_block_parameter(code, parameter, transpiler)
      token = /(?<![A-Za-z0-9_])#{Regexp.escape(parameter)}(?![A-Za-z0-9_])/
      return code unless code.match?(/&#{Regexp.escape(parameter)}(?![A-Za-z0-9_])/)

      temporary = transpiler.next_generated_local("mutable_block_param")
      rewritten = code.gsub(token, temporary)
      "  MUTABLE #{temporary} = COPY #{parameter};\n#{rewritten}"
    end

    def self.materialize_mutable_block_value_parameter(code, parameter, transpiler)
      token = /(?<![A-Za-z0-9_])#{Regexp.escape(parameter)}(?![A-Za-z0-9_])/
      return code unless code.match?(/&#{Regexp.escape(parameter)}(?![A-Za-z0-9_])/)

      temporary = transpiler.next_generated_local("mutable_block_param")
      rewritten = code.gsub(token, temporary)
      "{ MUTABLE #{temporary} = COPY #{parameter};\n#{rewritten} }"
    end

    # `T.unsafe(node).each_pair { |_, v| walk(v) }` over a UNION-typed node
    # is struct-member reflection, not a hash walk: lower it to a FOR loop
    # over the generated per-union children helper. The field-NAME param
    # has no CLEAR counterpart, so bodies that read it stay unsupported.
    def self.union_struct_walk_stage(context)
      transpiler = context.transpiler
      node = context.node
      recv_node = node.receiver
      if recv_node.is_a?(Prism::CallNode) && recv_node.name.to_s == "unsafe" &&
         recv_node.receiver.is_a?(Prism::ConstantReadNode) && recv_node.receiver.name.to_s == "T"
        inner = recv_node.arguments&.arguments&.first
        recv_node = inner if inner
      end
      recv_type = transpiler.clear_type_for_receiver_node(recv_node).to_s
      union = recv_type.delete_prefix("?")
      union = union[1...-1].to_s if union.start_with?("(") && union.end_with?(")")
      union = union.delete_prefix("?").split("@").first.to_s
      helper = transpiler.ensure_union_children_helper(union)
      return nil unless helper

      block = node.block
      return nil unless block.is_a?(Prism::BlockNode)

      item = transpiler.next_generated_local("walk_child")
      lowering = lower_literal_block(
        node,
        block,
        transpiler,
        "each_pair_walk",
        min_params: 2,
        max_params: 2,
        rename: ->(param_names) { { param_names[1] => item } },
        allow_next: true,
        allow_yield: true,
        allow_break: true,
        allow_return: true,
        local_types: ->(param_names) { param_names[1] ? { param_names[1] => union } : {} }
      )
      return nil if unsupported_result?(lowering)

      source = method_receiver(transpiler, context.receiver_code)
      "FOR #{item} IN #{helper}(#{source}) DO\n#{lowering.effect_code}\nEND"
    end

    # A key taken from `keys()` is always present, but CLEAR still types the
    # index read as optional. `x OR_ELSE panic(...)` is rejected outright --
    # the annotator has no operator entry for a NoReturn right operand -- so
    # unwrap instead. COPY keeps a non-Copy value owned by the loop body.
    def self.map_value_at(receiver, key_expr)
      "COPY UNWRAP (#{receiver}[#{key_expr}])"
    end

    def self.hash_each_effect_stage(context)
      receiver = context.receiver_code
      node = context.node
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      key_type = transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = transpiler.map_value_clear_type(receiver_type) || "Any"
      # Hash#each is a statement, and CLEAR's EACH pipeline stage cannot take a
      # body that returns, breaks, or is fallible -- a FOR loop always can.
      key_expr = "rtoc_key"
      value_expr = map_value_at(receiver, key_expr)
      nonlocal_return = node.block && block_contains_node_name?(node.block, "ReturnNode")

      lowering = lower_literal_block(
        node,
        node.block,
        transpiler,
        "hash.each",
        min_params: 2,
        max_params: 2,
        rename: lambda do |param_names|
          { param_names[0] => key_expr }
        end,
        allow_next: true,
        allow_yield: true,
        allow_break: true,
        allow_return: nonlocal_return,
        local_types: lambda do |param_names|
          { param_names[0] => key_type, param_names[1] => value_type }
        end
      )
      return lowering if unsupported_result?(lowering)

      value_name = lowering.parameter_names[1]
      lowering.effect_lines.unshift(indent_block_line("MUTABLE #{value_name}: #{value_type} = #{value_expr};"))

      "FOR rtoc_key IN #{pipeline_source(receiver)}.keys() DO\n#{lowering.effect_code}\nEND"
    end

    def self.hash_map_value_stage(context)
      receiver = context.receiver_code
      node = context.node
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      key_type = transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' : "CAST(panic(\"missing hash key\") AS #{value_type})"
      value_expr = map_value_at(receiver, "_")

      lowering = lower_literal_block(
        node,
        node.block,
        transpiler,
        "hash.map",
        min_params: 2,
        max_params: 2,
        rename: lambda do |param_names|
          { param_names[0] => "_", param_names[1] => value_expr }
        end,
        local_types: lambda do |param_names|
          { param_names[0] => key_type, param_names[1] => value_type }
        end
      )
      return lowering if unsupported_result?(lowering)

      source = "#{pipeline_source(receiver)}.keys()"
      if (tuple_type = tuple_cast_result_type(lowering.value_code))
        imperative_tuple_map_code(source, lowering.value_code, tuple_type)
      else
        "#{source} |> SELECT #{lowering.value_code}"
      end
    end

    # Renders the code a transform_values/transform_keys block computes for
    # one hash entry, given the CLEAR expression (and its type) that stands
    # in for the block's single parameter - `value_expr` re-reading the
    # current value for transform_values, the bare `rtoc_key` loop variable
    # for transform_keys. Handles both a literal block AND Ruby's `&:method`
    # symbol-to-proc shorthand (several real corpus call sites use it -
    # `&:size`, `&:to_i`, `&:to_sym`, `&:definition_id` - unlike `.map`'s
    # array-oriented `block_value_expression`, whose `_` placeholder and
    # array-element type source don't apply to a hash value/key).
    def self.hash_transform_placeholder_code(node, transpiler, method_label, placeholder, placeholder_type)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        return unsupported(transpiler, node, "#{method_label} requires a literal block or symbol-to-proc") unless block_node.expression.is_a?(Prism::SymbolNode)

        method_name = block_node.expression.value.to_s
        return "#{placeholder}.toString()" if method_name == "to_s"
        return "#{placeholder}.trim()" if method_name == "strip"
        return "symbol(#{placeholder})" if method_name == "to_sym"
        if placeholder_type && (typed_call = transpiler.typed_instance_method_call(placeholder_type, method_name, placeholder))
          return typed_call
        end
        # A `&:field` symbol-to-proc reads a struct field, not a method:
        # emit bare field access, since `x.field()` reads as a method call.
        if placeholder_type && transpiler.struct_field_reader?(placeholder_type.to_s.delete_prefix("?"), method_name)
          return "#{placeholder}.#{method_name}"
        end

        return "#{placeholder}.#{method_name}()"
      end

      # The block keeps its own parameter name (no rename) - typed_ir's
      # block_parameter_types already types it correctly as a bare value/key
      # (commit 05fc2f1350), not a [key, value] Tuple, so a nested pipeline
      # over it (`bounds.map { ... }`, the real corpus shape) sees a real
      # list type. Declaring it as a genuine local (matching hash_each_
      # effect_stage's own convention) rather than inlining `placeholder` at
      # every reference keeps that distinction visible in the rendered code
      # instead of just working by coincidence for single-reference bodies.
      lowering = lower_literal_block(
        node,
        block_node,
        transpiler,
        method_label,
        min_params: 1,
        max_params: 1,
        rename: ->(_param_names) { {} },
        local_types: lambda do |param_names|
          placeholder_type ? { param_names[0] => placeholder_type } : {}
        end
      )
      return lowering if unsupported_result?(lowering)

      # value_lines already encodes the full body (preceding statements in
      # statement form, the last as a bare value - see BlockLowering#
      # value_code); effect_lines is a SEPARATE, parallel rendering of the
      # same statements for Void/statement-only callers (hash_each_effect_
      # stage) and must not also be spliced in here, or the final statement
      # renders twice.
      param_name = lowering.parameter_names[0]
      type_annotation = placeholder_type ? ": #{placeholder_type}" : ""
      setup_line = indent_block_line("MUTABLE #{param_name}#{type_annotation} = #{placeholder};")
      "{ MUTABLE rtoc_value_block_marker = 0;\n#{setup_line}\n#{lowering.value_lines.join("\n")}\n}"
    end

    # The block's own declared return type - `hash_map_value_stage`'s array
    # counterpart never needs this (an Array's element type isn't a
    # separately-declared slot to keep in sync; `.map`'s SELECT just adopts
    # whatever the block returns), but a HashMap literal's value type must
    # be declared explicitly at `{}` construction, and it is NOT necessarily
    # the source Hash's own value type (real corpus case:
    # `generic_bounds.transform_values { |bound| Type.new(bound) }` turns a
    # `T::Array[String]`-valued Hash into a `Type`-valued one).
    def self.hash_transform_result_type(node, transpiler, placeholder_type)
      block_node = node.block
      if block_node.is_a?(Prism::BlockArgumentNode) && block_node.expression.is_a?(Prism::SymbolNode)
        method_name = block_node.expression.value.to_s
        return "String" if %w[to_s strip].include?(method_name)
        return "String@symbol" if method_name == "to_sym"
        return nil unless placeholder_type

        result = transpiler.method_return_type_for(method_name, placeholder_type).to_s
        return nil if result.empty? || result == "Auto"

        return result
      end

      return nil unless block_node.is_a?(Prism::BlockNode)

      statements = block_node.body&.body
      return nil unless statements&.any?

      # Mirrors lower_literal_block's own local_types context (the block
      # keeps its own parameter name - see hash_transform_placeholder_code)
      # so a nested pipeline over that parameter (`bounds.map { ... }`, the
      # real corpus shape) infers its result type against the parameter's
      # REAL type, not whatever @local_types the outer call site happens to
      # have in scope.
      param_name = block_node.parameters&.parameters&.requireds&.first
      param_name = param_name.name.to_s if param_name.respond_to?(:name)
      if placeholder_type && param_name
        transpiler.with_local_types({ param_name => placeholder_type }) do
          transpiler.inferred_clear_type(statements.last)
        end
      else
        transpiler.inferred_clear_type(statements.last)
      end
    end

    def self.hash_transform_values_stage(context)
      receiver = context.receiver_code
      node = context.node
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      key_type = transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' : "CAST(panic(\"missing hash key\") AS #{value_type})"
      value_expr = map_value_at(receiver, "rtoc_key")

      new_value_code = hash_transform_placeholder_code(node, transpiler, "hash.transform_values", value_expr, value_type)
      return new_value_code if unsupported_result?(new_value_code)

      new_value_type = hash_transform_result_type(node, transpiler, value_type) || "Any"
      result = transpiler.next_generated_local("transform_values_result")
      # A FOR loop (like every other block-terminated statement in this
      # grammar) does not take a trailing `;` before the value block's next
      # statement - matching the exact "stray semicolon after a block-form
      # statement" bug class this branch has repeatedly hit elsewhere
      # (block_statement_output?, the ELSE_IF fix). A hand-built minimal
      # repro of this exact shape (compiled and run via `./clear run`)
      # caught this with a leading `;` after END and needed it removed;
      # this template had the same stray `;` left in and only the repro
      # got fixed - caught by the mandatory clean verifier diff.
      "( { MUTABLE #{result}: {#{key_type}}#{new_value_type} = {}; " \
        "FOR rtoc_key IN #{pipeline_source(receiver)}.keys() DO #{result}[rtoc_key] = #{new_value_code}; END " \
        "#{result} } )"
    end

    def self.hash_transform_keys_stage(context)
      receiver = context.receiver_code
      node = context.node
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      key_type = transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' : "CAST(panic(\"missing hash key\") AS #{value_type})"
      value_expr = map_value_at(receiver, "rtoc_key")

      new_key_code = hash_transform_placeholder_code(node, transpiler, "hash.transform_keys", "rtoc_key", key_type)
      return new_key_code if unsupported_result?(new_key_code)

      new_key_type = hash_transform_result_type(node, transpiler, key_type) || "Any"
      result = transpiler.next_generated_local("transform_keys_result")
      "( { MUTABLE #{result}: {#{new_key_type}}#{value_type} = {}; " \
        "FOR rtoc_key IN #{pipeline_source(receiver)}.keys() DO #{result}[#{new_key_code}] = #{value_expr}; END " \
        "#{result} } )"
    end

    def self.hash_select_keys_stage(context)
      select_node = context.node.receiver
      return nil unless select_node.is_a?(Prism::CallNode) &&
                        select_node.name.to_s == "select" && select_node.block &&
                        select_node.receiver

      transpiler = context.transpiler
      source_node = select_node.receiver
      source = transpiler.visit(source_node)
      receiver_type = transpiler.clear_type_for_receiver_node(source_node)
      key_type = transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' : "CAST(panic(\"missing hash key\") AS #{value_type})"
      value_expr = map_value_at(source, "_")

      lowering = lower_literal_block(
        select_node,
        select_node.block,
        transpiler,
        "hash.select.keys",
        min_params: 2,
        max_params: 2,
        rename: lambda do |param_names|
          { param_names[0] => "_", param_names[1] => value_expr }
        end,
        local_types: lambda do |param_names|
          { param_names[0] => key_type, param_names[1] => value_type }
        end
      )
      return lowering if unsupported_result?(lowering)

      "#{pipeline_source(source)}.keys() |> WHERE #{lowering.value_code}"
    end

    def self.each_with_index_effect_loop(receiver, node, transpiler, receiver_type: nil, element_type: nil, max_params: 2)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "each_with_index without a block is not supported")
      end

      index_name = "rtoc_idx"
      receiver_type ||= transpiler.clear_type_for_receiver_node(node.receiver)
      collection_type = receiver_type.to_s.delete_prefix("?")
      fixed_array = collection_type.match(/\A\[\d+\](.+)\z/)
      unless element_type
        element_type = if collection_type.end_with?("[]")
          collection_type.delete_suffix("[]")
        elsif fixed_array
          fixed_array[1]
        end
      end
      # The receiver is spliced in once per element read AND once per loop
      # test, so a non-trivial receiver (`TRY (keys(self.bindings))`) would be
      # re-evaluated - re-allocating, re-TRYing - every iteration. Bind it
      # once, the way reverse_each_effect_loop already does.
      items = receiver.to_s
      items_decl = nil
      unless items.match?(/\A[A-Za-z_@][\w.@]*\z/)
        items = transpiler.next_generated_local("each_items")
        items_decl = "MUTABLE #{items} = #{receiver};"
      end
      element_expr = if receiver_type.to_s == "String"
        "#{items}.substr(#{index_name}, 1)"
      elsif fixed_array
        # Fixed arrays have total indexing once the index type is valid; unlike
        # dynamic arrays, their indexed read does not add a bounds optional.
        "#{items}[#{index_name}]"
      elsif element_type && !["Any", "Auto"].include?(element_type.to_s)
        "#{items}[#{index_name}]?"
      else
        "#{items}[#{index_name}]"
      end
      lowering = lower_literal_block(
        node,
        block_node,
        transpiler,
        "each_with_index",
        min_params: 1,
        max_params: max_params,
        rename: lambda do |param_names|
          aliases = { param_names[0] => element_expr }
          aliases[param_names[1]] = index_name if param_names.length > 1
          aliases
        end,
        allow_next: true,
        allow_yield: true,
        allow_break: true,
        allow_return: true,
        local_types: lambda do |param_names|
          next {} unless element_type && param_names.first

          # The loop condition proves the index is in bounds. Unwrap that
          # bounds-optional at the alias boundary so Ruby `each` exposes T,
          # not ?T; a genuinely optional element remains ?T.
          { param_names.first => element_type }
        end
      )
      return lowering if unsupported_result?(lowering)

      effect_code = lowering.effect_code.gsub(
        "CONTINUE;",
        "#{index_name} = #{index_name} + 1;\nCONTINUE;"
      )
      body = indent_block_line(effect_code)
      [
        items_decl,
        "MUTABLE #{index_name} = 0;",
        "WHILE #{index_name} < #{items}.length() DO",
        body,
        "  #{index_name} = #{index_name} + 1;",
        "END"
      ].compact.join("\n")
    end

    def self.each_char_with_index_effect_loop(node, transpiler)
      each_char = node.receiver
      unless each_char.is_a?(Prism::CallNode) && each_char.name.to_s == "each_char" &&
             each_char.receiver && !each_char.block &&
             (!each_char.arguments || each_char.arguments.arguments.empty?)
        return unsupported(transpiler, node, "with_index is only supported after String#each_char")
      end

      receiver = transpiler.visit(each_char.receiver)
      each_with_index_effect_loop(receiver, node, transpiler, receiver_type: "String", element_type: "String")
    end

    def self.reverse_each_effect_loop(receiver, node, transpiler)
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      element_type = receiver_type.end_with?("[]") ? receiver_type.delete_suffix("[]") : nil
      return unsupported(transpiler, node, "reverse_each requires a statically typed array") unless element_type

      items_name = transpiler.next_generated_local("reverse_items")
      index_name = transpiler.next_generated_local("reverse_i")
      lowering = lower_literal_block(
        node,
        node.block,
        transpiler,
        "reverse_each",
        min_params: 1,
        max_params: 1,
        rename: lambda { |param_names|
          indexed = "#{items_name}[#{index_name}]"
          { param_names.first => transpiler.optional_unwrap_code(indexed) }
        },
        allow_next: true,
        allow_break: true,
        allow_return: true,
        local_types: ->(param_names) { { param_names.first => element_type } }
      )
      return lowering if unsupported_result?(lowering)

      step = "#{index_name} = #{index_name} - 1;"
      effect_code = lowering.effect_code.gsub("CONTINUE;", "#{step}\nCONTINUE;")
      [
        "MUTABLE #{items_name}: #{receiver_type} = #{receiver};",
        "MUTABLE #{index_name} = #{items_name}.length() - 1;",
        "WHILE #{index_name} >= 0 DO",
        indent_block_line(effect_code),
        "  #{step}",
        "END"
      ].join("\n")
    end

    def self.mutable_receiver?(receiver)
      receiver.match?(/\A[a-z_]\w*\z/)
    end

    def self.static_ruby_type_for_shape(shape)
      case shape.to_s
      when "array" then "Array"
      when "hash" then "Hash"
      when "string" then "String"
      when "symbol" then "Symbol"
      when "nil" then "NilClass"
      when "bool" then "Boolean"
      when "numeric" then "Numeric"
      end
    end

    SHAPE_METHODS = {
      "array" => %w[any? all? collect each empty? filter filter_map find flat_map include? join length map map! one? reduce reject reverse reverse_each select size sort_by sum],
      "hash" => %w[any? each each_key each_pair each_value empty? include? key? keys length size values],
      "string" => %w[bytesize delete_prefix empty? end_with? force_encoding include? index length lines rstrip size split start_with? strip valid_encoding?]
    }.freeze

    def self.array_element_type_for_receiver(node, transpiler)
      return nil unless node.receiver

      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      text = receiver_type.to_s.delete_prefix("?")
      return text.delete_suffix("[]") if text.end_with?("[]")

      # A constant's inferred type (unlike a declared parameter type) is
      # stored in CLEAR's own emitted array syntax - size marker FIRST, not
      # last (`[]TypoRule`, or `[1]TypoRule` for a literal CLEAR infers a
      # known fixed length for) - real corpus: syntax_typo_scanner.rb's
      # `RULES.each do |r| pat = r.match ... end`, where RULES is a `T.let(
      # [...].freeze, T::Array[TypoRule])` module constant. Without this,
      # the block param `r` got no element type at all, so `r.match`
      # couldn't resolve as a struct field read and fell through to the
      # generic String#match registry entry ("match expects 1 argument").
      prefix = text[/\A\[\d*\]/]
      prefix ? text.delete_prefix(prefix) : nil
    end

    def self.block_value_lowering(node, transpiler, method_label, min_params: 0, max_params: 2)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      element_type = array_element_type_for_receiver(node, transpiler)
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
      map_key_type = transpiler.map_key_clear_type(receiver_type)
      map_value_type = transpiler.map_value_clear_type(receiver_type)
      lower_literal_block(
        node,
        block_node,
        transpiler,
        method_label,
        min_params: min_params,
        max_params: max_params,
        allow_next: true,
        rename: lambda do |param_names|
          pipeline_block_aliases(param_names)
        end,
        local_types: lambda do |param_names|
          if map_key_type && map_value_type && param_names.length >= 2
            { param_names[0] => map_key_type, param_names[1] => map_value_type }
          elsif element_type && param_names.first
            { param_names.first => element_type }
          else
            {}
          end
        end
      )
    end

    def self.block_value_expression(receiver, node, transpiler, method_label)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        method_name = block_node.expression.value.to_s
        element_type = array_element_type_for_receiver(node, transpiler).to_s
        if element_type.start_with?("Tuple<") && element_type.end_with?(">")
          tuple_members = transpiler.split_top_level_clear_list(
            element_type.delete_prefix("Tuple<").delete_suffix(">")
          )
          return "_._0" if method_name == "first" && tuple_members.any?
          return "_._#{tuple_members.length - 1}" if method_name == "last" && tuple_members.any?
        end
        return "_.toString()" if method_name == "to_s"
        return "_.trim()" if method_name == "strip"
        return "symbol(_)" if method_name == "to_sym"
        if !element_type.empty? &&
           (typed_call = transpiler.typed_instance_method_call(element_type, method_name, "_"))
          return typed_call
        end
        # A `&:field` symbol-to-proc reads a struct field, not a method: emit
        # bare field access, since `_.field()` reads as a method call.
        if !element_type.empty? && transpiler.struct_field_reader?(element_type.delete_prefix("?"), method_name)
          return "_.#{method_name}"
        end

        return "_.#{method_name}()"
      end

      lowering = block_value_lowering(node, transpiler, method_label)
      return lowering if unsupported_result?(lowering)

      materialize_mutable_block_value_parameter(lowering.value_code, "_", transpiler)
    end

    def self.block_effect_lowering(node, transpiler, method_label, min_params: 0, max_params: 2)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      element_type = array_element_type_for_receiver(node, transpiler)
      lower_literal_block(
        node,
        block_node,
        transpiler,
        method_label,
        min_params: min_params,
        max_params: max_params,
        rename: lambda do |param_names|
          pipeline_block_aliases(param_names)
        end,
        allow_next: true,
        allow_yield: true,
        allow_break: true,
        local_types: lambda do |param_names|
          element_type && param_names.first ? { param_names.first => element_type } : {}
        end
      )
    end

    def self.reduce_block_lowering(node, transpiler)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "reduce without a block is not supported")
      end

      lower_literal_block(
        node,
        block_node,
        transpiler,
        "reduce",
        min_params: 2,
        max_params: 2,
        rename: lambda do |param_names|
          { param_names[0] => "acc", param_names[1] => "_" }
        end
      )
    end

    def self.block_expression(receiver, node, transpiler, method_label)
      block_value_expression(receiver, node, transpiler, method_label)
    end

    # --- Registrations ---

    register("read", receiver: "File") do |context|
      fs_call(context, "read", min: 1, max: 1, fallible: true)
    end

    register("readlines", receiver: "File") do |context|
      fs_call(context, "readLines", min: 1, max: 1, fallible: true)
    end

    register("foreach", receiver: "File") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "File.foreach expects 1 argument")
      end

      context.transpiler.require_package("fs")
      context.transpiler.mark_current_function_fallible!
      lines = "TRY (readLines(#{args.first}))"
      block_node = context.node.block
      next lines unless block_node

      unless block_node.is_a?(Prism::BlockNode)
        next unsupported(context.transpiler, context.node, "File.foreach block must be a literal block")
      end

      pipeline_effect_stage(lines, lines, context.node, context.transpiler, "File.foreach")
    end

    register("write", receiver: "File") do |context|
      fs_call(context, "write", min: 2, max: 2, fallible: true)
    end

    register("binwrite", receiver: "File") do |context|
      fs_call(context, "write", min: 2, max: 2, fallible: true)
    end

    register("size", receiver: "File") do |context|
      fs_call(context, "size", min: 1, max: 1, fallible: true)
    end

    register("exist?", receiver: "File") do |context|
      fs_call(context, "exists?", min: 1, max: 1)
    end

    register("exists?", receiver: "File") do |context|
      fs_call(context, "exists?", min: 1, max: 1)
    end

    register("file?", receiver: "File") do |context|
      fs_call(context, "file?", min: 1, max: 1)
    end

    register("directory?", receiver: "File") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("delete", receiver: "File") do |context|
      fs_call(context, "delete", min: 1, max: 1, fallible: true)
    end

    register("mtime", receiver: "File") do |context|
      fs_call(context, "mtime", min: 1, max: 1, fallible: true)
    end

    register("readlink", receiver: "File") do |context|
      fs_call(context, "readLink", min: 1, max: 1, fallible: true)
    end

    register("symlink", receiver: "File") do |context|
      fs_call(context, "symlink", min: 2, max: 2, fallible: true)
    end

    register("symlink?", receiver: "File") do |context|
      fs_call(context, "symlink?", min: 1, max: 1)
    end

    register("join", receiver: "File") do |context|
      path_call(context, "join", min: 1, max: 64)
    end

    register("expand_path", receiver: "File") do |context|
      path_call(context, "expand", min: 1, max: 2)
    end

    register("basename", receiver: "File") do |context|
      path_call(context, "basename", min: 1, max: 2)
    end

    register("dirname", receiver: "File") do |context|
      path_call(context, "dirname", min: 1, max: 1)
    end

    register("glob", receiver: "Dir") do |context|
      fs_call(context, "glob", min: 1, max: 1, fallible: true)
    end

    register("exist?", receiver: "Dir") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("exists?", receiver: "Dir") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("children", receiver: "Dir") do |context|
      fs_call(context, "list", min: 1, max: 1, fallible: true)
    end

    register("entries", receiver: "Dir") do |context|
      fs_call(context, "listAll", min: 1, max: 1, fallible: true)
    end

    register("pwd", receiver: "Dir") do |context|
      fs_call(context, "pwd", min: 0, max: 0, fallible: true)
    end

    register("parse", receiver: "JSON") do |context|
      static_call(context, "parseJson", min: 1, max: 1)
    end

    register("generate", receiver: "JSON") do |context|
      static_call(context, "generateJson", min: 1, max: 1)
    end

    register("pretty_generate", receiver: "JSON") do |context|
      static_call(context, "prettyGenerateJson", min: 1, max: 1)
    end

    register("escape", receiver: "Regexp") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "Regexp.escape expects 1 argument")
      end
      context.transpiler.regex_escape_code(args.first)
    end

    register("last_match", receiver: "Regexp") do |context|
      context.transpiler.regex_last_match_code(context.node) ||
        unsupported(context.transpiler, context.node, "Regexp.last_match depends on Ruby's implicit regexp match state; use an explicit match result")
    end

    register("new", receiver: "Regexp") do |context|
      unsupported(context.transpiler, context.node, "Regexp.new is not supported; use explicit scanner or parser logic")
    end

    register("new", receiver: "StringScanner") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "StringScanner.new expects 1 argument")
      end
      context.transpiler.helper_config.call(:scanner_new, args) || "Scanner{ source: #{args.first}, pos: 0 }"
    end

    register("new", receiver: "Set") do |context|
      args = arguments(context)
      if args.empty?
        if context.node.block
          next unsupported(context.transpiler, context.node, "Set.new with a block requires a source enumerable")
        end
        next "Set[]"
      end

      unless args.length == 1
        next unsupported(context.transpiler, context.node, "Set.new expects 0 or 1 arguments")
      end

      source = args.first
      source_node = argument_nodes(context).first
      source_type = context.transpiler.inferred_clear_type_for_node(source_node).to_s
      expected_type = context.transpiler.expected_expression_type.to_s
      if ["", "Any", "Auto"].include?(source_type) && expected_type.end_with?("@set")
        list_type = expected_type.delete_suffix("@set")
        source = "CAST(#{source} AS #{list_type})"
      end
      if context.node.block
        projection = block_expression(source, context.node, context.transpiler, "Set.new")
        if source.match?(/\A[A-Za-z_]\w*\z/)
          "#{source} |> SELECT #{projection} |> DISTINCT _"
        else
          "( { MUTABLE rtoc_pipe_src = #{source}; rtoc_pipe_src |> SELECT #{projection} |> DISTINCT _ } )"
        end
      else
        if source.match?(/\A[A-Za-z_]\w*\z/)
          "#{source} |> DISTINCT _"
        else
          "( { MUTABLE rtoc_pipe_src = #{source}; rtoc_pipe_src |> DISTINCT _ } )"
        end
      end
    end

    register("from_function_signature", receiver: "Type") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "Type.from_function_signature expects 1 argument")
      end

      context.transpiler.function_signature_type_code("CAST(#{args.first} AS FunctionSignature)")
    end

    register("[]", receiver: "Set") do |context|
      args = arguments(context)
      args.empty? ? "Set[]" : "[#{args.join(', ')}] |> DISTINCT _"
    end

    register("length", receiver: "array") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.length()"
    end
    register("size", receiver: "array") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.length()"
    end
    register("empty?", receiver: "array") do |context|
      "(#{method_receiver(context.transpiler, context.receiver_code)}.length() == 0)"
    end
    register("delete_at", receiver: "array") do |context|
      args = arguments(context)
      next unsupported(context.transpiler, context.node, "Array#delete_at expects 1 argument") unless args.length == 1

      "#{context.transpiler.mutable_method_receiver_code(context.receiver_code)}.remove(#{args.first})"
    end

    # Ruby String#length/#size count CHARACTERS; CLEAR's length() counts
    # bytes. codepointCount is the semantic match (bytesize covers the
    # byte-oriented uses).
    register("length", receiver: "string") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.codepointCount()"
    end
    register("size", receiver: "string") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.codepointCount()"
    end
    register("empty?", receiver: "string") do |context|
      "(#{method_receiver(context.transpiler, context.receiver_code)}.length() == 0)"
    end

    # Ruby's bytesize is the semantic match for CLEAR's explicit byte-count
    # operation. Do not map it to codepointCount: compiler offsets, protocol
    # lengths, and source budgets are byte-oriented even for UTF-8 strings.
    register("bytesize", receiver: "string") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.bytes()"
    end

    # Ruby can attach an encoding tag to an arbitrary byte string. CLEAR has no
    # mutable encoding tag: ordinary strings are UTF-8, while untrusted bytes
    # are validated explicitly at their boundary. Preserve the copy performed
    # by `dup.force_encoding(Encoding::UTF_8)`, but erase only the UTF-8 retag.
    register("force_encoding") do |context|
      args = argument_nodes(context)
      unless args.length == 1 && args.first.location.slice.delete_prefix("::") == "Encoding::UTF_8"
        next unsupported(
          context.transpiler,
          context.node,
          "force_encoding is only translatable for Encoding::UTF_8; CLEAR strings do not carry mutable encoding tags"
        )
      end

      context.receiver_code
    end

    register("valid_encoding?") do |context|
      args = argument_nodes(context)
      unless args.empty?
        next unsupported(context.transpiler, context.node, "valid_encoding? expects no arguments")
      end

      "#{method_receiver(context.transpiler, context.receiver_code)}.validUtf8?()"
    end

    register("length", receiver: "hash") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.count()"
    end

    register("size", receiver: "hash") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.count()"
    end

    register("empty?", receiver: "hash") do |context|
      "(#{method_receiver(context.transpiler, context.receiver_code)}.count() == 0)"
    end

    register("split", receiver: "string") do |context|
      args = arguments(context)
      separator = args.first || "\"\\n\""
      "#{method_receiver(context.transpiler, context.receiver_code)}.split(#{separator})"
    end

    register("delete_prefix", receiver: "string") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "delete_prefix expects 1 argument")
      end

      "#{context.receiver_code}.deletePrefix(#{args.first})"
    end

    register("tr", receiver: "string") do |context|
      args = context.node.arguments ? context.node.arguments.arguments : []
      unless args.length == 2 && args.all?(Prism::StringNode)
        next unsupported(context.transpiler, context.node, "String#tr requires two literal character sets")
      end

      source = args[0].content
      replacement = args[1].content
      unless source.length == 1 && replacement.empty?
        next unsupported(context.transpiler, context.node, "String#tr currently supports deleting one literal character")
      end

      "#{method_receiver(context.transpiler, context.receiver_code)}.replace(#{source.inspect}, \"\")"
    end

    register("to_f", receiver: "string") do |context|
      "(#{method_receiver(context.transpiler, context.receiver_code)}.toFloat() OR_ELSE 0.0)"
    end

    register("to_f", receiver: "numeric") do |context|
      "#{method_receiver(context.transpiler, context.receiver_code)}.toFloat()"
    end

    register("count", receiver: "string") do |context|
      args = context.node.arguments ? context.node.arguments.arguments : []
      next unsupported(context.transpiler, context.node, "String#count requires one argument") unless args.length == 1
      next nil unless context.transpiler.helper_config.helper?(:string_count)

      context.transpiler.helper_config.call(
        :string_count,
        [context.receiver_code, context.transpiler.visit(args.first)]
      )
    end

    register("rindex", receiver: "string") do |context|
      args = context.node.arguments ? context.node.arguments.arguments : []
      next unsupported(context.transpiler, context.node, "String#rindex requires one argument") unless args.length == 1
      next nil unless context.transpiler.helper_config.helper?(:string_rindex)

      context.transpiler.helper_config.call(
        :string_rindex,
        [context.receiver_code, context.transpiler.visit(args.first)]
      )
    end

    register("nil?") do |context|
      type = context.transpiler.clear_type_for_receiver_node(context.node.receiver).to_s
      if !type.empty? && type != "Any" && type != "Auto" && !type.start_with?("?")
        "FALSE"
      else
        "(#{context.receiver_code} == NIL)"
      end
    end

    register("inspect") do |context|
      context.transpiler.helper_config.call_or(:inspect_value, "compilerInspectValue", [])
    end

    register("class", receiver: "self") do |context|
      class_name = context.transpiler.current_class_name
      class_name ? class_name.inspect : unsupported(context.transpiler, context.node, "self.class requires a known enclosing class")
    end

    register("is_a?") do |context|
      expected = static_first_argument_name(context)
      unless expected
        next context.transpiler.unsupported_expression(context.node, "is_a? requires a static type argument")
      end

      receiver = context.receiver_code
      actual = static_ruby_type_for_shape(context.receiver_shape)
      type_param = context.transpiler.current_type_param_for_receiver(context.receiver_name)
      next "#{type_param} IS_A #{context.transpiler.clear_type_expr(expected)}" if type_param

      expected_clear = context.transpiler.clear_type_expr(expected)
      receiver_type = context.transpiler.static_clear_type_for_receiver(context.receiver_name)
      receiver_type ||= context.transpiler.inferred_clear_type_for_node(context.node.receiver)
      expected_clear = context.transpiler.runtime_is_a_expected_type(receiver_type, expected_clear) if receiver_type

      strip_cap = ->(t) {
        return t.to_s if t.to_s.end_with?("@symbol")
        depth = 0
        t.to_s.each_char.with_index do |char, index|
          depth += 1 if "<[(".include?(char)
          depth -= 1 if ">])".include?(char)
          return t[0...index] if char == "@" && depth.zero?
        end
        t.to_s
      }

      receiver_base = receiver_type ? strip_cap.call(receiver_type.to_s.delete_prefix("?")) : nil
      expected_base = strip_cap.call(expected_clear.delete_prefix("?"))

      statically_matches = receiver_base && (
        receiver_base == expected_base ||
          (expected_base == "Any[]" && receiver_base.end_with?("[]")) ||
          (expected_base == "[Set]Any" &&
            (receiver_base.start_with?("[Set]") ||
              receiver_base.end_with?("[SET]") ||
              receiver_base.include?("[]@set")))
      )
      if receiver_type && receiver_type != "Auto" && statically_matches
        if receiver_type.to_s.start_with?("?")
          next "(#{receiver} != NIL)"
        else
          next "TRUE"
        end
      end

      if receiver_type && context.transpiler.runtime_union_narrowing_candidate?(receiver_type, expected_clear)
        if receiver_type.to_s.start_with?("?")
          # AND-narrowing types the receiver as the payload after the nil
          # guard; a redundant `?` unwrap is rejected there.
          next "((#{receiver} != NIL) AND (#{receiver} IS_A #{expected_clear}))"
        end
        next "#{receiver} IS_A #{expected_clear}"
      end

      next "TRUE" if actual && actual == expected
      next "FALSE" if actual && actual != expected

      if receiver_type && receiver_type.to_s.start_with?("?")
        "((#{receiver} != NIL) AND (#{receiver} IS_A #{expected_clear}))"
      else
        "#{receiver} IS_A #{expected_clear}"
      end
    end

    register("respond_to?") do |context|
      method_name = static_first_argument_name(context)
      unless method_name
        next context.transpiler.unsupported_expression(context.node, "respond_to? requires a static method name")
      end

      receiver = context.receiver_code
      methods = SHAPE_METHODS[context.receiver_shape.to_s]
      next(methods.include?(method_name) ? "TRUE" : "FALSE") if methods

      static_result = context.transpiler.static_respond_to_result(receiver, method_name, context.node.receiver)
      next(static_result ? "TRUE" : "FALSE") unless static_result.nil?

      "respondsTo?(#{receiver}, #{method_name.inspect})"
    end

    register("strip") do |receiver, _node, _transpiler|
      "#{method_receiver(_transpiler, receiver)}.trim()"
    end

    register("compact") do |context|
      args = arguments(context)
      next nil unless args.empty?

      receiver_node = context.node.receiver
      if receiver_node.is_a?(Prism::ArrayNode) && receiver_node.elements.none? { |element| element.is_a?(Prism::NilNode) }
        context.receiver_code
      else
        "#{pipeline_source(context.receiver_code)} |> WHERE _ != NIL"
      end
    end

    register("last") do |context|
      args = arguments(context)
      next nil unless args.empty?

      receiver_type = context.transpiler.inferred_clear_type_for_node(context.node.receiver).to_s
      next nil unless receiver_type.start_with?("Tuple<") && receiver_type.end_with?(">")

      members = context.transpiler.split_top_level_clear_list(
        receiver_type.delete_prefix("Tuple<").delete_suffix(">")
      )
      next nil if members.empty?

      "#{context.receiver_code}._#{members.length - 1}"
    end

    register("rstrip") do |receiver, _node, transpiler|
      pattern = transpiler.regex_literal_code('"\\\\s+\\\\z"')
      transpiler.regex_replace_all_code(receiver, pattern, '""')
    end

    register("dup") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.empty?
        next unsupported(transpiler, node, "dup expects no arguments")
      end

      transpiler.send(:explicit_dup_code, receiver, node.receiver)
    end

    register("to_i") do |context|
      args = argument_nodes(context)
      unless args.length <= 1
        next unsupported(context.transpiler, context.node, "to_i expects 0 or 1 arguments")
      end

      if args.empty?
        context.transpiler.integer_conversion_code(context.node.receiver, context.receiver_code)
      else
        base = context.transpiler.visit(args.first)
        helper = context.transpiler.helper_config.call(:string_to_int_base, [context.receiver_code, base])
        if helper
          context.transpiler.propagate_fallible_expression(helper)
        else
          context.transpiler.propagate_fallible_expression(
            "#{method_receiver(context.transpiler, context.receiver_code)}.toInt(#{base})"
          )
        end
      end
    end

    register("compiler_zig_translate_c") do |context|
      args = arguments(context)
      unless args.length == 3
        next unsupported(context.transpiler, context.node, "compiler_zig_translate_c expects 3 arguments")
      end

      helper = context.transpiler.helper_config.call(:zig_translate_c, args)
      next nil unless helper

      context.transpiler.propagate_fallible_expression(helper)
    end

    register("bit_length", receiver: "numeric") do |context|
      args = argument_nodes(context)
      unless args.empty?
        next unsupported(context.transpiler, context.node, "bit_length expects no arguments")
      end

      "#{method_receiver(context.transpiler, context.receiver_code)}.bitLength()"
    end

    register("to_s") do |context|
      args = argument_nodes(context)
      unless args.empty?
        next unsupported(context.transpiler, context.node, "to_s expects no arguments")
      end

      receiver_type = context.transpiler.static_clear_type_for_receiver(context.receiver_name) ||
                      context.transpiler.clear_type_for_receiver_node(context.node.receiver)
      optional_receiver = receiver_type.to_s.start_with?("?")
      receiver_type = receiver_type.to_s.delete_prefix("?") if receiver_type
      next "CAST(#{context.receiver_code} AS String)" if receiver_type == "String@symbol"
      next "(#{context.receiver_code} OR_ELSE \"\")" if optional_receiver && receiver_type&.start_with?("String")
      next context.receiver_code if receiver_type&.start_with?("String")
      next "#{method_receiver(context.transpiler, context.receiver_code)}.toString()" if %w[Int64 Float64].include?(receiver_type)
      next "CAST(#{context.receiver_code} AS String)" if context.receiver_shape.to_s == "symbol"
      next context.receiver_code if context.receiver_shape.to_s == "string"
      next "CAST(#{context.receiver_code} AS String)" if context.receiver_kind.to_s == "symbol_literal"
      next context.receiver_code if %w[string_literal symbol_literal].include?(context.receiver_kind.to_s)
      next "CAST(#{context.receiver_code} AS String)"

      nil
    end

    register("to_sym") do |context|
      args = argument_nodes(context)
      unless args.empty?
        next unsupported(context.transpiler, context.node, "to_sym expects no arguments")
      end

      receiver_type = context.transpiler.static_clear_type_for_receiver(context.receiver_name) ||
                      context.transpiler.clear_type_for_receiver_node(context.node.receiver)
      receiver_type = receiver_type.to_s.delete_prefix("?") if receiver_type
      next "symbol(#{context.receiver_code})" if receiver_type&.start_with?("String")
      next "symbol(#{context.receiver_code})" if %w[string symbol].include?(context.receiver_shape.to_s)
      next "symbol(#{context.receiver_code})" if %w[string_literal symbol_literal].include?(context.receiver_kind.to_s)
      next "symbol(#{context.receiver_code})" if context.node.receiver.is_a?(Prism::CallNode) && context.node.receiver.name.to_s == "to_s"

      nil
    end

    register("chr") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |arg| transpiler.visit(arg) } : []
      unless args.length <= 1
        next unsupported(transpiler, node, "chr expects 0 or 1 arguments")
      end

      transpiler.helper_config.call(:codepoint_to_string, [receiver]) || "codepointToString(#{receiver})"
    end

    register("match?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.length == 1
        next unsupported(transpiler, node, "match? expects 1 argument")
      end

      pattern = transpiler.visit(args.first)
      if regex_node?(args.first)
        transpiler.regex_match_code(receiver, pattern)
      else
        "#{method_receiver(transpiler, receiver)}.match?(#{pattern})"
      end
    end

    register("match") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      # A zero-arg `.match` is never a valid String#match/Regexp#match call
      # (both require the pattern) - it can only be a same-named struct
      # field read this generic entry shadowed (real corpus: ast/syntax_
      # typo_scanner.rb's `TypoRule#match` field, read via `r.match` inside
      # a RULES.each block). Decline instead of erroring so the field-read
      # fallback in call_lowerer.rb gets a chance; keep erroring for any
      # other wrong arg count, which is unambiguously a real mis-call.
      next nil if args.empty?
      unless args.length == 1
        next unsupported(transpiler, node, "match expects 1 argument")
      end
      next nil unless transpiler.helper_config.helper?(:regex_match_data)

      if regex_node?(args.first)
        # `str.match(re)` — string receiver, regex argument.
        transpiler.regex_match_data_code(receiver, transpiler.visit(args.first))
      elsif regex_node?(node.receiver) || transpiler.regex_pattern_expression?(node.receiver)
        # `re.match(str)` — regex receiver, string argument.
        transpiler.regex_match_data_code(transpiler.visit(args.first), receiver)
      else
        nil
      end
    end

    register("scan") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next nil unless args.length == 1 && regex_node?(args.first)
      next transpiler.regex_scan_block_code(node, args.first) if node.block

      helper = transpiler.scanner_scan_value_node?(node) ? :scanner_scan_value : :scanner_scan
      next nil unless transpiler.helper_config.helper?(helper)

      pattern = transpiler.visit(args.first)
      transpiler.helper_config.call(helper, [receiver, pattern])
    end

    register("matched") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next nil unless args.empty?

      transpiler.helper_config.call(:scanner_matched, [receiver])
    end

    register("peek") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |arg| transpiler.visit(arg) } : []
      next nil unless transpiler.helper_config.helper?(:scanner_peek)

      transpiler.helper_config.call(:scanner_peek, [receiver, *args])
    end

    register("getch") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |arg| transpiler.visit(arg) } : []
      next nil unless args.empty? && transpiler.helper_config.helper?(:scanner_getch)

      transpiler.helper_config.call(:scanner_getch, [receiver])
    end

    register("eos?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next nil unless args.empty? && transpiler.helper_config.helper?(:scanner_eos)

      transpiler.helper_config.call(:scanner_eos, [receiver])
    end

    register("pos") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next nil unless args.empty? && transpiler.helper_config.helper?(:scanner_pos)

      scanner_receiver = transpiler.helper_config.scanner_receiver?(receiver) ||
                         transpiler.registry_receiver_shape(node.receiver) == "scanner"
      next nil unless scanner_receiver

      transpiler.helper_config.call(:scanner_pos, [receiver])
    end

    register("[]") do |context|
      next nil unless context.transpiler.helper_config.helper?(:scanner_capture)
      scanner_receiver = context.transpiler.helper_config.scanner_receiver?(context.receiver_code) ||
                         context.receiver_shape == "scanner"
      next nil unless scanner_receiver

      args = arguments(context)
      next nil unless args.length == 1

      receiver_code = context.receiver_code
      receiver_type = context.receiver_name && context.transpiler.static_clear_type_for_receiver(context.receiver_name)
      receiver_code = "#{receiver_code}?" if receiver_type.to_s.start_with?("?") && !receiver_code.to_s.end_with?("?")
      context.transpiler.helper_config.call(:scanner_capture, [receiver_code, args.first])
    end

    register("start_with?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      target = method_receiver(transpiler, receiver)
      checks = args.map { |arg| "#{target}.startsWith?(#{arg})" }
      checks.length == 1 ? checks.first : "(#{checks.join(' OR ')})"
    end

    register("end_with?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      target = method_receiver(transpiler, receiver)
      checks = args.map { |arg| "#{target}.endsWith?(#{arg})" }
      checks.length == 1 ? checks.first : "(#{checks.join(' OR ')})"
    end

    register("delete_prefix") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      next unsupported(transpiler, node, "delete_prefix expects 1 argument") unless args.length == 1

      transpiler.string_delete_affix_code(:prefix, method_receiver(transpiler, receiver), args.first)
    end

    register("delete_suffix") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      next unsupported(transpiler, node, "delete_suffix expects 1 argument") unless args.length == 1

      transpiler.string_delete_affix_code(:suffix, method_receiver(transpiler, receiver), args.first)
    end

    register("index") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{method_receiver(transpiler, receiver)}.indexOf(#{args.join(', ')})"
    end

    register("lines") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      separator = args.first || "\"\\n\""
      "#{method_receiver(transpiler, receiver)}.split(#{separator})"
    end

    register("join") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      separator = args.first || "\"\""
      "#{method_receiver(transpiler, receiver)}.join(#{separator})"
    end

    register("drop") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.length == 1
        next unsupported(transpiler, node, "drop expects 1 argument")
      end

      "#{pipeline_source(receiver)} |> SKIP #{transpiler.visit(args.first)}"
    end

    register("take") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.length == 1
        next unsupported(transpiler, node, "take expects 1 argument")
      end

      "#{pipeline_source(receiver)} |> LIMIT #{transpiler.visit(args.first)}"
    end

    register("map", receiver: "hash") do |context|
      hash_map_value_stage(context)
    end

    register("transform_values", receiver: "hash") do |context|
      hash_transform_values_stage(context)
    end

    # Unlike each_pair's own generic fallback (which hard-errors when the
    # receiver type isn't statically known), decline (nil) rather than
    # raise here: a real corpus call site
    # (protocol_projection_resolver.rb's `issue` method) calls
    # `values.transform_values(&:to_s)` where `values:` is a `**values`
    # keyword-splat parameter - genuinely T.untyped, with no way to
    # statically resolve it as a Hash even though it obviously is one at
    # runtime. Before this file registered transform_values at all, that
    # call fell through to a generic passthrough that happened to produce
    # syntactically valid (if not really meaningful) CLEAR text and passed
    # G1; hard-erroring here regressed G1 on that one file, which cascaded
    # to 101 more files that depend on it - declining preserves the
    # original, more permissive behavior for this specific unresolvable-
    # type case while still handling every statically-resolvable call
    # through the branch above.
    register("transform_values") do |context|
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(context.node.receiver)
      next nil unless receiver_type && transpiler.map_value_clear_type(receiver_type)

      hash_transform_values_stage(context)
    end

    register("transform_keys", receiver: "hash") do |context|
      hash_transform_keys_stage(context)
    end

    register("transform_keys") do |context|
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(context.node.receiver)
      next nil unless receiver_type && transpiler.map_value_clear_type(receiver_type)

      hash_transform_keys_stage(context)
    end

    register("keys", receiver: "hash") do |context|
      selected_keys = hash_select_keys_stage(context)
      next selected_keys if selected_keys

      "#{method_receiver(context.transpiler, context.receiver_code)}.keys()"
    end

    register("map") do |context|
      next nil unless context.node.block || context.receiver_shape == "array"

      pipeline_value_stage(context.receiver_code, "SELECT", context.node, context.transpiler, "map")
    end

    register("map!") do |receiver, node, transpiler|
      field_node = node.receiver
      typed_field_receiver = field_node.is_a?(Prism::CallNode) && field_node.receiver &&
        (!field_node.arguments || field_node.arguments.arguments.empty?)
      field_receiver = receiver.to_s.match?(/\A[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*\z/) ||
        (receiver.to_s.end_with?("?") && receiver.to_s.include?(".")) || typed_field_receiver
      unless mutable_receiver?(receiver) || field_receiver
        next unsupported(transpiler, node, "map! is only supported on a mutable local receiver")
      end

      block_body = block_expression(receiver, node, transpiler, "map!")
      next block_body if unsupported_result?(block_body)

      assignment_receiver = if typed_field_receiver
        "#{transpiler.visit(field_node.receiver)}.#{field_node.name}"
      else
        receiver
      end
      "#{assignment_receiver} = #{pipeline_source(receiver)} |> SELECT #{block_body}"
    end

    register("collect") do |context|
      translate(
        "map",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("select") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "WHERE", node, transpiler, "select")
    end

    register("filter") do |context|
      translate(
        "select",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("reject") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "reject")
      next block_body if unsupported_result?(block_body)

      "#{pipeline_source(receiver)} |> WHERE !(#{block_body})"
    end

    register("any?") do |context|
      if context.node.block
        context.transpiler.closed_static_type_any_predicate(context.node) ||
          pipeline_value_stage(context.receiver_code, "ANY", context.node, context.transpiler, "any?")
      elsif context.receiver_shape == "array"
        "#{pipeline_source(context.receiver_code)} |> ANY _"
      else
        nil
      end
    end

    register("all?") do |context|
      if context.node.block
        pipeline_value_stage(context.receiver_code, "ALL", context.node, context.transpiler, "all?")
      elsif context.receiver_shape == "array"
        "#{pipeline_source(context.receiver_code)} |> ALL _"
      else
        nil
      end
    end

    register("one?", receiver: "array") do |context|
      next nil if context.node.block

      "(#{context.receiver_code}.length() == 1)"
    end

    register("count") do |context|
      next nil unless context.node.block

      pipeline_value_stage(context.receiver_code, "COUNT", context.node, context.transpiler, "count")
    end

    register("find") do |receiver, node, transpiler|
      block = node.block
      statements = block.is_a?(Prism::BlockNode) ? (block.body&.body || []) : []
      requireds = block.is_a?(Prism::BlockNode) ? (block.parameters&.parameters&.requireds || []) : []
      predicate = statements.first
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s
      if block.is_a?(Prism::BlockNode) && statements.length == 1 && requireds.length == 1 &&
         requireds.first.respond_to?(:name) && predicate.is_a?(Prism::CallNode) &&
         predicate.name.to_s == "is_a?" && predicate.receiver.is_a?(Prism::LocalVariableReadNode) &&
         predicate.receiver.name.to_s == requireds.first.name.to_s && receiver_type.include?("Emittable[]")
        expected = predicate.arguments&.arguments&.first
        if expected.is_a?(Prism::ConstantReadNode) || expected.is_a?(Prism::ConstantPathNode)
          expected_type = transpiler.clear_type_expr(expected.location.slice)
          next "#{pipeline_source(receiver)} |> WHERE _ IS_A #{expected_type} |> SELECT (COPY CAST(_ AS #{expected_type})) |> FIND TRUE"
        end
      end

      pipeline_value_stage(receiver, "FIND", node, transpiler, "find")
    end

    register("detect") do |context|
      translate(
        "find",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("filter_map") do |receiver, node, transpiler|
      literal_block = node.block if node.block.is_a?(Prism::BlockNode)
      statements = literal_block&.body&.body || []
      assignment, conditional = statements
      requireds = literal_block&.parameters&.parameters&.requireds || []
      if statements.length == 2 && requireds.length == 1 && requireds.first.respond_to?(:name) &&
         assignment.is_a?(Prism::LocalVariableWriteNode) &&
         assignment.value.is_a?(Prism::CallNode) && assignment.value.name.to_s == "[]" &&
         conditional.is_a?(Prism::IfNode) && conditional.consequent &&
         conditional.predicate.is_a?(Prism::LocalVariableReadNode) &&
         conditional.predicate.name == assignment.name &&
         conditional.statements&.body&.length == 1 &&
         conditional.consequent.statements&.body == [conditional.consequent.statements.body.first] &&
         conditional.consequent.statements.body.first.is_a?(Prism::NilNode)
        param_name = requireds.first.name.to_s
        aliases = { param_name => "_" }
        lookup = transpiler.with_block_local_scope do
          transpiler.with_renames(aliases) { transpiler.visit(assignment.value) }
        end
        value = transpiler.with_block_local_scope do
          value_aliases = aliases.merge(assignment.name.to_s => transpiler.optional_unwrap_code(lookup))
          transpiler.with_renames(value_aliases) do
            transpiler.visit(conditional.statements.body.first)
          end
        end
        if (tuple_type = tuple_cast_result_type(value))
          next imperative_tuple_map_code(
            pipeline_source(receiver),
            value,
            tuple_type,
            predicate: "#{lookup} != NIL"
          )
        end
        next "#{pipeline_source(receiver)} |> WHERE #{lookup} != NIL |> SELECT #{value}"
      end

      block_body = block_expression(receiver, node, transpiler, "filter_map")
      next block_body if unsupported_result?(block_body)

      "#{pipeline_source(receiver)} |> SELECT:? #{block_body} |> WHERE _ != NIL"
    end

    register("flat_map") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "UNNEST", node, transpiler, "flat_map")
    end

    register("sort_by") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "ORDER_BY", node, transpiler, "sort_by")
    end

    register("sort") do |receiver, node, transpiler|
      if node.block
        next unsupported(transpiler, node, "sort with a custom comparator block is not supported; use sort_by")
      end

      "#{pipeline_source(receiver)} |> ORDER_BY _"
    end

    register("sum") do |receiver, node, transpiler|
      if node.block
        pipeline_value_stage(receiver, "SUM", node, transpiler, "sum")
      else
        "#{pipeline_source(receiver)} |> SUM _"
      end
    end

    register("reduce") do |context|
      args = argument_nodes(context)
      if args.empty? && !context.node.block && context.receiver_shape.nil?
        next nil
      end

      if !context.node.block && args.last.is_a?(Prism::SymbolNode) && %w[& |].include?(args.last.value.to_s)
        operator = args.last.value.to_s
        init_val = if args.length == 2
          context.transpiler.visit(args.first)
        elsif args.length == 1 && operator == "&"
          "#{pipeline_source(context.receiver_code)}[0]"
        end
        unless init_val
          next unsupported(context.transpiler, context.node, "reduce(#{args.last.value.inspect}) needs an explicit initial value")
        end
        reduction = if operator == "&"
          context.transpiler.generic_set_intersection_operator_code("acc", "_")
        else
          context.transpiler.generic_set_union_operator_code("acc", "_")
        end
        next "#{pipeline_source(context.receiver_code)} |> REDUCE(#{init_val}) (#{reduction})"
      end

      init_val = args.first ? context.transpiler.visit(args.first) : "0"
      lowering = reduce_block_lowering(context.node, context.transpiler)
      next lowering if unsupported_result?(lowering)

      "#{pipeline_source(context.receiver_code)} |> REDUCE(#{init_val}) #{lowering.value_code}"
    end

    register("inject") do |context|
      translate(
        "reduce",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("gsub") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2
        next nil
      end

      pattern = transpiler.visit(args[0])
      replacement = transpiler.visit(args[1])
      if regex_node?(args[0])
        transpiler.regex_replace_all_code(receiver, pattern, replacement)
      else
        "#{method_receiver(transpiler, receiver)}.replace(#{pattern}, #{replacement})"
      end
    end

    register("sub") do |context|
      args = argument_nodes(context)
      if context.node.block || args.length != 2
        next nil
      end

      receiver = context.transpiler.string_conversion_code(context.node.receiver, context.receiver_code)
      pattern = context.transpiler.visit(args[0])
      replacement = context.transpiler.visit(args[1])
      if regex_node?(args[0])
        context.transpiler.regex_replace_first_code(receiver, pattern, replacement)
      elsif args[0].is_a?(Prism::StringNode) && context.transpiler.helper_config.helper?(:regex_replace_first)
        escaped_pattern = context.transpiler.regex_literal_code(Regexp.escape(args[0].content).inspect)
        context.transpiler.regex_replace_first_code(receiver, escaped_pattern, replacement)
      else
        "replaceFirst(#{receiver}, #{pattern}, #{replacement})"
      end
    end

    register("include?") do |receiver, node, transpiler|
      arg_nodes = node.arguments ? node.arguments.arguments : []
      if arg_nodes.length == 1 && (predicate = transpiler.static_string_set_include_code(receiver, arg_nodes.first))
        next predicate
      end

      args = arg_nodes.map { |a| transpiler.visit(a) }
      "#{method_receiver(transpiler, receiver)}.contains?(#{args.join(', ')})"
    end

    register("key?") do |receiver, node, transpiler|
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      next nil unless receiver_type == "Any" || transpiler.map_key_clear_type(receiver_type)

      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{method_receiver(transpiler, receiver)}.contains?(#{args.join(', ')})"
    end

    register("has_key?") do |receiver, node, transpiler|
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      next nil unless receiver_type == "Any" || transpiler.map_key_clear_type(receiver_type)

      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{method_receiver(transpiler, receiver)}.contains?(#{args.join(', ')})"
    end

    register("dig") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |arg| transpiler.visit(arg) } : []
      next unsupported(transpiler, node, "dig expects at least one key") if args.empty? || node.block

      render = lambda do |subject, remaining|
        access = "#{method_receiver(transpiler, subject)}[#{remaining.first}]"
        next access if remaining.length == 1

        nested = render.call("(#{access})?", remaining.drop(1))
        "(IF #{access} != NIL THEN\n  #{nested}\nELSE\n  NIL\nEND)"
      end
      render.call(receiver, args)
    end

    register("to_set") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next unsupported(transpiler, node, "to_set expects no arguments") unless args.empty? && !node.block

      "#{pipeline_source(receiver)} |> DISTINCT _"
    end

    register("uniq") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      next unsupported(transpiler, node, "Array#uniq expects no arguments") unless args.empty?

      if node.block
        next pipeline_value_stage(receiver, "DISTINCT", node, transpiler, "uniq")
      end

      # CLEAR's DISTINCT terminal is set-shaped. Ruby Array#uniq preserves the
      # receiver's Array type, including element ownership capabilities.
      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s
      expected_type = transpiler.expected_expression_type.to_s
      if (!receiver_type.end_with?("]") || !receiver_type.include?("[")) && expected_type.end_with?("[]")
        receiver_type = expected_type
      end
      distinct = "#{pipeline_source(receiver)} |> DISTINCT _"
      if receiver_type.end_with?("]") && receiver_type.include?("[")
        "CAST((#{distinct}) AS #{receiver_type})"
      else
        "#{distinct} |> SELECT COPY _"
      end
    end

    register("to_a", receiver: "set") do |context|
      args = argument_nodes(context)
      next unsupported(context.transpiler, context.node, "Set#to_a expects no arguments") unless args.empty? && !context.node.block

      "#{pipeline_source(context.receiver_code)} |> SELECT COPY _"
    end

    register("add", receiver: "set") do |context|
      nodes = argument_nodes(context)
      next unsupported(context.transpiler, context.node, "Set#add expects one argument") unless nodes.length == 1 && !context.node.block

      value = context.transpiler.visit(nodes.first)
      value = "COPY #{value}" if context.transpiler.stored_borrowed_value?(nodes.first)
      "#{context.transpiler.mutable_method_receiver_code(context.receiver_code)}.insert(#{value})"
    end

    register("to_a", receiver: "hash") do |context|
      args = argument_nodes(context)
      next unsupported(context.transpiler, context.node, "Hash#to_a expects no arguments") unless args.empty? && !context.node.block

      receiver_type = context.transpiler.clear_type_for_receiver_node(context.node.receiver)
      key_type = context.transpiler.map_key_clear_type(receiver_type) || "Any"
      value_type = context.transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' : "CAST(panic(\"missing hash key\") AS #{value_type})"
      source = pipeline_source(context.receiver_code)
      tuple_type = "Tuple<#{key_type}, #{value_type}>"
      value = "CAST(Tuple{COPY _, #{map_value_at(source, '_')}} AS #{tuple_type})"
      imperative_tuple_map_code("#{source}.keys()", value, tuple_type)
    end

    register("merge", receiver: "hash") do |context|
      nodes = argument_nodes(context)
      next unsupported(context.transpiler, context.node, "Hash#merge expects one argument and no block") unless
        nodes.length == 1 && !context.node.block

      other = context.transpiler.visit(nodes.first)
      other_type = context.transpiler.inferred_clear_type_for_node(nodes.first)
      receiver_type = context.transpiler.clear_type_for_receiver_node(context.node.receiver)
      value_type = context.transpiler.map_value_clear_type(other_type) ||
        context.transpiler.map_value_clear_type(receiver_type) || "Any"
      fallback = value_type == "Any" ? 'panic("missing hash key")' :
        "CAST(panic(\"missing hash key\") AS #{value_type})"
      source = pipeline_source(context.receiver_code)
      right = pipeline_source(other)
      "#{right}.keys() |> REDUCE(COPY #{source}) { acc[_] = #{map_value_at(right, '_')}; acc }"
    end

    register("replace") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      receiver_type = transpiler.inferred_clear_type_for_node(node.receiver).to_s.delete_prefix("?")
      target = receiver_type == "String" ? method_receiver(transpiler, receiver) : transpiler.mutable_method_receiver_code(receiver)
      "#{target}.replace(#{args.join(', ')})"
    end

    register("each", receiver: "hash") do |context|
      hash_each_effect_stage(context)
    end

    register("each") do |context|
      receiver = context.receiver_code
      node = context.node
      transpiler = context.transpiler
      block = node.block
      # `&blk` forwards someone else's block: a BlockArgumentNode has no
      # parameter list to shape the iteration from.
      requireds = block.is_a?(Prism::BlockNode) ? (block.parameters&.parameters&.requireds || []) : []
      if requireds.length == 2
        # A two-parameter block destructures Array elements but iterates
        # key/value on a Hash; only a statically array-like receiver may
        # take the element path, everything else keeps hash semantics.
        receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
        array_like = context.receiver_shape.to_s == "array" ||
          (receiver_type && transpiler.array_element_clear_type(receiver_type))
        next hash_each_effect_stage(context) unless array_like
        next pipeline_effect_stage(receiver, receiver, node, transpiler, "each")
      end

      if node.block && %w[ReturnNode NextNode BreakNode].any? { |name| block_contains_node_name?(node.block, name) }
        next each_with_index_effect_loop(receiver, node, transpiler, max_params: 1)
      end

      pipeline_effect_stage(receiver, receiver, node, transpiler, "each")
    end

    register("reverse_each") do |receiver, node, transpiler|
      next "#{method_receiver(transpiler, receiver)}.reverse()" unless node.block

      receiver_type = transpiler.clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      if receiver_type.end_with?("[]")
        next reverse_each_effect_loop(receiver, node, transpiler)
      end

      pipeline_effect_stage(receiver, "#{method_receiver(transpiler, receiver)}.reverse()", node, transpiler, "reverse_each")
    end

    register("each_key") do |receiver, node, transpiler|
      pipeline_effect_stage(receiver, "#{method_receiver(transpiler, receiver)}.keys()", node, transpiler, "each_key")
    end

    register("each_value") do |receiver, node, transpiler|
      next "#{method_receiver(transpiler, receiver)}.values()" unless node.block

      source = "#{method_receiver(transpiler, receiver)}.values()"
      if block_contains_node_name?(node.block, "ReturnNode")
        receiver_type = transpiler.clear_type_for_receiver_node(node.receiver)
        element_type = transpiler.map_value_clear_type(receiver_type)
        next for_each_effect_loop(source, node, transpiler, "each_value", element_type: element_type)
      end

      pipeline_effect_stage(receiver, source, node, transpiler, "each_value")
    end

    register("each_pair", receiver: "hash") do |context|
      hash_each_effect_stage(context)
    end

    register("each_pair") do |context|
      transpiler = context.transpiler
      receiver_type = transpiler.clear_type_for_receiver_node(context.node.receiver)
      unless receiver_type && transpiler.map_value_clear_type(receiver_type)
        walk = union_struct_walk_stage(context)
        next walk if walk

        next unsupported(transpiler, context.node, "each_pair requires a statically known hash receiver")
      end

      hash_each_effect_stage(context)
    end

    register("each_with_index") do |receiver, node, transpiler|
      each_with_index_effect_loop(receiver, node, transpiler)
    end


    register("with_index") do |_receiver, node, transpiler|
      each_char_with_index_effect_loop(node, transpiler)
    end

    register("loop", receiver: "implicit") do |_receiver, node, transpiler|
      unsupported(transpiler, node, "Ruby loop requires exact break/next semantics before lowering")
    end
  end
end
