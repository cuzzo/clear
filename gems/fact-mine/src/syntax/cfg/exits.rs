use crate::ast::Node;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LoopExitKind {
    Break,
    Continue,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FunctionExitKind {
    Return,
    Throw,
}

impl LoopExitKind {
    pub(crate) fn edge_kind(self) -> &'static str {
        match self {
            Self::Break => "break",
            Self::Continue => "continue",
        }
    }

    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::Break => "break",
            Self::Continue => "continue",
        }
    }
}

impl FunctionExitKind {
    pub(crate) fn edge_kind(self) -> &'static str {
        match self {
            Self::Return => "return",
            Self::Throw => "throw",
        }
    }

    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::Return => "return",
            Self::Throw => "throw",
        }
    }
}

pub(crate) fn loop_exit(node: &Node) -> Option<LoopExitKind> {
    match node.r#type.as_str() {
        "BREAK" => Some(LoopExitKind::Break),
        "NEXT" | "CONTINUE" => Some(LoopExitKind::Continue),
        _ => None,
    }
}

pub(crate) fn function_exit(node: &Node) -> Option<FunctionExitKind> {
    match node.r#type.as_str() {
        "RETURN" => Some(FunctionExitKind::Return),
        "RAISE" | "THROW" | "PANIC" => Some(FunctionExitKind::Throw),
        _ => None,
    }
}

pub(crate) fn terminal_edge_kind(kind: &str) -> bool {
    matches!(kind, "return" | "throw")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_loop_exits() {
        assert_eq!(loop_exit(&node("BREAK")), Some(LoopExitKind::Break));
        assert_eq!(loop_exit(&node("NEXT")), Some(LoopExitKind::Continue));
        assert_eq!(loop_exit(&node("CONTINUE")), Some(LoopExitKind::Continue));
        assert_eq!(loop_exit(&node("RETURN")), None);
    }

    #[test]
    fn classifies_function_exits() {
        assert_eq!(
            function_exit(&node("RETURN")),
            Some(FunctionExitKind::Return)
        );
        assert_eq!(function_exit(&node("RAISE")), Some(FunctionExitKind::Throw));
        assert_eq!(function_exit(&node("THROW")), Some(FunctionExitKind::Throw));
        assert_eq!(function_exit(&node("PANIC")), Some(FunctionExitKind::Throw));
        assert_eq!(function_exit(&node("BREAK")), None);
        assert_eq!(FunctionExitKind::Throw.edge_kind(), "throw");
        assert_eq!(FunctionExitKind::Throw.role(), "throw");
        assert!(terminal_edge_kind("return"));
        assert!(terminal_edge_kind("throw"));
        assert!(!terminal_edge_kind("break"));
    }

    fn node(kind: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: kind.len(),
            text: kind.to_ascii_lowercase(),
        }
    }
}
