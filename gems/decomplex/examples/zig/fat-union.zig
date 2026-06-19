pub fn handle(node: Ast) void {
    switch (node) {
        AST.Call => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.recv();
        },
        AST.Func => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.name();
        },
        AST.Lit => {
            node.line();
            node.col();
            node.ty();
            node.span();
            node.parent();
            node.value();
        },
    }
}
