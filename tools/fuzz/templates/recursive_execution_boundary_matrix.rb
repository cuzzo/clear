# Recursive @parallel admission matrix. A boundary decision must inspect the
# complete captured type, not only the binding's outer capability.

REB_SHAPES = %i[struct nested_struct optional list map union inline_union].freeze
REB_CAPABILITIES = %i[multiowned shared].freeze

REB_CELLS = REB_SHAPES.product(REB_CAPABILITIES).map do |shape, capability|
  {
    shape: shape,
    capability: capability,
    expected: capability == :multiowned ? :compile_error : :pass,
  }
end

FuzzGenerator.register(:recursive_execution_boundary_matrix, cells: REB_CELLS) do |p|
  cap = p[:capability] == :shared ? "@shared" : "@multiowned"
  declarations, holder_type, holder_value = case p[:shape]
  when :struct
    ["STRUCT Holder { item: Item#{cap} }", "Holder", "Holder{ item: Item{ value: 7 } #{cap} }"]
  when :nested_struct
    ["STRUCT Inner { item: Item#{cap} }\nSTRUCT Holder { inner: Inner }", "Holder", "Holder{ inner: Inner{ item: Item{ value: 7 } #{cap} } }"]
  when :optional
    ["STRUCT Holder { item: ?Item#{cap} }", "Holder", "Holder{ item: Item{ value: 7 } #{cap} }"]
  when :list
    ["", "Item#{cap}[]@list", "[Item{ value: 7 } #{cap}]"]
  when :map
    ["", "HashMap<Item#{cap}>", "{ \"item\": Item{ value: 7 } #{cap} }"]
  when :union
    ["UNION Holder { Empty, ItemValue: Item#{cap} }", "Holder", "Holder{ ItemValue: Item{ value: 7 } #{cap} }"]
  when :inline_union
    ["UNION Holder { Empty, Wrapped { item: Item#{cap} } }", "Holder", "Holder.Wrapped{ item: Item{ value: 7 } #{cap} }"]
  end

  <<~CLEAR
    STRUCT Item { value: Int64 }
    #{declarations}
    FN consume(value: #{holder_type}) RETURNS Void -> RETURN; END
    FN main() RETURNS Void ->
        holder: #{holder_type} = #{holder_value};
        task: ~Void = BG { @parallel -> consume(holder); };
        NEXT task;
        RETURN;
    END
  CLEAR
end
