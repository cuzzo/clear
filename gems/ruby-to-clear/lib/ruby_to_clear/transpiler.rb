# frozen_string_literal: true

require "prism"
require "set"

require_relative "method_registry"

module RubyToClear
  class Transpiler
    class TranspilationError < StandardError; end

    DYNAMIC_RUBY_CALLS = {
      "send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "__send__" => "dynamic dispatch; replace with a closed case/table over known method names",
      "public_send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "const_get" => "dynamic constant lookup; replace with an explicit registry map",
      "const_defined?" => "dynamic constant lookup; replace with an explicit registry map",
      "instance_variable_get" => "dynamic instance state; replace with declared fields or a typed side table",
      "instance_variable_set" => "dynamic instance state; replace with declared fields or a typed side table",
      "define_method" => "dynamic method definition; generate explicit methods or a closed dispatcher",
      "method_missing" => "dynamic method definition; replace with explicit protocol methods",
      "eval" => "dynamic evaluation; refactor before translation",
      "instance_eval" => "dynamic evaluation; refactor before translation",
      "class_eval" => "dynamic evaluation; refactor before translation",
      "module_eval" => "dynamic evaluation; refactor before translation",
    }.freeze

    def initialize(source, raise_on_error: true)
      @source = source
      @raise_on_error = raise_on_error
      @indent_level = 0
      @declared_locals = Set.new
      @struct_fields = {}
      @current_class = nil
      @renames = {}
      @mutable_params = nil
      @type_aliases = {}
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
        unsupported_comment(node, message)
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

    def parse_sig(sig_call_node)
      param_types = {}
      return_type = "Auto"
      
      return [param_types, return_type] unless sig_call_node&.block
      
      body_node = sig_call_node.block.body
      return [param_types, return_type] unless body_node.is_a?(Prism::StatementsNode)
      
      body_node.body.each do |stmt|
        walk_sig_chain = ->(call_node) do
          return unless call_node.is_a?(Prism::CallNode)
          
          case call_node.name.to_s
          when "void"
            return_type = "Void"
          when "returns"
            if call_node.arguments && call_node.arguments.arguments.first
              return_type = convert_sorbet_type(call_node.arguments.arguments.first)
            end
          when "params"
            if call_node.arguments && call_node.arguments.arguments.first.is_a?(Prism::KeywordHashNode)
              call_node.arguments.arguments.first.elements.each do |assoc|
                if assoc.is_a?(Prism::AssocNode)
                  param_name = assoc.key.value.to_s
                  param_type = convert_sorbet_type(assoc.value)
                  param_types[param_name] = param_type
                end
              end
            end
          end
          
          walk_sig_chain.call(call_node.receiver) if call_node.receiver
        end
        
        walk_sig_chain.call(stmt)
      end
      
      [param_types, return_type]
    end

    def convert_sorbet_type(node)
      return "Auto" unless node
      
      case node.class.name.split("::").last
      when "ConstantReadNode"
        name = node.name.to_s
        return @type_aliases[name] if @type_aliases.key?(name)

        case name
        when "Integer" then "Int64"
        when "Float" then "Float64"
        when "String" then "String"
        when "Symbol" then "String@symbol"
        when "NilClass" then "Void"
        when "Boolean" then "Bool"
        when "TrueClass", "FalseClass" then "Bool"
        when "T" then "Auto"
        else name
        end
      when "ConstantPathNode"
        path = node.location.slice.strip
        case path
        when "T::Boolean" then "Bool"
        when "T::Array" then "Auto[]"
        when "T::Hash" then "HashMap<Auto, Auto>"
        when "T::Set" then "Auto[]@set"
        when "T.untyped" then "Auto"
        else path.gsub("::", ".")
        end
      when "CallNode"
        if node.receiver && node.receiver.location.slice.strip == "T"
          case node.name.to_s
          when "nilable"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "?#{inner}"
          when "any"
            args = node.arguments ? node.arguments.arguments : []
            non_nil_args = args.reject { |a| a.location.slice.strip == "NilClass" }
            if non_nil_args.length == 1
              inner = convert_sorbet_type(non_nil_args.first)
              return "?#{inner}"
            else
              return "Auto"
            end
          when "untyped", "anything"
            return "Auto"
          end
        end
        
        if node.name.to_s == "[]"
          receiver_name = node.receiver ? node.receiver.location.slice.strip : ""
          if receiver_name == "T::Array" || receiver_name == "Array"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "#{inner}[]"
          elsif receiver_name == "T::Hash" || receiver_name == "Hash"
            args = node.arguments ? node.arguments.arguments : []
            key = convert_sorbet_type(args[0])
            value = convert_sorbet_type(args[1])
            return "HashMap<#{key}, #{value}>"
          elsif receiver_name == "T::Set" || receiver_name == "Set"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "#{inner}[]@set"
          elsif receiver_name == "T::Enumerable" || receiver_name == "Enumerable"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "#{inner}[]"
          end
        end
        
        "Auto"
      else
        "Auto"
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
          res = raise_unsupported("Keyword arguments are not supported", arg)
          return res if res.is_a?(String) && res.include?("# [UNSUPPORTED:")
        end
      end
      nil
    end

    def check_parameters!(parameters_node)
      return unless parameters_node
      if !parameters_node.keywords.empty? || parameters_node.keyword_rest
        return raise_unsupported("Keyword parameters are not supported", parameters_node)
      end
      nil
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

    def sorbet_typed_value(node)
      return nil unless sorbet_call?(node)
      return nil unless ["let", "cast"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2

      [args.first, convert_sorbet_type(args[1])]
    end

    def sorbet_type_alias_value(node)
      return nil unless sorbet_call?(node, "type_alias")
      return nil unless node.block&.body.is_a?(Prism::StatementsNode)

      body = node.block.body.body
      return nil unless body.length == 1

      convert_sorbet_type(body.first)
    end

    def t_struct_class?(node)
      node.superclass&.location&.slice == "T::Struct"
    end

    def t_struct_field(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil?
      return nil unless ["const", "prop"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2
      return nil unless args.first.is_a?(Prism::SymbolNode)

      [args.first.value.to_s, convert_sorbet_type(args[1])]
    end

    def dynamic_ruby_call_reason(name)
      DYNAMIC_RUBY_CALLS[name.to_s]
    end

    # --- Node Visitors ---

    def visit_program_node(node)
      visit(node.statements)
    end


    def visit_statements_node(node)
      last_sig = nil
      node.body.map do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          next nil
        end

        if stmt.is_a?(Prism::DefNode)
          @current_sig = last_sig
          last_sig = nil
        else
          last_sig = nil
        end

        code = visit(stmt)
        @current_sig = nil
        next if code.empty?

        unless code.end_with?(";") || code.end_with?("END") || code.start_with?("STRUCT ") || code.lstrip.start_with?("#")
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
      value_node = node.value
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      end

      val = visit(value_node)
      if @declared_locals.include?(name)
        "#{name} = #{val}"
      else
        @declared_locals << name
        typed = type_annotation && type_annotation != "Auto" ? ": #{type_annotation}" : ""
        "MUTABLE #{name}#{typed} = #{val}"
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

      if (type_alias = sorbet_type_alias_value(node.value))
        @type_aliases[name] = type_alias
        return ""
      end

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
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      "#{prefix}#{node.name}: #{type}"
    end

    def visit_parameters_node(node)
      requireds = node.requireds.map { |param| visit(param) }
      optionals = node.optionals.map { |param| visit(param) }
      (requireds + optionals).join(", ")
    end

    def visit_optional_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      default_val = visit(node.value)
      "#{prefix}#{node.name} = #{default_val}: #{type}"
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
      return raise_unsupported("Regular expressions are not supported", node)
    end

    def visit_interpolated_regular_expression_node(node)
      return raise_unsupported("Regular expressions are not supported", node)
    end

    def visit_interpolated_string_node(node)
      parts = node.parts.map { |part| interpolated_string_part(part) }.join
      "\"#{parts}\""
    end

    def visit_embedded_statements_node(node)
      "${#{embedded_statement_expression(node)}}"
    end

    def interpolated_string_part(part)
      case part
      when Prism::StringNode
        part.content
      when Prism::EmbeddedStatementsNode
        "${#{embedded_statement_expression(part)}}"
      when Prism::InterpolatedStringNode
        part.parts.map { |nested_part| interpolated_string_part(nested_part) }.join
      else
        visit(part).delete_suffix(";")
      end
    end

    def embedded_statement_expression(node)
      statements = node.statements
      return "" unless statements

      unless statements.body.length == 1
        return raise_unsupported("String interpolation must contain a single expression", node)
      end

      visit(statements.body.first).delete_suffix(";")
    end

    def visit_call_node(node)
      chk = check_arguments!(node.arguments)
      return chk if chk.is_a?(String) && chk.include?("# [UNSUPPORTED:")

      if (reason = dynamic_ruby_call_reason(node.name.to_s))
        return raise_unsupported("#{node.name} is a Ruby dynamic/reflection call: #{reason}", node)
      end

      if sorbet_call?(node)
        return "" if node.name.to_s == "bind"

        if (unwrapped = sorbet_unwrapped_value(node))
          return visit(unwrapped)
        end
      end

      if node.name.to_s == "gsub" || node.name.to_s == "sub"
        rec_code = node.receiver ? visit(node.receiver) : nil
        if rec_code
          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver)
          )
          return translated if translated
        end
        return raise_unsupported("gsub/sub with dynamic regex, block, or invalid arguments is not supported", node)
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
        if node.receiver
          lhs = visit(node.receiver)
          translated = MethodRegistry.translate(
            node.name.to_s,
            lhs,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver)
          )
          return translated if translated
        end
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
          rec_code = visit(node.receiver)
          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver)
          )
          return translated if translated

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
          translated = MethodRegistry.translate(
            name_str,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver)
          )
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

      if t_struct_class?(node)
        body_nodes = node.body&.body || []
        fields = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
        if fields.length == body_nodes.length
          @struct_fields[@current_class] = fields.map(&:first)
          field_decls = fields.map { |field, type| "  #{field}: #{type}" }.join(",\n")
          @current_class = old_class
          return "STRUCT #{node.constant_path.location.slice.strip} {\n#{field_decls}\n}"
        end
      end

      ivar_names = collect_instance_variables(node)
      struct_fields = ivar_names.map { |name| "  #{name}: Auto" }.join(",\n")
      struct_code = "STRUCT #{@current_class} {\n#{struct_fields}\n}"

      body_code = visit(node.body)

      @current_class = old_class

      "#{struct_code}\n\n#{body_code}"
    end

    def visit_def_node(node)
      chk = check_parameters!(node.parameters)
      return chk if chk.is_a?(String) && chk.include?("# [UNSUPPORTED:")
      
      name = node.name.to_s
      param_types, sig_return_type = parse_sig(@current_sig)
      @param_types = param_types

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
      @param_types = nil

      ret_type = if name == "initialize"
        "Void"
      elsif sig_return_type != "Auto"
        sig_return_type
      else
        "!Auto"
      end
      sig_name = name == "initialize" ? "initialize!" : name

      "FN #{sig_name}(#{params.join(', ')}) RETURNS #{ret_type} ->\n#{full_body}\nEND"
    end

    def visit_block_argument_node(node)
      "&#{visit(node.expression)}"
    end

    def visit_multi_write_node(node)
      unless node.value.is_a?(Prism::ArrayNode)
        return raise_unsupported("Destructuring is only supported for literal array values", node)
      end
      
      lefts = node.lefts
      rights = node.value.elements
      
      if lefts.length != rights.length
        return raise_unsupported("Multi-write left and right side lengths must match", node)
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
      return raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_rescue_modifier_node(node)
      return raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_begin_node(node)
      if node.rescue_clause
        return raise_unsupported("Exception handling (rescue) is not supported", node)
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

    def registry_receiver_kind(receiver)
      case receiver
      when nil then "implicit"
      when Prism::SelfNode then "self"
      when Prism::LocalVariableReadNode then "local"
      when Prism::InstanceVariableReadNode then "ivar"
      when Prism::ClassVariableReadNode then "class_var"
      when Prism::GlobalVariableReadNode then "global"
      when Prism::ConstantReadNode then "constant"
      when Prism::ConstantPathNode then "constant_path"
      when Prism::CallNode then "call_result"
      when Prism::ParenthesesNode then "parenthesized"
      when Prism::StringNode, Prism::InterpolatedStringNode then "string_literal"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "symbol_literal"
      when Prism::IntegerNode, Prism::FloatNode then "numeric_literal"
      when Prism::ArrayNode then "array_literal"
      when Prism::HashNode then "hash_literal"
      when Prism::NilNode then "nil_literal"
      when Prism::TrueNode, Prism::FalseNode then "bool_literal"
      else receiver.class.name.split("::").last
      end
    end

    def registry_receiver_name(receiver)
      return nil unless receiver

      if receiver.respond_to?(:full_name)
        receiver.full_name
      elsif receiver.respond_to?(:name)
        receiver.name.to_s
      end
    rescue StandardError
      nil
    end

    def comment_unsupported(node)
      unsupported_comment(node)
    end

    def unsupported_comment(node, message = nil)
      node_name = node.class.name.split("::").last
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      slice = node.location.slice
      lines = slice.split("\n")
      header = "# [UNSUPPORTED: #{node_name} at #{source_loc}]"
      header = "#{header} #{message}" if message
      commented_lines = [header]
      lines.each do |line|
        commented_lines << "# #{line}"
      end
      commented_lines.map { |l| "#{indent}#{l}" }.join("\n")
    end
  end
end
