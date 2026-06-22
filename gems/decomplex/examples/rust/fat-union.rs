fn handle(node: Ast) {
    match node {
        AST::Call => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.recv();
        }
        AST::Func => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.name();
        }
        AST::Lit => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.value();
        }
    }
}
