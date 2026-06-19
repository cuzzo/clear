func frame(node: Node) -> Bool { return node.provenance == FRAME }
func is_frame(node: Node) -> Bool { return provenance == FRAME }
func heap(node: Node) -> Bool { return node.provenance == HEAP }
func somewhere(node: Node) -> Int { if node.provenance == FRAME { return 1 }; return 0 }
