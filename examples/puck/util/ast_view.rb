require_relative 'terminal'

module Puck
  # Renders a Puck AST node as an indented text tree. Generic across v1-v7
  # because it just enumerates whatever fields the node carries
  # (val / left / right / args / arg / name / value), so new node types in
  # later versions are handled without changes.
  module AstView
    INDENT = "  "

    def self.render(node, width:, max_lines: 12)
      lines = []
      render_node(node, "", lines, width, max_lines)
      lines.first(max_lines).map { |line| Terminal.truncate(line, width) }
    end

    def self.summary(node, width)
      Terminal.truncate(node_header(node), width)
    end

    # --- internals --------------------------------------------------------

    def self.render_node(node, indent, lines, width, max_lines)
      return if lines.length >= max_lines

      if structured_node?(node)
        lines << Terminal.truncate("#{indent}#{node_header(node)}", width)
        children = collect_children(node)
        children.each do |label, child|
          return if lines.length >= max_lines
          render_child(label, child, indent + INDENT, lines, width, max_lines)
        end
      else
        lines << Terminal.truncate("#{indent}#{inspect_value(node)}", width)
      end
    end

    def self.render_child(label, child, indent, lines, width, max_lines)
      if structured_node?(child)
        lines << Terminal.truncate("#{indent}#{label}: #{node_header(child)}", width)
        grandchildren = collect_children(child)
        grandchildren.each do |sub_label, sub_child|
          return if lines.length >= max_lines
          render_child(sub_label, sub_child, indent + INDENT, lines, width, max_lines)
        end
      elsif child.is_a?(Array)
        if child.empty?
          lines << Terminal.truncate("#{indent}#{label}: []", width)
        else
          lines << Terminal.truncate("#{indent}#{label}: [", width)
          child.each_with_index do |item, i|
            return if lines.length >= max_lines
            render_child("[#{i}]", item, indent + INDENT, lines, width, max_lines)
          end
          lines << Terminal.truncate("#{indent}]", width) if lines.length < max_lines
        end
      else
        lines << Terminal.truncate("#{indent}#{label}: #{inspect_value(child)}", width)
      end
    end

    # A node is "structured" if it has the .type accessor that both AstNode
    # and ExprNode (across all versions) define.
    def self.structured_node?(node)
      node.respond_to?(:type) && node.respond_to?(:members)
    end

    def self.node_header(node)
      return inspect_value(node) unless structured_node?(node)

      bits = [node.type.to_s]
      bits << node.var.inspect if node.respond_to?(:var) && node.var
      bits << node.name.inspect if node.respond_to?(:name) && node.name
      val = node.respond_to?(:value) ? node.value : nil
      bits << val.inspect if val.is_a?(Symbol) || val.is_a?(Numeric) || val.is_a?(String)
      bits.compact.join(" ")
    end

    # Walks an AstNode/ExprNode and produces (label, child) pairs for the
    # interesting fields. The label is what shows up before the colon. Order
    # roughly matches source order so the rendered tree reads top-to-bottom.
    def self.collect_children(node)
      out = []
      seen_value_in_header = node.respond_to?(:value) && node.value.is_a?(Symbol)

      val = node.respond_to?(:val) ? node.val : nil
      case val
        when Hash
          val.each { |k, v| out << [k.to_s, v] }
        when Array
          val.each_with_index { |v, i| out << ["[#{i}]", v] }
        when nil
          # nothing
        when Symbol, Numeric
          out << ["val", val] unless seen_value_in_header
        else
          out << ["val", val]
      end

      [:left, :right].each do |sym|
        next unless node.respond_to?(sym)
        v = node.send(sym)
        out << [sym.to_s, v] unless v.nil?
      end

      if node.respond_to?(:args)
        args = node.args
        out << ["args", args] if args
      end

      if node.respond_to?(:arg)
        arg = node.arg
        out << ["arg", arg] if arg
      end

      out
    end

    def self.inspect_value(v)
      case v
        when nil then "nil"
        when Symbol, Numeric, String, TrueClass, FalseClass then v.inspect
        else v.to_s
      end
    end

    # Source-like rendering: each statement-shaped node gets one line that
    # echoes its Puck syntax, tagged with [TypeName]. Expressions inline.
    # Returns a list of lines with `> ` marker on the focused node.
    #
    # Used by compile.rb's AST pane to keep the tree compact.
    def self.render_source_like(node, indent, focus_node, lines, width)
      return unless node
      return render_unknown_array(node, indent, focus_node, lines, width) if node.is_a?(Array)
      return lines << Terminal.truncate("#{indent}#{node.inspect}", width) unless structured_node?(node)

      is_focus = focus_node && node.equal?(focus_node)
      mark = is_focus ? "> " : "  "

      case node.type
        when :Procedure   then render_procedure(node, indent, mark, focus_node, lines, width)
        when :Module      then render_module(node, indent, mark, focus_node, lines, width)
        when :Assignment  then lines << Terminal.truncate("#{mark}#{indent}[Assign]  #{node.var} := #{inline_expr(node.val)}", width)
        when :Loop        then render_loop(node, indent, mark, focus_node, lines, width)
        when :If          then render_if(node, indent, mark, focus_node, lines, width)
        when :Exit        then lines << Terminal.truncate("#{mark}#{indent}[Exit]", width)
        when :Return      then lines << Terminal.truncate("#{mark}#{indent}[Return]  #{inline_expr(node.val)}", width)
        when :Syscall     then lines << Terminal.truncate("#{mark}#{indent}[Syscall] SYSCALL(#{node.val}, #{node.var})", width)
        when :CallStatement
          args = (node.val || []).map { |a| inline_expr(a) }.join(", ")
          lines << Terminal.truncate("#{mark}#{indent}[Call]    #{node.var}(#{args})", width)
        when :Macro       then render_macro(node, indent, mark, focus_node, lines, width)
        else
          # Unknown statement type — fall back to one-line summary so the
          # renderer never errors out on new node kinds in later versions.
          lines << Terminal.truncate("#{mark}#{indent}[#{node.type}] #{inline_expr(node)}", width)
      end
    end

    def self.render_procedure(node, indent, mark, focus_node, lines, width)
      params = (node.val[:params] || [node.val[:param]].compact).join(", ")
      lines << Terminal.truncate("#{mark}#{indent}[Procedure] #{node.var}(#{params})", width)
      body = node.val[:body] || []
      body.each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
    end

    def self.render_module(node, indent, mark, focus_node, lines, width)
      lines << Terminal.truncate("#{mark}#{indent}[Module]  #{node.var}", width)
      (node.val[:declarations] || []).each { |d| render_source_like(d, indent + "    ", focus_node, lines, width) }
      (node.val[:body] || []).each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
    end

    def self.render_loop(node, indent, mark, focus_node, lines, width)
      lines << Terminal.truncate("#{mark}#{indent}[Loop]", width)
      body = node.val.is_a?(Array) ? node.val : (node.val[:body] || [])
      body.each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
    end

    def self.render_if(node, indent, mark, focus_node, lines, width)
      cond = inline_expr(node.val[:condition])
      lines << Terminal.truncate("#{mark}#{indent}[If]      #{cond} THEN", width)
      (node.val[:body] || []).each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
      else_body = node.val[:else_body] || []
      if else_body.any?
        lines << Terminal.truncate("  #{indent}ELSE", width)
        else_body.each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
      end
    end

    def self.render_macro(node, indent, mark, focus_node, lines, width)
      params = (node.val[:params] || []).join(", ")
      body_param = node.val[:body_param] ? " DO #{node.val[:body_param]}" : ""
      lines << Terminal.truncate("#{mark}#{indent}[Macro]   #{node.var}(#{params})#{body_param}", width)
      (node.val[:template] || []).each { |stmt| render_source_like(stmt, indent + "    ", focus_node, lines, width) }
    end

    def self.render_unknown_array(arr, indent, focus_node, lines, width)
      arr.each { |x| render_source_like(x, indent, focus_node, lines, width) }
    end

    # Given a focus node (which may be a deeply-nested expression like
    # Integer/Variable/Math), find the statement-shaped AST node that owns
    # the line where `>` should appear. The deepest statement whose inline
    # fields (condition / val / args) transitively contain focus_node wins.
    # If focus_node is itself a statement node, returns it.
    #
    # Returns nil when no node matches.
    def self.find_focus_target(forest, focus_node)
      return nil if focus_node.nil?
      best = nil
      visit = lambda do |node|
        return unless structured_node?(node)
        if node.equal?(focus_node) || inline_contains?(node, focus_node)
          best = node  # later/deeper visits overwrite
        end
        sub_statements_of(node).each { |s| visit.call(s) }
      end
      forest.each do |entry|
        n = entry.is_a?(Hash) ? entry[:node] : entry
        visit.call(n)
      end
      best
    end

    # Statement-shaped children — only fields that get their own line in
    # render_source_like. Excludes inline expression fields like If#condition
    # or Assignment#val.
    def self.sub_statements_of(node)
      return [] unless structured_node?(node)
      case node.type
        when :Procedure, :Macro
          node.val.is_a?(Hash) ? (node.val[:body] || []) : []
        when :Module
          (node.val[:declarations] || []) + (node.val[:body] || [])
        when :Loop
          node.val.is_a?(Array) ? node.val : (node.val[:body] || [])
        when :If
          (node.val[:body] || []) + (node.val[:else_body] || [])
        else []
      end
    end

    # Inline fields are the ones whose values render on the same line as
    # the statement header (e.g., If's condition becomes "i = 42").
    def self.inline_fields_of(node)
      return [] unless structured_node?(node)
      case node.type
        when :Assignment, :Return then [node.val]
        when :If then [node.val[:condition]]
        when :CallStatement       then (node.val || [])
        else []
      end
    end

    def self.inline_contains?(node, target)
      inline_fields_of(node).any? { |v| contains_node_deeply?(v, target) }
    end

    def self.contains_node_deeply?(node, target)
      return false if node.nil?
      return true if node.equal?(target)
      return node.any? { |x| contains_node_deeply?(x, target) } if node.is_a?(Array)
      return false unless structured_node?(node)
      collect_children(node).any? { |_, child| contains_node_deeply?(child, target) }
    end

    # Inline expression rendering. Returns a single-line string.
    def self.inline_expr(node)
      return "<nil>" if node.nil?
      return node.inspect unless structured_node?(node)

      case node.type
        when :Integer then node.value.to_s
        when :String  then node.value.inspect
        when :Variable then node.name.to_s
        when :Math    then "#{inline_expr(node.left)} #{node.value} #{inline_expr(node.right)}"
        when :Equal   then "#{inline_expr(node.left)} = #{inline_expr(node.right)}"
        when :Compare then "#{inline_expr(node.left)} #{node.value} #{inline_expr(node.right)}"
        when :Add     then "#{inline_expr(node.left)} + #{inline_expr(node.right)}"
        when :Call
          args_list =
            if node.respond_to?(:args) && node.args then node.args
            elsif node.respond_to?(:arg) && node.arg then [node.arg]
            else []
            end
          "#{node.name}(#{args_list.map { |a| inline_expr(a) }.join(', ')})"
        else node_header(node)
      end
    end
  end
end
