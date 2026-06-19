pub fn frame(node: Node) bool { return node.provenance == FRAME; }
pub fn is_frame(node: Node) bool { return provenance == FRAME; }
pub fn heap(node: Node) bool { return node.provenance == HEAP; }

pub fn somewhere(node: Node) i32 {
    if (node.provenance == FRAME) { return 1; }
    return 0;
}
