# Stateful collection sequences cover overwrite cleanup, numeric/string map
# parity, copy/materialization, and mutation while an element borrow is live.

SCM_MAP_KEYS = %i[string numeric].freeze
SCM_CAPS = %i[multiowned shared].freeze
SCM_OPERATIONS = %i[overwrite delete_reinsert copy_values].freeze

SCM_CELLS = SCM_MAP_KEYS.product(SCM_CAPS, SCM_OPERATIONS).map do |key_kind, capability, operation|
  { key_kind: key_kind, capability: capability, operation: operation }
end
SCM_CELLS.concat([
  { key_kind: :list, capability: :multiowned, operation: :borrow_then_clear, expected: :compile_error },
  { key_kind: :list, capability: :shared, operation: :borrow_then_overwrite, expected: :compile_error },
  { key_kind: :string, capability: :multiowned, operation: :borrow_then_delete, expected: :compile_error },
  { key_kind: :numeric, capability: :shared, operation: :borrow_then_overwrite, expected: :compile_error },
])

FuzzGenerator.register(:stateful_container_matrix, cells: SCM_CELLS) do |p|
  cap = p[:capability] == :shared ? "@shared" : "@multiowned"
  if p[:key_kind] == :list
    mutation = p[:operation] == :borrow_then_clear ? "items.clear();" : "items[0] = Managed{ text: COPY \"new\" } #{cap};"
    body = <<~CLEAR.chomp
      MUTABLE items: Managed#{cap}[]@list = [];
          items.append(Managed{ text: COPY "old" } #{cap});
          IF items[0] EXISTS AS borrowed THEN
              #{mutation}
              ASSERT borrowed.text == "old";
          END
    CLEAR
  else
    numeric = p[:key_kind] == :numeric
    map_type = numeric ? "HashMap<Int64, Managed#{cap}>" : "HashMap<Managed#{cap}>"
    key = numeric ? "7_i64" : '"key"'
    body = case p[:operation]
    when :overwrite
      "MUTABLE items: #{map_type} = {}; items[#{key}] = Managed{ text: COPY \"old\" } #{cap}; items[#{key}] = Managed{ text: COPY \"new\" } #{cap}; ASSERT items[#{key}]?.text == \"new\";"
    when :delete_reinsert
      "MUTABLE items: #{map_type} = {}; items[#{key}] = Managed{ text: COPY \"first\" } #{cap}; items.delete(#{key}); items[#{key}] = Managed{ text: COPY \"second\" } #{cap}; ASSERT items[#{key}]?.text == \"second\";"
    when :copy_values
      "MUTABLE items: #{map_type} = {}; items[#{key}] = Managed{ text: COPY \"copy\" } #{cap}; copied = COPY items; values = items.values(); items.delete(#{key}); ASSERT copied[#{key}]?.text == \"copy\"; ASSERT values[0]?.text == \"copy\";"
    when :borrow_then_delete
      "MUTABLE items: #{map_type} = {}; items[#{key}] = Managed{ text: COPY \"old\" } #{cap}; IF items[#{key}] EXISTS AS borrowed THEN items.delete(#{key}); ASSERT borrowed.text == \"old\"; END"
    when :borrow_then_overwrite
      "MUTABLE items: #{map_type} = {}; items[#{key}] = Managed{ text: COPY \"old\" } #{cap}; IF items[#{key}] EXISTS AS borrowed THEN items[#{key}] = Managed{ text: COPY \"new\" } #{cap}; ASSERT borrowed.text == \"old\"; END"
    end
  end

  <<~CLEAR
    STRUCT Managed { text: String }
    FN main() RETURNS Void ->
        #{body}
        RETURN;
    END
  CLEAR
end
