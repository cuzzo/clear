# Template: collection-shape smoke matrix.
#
# Keeps the fuzz harness honest about every collection shape named in
# FuzzSurfaceRegistry::SURFACES[:collection_shapes]. These cells are small
# end-to-end programs: construct the collection, perform its canonical mutation
# and readback path, and assert the observable result.
#
# This intentionally complements the deeper ownership templates. It does not
# try to cross every collection with every escape sink; it prevents a broad
# shape from being listed in the registry while no fuzz cell even instantiates
# it.

COLLECTION_SHAPE_SMOKE_CELLS = [
  { shape: :dynamic_array },
  { shape: :list },
  { shape: :string_list },
  { shape: :pool },
  { shape: :set },
  { shape: :hash_map },
  { shape: :sharded_list },
  { shape: :sharded_pool },
  { shape: :sharded_set },
  { shape: :sharded_hash_map },
  { shape: :soa_list },
  { shape: :soa_pool },
  { shape: :constructor_modifiers },
  { shape: :nested_collection },
]

FuzzGenerator.register(:collection_shape_smoke, cells: COLLECTION_SHAPE_SMOKE_CELLS) do |p|
  case p[:shape]
  when :dynamic_array
    <<~CHT
      FN main() RETURNS Void ->
          vals: Int64[] = [1_i64, 2_i64, 3_i64];
          ASSERT length(vals) == 3_i64, "dynamic array length";
          ASSERT vals[0_i64] == 1_i64, "dynamic array first";
          RETURN;
      END
    CHT

  when :list
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = [];
          vals.append(1_i64);
          vals.append(2_i64);
          vals.append(3_i64);
          ASSERT vals.length() == 3_i64, "list length";
          ASSERT vals[2_i64] == 3_i64, "list index";
          RETURN;
      END
    CHT

  when :string_list
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: String[]@list = List[];
          vals.append(COPY "alpha");
          vals.append(COPY "beta");
          ASSERT vals.length() == 2_i64, "string list length";
          ASSERT vals[1_i64] == "beta", "string list index";
          RETURN;
      END
    CHT

  when :pool
    <<~CHT
      STRUCT Item { value: Int64 }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool = [];
          id = pool.insert(Item{ value: 42_i64 });
          ASSERT pool.length() == 1_i64, "pool length";
          IF pool[id] AS item THEN
              ASSERT item.value == 42_i64, "pool readback";
          ELSE
              ASSERT FALSE, "pool handle should be live";
          END
          pool.remove(id);
          ASSERT pool[id] == NIL, "pool stale handle";
          RETURN;
      END
    CHT

  when :set
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@set = [];
          vals.insert(7_i64);
          vals.insert(9_i64);
          vals.insert(7_i64);
          ASSERT vals.length() == 2_i64, "set unique length";
          ASSERT vals.contains?(9_i64), "set contains value";
          RETURN;
      END
    CHT

  when :hash_map
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: HashMap<Int64> = {};
          vals["a"] = 10_i64;
          vals["b"] = 20_i64;
          ASSERT vals.count() == 2_i64, "map count";
          ASSERT vals["b"] OR 0_i64 == 20_i64, "map readback";
          RETURN;
      END
    CHT

  when :sharded_list
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: Float64[]@list:sharded(2) = [];
          vals.append(1.0);
          vals.append(2.0);
          vals.append(3.0);
          total = vals |> SUM _;
          ASSERT total == 6.0, "sharded list sum";
          RETURN;
      END
    CHT

  when :sharded_pool
    <<~CHT
      STRUCT Item { value: Int64 }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool:sharded(2) = [];
          id1 = pool.insert(Item{ value: 10_i64 });
          id2 = pool.insert(Item{ value: 20_i64 });
          ASSERT pool.length() == 2_i64, "sharded pool length";
          ASSERT pool.get(id1) != NIL, "sharded pool get id1";
          pool.remove(id2);
          ASSERT pool.get(id2) == NIL, "sharded pool stale handle";
          RETURN;
      END
    CHT

  when :sharded_set
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@set:sharded(2) = [];
          vals.insert(1_i64);
          vals.insert(2_i64);
          vals.insert(1_i64);
          ASSERT vals.length() == 2_i64, "sharded set unique length";
          ASSERT vals.contains?(2_i64), "sharded set contains value";
          RETURN;
      END
    CHT

  when :sharded_hash_map
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE vals: HashMap<Int64>@sharded(2) = {};
          vals["a"] = 10_i64;
          vals["b"] = 20_i64;
          ASSERT vals.count() == 2_i64, "sharded map count";
          ASSERT vals["a"] OR 0_i64 == 10_i64, "sharded map readback";
          RETURN;
      END
    CHT

  when :soa_list
    <<~CHT
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
          MUTABLE vals: Item[]@list:soa = [];
          vals.append(Item{ value: 1.0, other: 10.0 });
          vals.append(Item{ value: 2.0, other: 20.0 });
          vals.append(Item{ value: 3.0, other: 30.0 });
          total = vals |> SUM _.value;
          ASSERT total == 6.0, "soa list field sum";
          RETURN;
      END
    CHT

  when :soa_pool
    <<~CHT
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
          MUTABLE vals: Item[8]@pool:soa = [];
          vals.insert(Item{ value: 1.0, other: 10.0 });
          vals.insert(Item{ value: 2.0, other: 20.0 });
          vals.insert(Item{ value: 3.0, other: 30.0 });
          total = vals |> SUM _.value;
          ASSERT total == 6.0, "soa pool field sum";
          RETURN;
      END
    CHT

  when :constructor_modifiers
    <<~CHT
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
          MUTABLE vals: Float64[]@list:sharded(2) = List[]:sharded(2);
          vals.append(1.0);
          vals.append(2.0);
          ASSERT vals.length() == 2_i64, "sharded list constructor";

          MUTABLE pool: Item[8]@pool:soa = Pool[]:soa;
          pool.insert(Item{ value: 1.0, other: 10.0 });
          pool.insert(Item{ value: 2.0, other: 20.0 });
          total = pool |> SUM _.value;
          ASSERT total == 3.0, "soa pool constructor";
          RETURN;
      END
    CHT

  when :nested_collection
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE outer: Int64[][]@list = [];
          MUTABLE inner: Int64[]@list = [];
          inner.append(5_i64);
          inner.append(6_i64);
          outer.append(inner);
          ASSERT outer.length() == 1_i64, "nested outer length";
          ASSERT outer[0_i64][1_i64] == 6_i64, "nested readback";
          RETURN;
      END
    CHT
  end
end
