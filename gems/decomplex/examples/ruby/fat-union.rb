# frozen_string_literal: true

def handle(node)
  case node
  when AST::Call
    node.line
    node.col
    node.ty
    node.span
    node.parent
    node.recv
  when AST::Func
    node.line
    node.col
    node.ty
    node.span
    node.parent
    node.name
  when AST::Lit
    node.line
    node.col
    node.ty
    node.span
    node.parent
    node.value
  end
end
