struct Statement;
struct Function { statements: Vec<Statement> }
struct Document { functions: Vec<Function> }

fn walk_documents(documents: &[Document]) {
    for document in documents {
        for function in &document.functions {
            for statement in &function.statements {
                consume(statement);
            }
        }
    }
}
