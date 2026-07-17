# Cross-scheduler graph operations. Managed String payloads force the guarded
# read path to materialize owned values before the lock is released.

SHARED_NODE_GRAPH_OPERATIONS = %i[
  cycle replace managed_read list_growth parallel_increment local_node_rejected
].freeze
SHARED_NODE_GRAPH_CELLS = SHARED_NODE_GRAPH_OPERATIONS.map do |operation|
  { operation: operation, expected: operation == :local_node_rejected ? :compile_error : :pass }
end

FuzzGenerator.register(:shared_node_graph_matrix, cells: SHARED_NODE_GRAPH_CELLS) do |p|
  if p[:operation] == :local_node_rejected
    next <<~CLEAR
      STRUCT LocalNode { id: Int64 }
      FN main() RETURNS Void ->
        root: LocalNode@node = LocalNode{ id: 1 };
        task: ~Int64 = BG { @parallel -> root.id; };
        NEXT task;
      END
    CLEAR
  end

  body = case p[:operation]
  when :cycle
    'MUTABLE root: Node@shared:node = Node{ id: 1, name: COPY "root" }; root.left = Node{ id: 2, name: COPY "child" }; root.left?.left = root; ASSERT root.left?.left?.id == 1;'
  when :replace
    'MUTABLE root: Node@shared:node = Node{ id: 1, name: COPY "root" }; root.left = Node{ id: 2, name: COPY "old" }; root.left = Node{ id: 3, name: COPY "new" }; ASSERT root.left?.name == "new";'
  when :managed_read
    'MUTABLE root: Node@shared:node = Node{ id: 1, name: COPY "managed" }; snapshot = COPY root.name; root.name = COPY "changed"; ASSERT snapshot == "managed"; ASSERT root.name == "changed";'
  when :list_growth
    <<~CLEAR.chomp
      MUTABLE root: Node@shared:node = Node{ id: 1, name: COPY "root" };
      MUTABLE i = 0_i64;
      WHILE i < 5000_i64 DO
        &root.children.append(Node{ id: i + 2_i64, name: i.toString() });
        i += 1_i64;
      END
      ASSERT root.children.length() == 5000_i64;
      ASSERT root.children[4999]?.id == 5001_i64;
    CLEAR
  when :parallel_increment
    <<~CLEAR.chomp
      MUTABLE root: Node@shared:node = Node{ id: 0, name: COPY "root" };
      first: ~Void = BG { @parallel -> root.id = root.id + 1_i64; };
      second: ~Void = BG { @parallel -> root.id = root.id + 1_i64; };
      NEXT first;
      NEXT second;
      ASSERT root.id == 2_i64;
    CLEAR
  end

  <<~CLEAR
    STRUCT Node {
      left: ?Node@shared:node,
      children: Node@shared:node[]@list,
      id: Int64,
      name: String
    }
    FN main() RETURNS Void ->
      #{body}
      RETURN;
    END
  CLEAR
end
