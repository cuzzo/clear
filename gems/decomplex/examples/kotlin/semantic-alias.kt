fun frame(node: Node): Boolean { return node.provenance == FRAME }
fun is_frame(node: Node): Boolean { return provenance == FRAME }
fun heap(node: Node): Boolean { return node.provenance == HEAP }
fun somewhere(node: Node): Int { if (node.provenance == FRAME) { return 1 }; return 0 }
