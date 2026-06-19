struct Node {
    storage: i32,
    provenance: i32,
}

fn stable_one(mut node: Node) {
    node.storage = 1;
    node.provenance = 1;
}

fn stable_two(mut node: Node) {
    node.storage = 1;
    node.provenance = 1;
}

fn stable_three(mut node: Node) {
    node.storage = 1;
    node.provenance = 1;
}

fn misses_provenance(mut node: Node) {
    node.storage = 1;
}
