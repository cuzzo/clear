const Node = struct {
    storage: i32,
    provenance: i32,
};

pub fn stable_one(node: *Node) void {
    node.storage = 1;
    node.provenance = 1;
}

pub fn stable_two(node: *Node) void {
    node.storage = 1;
    node.provenance = 1;
}

pub fn stable_three(node: *Node) void {
    node.storage = 1;
    node.provenance = 1;
}

pub fn misses_provenance(node: *Node) void {
    node.storage = 1;
}
