use super::{ControlFlowNode, MethodCursor};
use crate::ast::{self, Node};
use crate::syntax::local_flow::Statement;
use crate::syntax::Span;

pub(crate) fn entry_node(cursor: &MethodCursor) -> ControlFlowNode {
    ControlFlowNode {
        id: cursor.entry_id(),
        file: cursor.file().to_string(),
        function: cursor.function().to_string(),
        owner: cursor.owner().to_string(),
        kind: "entry".to_string(),
        role: "function_entry".to_string(),
        line: cursor.method_line(),
        span: cursor.method_span(),
        source: String::new(),
    }
}

pub(crate) fn statement_node(cursor: &MethodCursor, statement: &Statement) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "statement",
        "linear_statement",
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn branch_statement_node(
    cursor: &MethodCursor,
    statement: &Statement,
    branch_kind: &str,
) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "branch",
        &format!("{branch_kind}_condition"),
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn case_statement_node(
    cursor: &MethodCursor,
    statement: &Statement,
    case_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "case",
        case_role,
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn callback_statement_node(
    cursor: &MethodCursor,
    statement: &Statement,
    callback_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "callback",
        callback_role,
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn exception_statement_node(
    cursor: &MethodCursor,
    statement: &Statement,
    exception_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "exception",
        exception_role,
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn nested_statement_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "statement",
        "linear_statement",
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn nested_branch_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    branch_kind: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "branch",
        &format!("{branch_kind}_condition"),
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn nested_case_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    case_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "case",
        case_role,
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn nested_callback_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    callback_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "callback",
        callback_role,
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn nested_exception_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    exception_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "exception",
        exception_role,
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn loop_statement_node(
    cursor: &MethodCursor,
    statement: &Statement,
    loop_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        cursor.statement_id(statement),
        "loop",
        loop_role,
        statement.line,
        statement.span,
        statement.source.clone(),
    )
}

pub(crate) fn nested_loop_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    loop_role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "loop",
        loop_role,
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn control_exit_node(
    cursor: &MethodCursor,
    id: String,
    source_node: &Node,
    role: &str,
) -> ControlFlowNode {
    node(
        cursor,
        id,
        "jump",
        role,
        source_node.first_lineno,
        span(source_node),
        ast::normalize_text(&source_node.text),
    )
}

pub(crate) fn exit_node(cursor: &MethodCursor) -> ControlFlowNode {
    ControlFlowNode {
        id: cursor.exit_id(),
        file: cursor.file().to_string(),
        function: cursor.function().to_string(),
        owner: cursor.owner().to_string(),
        kind: "exit".to_string(),
        role: "function_exit".to_string(),
        line: cursor.exit_line(),
        span: cursor.method_span(),
        source: String::new(),
    }
}

fn node(
    cursor: &MethodCursor,
    id: String,
    kind: &str,
    role: &str,
    line: usize,
    span: Span,
    source: String,
) -> ControlFlowNode {
    ControlFlowNode {
        id,
        file: cursor.file().to_string(),
        function: cursor.function().to_string(),
        owner: cursor.owner().to_string(),
        kind: kind.to_string(),
        role: role.to_string(),
        line,
        span,
        source,
    }
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn statement_nodes_preserve_source_location() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 5, 5], 1);
        let node = statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 4,
                span: [4, 4, 4, 13],
                source: "work()".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
        );

        assert_eq!(node.kind, "statement");
        assert_eq!(node.role, "linear_statement");
        assert_eq!(node.line, 4);
        assert_eq!(node.span, [4, 4, 4, 13]);
        assert_eq!(node.source, "work()");
    }

    #[test]
    fn branch_nodes_preserve_condition_role() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 7, 5], 1);
        let node = branch_statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 6,
                span: [4, 4, 6, 7],
                source: "if ready? work() end".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
            "if",
        );

        assert_eq!(node.kind, "branch");
        assert_eq!(node.role, "if_condition");
    }

    #[test]
    fn loop_nodes_preserve_loop_role() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 7, 5], 1);
        let node = loop_statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 6,
                span: [4, 4, 6, 7],
                source: "while ready? work() end".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
            "while_loop",
        );

        assert_eq!(node.kind, "loop");
        assert_eq!(node.role, "while_loop");
    }

    #[test]
    fn case_nodes_preserve_case_role() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 8, 5], 1);
        let node = case_statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 7,
                span: [4, 4, 7, 7],
                source: "case role when :owner work() end".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
            "case_dispatch",
        );

        assert_eq!(node.kind, "case");
        assert_eq!(node.role, "case_dispatch");
    }

    #[test]
    fn callback_nodes_preserve_callback_role() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 8, 5], 1);
        let node = callback_statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 7,
                span: [4, 4, 7, 7],
                source: "transaction { work() }".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
            "callback_region",
        );

        assert_eq!(node.kind, "callback");
        assert_eq!(node.role, "callback_region");
    }

    #[test]
    fn exception_nodes_preserve_exception_role() {
        let cursor = MethodCursor::new("test.rb", "Example", "run", 3, [3, 2, 8, 5], 1);
        let node = exception_statement_node(
            &cursor,
            &Statement {
                index: 0,
                line: 4,
                end_line: 7,
                span: [4, 4, 7, 7],
                source: "begin work() rescue recover() end".to_string(),
                reads: BTreeSet::new(),
                writes: BTreeSet::new(),
                dependencies: Vec::new(),
                co_uses: Vec::new(),
            },
            "rescue_region",
        );

        assert_eq!(node.kind, "exception");
        assert_eq!(node.role, "rescue_region");
    }
}
