impl<'a> FileIndexer<'a> {
    fn inspect_branch_guard(&mut self, _node: Node<'_>, _inverted: bool, _frame: &mut Frame) {}

    fn provably_non_nil(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                frame.non_nil_locals.contains(&name) && !frame.maybe_nil_locals.contains(&name)
            }
            NormKind::Call => !safe_navigation(node)
                && call_name(node, self.file)
                    .is_some_and(|name| self.global.method_return_types.get(&name).is_some_and(|types| types.len() == 1 && !types.contains("NilClass"))),
            NormKind::SelfNode => true,
            _ => self.non_nil_literal(node, frame),
        }
    }

    fn non_nil_literal(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        self.static_expression_type(node, frame)
            .is_some_and(|ty| ty != "NilClass")
    }
}
