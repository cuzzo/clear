use crate::syntax::{local_flow::Statement, Span};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct MethodCursor {
    file: String,
    owner: String,
    function: String,
    method_line: usize,
    method_span: Span,
    statement_count: usize,
}

impl MethodCursor {
    pub(crate) fn new(
        file: &str,
        owner: &str,
        function: &str,
        method_line: usize,
        method_span: Span,
        statement_count: usize,
    ) -> Self {
        Self {
            file: file.to_string(),
            owner: owner.to_string(),
            function: function.to_string(),
            method_line,
            method_span,
            statement_count,
        }
    }

    pub(crate) fn file(&self) -> &str {
        &self.file
    }

    pub(crate) fn owner(&self) -> &str {
        &self.owner
    }

    pub(crate) fn function(&self) -> &str {
        &self.function
    }

    pub(crate) fn method_line(&self) -> usize {
        self.method_line
    }

    pub(crate) fn method_span(&self) -> Span {
        self.method_span
    }

    pub(crate) fn exit_line(&self) -> usize {
        self.method_span[2]
    }

    pub(crate) fn entry_id(&self) -> String {
        self.node_id("entry", 0, self.method_line, self.method_span[1])
    }

    pub(crate) fn statement_id(&self, statement: &Statement) -> String {
        self.node_id(
            "stmt",
            statement.index + 1,
            statement.line,
            statement.span[1],
        )
    }

    pub(crate) fn exit_id(&self) -> String {
        self.node_id(
            "exit",
            self.statement_count + 1,
            self.exit_line(),
            self.method_span[3],
        )
    }

    pub(crate) fn synthetic_id(
        &self,
        role: &str,
        path: &str,
        line: usize,
        column: usize,
    ) -> String {
        format!(
            "cfg:{}#{}:{role}:{}:{line}:{column}",
            id_part(&self.owner),
            id_part(&self.function),
            id_part(path)
        )
    }

    fn node_id(&self, role: &str, index: usize, line: usize, column: usize) -> String {
        format!(
            "cfg:{}#{}:{role}:{index}:{line}:{column}",
            id_part(&self.owner),
            id_part(&self.function)
        )
    }
}

fn id_part(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_control() || ch.is_whitespace() {
                '_'
            } else {
                ch
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn ids_are_stable_and_role_scoped() {
        let cursor = MethodCursor::new("test.rb", "Example Owner", "run now", 3, [3, 2, 7, 5], 1);
        let statement = Statement {
            index: 0,
            line: 4,
            end_line: 4,
            span: [4, 4, 4, 13],
            source: "work()".to_string(),
            reads: BTreeSet::new(),
            writes: BTreeSet::new(),
            dependencies: Vec::new(),
            co_uses: Vec::new(),
        };

        assert_eq!(cursor.entry_id(), "cfg:Example_Owner#run_now:entry:0:3:2");
        assert_eq!(
            cursor.statement_id(&statement),
            "cfg:Example_Owner#run_now:stmt:1:4:4"
        );
        assert_eq!(cursor.exit_id(), "cfg:Example_Owner#run_now:exit:2:7:5");
        assert_eq!(
            cursor.synthetic_id("stmt", "1.then.0", 5, 6),
            "cfg:Example_Owner#run_now:stmt:1.then.0:5:6"
        );
    }
}
