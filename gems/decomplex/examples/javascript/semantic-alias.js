function frame(node) { return node.provenance == FRAME; }
function is_frame(node) { return provenance == FRAME; }
function heap(node) { return node.provenance == HEAP; }
function somewhere(node) { if (node.provenance == FRAME) { return 1; } return 0; }
