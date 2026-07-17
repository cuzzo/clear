# Stateful @node graph operations. Managed String payloads make every cell a
# cleanup/leak oracle in addition to a handle/topology check.

NODE_GRAPH_OPERATIONS = %i[self_cycle cycle replace optional_chain list_growth existing_handle nested_scope].freeze
NODE_GRAPH_CELLS = NODE_GRAPH_OPERATIONS.map { |operation| { operation: operation } }

FuzzGenerator.register(:node_graph_matrix, cells: NODE_GRAPH_CELLS) do |p|
  body = case p[:operation]
  when :self_cycle
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"root\" }; root.left = root; ASSERT root.left?.id == 1;"
  when :cycle
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"root\" }; root.left = Node{ id: 2, name: COPY \"child\" }; root.left?.left = root; ASSERT root.left?.left?.id == 1;"
  when :replace
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"root\" }; root.left = Node{ id: 2, name: COPY \"old\" }; root.left = Node{ id: 3, name: COPY \"new\" }; ASSERT root.left?.name == \"new\";"
  when :optional_chain
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"root\" }; root.left = Node{ id: 2, name: COPY \"left\" }; root.left?.right = Node{ id: 3, name: COPY \"right\" }; ASSERT root.left?.right?.id == 3;"
  when :list_growth
    <<~CLEAR.chomp
      MUTABLE root: Node@node = Node{ id: 1, name: COPY "root" };
          MUTABLE i = 0_i64;
          WHILE i < 5000_i64 DO
              &root.children.append(Node{ id: i + 2_i64, name: i.toString() });
              i += 1_i64;
          END
          ASSERT root.children.length() == 5000_i64;
          ASSERT root.children[4999]?.id == 5001_i64;
    CLEAR
  when :existing_handle
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"root\" }; &root.children.append(Node{ id: 2, name: COPY \"child\" }); IF root.children[0] EXISTS AS child THEN root.left = child; END ASSERT root.left?.id == 2;"
  when :nested_scope
    "MUTABLE root: Node@node = Node{ id: 1, name: COPY \"outer\" }; IF TRUE THEN root.left = Node{ id: 2, name: COPY \"inner\" }; END ASSERT root.left?.name == \"inner\";"
  end

  <<~CLEAR
    STRUCT Node {
      left: ?Node@node,
      right: ?Node@node,
      children: Node@node[]@list,
      id: Int64,
      name: String
    }
    FN main() RETURNS Void ->
        #{body}
        RETURN;
    END
  CLEAR
end
