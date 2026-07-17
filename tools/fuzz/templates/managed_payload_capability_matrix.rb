# Rc/Arc generic operations over payloads that themselves own heap memory.
# This is deliberately separate from rc_generic_*'s Int64 payload so a missing
# recursive destructor or structural retain cannot hide behind a trivial T.

MPC_OPERATIONS = %i[
  direct optional struct union list_append list_overwrite list_copy map_put
  map_overwrite map_values map_copy
].freeze

MPC_CELLS = MPC_OPERATIONS.product(%i[multiowned shared]).map do |operation, capability|
  { operation: operation, capability: capability }
end

FuzzGenerator.register(:managed_payload_capability_matrix, cells: MPC_CELLS) do |p|
  cap = p[:capability] == :shared ? "@shared" : "@multiowned"
  body = case p[:operation]
  when :direct
    "item = Managed{ text: COPY \"direct\" } #{cap}; ASSERT item.text == \"direct\";"
  when :optional
    "item: ?Managed#{cap} = Managed{ text: COPY \"optional\" } #{cap}; ASSERT item?.text == \"optional\";"
  when :struct
    "holder = Holder{ item: Managed{ text: COPY \"struct\" } #{cap} }; copied = COPY holder; ASSERT copied.item.text == \"struct\";"
  when :union
    <<~CLEAR.chomp
      choice: Choice = Choice{ Item: Managed{ text: COPY "union" } #{cap} };
          copied = COPY choice;
          PARTIAL MATCH copied START
              Choice.Item AS item -> ASSERT item.text == "union";,
              DEFAULT -> ASSERT FALSE;
          END
    CLEAR
  when :list_append
    "MUTABLE items: Managed#{cap}[]@list = []; &items.append(Managed{ text: COPY \"append\" } #{cap}); ASSERT items[0]?.text == \"append\";"
  when :list_overwrite
    "MUTABLE items: Managed#{cap}[]@list = [Managed{ text: COPY \"old\" } #{cap}]; items[0] = Managed{ text: COPY \"new\" } #{cap}; ASSERT items[0]?.text == \"new\";"
  when :list_copy
    "MUTABLE items: Managed#{cap}[]@list = [Managed{ text: COPY \"copy\" } #{cap}]; copied = COPY items; &items.clear(); ASSERT copied[0]?.text == \"copy\";"
  when :map_put
    "MUTABLE items: HashMap<Managed#{cap}> = {}; items[\"k\"] = Managed{ text: COPY \"put\" } #{cap}; ASSERT items[\"k\"]?.text == \"put\";"
  when :map_overwrite
    "MUTABLE items: HashMap<Managed#{cap}> = {}; items[\"k\"] = Managed{ text: COPY \"old\" } #{cap}; items[\"k\"] = Managed{ text: COPY \"new\" } #{cap}; ASSERT items[\"k\"]?.text == \"new\";"
  when :map_values
    "MUTABLE items: HashMap<Managed#{cap}> = {}; items[\"k\"] = Managed{ text: COPY \"values\" } #{cap}; values = items.values(); &items.delete(\"k\"); ASSERT values[0]?.text == \"values\";"
  when :map_copy
    "MUTABLE items: HashMap<Managed#{cap}> = {}; items[\"k\"] = Managed{ text: COPY \"mapcopy\" } #{cap}; copied = COPY items; &items.delete(\"k\"); ASSERT copied[\"k\"]?.text == \"mapcopy\";"
  end

  <<~CLEAR
    STRUCT Managed { text: String }
    STRUCT Holder { item: Managed#{cap} }
    UNION Choice { Empty, Item: Managed#{cap} }
    FN main() RETURNS Void ->
        #{body}
        RETURN;
    END
  CLEAR
end
