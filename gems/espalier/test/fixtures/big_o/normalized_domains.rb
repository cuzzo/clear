def indexed_children(buckets)
  buckets.each_key do |key|
    buckets[key].each { |item| consume(item) }
  end
end

def unknown_result_sizes(paths, input)
  paths.each do |path|
    rows = lookup(path, input)
    rows.each do |row|
      edits = choose(row, input)
      edits.each { |edit| consume(edit) }
    end
  end
end

def non_iterator_wrapper(items)
  with_context { items.each { |item| consume(item) } }
end


def callback_result(paths, input)
  paths.each { |path| classify(path, input).map { |row| consume(row) } }
end


sig { params(items: Array).returns(Array) }
def repeated_sort(items)
  items.each { items.sort }
end


def linear_helper(items)
  items.each { |item| consume(item) }
end

def repeated_helper(items)
  items.each { linear_helper(items) }
end


sig { params(items: Array).returns(Array) }
def unknown_collection_call(items)
  items.each { transform(items) }
end

def allocate_helper(items)
  items.map { |item| consume(item) }
end

def call_allocate_helper(items)
  allocate_helper(items)
end

def scan_partition(items)
  items.each { |item| consume(item) }
end

def scan_partitions(groups)
  groups.each { |group| scan_partition(group) }
end
