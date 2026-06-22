package main
func frame(node Node) bool { return node.provenance == FRAME }
func is_frame(node Node) bool { return provenance == FRAME }
func heap(node Node) bool { return node.provenance == HEAP }
func somewhere(node Node) int { if node.provenance == FRAME { return 1 }; return 0 }
