def handle(node):
    match node:
        case AST.Call:
            node.line(); node.col(); node.ty(); node.span(); node.parent(); node.recv()
        case AST.Func:
            node.line(); node.col(); node.ty(); node.span(); node.parent(); node.name()
        case AST.Lit:
            node.line(); node.col(); node.ty(); node.span(); node.parent(); node.value()
