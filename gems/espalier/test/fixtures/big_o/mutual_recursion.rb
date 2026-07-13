def mutual_a(items)
  items.each { mutual_b(items) }
end

def mutual_b(items)
  items.each { mutual_a(items) }
end

def call_mutual(items)
  mutual_a(items)
end
