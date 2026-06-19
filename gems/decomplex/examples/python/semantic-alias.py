def frame(node): return node.provenance == FRAME
def is_frame(node): return provenance == FRAME
def heap(node): return node.provenance == HEAP
def somewhere(node):
    if node.provenance == FRAME:
        return 1
    return 0
