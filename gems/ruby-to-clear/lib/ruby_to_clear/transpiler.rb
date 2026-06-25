# frozen_string_literal: true

require "prism"
require "set"

require_relative "method_registry"

module RubyToClear
  class Transpiler
    def initialize(source)
      @source = source
      @indent_level = 0
      @declared_locals = Set.new
      @struct_fields = {}
      @current_class = nil
      @renames = {}
    end

    def transpile(program_node)
      visit(program_node)
    end

    def visit(node)
      return "" unless node

      node_name = node.class.name.split("::").last
      method_name = "visit_#{node_name.gsub(/(?<!^)(?=[A-Z])/, '_').downcase}"
      if respond_to?(method_name, true)
        send(method_name, node)
      else
        comment_unsupported(node)
      end
    end

    def with_renames(new_renames)
      old_renames = @renames.dup
      @renames.merge!(new_renames.compact)
      yield
    ensure
      @renames = old_renames
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



    # --- Node Visitors ---

    def visit_program_node(node)
      visit(node.statements)
    end

    def visit_statements_node(node)
      node.body.map do |stmt|
        code = visit(stmt)
        # Skip empty lines
        next if code.empty?

        # Append semicolon if it doesn't end with a semicolon, END, or isn't a comment/STRUCT definition
        unless code.end_with?(";") || code.end_with?("END") || code.start_with?("STRUCT ") || code.start_with?("#")
          code = "#{code};"
        end

        # Indent every line of the statement
        code.split("\n").map { |line| "#{indent}#{line}" }.join("\n")
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

    def visit_instance_variable_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = visit(node.value)
      "self.#{name} = #{val}"
    end

    def visit_constant_write_node(node)
      name = node.name.to_s

      # Check if value is a Struct.new(...) call
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
      "#{node.name}: Auto"
    end

    def visit_parameters_node(node)
      node.requireds.map { |param| visit(param) }.join(", ")
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
      raw = node.location.slice.strip[1...-1]
      "\"#{raw.gsub('\\', '\\\\\\\\')}\""
    end

    def visit_interpolated_regular_expression_node(node)
      parts = node.parts.map do |part|
        if part.is_a?(Prism::StringNode)
          part.content.gsub('\\', '\\\\\\\\')
        else
          stmt_code = visit(part.statements)
          "${#{stmt_code.delete_suffix(';')}}"
        end
      end.join
      "\"#{parts}\""
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
          translated = MethodRegistry.translate(name_str, rec_code, args_list, node.block, self)
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
      name = node.name.to_s
      params = []

      if @current_class && !node.receiver
        params << "MUTABLE self: #{@current_class}"
      end

      if node.parameters
        params_str = visit(node.parameters)
        params << params_str unless params_str.empty?
      end

      body_code = with_indent { visit(node.body) }
      ret_type = name == "initialize" ? "Void" : "!Auto"
      sig_name = name == "initialize" ? "initialize!" : name

      "FN #{sig_name}(#{params.join(', ')}) RETURNS #{ret_type} ->\n#{body_code}\nEND"
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
