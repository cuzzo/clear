# Recursive generic-copy/coercion matrix outside collection-specific APIs.
# These cells force Rc/Arc handles through optional, struct, union, and nested
# aggregate shapes and then destroy the source before observing the copy.

RC_GENERIC_VALUE_OPERATIONS = %i[
  struct_copy optional_struct_copy union_copy optional_union_copy
  list_optional_copy map_optional_values
].freeze

RC_GENERIC_VALUE_CELLS = RC_GENERIC_VALUE_OPERATIONS.product(%i[multiowned shared]).map do |operation, capability|
  { operation: operation, capability: capability }
end

FuzzGenerator.register(:rc_generic_value_matrix, cells: RC_GENERIC_VALUE_CELLS) do |p|
  cap = p[:capability] == :shared ? "@shared" : "@multiowned"
  prelude = "STRUCT RefItem { value: Int64 }\n"

  body = case p[:operation]
  when :struct_copy
    prelude += "STRUCT Holder { item: RefItem#{cap} }\n"
    <<~CLEAR
      source = Holder{ item: RefItem{ value: 7_i64 } #{cap} };
          copied = COPY source;
          ASSERT source.item.value == 7_i64;
          ASSERT copied.item.value == 7_i64;
    CLEAR
  when :optional_struct_copy
    prelude += "STRUCT Holder { item: ?RefItem#{cap} }\n"
    <<~CLEAR
      source = Holder{ item: RefItem{ value: 7_i64 } #{cap} };
          copied = COPY source;
          ASSERT source.item?.value == 7_i64;
          ASSERT copied.item?.value == 7_i64;
    CLEAR
  when :union_copy
    prelude += "UNION Choice { Empty, Item: RefItem#{cap} }\n"
    <<~CLEAR
      source: Choice = Choice{ Item: RefItem{ value: 7_i64 } #{cap} };
          copied = COPY source;
          PARTIAL MATCH copied START
              Choice.Item AS item -> ASSERT item.value == 7_i64;,
              DEFAULT -> ASSERT FALSE;
          END
    CLEAR
  when :optional_union_copy
    prelude += "UNION Choice { Empty, Item: RefItem#{cap} }\n"
    <<~CLEAR
      source: ?Choice = Choice{ Item: RefItem{ value: 7_i64 } #{cap} };
          copied: ?Choice = COPY source;
          IF copied EXISTS AS choice THEN
              PARTIAL MATCH choice START
                  Choice.Item AS item -> ASSERT item.value == 7_i64;,
                  DEFAULT -> ASSERT FALSE;
              END
          ELSE ASSERT FALSE;
          END
    CLEAR
  when :list_optional_copy
    <<~CLEAR
      MUTABLE source: ?RefItem#{cap}[]@list = [];
          &source.append(RefItem{ value: 7_i64 } #{cap});
          copied = COPY source;
          &source.clear();
          ASSERT copied[0_i64]?.value == 7_i64;
    CLEAR
  when :map_optional_values
    <<~CLEAR
      MUTABLE source: HashMap<?RefItem#{cap}> = {};
          source["item"] = RefItem{ value: 7_i64 } #{cap};
          values = source.values();
          &source.delete("item");
          ASSERT values[0]?.value == 7;
    CLEAR
  end

  <<~CLEAR
    #{prelude}FN main() RETURNS Void ->
        #{body}
        RETURN;
    END
  CLEAR
end
