# Template: Tuple x collection/capability composition matrix.
#
# Tuple is a structural product, so it must compose recursively in both
# directions: collections may contain Tuple values, and Tuple fields may be
# collections. These are end-to-end cells rather than parser-only examples;
# each positive cell constructs the shape and observes a positional field.

TUPLE_COLLECTION_COMPOSITION_CELLS = %i[
  fixed_of_tuple
  list_of_tuple
  pool_of_tuple
  set_of_tuple
  map_of_tuple
  stream_of_tuple
  tuple_of_fixed
  tuple_of_list
  tuple_of_pool
  tuple_of_set
  tuple_of_map
  tuple_of_capable_collections
  optional_tuple
  tuple_optional_item
  fallible_tuple
  tuple_fallible_item
  future_tuple
  tuple_future_item
  tuple_of_tensed_collections
].map { |composition| { composition: composition } }.freeze

FuzzGenerator.register(
  :tuple_collection_composition_matrix,
  cells: TUPLE_COLLECTION_COMPOSITION_CELLS,
) do |p|
  body = case p[:composition]
  when :fixed_of_tuple
    <<~CLEAR
      values: [2]Tuple<Int64, Bool> = [Tuple{1_i64, TRUE}, Tuple{2_i64, FALSE}];
      ASSERT values[1_i64]._0 == 2_i64, "fixed array of Tuple";
      ASSERT !(values[1_i64]._1), "fixed array Tuple field";
    CLEAR
  when :list_of_tuple
    <<~CLEAR
      MUTABLE values: [List]Tuple<Int64, Bool> = List[];
      values.append(Tuple{3_i64, TRUE});
      IF values[0_i64] EXISTS AS item THEN
          ASSERT item._0 == 3_i64, "List of Tuple";
          ASSERT item._1, "List Tuple field";
      ELSE
          ASSERT FALSE, "List Tuple item exists";
      END
    CLEAR
  when :pool_of_tuple
    <<~CLEAR
      MUTABLE values: [Pool(4)]Tuple<Int64, Bool> = Pool[];
      id = values.insert(Tuple{4_i64, TRUE});
      IF values[id] EXISTS AS item THEN
          ASSERT item._0 == 4_i64, "Pool of Tuple";
      ELSE
          ASSERT FALSE, "Pool Tuple item exists";
      END
    CLEAR
  when :set_of_tuple
    <<~CLEAR
      MUTABLE values: [Set]Tuple<Int64, Bool> = Set[];
      item = Tuple{5_i64, TRUE};
      values.insert(COPY item);
      ASSERT values.contains?(item), "Set of Tuple";
    CLEAR
  when :map_of_tuple
    <<~CLEAR
      MUTABLE values: {String}Tuple<Int64, Bool> = {};
      values["item"] = Tuple{6_i64, TRUE};
      IF values["item"] EXISTS AS item THEN
          ASSERT item._0 == 6_i64, "map of Tuple";
      ELSE
          ASSERT FALSE, "map Tuple item exists";
      END
    CLEAR
  when :stream_of_tuple
    ""
  when :tuple_of_fixed
    <<~CLEAR
      value: Tuple<[2]Int64, Bool> = Tuple{[9_i64, 10_i64], TRUE};
      ASSERT value._0[1_i64] == 10_i64, "Tuple of fixed array";
    CLEAR
  when :tuple_of_list
    <<~CLEAR
      value: Tuple<[List]Int64, Bool> = Tuple{List[], TRUE};
      ASSERT value._0.length() == 0_i64, "Tuple of List";
    CLEAR
  when :tuple_of_pool
    <<~CLEAR
      MUTABLE items: [Pool(4)]Int64 = Pool[];
      id = items.insert(12_i64);
      MUTABLE value: Tuple<[Pool(4)]Int64, Bool> = Tuple{GIVE items, TRUE};
      ASSERT value._0.length() == 1_i64, "Tuple of Pool";
    CLEAR
  when :tuple_of_set
    <<~CLEAR
      MUTABLE items: [Set]Int64 = Set[];
      items.insert(13_i64);
      value: Tuple<[Set]Int64, Bool> = Tuple{GIVE items, TRUE};
      ASSERT value._0.contains?(13_i64), "Tuple of Set";
    CLEAR
  when :tuple_of_map
    <<~CLEAR
      MUTABLE items: {String}Int64 = {};
      items["item"] = 14_i64;
      value: Tuple<{String}Int64, Bool> = Tuple{GIVE items, TRUE};
      ASSERT (value._0["item"] OR_ELSE 0_i64) == 14_i64, "Tuple of map";
    CLEAR
  when :tuple_of_capable_collections
    ""
  when :optional_tuple
    <<~CLEAR
      value: ?Tuple<Int64, Bool> = Tuple{15_i64, TRUE};
      IF value EXISTS AS item THEN
          ASSERT item._0 == 15_i64, "optional Tuple";
      ELSE
          ASSERT FALSE, "optional Tuple exists";
      END
    CLEAR
  when :tuple_optional_item
    <<~CLEAR
      value: Tuple<?Int64, Bool> = Tuple{NIL, TRUE};
      ASSERT value._0 == NIL, "Tuple optional item";
    CLEAR
  when :fallible_tuple
    <<~CLEAR
      value: Tuple<Int64, Bool> = makeFallibleTuple() OR_ELSE RAISE;
      ASSERT value._0 == 16_i64, "fallible Tuple";
    CLEAR
  when :tuple_fallible_item
    <<~CLEAR
      value: Tuple<!Int64, Bool> = Tuple{makeFallibleNumber(), TRUE};
      number: Int64 = value._0 OR_ELSE RAISE;
      ASSERT number == 17_i64, "Tuple fallible item";
    CLEAR
  when :future_tuple, :tuple_future_item, :tuple_of_tensed_collections
    ""
  else
    raise "unknown Tuple collection composition #{p[:composition].inspect}"
  end

  if p[:composition] == :stream_of_tuple
    next <<~CLEAR
      FN makeTupleStream() RETURNS [~INF]Tuple<Int64, Bool> ->
          RETURN BG STREAM YIELDS Tuple<Int64, Bool> {
              YIELD Tuple{7_i64, TRUE};
              WHILE TRUE DO YIELD Tuple{8_i64, FALSE}; END
          };
      END

      FN main() RETURNS Void ->
          RETURN;
      END
    CLEAR
  end

  if p[:composition] == :tuple_of_capable_collections
    next <<~CLEAR
      FN acceptCapableTuple(value: Tuple<[List]@shared Int64, {String}@sharded(2) Bool>) RETURNS Void ->
          RETURN;
      END

      FN main() RETURNS Void ->
          RETURN;
      END
    CLEAR
  end

  if p[:composition] == :future_tuple
    next <<~CLEAR
      FN acceptFutureTuple(value: ~Tuple<Int64, Bool>) RETURNS Void ->
          item: Tuple<Int64, Bool> = NEXT value;
          ASSERT item._0 == 18_i64, "future Tuple payload";
          RETURN;
      END

      FN main() RETURNS Void ->
          RETURN;
      END
    CLEAR
  end

  if p[:composition] == :tuple_future_item
    next <<~CLEAR
      FN acceptTupleFuture(TAKES value: Tuple<~Int64, Bool>) RETURNS Void ->
          number: Int64 = NEXT value._0;
          ASSERT number == 19_i64, "Tuple future item";
          RETURN;
      END

      FN main() RETURNS Void ->
          RETURN;
      END
    CLEAR
  end

  if p[:composition] == :tuple_of_tensed_collections
    next <<~CLEAR
      FN acceptTensedTuple(
          value: Tuple<?[List]Int64, [List]?Int64, !{String}Int64, {String}!Int64, ~[List]Int64, [List]~Int64>
      ) RETURNS Void ->
          RETURN;
      END

      FN main() RETURNS Void ->
          RETURN;
      END
    CLEAR
  end

  helpers = case p[:composition]
  when :fallible_tuple
    <<~CLEAR
      FN makeFallibleTuple() RETURNS !Tuple<Int64, Bool> ->
          RETURN Tuple{16_i64, TRUE};
      END
    CLEAR
  when :tuple_fallible_item
    <<~CLEAR
      FN makeFallibleNumber() RETURNS !Int64 ->
          RETURN 17_i64;
      END
    CLEAR
  else
    ""
  end

  <<~CLEAR
    #{helpers}
    FN main() RETURNS Void ->
    #{body.lines.map { |line| "    #{line}" }.join}    RETURN;
    END
  CLEAR
end
