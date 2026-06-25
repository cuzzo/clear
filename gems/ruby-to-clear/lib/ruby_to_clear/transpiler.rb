# frozen_string_literal: true

require "prism"
require "set"

require_relative "method_registry"

module RubyToClear
  class Transpiler
    class TranspilationError < StandardError; end

    def initialize(source, raise_on_error: true)
      @source = source
      @raise_on_error = raise_on_error
      @indent_level = 0
      @declared_locals = Set.new
      @struct_fields = {}
      @current_class = nil
      @renames = {}
      @mutable_params = nil
    end

    def transpile(program_node)
      visit(program_node)
    end

    def visit(node)
      return "" unless node

      node_name = node.class.name.split("::").last
      method_name = "visit_#{node_name.gsub(/(?<!^)(?=[A-Z])/, '_').downcase}"
      if respond_to?(method_name, true)
        res = send(method_name, node)
        if res.is_a?(String) && res.include?("# [UNSUPPORTED:") &&
           node_name != "StatementsNode" && node_name != "ProgramNode" &&
           node_name != "ClassNode" && node_name != "DefNode"
          if @raise_on_error
            raise_unsupported("Unsupported construct #{node_name}", node)
          else
            comment_unsupported(node)
          end
        else
          res
        end
      else
        raise_unsupported("Unsupported node #{node_name}", node)
      end
    end

    def with_renames(new_renames)
      old_renames = @renames.dup
      @renames.merge!(new_renames.compact)
      yield
    ensure
      @renames = old_renames
    end

    def raise_unsupported(message, node)
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      err_msg = "Unsupported Ruby syntax: #{message} at line #{source_loc}\nSource: #{loc.slice.strip}"
      
      if @raise_on_error
        raise TranspilationError, err_msg
      else
        "# [UNSUPPORTED: #{node.class.name.split('::').last}]\n# #{loc.slice.gsub("\n", "\n# ")}"
      end
    end

    def simple_block_expression?(block_node)
      body_node = block_node.body
      return false unless body_node.is_a?(Prism::StatementsNode)
      return false unless body_node.body.size == 1
      pure_expression?(body_node.body.first)
    end

    def pure_expression?(node)
      return false unless node
      case node.class.name.split("::").last
      when "CallNode", "LocalVariableReadNode", "IntegerNode", "StringNode", "SymbolNode", "SelfNode",
           "AndNode", "OrNode", "ParenthesesNode", "NilNode", "FalseNode", "TrueNode",
           "ArrayNode", "HashNode", "RangeNode", "ConstantReadNode", "ConstantPathNode"
        true
      else
        false
      end
    end

    private

    def indent
      "  " * @indent_level
    end

    def with_indent
      @indent_level += 1
      yield
    ensure
      @indent_level -= 1
    end

    def check_arguments!(arguments_node)
      return unless arguments_node
      arguments_node.arguments.each do |arg|
        if arg.is_a?(Prism::KeywordHashNode)
          raise_unsupported("Keyword arguments are not supported", arg)
        end
      end
    end

    def check_parameters!(parameters_node)
      return unless parameters_node
      if !parameters_node.keywords.empty? || parameters_node.keyword_rest
        raise_unsupported("Keyword parameters are not supported", parameters_node)
      end
    end

    def collect_written_variables(node, parameter_names = Set.new, exclude_defs: false)
      written = Set.new
      walk = ->(n) do
        return unless n
        if exclude_defs && n.is_a?(Prism::DefNode)
          return
        end
        if n.respond_to?(:name) && n.class.name.start_with?("Prism::LocalVariable") && 
           (n.class.name.end_with?("WriteNode") || n.class.name.end_with?("TargetNode"))
          written << n.name.to_s
        end
        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      written
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

    # --- Node Visitors ---

    def visit_program_node(node)
      visit(node.statements)
    end


    def visit_statements_node(node)
      node.body.map do |stmt|
        code = visit(stmt)
        next if code.empty?

        unless code.end_with?(";") || code.end_with?("END") || code.start_with?("STRUCT ") || code.start_with?("#")
          code = "#{code};"
        end

        code.split("\n").map { |line| line.start_with?(" ") ? line : "#{indent}#{line}" }.join("\n")
      end.compact.join("\n")
    end

    def visit_else_node(node)
      visit(node.statements)
    end

    def visit_integer_node(node)
      node.value.to_s
    end

    def visit_string_node(node)
      "\"#{node.content}\""
    end

    def visit_symbol_node(node)
      ".#{node.value}"
    end

    def visit_local_variable_read_node(node)
      name = node.name.to_s
      @renames[name] || name
    end

    def visit_self_node(node)
      "self"
    end

    def visit_local_variable_target_node(node)
      name = node.name.to_s
      @renames[name] || name
    end

    def visit_block_parameters_node(node)
      visit(node.parameters)
    end

    def visit_instance_variable_read_node(node)
      "self.#{node.name.to_s.delete_prefix('@')}"
    end

    def visit_constant_read_node(node)
      node.name.to_s
    end

    def visit_constant_path_node(node)
      node.location.slice.gsub("::", ".")
    end

    def visit_arguments_node(node)
      node.arguments.map { |arg| visit(arg) }.join(", ")
    end

    def visit_local_variable_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = #{val}"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_local_variable_operator_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      op = node.operator.to_s.delete_suffix("=")
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} #{op} #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_operator_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      op = node.operator.to_s.delete_suffix("=")
      val = visit(node.value)
      "self.#{name} = (self.#{name} #{op} #{val})"
    end

    def visit_local_variable_or_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} || #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_local_variable_and_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} && #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = visit(node.value)
      "self.#{name} = #{val}"
    end

    def visit_constant_write_node(node)
      name = node.name.to_s

      if node.value.is_a?(Prism::CallNode) &&
         (node.value.receiver.nil? || (node.value.receiver.is_a?(Prism::ConstantReadNode) && node.value.receiver.name == :Struct)) &&
         node.value.name == :new

        fields = []
        if node.value.arguments
          node.value.arguments.arguments.each do |arg|
            fields << arg.value.to_s if arg.is_a?(Prism::SymbolNode)
          end
        end
        @struct_fields[name] = fields

        field_decls = fields.map { |f| "  #{f}: Auto" }.join(",\n")
        return "STRUCT #{name} {\n#{field_decls}\n}"
      end

      val = visit(node.value)
      "#{name} = #{val}"
    end

    def visit_range_node(node)
      left = node.left ? visit(node.left) : ""
      right = node.right ? visit(node.right) : ""
      op = node.exclude_end? ? "..<" : "..="
      "#{left} #{op} #{right}"
    end

    def visit_required_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      "#{prefix}#{node.name}: Auto"
    end

    def visit_parameters_node(node)
      requireds = node.requireds.map { |param| visit(param) }
      optionals = node.optionals.map { |param| visit(param) }
      (requireds + optionals).join(", ")
    end

    def visit_optional_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      default_val = visit(node.value)
      "#{prefix}#{node.name} = #{default_val}: Auto"
    end

    def visit_array_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "[#{elements}]"
    end

    def visit_hash_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "{#{elements}}"
    end

    def visit_keyword_hash_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "{#{elements}}"
    end

    def visit_assoc_node(node)
      key = visit(node.key)
      key = node.key.value.to_s if node.key.is_a?(Prism::SymbolNode)
      val = visit(node.value)
      "#{key}: #{val}"
    end

    def visit_and_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      "(#{lhs} && #{rhs})"
    end

    def visit_or_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      "(#{lhs} || #{rhs})"
    end

    def visit_nil_node(node)
      "NIL"
    end

    def visit_false_node(node)
      "FALSE"
    end

    def visit_true_node(node)
      "TRUE"
    end

    def visit_parentheses_node(node)
      if node.body
        "(#{visit(node.body)})"
      else
        "()"
      end
    end

    def visit_until_node(node)
      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE !(#{pred}) DO\n#{body}\nEND"
    end

    def visit_while_node(node)
      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE #{pred} DO\n#{body}\nEND"
    end

    def visit_return_node(node)
      if node.arguments
        "RETURN #{visit(node.arguments)}"
      else
        "RETURN"
      end
    end

    def visit_break_node(node)
      "BREAK"
    end

    def visit_next_node(node)
      "NEXT"
    end

    def visit_if_node(node)
      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      consequent_code = node.consequent ? format_consequent(node.consequent) : ""
      "IF #{pred} THEN\n#{body}#{consequent_code}\nEND"
    end

    def visit_unless_node(node)
      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      consequent_code = node.consequent ? format_consequent(node.consequent) : ""
      "IF !(#{pred}) THEN\n#{body}#{consequent_code}\nEND"
    end

    def visit_case_node(node)
      if node.predicate.nil?
        first_when = node.conditions.first
        other_whens = node.conditions[1..-1] || []

        pred = visit(first_when.conditions.first)
        body = with_indent { visit(first_when.statements) }

        consequent_code = ""
        other_whens.each do |w|
          w_pred = visit(w.conditions.first)
          w_body = with_indent { visit(w.statements) }
          consequent_code += "\nELSE_IF #{w_pred} THEN\n#{w_body}"
        end

        if node.consequent
          else_body = with_indent { visit(node.consequent) }
          consequent_code += "\nELSE\n#{else_body}"
        end

        "IF #{pred} THEN\n#{body}#{consequent_code}\nEND"
      else
        target = visit(node.predicate)
        arms = []
        node.conditions.each do |w|
          w.conditions.each do |cond|
            cond_val = visit(cond)
            stmt_val = visit(w.statements)
            arms << "#{cond_val} -> #{stmt_val},"
          end
        end

        if node.consequent
          else_val = visit(node.consequent)
          arms << "DEFAULT -> #{else_val}"
        end

        arms_body = with_indent do
          arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
        end

        "PARTIAL MATCH #{target} START\n#{arms_body}\nEND"
      end
    end

    def visit_regular_expression_node(node)
      raise_unsupported("Regular expressions are not supported", node)
    end

    def visit_interpolated_regular_expression_node(node)
      raise_unsupported("Regular expressions are not supported", node)
    end

    def visit_interpolated_string_node(node)
      parts = node.parts.map do |part|
        if part.is_a?(Prism::StringNode)
          part.content
        else
          stmt_code = visit(part.statements)
          "${#{stmt_code.delete_suffix(';')}}"
        end
      end.join
      "\"#{parts}\""
    end

    def visit_embedded_statements_node(node)
      stmt_code = visit(node.statements)
      "${#{stmt_code.delete_suffix(';')}}"
    end

    def visit_call_node(node)
      check_arguments!(node.arguments)

      if node.name.to_s == "gsub" || node.name.to_s == "sub"
        rec_code = node.receiver ? visit(node.receiver) : nil
        if rec_code
          translated = MethodRegistry.translate(node.name.to_s, rec_code, node, self)
          return translated if translated
        end
        raise_unsupported("gsub/sub with dynamic regex, block, or invalid arguments is not supported", node)
      end

      case node.name.to_s
      when "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&&", "||", "&", "|"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "(#{lhs} #{node.name} #{rhs})"
      when "<<"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "#{lhs}.append(#{rhs})"
      when "[]"
        lhs = visit(node.receiver)
        args = visit(node.arguments)
        "#{lhs}[#{args}]"
      when "[]="
        lhs = visit(node.receiver)
        index = visit(node.arguments.arguments.first)
        value = visit(node.arguments.arguments.last)
        "#{lhs}[#{index}] = #{value}"
      else
        if node.receiver.is_a?(Prism::ConstantReadNode) && node.name.to_s == "new"
          class_name = node.receiver.name.to_s
          if @struct_fields[class_name]
            fields = @struct_fields[class_name]
            args = node.arguments ? node.arguments.arguments : []
            assoc_pairs = []
            args.each_with_index do |arg, idx|
              field_name = fields[idx] || "field_#{idx}"
              assoc_pairs << "#{field_name}: #{visit(arg)}"
            end
            return "#{class_name}{ #{assoc_pairs.join(', ')} }"
          else
            args_list = node.arguments ? visit(node.arguments) : ""
            return "#{class_name}{ #{args_list} }"
          end
        end

        rec_code = node.receiver ? visit(node.receiver) : nil
        name_str = node.name.to_s
        args_list = node.arguments ? node.arguments.arguments.map { |arg| visit(arg) } : []

        if rec_code
          translated = MethodRegistry.translate(name_str, rec_code, node, self)
          return translated if translated
        end

        rec = rec_code ? "#{rec_code}." : ""
        args_str = args_list.join(", ")

        if node.block
          block_code = visit(node.block)
          "#{rec}#{name_str}(#{args_str}) #{block_code}"
        else
          "#{rec}#{name_str}(#{args_str})"
        end
      end
    end

    def visit_class_node(node)
      old_class = @current_class
      @current_class = node.constant_path.location.slice.strip

      ivar_names = collect_instance_variables(node)
      struct_fields = ivar_names.map { |name| "  #{name}: Auto" }.join(",\n")
      struct_code = "STRUCT #{@current_class} {\n#{struct_fields}\n}"

      body_code = visit(node.body)

      @current_class = old_class

      "#{struct_code}\n\n#{body_code}"
    end

    def visit_def_node(node)
      check_parameters!(node.parameters)
      
      name = node.name.to_s
      param_names = extract_parameter_names(node)
      written_vars = collect_written_variables(node.body, param_names)
      written_params = param_names & written_vars
      
      @mutable_params = written_params
      
      params = []
      if @current_class && !node.receiver
        params << "MUTABLE self: #{@current_class}"
      end

      if node.parameters
        params_str = visit(node.parameters)
        params << params_str unless params_str.empty?
      end

      old_declared = @declared_locals
      @declared_locals = Set.new(param_names)
      
      local_vars_to_declare = (written_vars - param_names).to_a.sort
      local_vars_to_declare.each { |var| @declared_locals << var }

      body_code = with_indent { visit(node.body) }
      
      decls_code = local_vars_to_declare.map do |var|
        "#{indent}  MUTABLE #{var} = NIL;"
      end.join("\n")

      full_body = if decls_code.empty?
        body_code
      elsif body_code.empty?
        decls_code
      else
        "#{decls_code}\n#{body_code}"
      end

      @declared_locals = old_declared
      @mutable_params = nil

      ret_type = name == "initialize" ? "Void" : "!Auto"
      sig_name = name == "initialize" ? "initialize!" : name

      "FN #{sig_name}(#{params.join(', ')}) RETURNS #{ret_type} ->\n#{full_body}\nEND"
    end

    def visit_block_argument_node(node)
      "&#{visit(node.expression)}"
    end

    def visit_multi_write_node(node)
      unless node.value.is_a?(Prism::ArrayNode)
        raise_unsupported("Destructuring is only supported for literal array values", node)
      end
      
      lefts = node.lefts
      rights = node.value.elements
      
      if lefts.length != rights.length
        raise_unsupported("Multi-write left and right side lengths must match", node)
      end
      
      temp_names = lefts.map.with_index { |_, idx| "__tmp_multi_#{idx}" }
      
      decls = []
      assigns = []
      
      rights.each_with_index do |r, idx|
        val = visit(r)
        temp_name = temp_names[idx]
        @declared_locals << temp_name
        decls << "MUTABLE #{temp_name} = #{val}"
      end
      
      lefts.each_with_index do |l, idx|
        target_name = visit(l)
        temp_name = temp_names[idx]
        assigns << "#{target_name} = #{temp_name}"
      end
      
      (decls + assigns).join(";\n")
    end

    def visit_rescue_node(node)
      raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_rescue_modifier_node(node)
      raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_begin_node(node)
      if node.rescue_clause
        raise_unsupported("Exception handling (rescue) is not supported", node)
      else
        visit(node.statements)
      end
    end

    def format_consequent(consequent_node)
      if consequent_node.is_a?(Prism::IfNode)
        pred = visit(consequent_node.predicate)
        body = with_indent { visit(consequent_node.statements) }
        nested = consequent_node.consequent ? format_consequent(consequent_node.consequent) : ""
        "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      else
        body = with_indent { visit(consequent_node) }
        "\nELSE\n#{body}"
      end
    end

    def collect_instance_variables(node)
      ivars = Set.new
      walk = ->(n) do
        next unless n

        if n.is_a?(Prism::InstanceVariableReadNode) || n.is_a?(Prism::InstanceVariableWriteNode)
          ivars << n.name.to_s.delete_prefix("@")
        end
        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      ivars.to_a.sort
    end

    def comment_unsupported(node)
      node_name = node.class.name.split("::").last
      slice = node.location.slice
      lines = slice.split("\n")
      commented_lines = ["# [UNSUPPORTED: #{node_name}]"]
      lines.each do |line|
        commented_lines << "# #{line}"
      end
      commented_lines.map { |l| "#{indent}#{l}" }.join("\n")
    end
  end
end
