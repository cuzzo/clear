use crate::decomplex::ast::RawNode;

pub(crate) fn named_children(node: &RawNode) -> Vec<&RawNode> {
    node.children.iter().filter(|child| child.named).collect()
}

pub(crate) fn child_by_field<'a>(node: &'a RawNode, field: &str) -> Option<&'a RawNode> {
    node.children
        .iter()
        .find(|child| child.field_name.as_deref() == Some(field))
}

pub(crate) fn first_child_kind(node: &RawNode) -> Option<String> {
    node.children.first().map(|child| child.kind.clone())
}

pub(crate) fn next_sibling_text(node: &RawNode, parent: &RawNode) -> Option<String> {
    let index = child_index(node, parent)?;
    parent
        .children
        .get(index + 1)
        .map(|sibling| sibling.text.clone())
}

pub(crate) fn next_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = pointer_child_index(node, parent)?;
    parent.children.get(index + 1)
}

pub(crate) fn previous_sibling_text(node: &RawNode, parent: &RawNode) -> Option<String> {
    let index = child_index(node, parent)?;
    index
        .checked_sub(1)
        .and_then(|previous| parent.children.get(previous))
        .map(|sibling| sibling.text.clone())
}

pub(crate) fn previous_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = pointer_child_index(node, parent)?;
    index
        .checked_sub(1)
        .and_then(|previous| parent.children.get(previous))
}

pub(crate) fn child_index(node: &RawNode, parent: &RawNode) -> Option<usize> {
    parent.children.iter().position(|child| {
        child.kind == node.kind
            && child.text == node.text
            && child.span == node.span
            && child.named == node.named
    })
}

fn pointer_child_index(node: &RawNode, parent: &RawNode) -> Option<usize> {
    parent
        .children
        .iter()
        .position(|child| std::ptr::eq(child, node))
}
