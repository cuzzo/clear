def stable_one(node)
  node.storage = :heap
  node.provenance = :heap
end

def stable_two(node)
  node.storage = :heap
  node.provenance = :heap
end

def stable_three(node)
  node.storage = :heap
  node.provenance = :heap
end

def misses_provenance(node)
  node.storage = :heap
end

def ignored_index_write(entry)
  entry[:storage] = :heap
  entry[:provenance] = :heap
end
