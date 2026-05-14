require_relative 'parser'

# Compile-time AST rewrite step. Walks the AST once, and for each MACRO
# definition it sees, stashes the template. For each MacroCall, it stitches
# the call's args and body into a fresh copy of the template, then re-walks
# the result so nested macros (e.g. FOR built on WHILE) expand recursively.
#
# Substitution and recursive expansion happen in a SINGLE walker, so there
# is exactly one place that knows how each AST node shape recurses into its
# children.
class MacroExpander
  MAX_DEPTH = 50

  def initialize
    @macros = {}
  end

  def expand(ast)
    expand_statements(ast, {}, nil, nil, 0)
  end

  # The walker. `bindings` map macro parameter names to caller expressions.
  # `body_binding` is the name of the macro's body slot, and `body` is the
  # caller's block of statements that will be spliced wherever `body;`
  # appears in the template. At the top level all three are empty/nil.
  def expand_statements(nodes, bindings, body_binding, body, depth)
    raise "Macro expansion is too deep." if depth > MAX_DEPTH

    out = []
    nodes.each do |node|
      case node.type
      when :Macro
        # MACRO definitions are stashed and dropped from the output.
        @macros[node.var] = node.val
      when :MacroCall
        out.concat(expand_macro_call(node, bindings, body_binding, body, depth))
      when :CallStatement
        if body_binding && node.var == body_binding && node.val.empty?
          # `body;` in a template: splice the caller's block. The block was
          # already expanded once before being passed in (see expand_macro_call),
          # so we just paste a fresh copy.
          out.concat(copy(body))
        else
          out << expand_node(node, bindings, body_binding, body, depth)
        end
      else
        out << expand_node(node, bindings, body_binding, body, depth)
      end
    end
    out
  end

  # Per-node rewrite. Substitutes bindings into expressions/names at the
  # leaves; recurses into nested statement blocks via expand_statements so
  # nested MacroCalls and body splices are handled uniformly.
  def expand_node(node, bindings, body_binding, body, depth)
    case node.type
    when :Module
      AstNode.new(:Module, node.var, {
        declarations: expand_statements(node.val[:declarations], bindings, body_binding, body, depth),
        body: expand_statements(node.val[:body], bindings, body_binding, body, depth)
      })
    when :Procedure
      AstNode.new(:Procedure, node.var, node.val.merge(
        body: expand_statements(node.val[:body], bindings, body_binding, body, depth)
      ))
    when :Assignment, :Return
      AstNode.new(node.type, substitute_name(node.var, bindings), substitute_expression(node.val, bindings))
    when :Syscall
      AstNode.new(:Syscall, substitute_name(node.var, bindings), node.val)
    when :If
      AstNode.new(:If, nil, {
        condition: substitute_expression(node.val[:condition], bindings),
        body: expand_statements(node.val[:body], bindings, body_binding, body, depth),
        else_body: expand_statements(node.val[:else_body] || [], bindings, body_binding, body, depth)
      })
    when :Loop
      AstNode.new(:Loop, nil, expand_statements(node.val, bindings, body_binding, body, depth))
    when :CallStatement
      AstNode.new(:CallStatement, node.var, node.val.map { |arg| substitute_expression(arg, bindings) })
    else
      node
    end
  end

  # Expand one MacroCall. Three steps:
  #   1. Substitute the *outer* bindings into the call's args and body. This
  #      is what makes nested calls compose: FOR(i, 1, 5) inside another
  #      macro's template needs the outer macro's `i`/`1`/`5` resolved
  #      before they become the inner macro's parameters.
  #   2. Bind the (now resolved) args to the macro's parameter names.
  #   3. Walk a fresh copy of the template with the new bindings; depth+1.
  def expand_macro_call(node, outer_bindings, outer_body_binding, outer_body, depth)
    macro = @macros.fetch(node.var)
    args = node.val[:args].map { |arg| substitute_expression(arg, outer_bindings) }
    body = expand_statements(node.val[:body], outer_bindings, outer_body_binding, outer_body, depth)

    bindings = macro[:params].zip(args).to_h
    expand_statements(copy(macro[:template]), bindings, macro[:body_param], body, depth + 1)
  end

  # Expression-level substitution. A bare Variable whose name matches a
  # binding is replaced by a fresh copy of the bound expression. Other
  # expression shapes are rebuilt with substituted children.
  def substitute_expression(expression, bindings)
    return copy(bindings[expression.name]) if expression.type == :Variable && bindings.key?(expression.name)

    case expression.type
    when :Math, :Compare
      ExprNode.new(
        type: expression.type,
        value: expression.value,
        left: substitute_expression(expression.left, bindings),
        right: substitute_expression(expression.right, bindings)
      )
    when :Call
      ExprNode.new(
        type: :Call,
        name: expression.name,
        args: expression.args.map { |arg| substitute_expression(arg, bindings) }
      )
    else
      expression
    end
  end

  # Assignment / Return / Syscall targets are names, not expressions. If the
  # caller bound `i` to the expression Variable("j"), then `i := ...` in
  # the template needs to become `j := ...`. Returns the original name when
  # the binding isn't a bare Variable (anything else would be a use error).
  def substitute_name(name, bindings)
    expression = bindings[name]
    return name unless expression&.type == :Variable
    expression.name
  end

  # Templates and bound expressions can be inserted at multiple call sites
  # within one program. A deep copy keeps each insertion independent, so a
  # later compile-time rewrite of one copy doesn't bleed into another.
  def copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
