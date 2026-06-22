function frame(node) return node.provenance == FRAME end
function is_frame(node) return provenance == FRAME end
function heap(node) return node.provenance == HEAP end
function somewhere(node) if node.provenance == FRAME then return 1 end return 0 end
