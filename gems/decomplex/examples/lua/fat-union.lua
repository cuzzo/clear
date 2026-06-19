function handle(node)
  if node == AST.Call then node.line(); node.col(); node.ty(); node.span(); node.parent(); node.recv() end
  if node == AST.Func then node.line(); node.col(); node.ty(); node.span(); node.parent(); node.name() end
  if node == AST.Lit then node.line(); node.col(); node.ty(); node.span(); node.parent(); node.value() end
end
