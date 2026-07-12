# Capability cross-product for every ownership-sensitive operation supported
# by generic list, pool, set, and map collections. Scalar queries
# (length/count/empty?) are intentionally absent: they never read, copy,
# transfer, or destroy an element and therefore have no capability behavior.

require_relative "../surface_registry"

RC_GENERIC_COLLECTION_OPERATIONS = FuzzSurfaceRegistry::SURFACES.fetch(:generic_collection_operations)

RC_GENERIC_COLLECTION_CELLS = RC_GENERIC_COLLECTION_OPERATIONS.product(%i[multiowned shared]).map do |operation, capability|
  expected = :compile_error if operation.to_s.start_with?("sharded_") && capability == :multiowned
  { operation: operation, capability: capability, expected: expected || :pass }
end

def rcgc_cap(capability)
  capability == :shared ? "@shared" : "@multiowned"
end

def rcgc_list_setup(cap)
  <<~CLEAR.chomp
    MUTABLE items: RefItem#{cap}[]@list = [];
        items.append(RefItem{ value: 7_i64 } #{cap});
  CLEAR
end

def rcgc_pool_setup(cap)
  <<~CLEAR.chomp
    MUTABLE items: RefItem#{cap}[8]@pool = [];
        id = items.insert(RefItem{ value: 7_i64 } #{cap});
  CLEAR
end

def rcgc_map_setup(cap)
  <<~CLEAR.chomp
    MUTABLE items: HashMap<RefItem#{cap}> = {};
        items["item"] = RefItem{ value: 7_i64 } #{cap};
  CLEAR
end

def rcgc_set_setup(cap)
  <<~CLEAR.chomp
    MUTABLE items: RefItem#{cap}[]@set = [];
        items.insert(RefItem{ value: 7_i64 } #{cap});
  CLEAR
end

def rcgc_shared_set_key_setup
  <<~CLEAR.chomp
    MUTABLE items: RefItem@shared[]@set = [];
        item = RefItem{ value: 7_i64 } @shared;
        items.insert(COPY item);
  CLEAR
end

FuzzGenerator.register(:rc_generic_collection_matrix, cells: RC_GENERIC_COLLECTION_CELLS) do |p|
  cap = rcgc_cap(p[:capability])
  setup, exercise = case p[:operation]
  when :list_append
    [rcgc_list_setup(cap), 'IF items[0_i64] EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :list_index
    [rcgc_list_setup(cap), 'IF items[0_i64] EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    IF items[0_i64] EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :list_set
    [rcgc_list_setup(cap), 'items[0_i64] = RefItem{ value: 8_i64 } ' + cap + ';\n    IF items[0_i64] EXISTS AS item THEN ASSERT item.value == 8_i64; END']
  when :list_first
    [rcgc_list_setup(cap), 'IF items.first() EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    IF items.first() EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :list_last
    [rcgc_list_setup(cap), 'IF items.last() EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    IF items.last() EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :list_pop
    [rcgc_list_setup(cap), 'IF items.pop() EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    ASSERT items.empty?();']
  when :list_remove
    [rcgc_list_setup(cap), 'item = items.remove(0_i64);\n    ASSERT item.value == 7_i64;\n    ASSERT items.empty?();']
  when :list_clear
    [rcgc_list_setup(cap), 'items.clear();\n    ASSERT items.empty?();']
  when :list_slice
    [rcgc_list_setup(cap), 'window = items[0_i64..<1_i64];\n    ASSERT window[0_i64].value == 7_i64;\n    ASSERT items[0_i64]?.value == 7_i64;']
  when :list_copy
    [rcgc_list_setup(cap), 'copied = COPY items;\n    items.clear();\n    ASSERT copied[0_i64]?.value == 7_i64;']
  when :list_iteration
    [rcgc_list_setup(cap), 'MUTABLE total = 0_i64;\n    FOR item IN items DO total += item.value; END\n    ASSERT total == 7_i64;\n    ASSERT items[0_i64]?.value == 7_i64;']
  when :pool_insert_get
    [rcgc_pool_setup(cap), 'IF items[id] EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    IF items[id] EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :pool_remove
    [rcgc_pool_setup(cap), 'items.remove(id);\n    ASSERT items[id] == NIL;']
  when :pool_copy
    [rcgc_pool_setup(cap), 'copied = COPY items;\n    items.remove(id);\n    ASSERT copied.length() == 1_i64;']
  when :pool_iteration
    [rcgc_pool_setup(cap), 'MUTABLE total = 0_i64;\n    FOR item IN items DO total += item.value; END\n    ASSERT total == 7_i64;']
  when :set_insert_iteration
    [rcgc_set_setup(cap), 'MUTABLE total = 0_i64;\n    FOR item IN items DO total += item.value; END\n    ASSERT total == 7_i64;']
  when :set_contains
    if p[:capability] == :shared
      [rcgc_shared_set_key_setup, 'ASSERT items.contains?(item);']
    else
      [rcgc_set_setup(cap), 'probe = RefItem{ value: 8_i64 } @multiowned;\n    ASSERT !items.contains?(probe);']
    end
  when :set_index
    if p[:capability] == :shared
      [rcgc_shared_set_key_setup, 'ASSERT items[item]?.value == 7_i64;']
    else
      [rcgc_set_setup(cap), 'probe = RefItem{ value: 8_i64 } @multiowned;\n    ASSERT items[probe] == NIL;']
    end
  when :set_remove
    if p[:capability] == :shared
      [rcgc_shared_set_key_setup, 'items.remove(item);\n    ASSERT items.empty?();']
    else
      [rcgc_set_setup(cap), 'probe = RefItem{ value: 8_i64 } @multiowned;\n    items.remove(probe);\n    ASSERT items.length() == 1_i64;']
    end
  when :set_copy
    [rcgc_set_setup(cap), 'copied = COPY items;\n    ASSERT copied.length() == 1_i64;\n    ASSERT items.length() == 1_i64;']
  when :map_put_get
    [rcgc_map_setup(cap), 'IF items["item"] EXISTS AS item THEN ASSERT item.value == 7_i64; END\n    IF items["item"] EXISTS AS item THEN ASSERT item.value == 7_i64; END']
  when :map_delete
    [rcgc_map_setup(cap), 'items.delete("item");\n    ASSERT items["item"] == NIL;']
  when :map_values
    [rcgc_map_setup(cap), 'values = items.values();\n    items.delete("item");\n    ASSERT values[0]?.value == 7;']
  when :map_copy
    [rcgc_map_setup(cap), 'copied = COPY items;\n    items.delete("item");\n    ASSERT copied["item"]?.value == 7_i64;']
  when :map_iteration
    [rcgc_map_setup(cap), 'FOR key IN items DO ASSERT items[key]?.value == 7_i64; END\n    ASSERT items["item"]?.value == 7_i64;']
  when :sharded_list_copy
    ['MUTABLE items: RefItem' + cap + '[]@list:sharded(2) = [];\n    items.append(RefItem{ value: 7_i64 } ' + cap + ');',
     'copied = COPY items;\n    ASSERT copied.length() == 1_i64;']
  when :sharded_pool_copy
    ['MUTABLE items: RefItem' + cap + '[8]@pool:sharded(2) = [];\n    _ = items.insert(RefItem{ value: 7_i64 } ' + cap + ');',
     'copied = COPY items;\n    ASSERT copied.length() == 1_i64;']
  when :sharded_set_copy
    ['MUTABLE items: RefItem' + cap + '[]@set:sharded(2) = [];\n    items.insert(RefItem{ value: 7_i64 } ' + cap + ');',
     'copied = COPY items;\n    ASSERT copied.length() == 1_i64;']
  when :sharded_map_values
    ['MUTABLE items: HashMap<RefItem' + cap + '>@sharded(2) = {};\n    items["item"] = RefItem{ value: 7_i64 } ' + cap + ';',
     'values = items.values();\n    items.delete("item");\n    ASSERT values[0_i64]?.value == 7_i64;']
  when :sharded_map_keys
    ['MUTABLE items: HashMap<RefItem' + cap + '>@sharded(2) = {};\n    items["item"] = RefItem{ value: 7_i64 } ' + cap + ';',
     'keys = items.keys();\n    items.delete("item");\n    ASSERT keys[0_i64]?.length() == 4_i64;']
  when :sharded_map_copy
    ['MUTABLE items: HashMap<RefItem' + cap + '>@sharded(2) = {};\n    items["item"] = RefItem{ value: 7_i64 } ' + cap + ';',
     'copied = COPY items;\n    items.delete("item");\n    ASSERT copied["item"]?.value == 7_i64;']
  end
  setup = setup.gsub('\\n', "\n")
  exercise = exercise.gsub('\\n', "\n")

  <<~CLEAR
    STRUCT RefItem { value: Int64 }
    FN main() RETURNS Void ->
        #{setup}
        #{exercise}
        RETURN;
    END
  CLEAR
end
