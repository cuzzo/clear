use crate::ast::RawNode;

pub(crate) fn named_children(node: &RawNode) -> Vec<&RawNode> {
    node.children.iter().filter(|child| child.named).collect()
}

pub(crate) fn child_by_field<'a>(node: &'a RawNode, field: &str) -> Option<&'a RawNode> {
    node.children
        .iter()
        .find(|child| child.field_name.as_deref() == Some(field))
}

pub(crate) fn next_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = pointer_child_index(node, parent)?;
    parent.children.get(index + 1)
}

pub(crate) fn previous_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = pointer_child_index(node, parent)?;
    index
        .checked_sub(1)
        .and_then(|previous| parent.children.get(previous))
}

fn pointer_child_index(node: &RawNode, parent: &RawNode) -> Option<usize> {
    parent
        .children
        .iter()
        .position(|child| std::ptr::eq(child, node))
}
