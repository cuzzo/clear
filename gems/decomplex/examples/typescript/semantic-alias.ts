function frame(node: Node): boolean { return node.provenance == FRAME; }
function is_frame(node: Node): boolean { return provenance == FRAME; }
function heap(node: Node): boolean { return node.provenance == HEAP; }
function somewhere(node: Node): number { if (node.provenance == FRAME) { return 1; } return 0; }
