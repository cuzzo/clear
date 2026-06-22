fn frame(node: Node) -> bool { node.provenance == FRAME }
fn is_frame(node: Node) -> bool { provenance == FRAME }
fn heap(node: Node) -> bool { node.provenance == HEAP }

fn somewhere(node: Node) -> i32 {
    if node.provenance == FRAME { return 1; }
    0
}
