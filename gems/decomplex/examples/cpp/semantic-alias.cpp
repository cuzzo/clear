bool frame(Node node) { return node.provenance == FRAME; }
bool is_frame(Node node) { return provenance == FRAME; }
bool heap(Node node) { return node.provenance == HEAP; }
int somewhere(Node node) { if (node.provenance == FRAME) { return 1; } return 0; }
