# Template: broad ownership surface smoke cells.
#
# These cells cover registry dimensions that should not be forced onto every
# semantic template. Each cell is intentionally small: it proves one cleanup
# value shape, escape sink, or MIR ownership contract is represented by at
# least one end-to-end fuzz program.

OWNERSHIP_SURFACE_CELLS = []

[
  :string,
  :frame_string_concat,
  :dynamic_array,
  :frame_list,
  :heap_list,
  :pool,
  :set,
  :hash_map,
  :sharded_list,
  :sharded_pool,
  :sharded_set,
  :sharded_hash_map,
  :soa_list,
  :soa_pool,
  :struct_owned_fields,
  :union_owned_payload,
  :option_owned_payload,
  :nested_container,
].each { |shape| OWNERSHIP_SURFACE_CELLS << { axis: :cleanup_value_shapes, shape: shape } }

[
  :return_value,
  :struct_field_store,
  :list_append,
  :set_insert,
  :map_put,
  :pool_insert,
  :collection_literal,
  :function_arg,
].each { |sink| OWNERSHIP_SURFACE_CELLS << { axis: :escape_sinks, sink: sink } }

[
  :promotion_on_escape,
  :cleanup_on_all_paths,
  :loop_frame_rewind,
  :error_path_allocator_identity,
  :move_suppresses_cleanup,
  :alias_non_escape,
  :bg_lifetime_enforcement,
  :collection_mutation_visible_to_mir,
  :non_copy_requires_explicit_move_or_copy,
].each do |contract|
  cell = { axis: :mir_ownership_contracts, contract: contract }
  # non_copy_requires_explicit_move_or_copy expects :pass, not
  # :compile_error: a TAKES parameter is itself the ownership-transfer
  # signal (INV-13: was_moved set by `param[:takes] || GIVE`). Passing
  # to a TAKES slot does NOT require an explicit `GIVE` at the call
  # site -- the prior :compile_error expectation was a stale premise.
  if [:alias_non_escape, :bg_lifetime_enforcement].include?(contract)
    cell[:expected] = :compile_error
  end
  OWNERSHIP_SURFACE_CELLS << cell
end

FuzzGenerator.register(:ownership_surface_smoke, cells: OWNERSHIP_SURFACE_CELLS) do |p|
  case p[:axis]
  when :cleanup_value_shapes
    ownership_surface_cleanup_cell(p[:shape])
  when :escape_sinks
    ownership_surface_escape_sink_cell(p[:sink])
  when :mir_ownership_contracts
    ownership_surface_contract_cell(p[:contract])
  end
end

def ownership_surface_cleanup_cell(shape)
  case shape
  when :string
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE s: String = "";
          s = s $+ "owned";
          ASSERT s.length() == 5_i64, "string cleanup shape";
          RETURN;
      END
    CHT
  when :frame_string_concat
    <<~CHT
      FN main() RETURNS Void ->
          s: String = "n" $+ 1_i64.toString();
          ASSERT s.length() == 2_i64, "frame string cleanup shape";
          RETURN;
      END
    CHT
  when :dynamic_array, :frame_list
    <<~CHT
      FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64, 3_i64];
          ASSERT xs[1_i64] == 2_i64, "frame array cleanup shape";
          RETURN;
      END
    CHT
  when :heap_list
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: String[]@list = [];
          xs.append(COPY "list");
          ASSERT xs.length() == 1_i64, "heap list cleanup shape";
          RETURN;
      END
    CHT
  when :pool
    <<~CHT
      STRUCT Item { name: String }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool = [];
          id = pool.insert(Item{ name: COPY "pool" });
          ASSERT pool.get(id) != NIL, "pool cleanup shape";
          RETURN;
      END
    CHT
  when :set
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE set: String[]@set = [];
          set.insert(COPY "set");
          ASSERT set.length() == 1_i64, "set cleanup shape";
          RETURN;
      END
    CHT
  when :hash_map
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE map: HashMap<String> = {};
          map["k"] = "map" $+ 1_i64.toString();
          ASSERT map.count() == 1_i64, "hash map cleanup shape";
          RETURN;
      END
    CHT
  when :sharded_list
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: Float64[]@list:sharded(2) = [];
          xs.append(1.0);
          total = xs |> SUM _;
          ASSERT total == 1.0, "sharded list cleanup shape";
          RETURN;
      END
    CHT
  when :sharded_pool
    <<~CHT
      STRUCT Item { name: String }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool:sharded(2) = [];
          id = pool.insert(Item{ name: COPY "sp" });
          ASSERT pool.get(id) != NIL, "sharded pool cleanup shape";
          RETURN;
      END
    CHT
  when :sharded_set
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE set: Int64[]@set:sharded(2) = [];
          set.insert(1_i64);
          ASSERT set.length() == 1_i64, "sharded set cleanup shape";
          RETURN;
      END
    CHT
  when :sharded_hash_map
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE map: HashMap<Int64>@sharded(2) = {};
          map["k"] = 1_i64;
          ASSERT map.count() == 1_i64, "sharded hash map cleanup shape";
          RETURN;
      END
    CHT
  when :soa_list
    <<~CHT
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
          MUTABLE xs: Item[]@list:soa = [];
          xs.append(Item{ value: 1.0, other: 10.0 });
          total = xs |> SUM _.value;
          ASSERT total == 1.0, "soa list cleanup shape";
          RETURN;
      END
    CHT
  when :soa_pool
    <<~CHT
      STRUCT Item { value: Float64, other: Float64 }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool:soa = [];
          pool.insert(Item{ value: 1.0, other: 10.0 });
          ASSERT pool.length() == 1_i64, "soa pool cleanup shape";
          RETURN;
      END
    CHT
  when :struct_owned_fields
    <<~CHT
      STRUCT Holder { name: String }

      FN main() RETURNS Void ->
          h = Holder{ name: COPY "holder" };
          ASSERT h.name == "holder", "struct owned fields cleanup shape";
          RETURN;
      END
    CHT
  when :union_owned_payload
    <<~CHT
      UNION Value { Nil, Str: String, List: Value[] }

      FN main() RETURNS Void ->
          v = Value{ Str: COPY "union" };
          copy = COPY v;
          RETURN;
      END
    CHT
  when :option_owned_payload
    <<~CHT
      FN main() RETURNS Void ->
          value: ?String = COPY "option";
          ASSERT value.present?(), "optional payload cleanup shape";
          RETURN;
      END
    CHT
  when :nested_container
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE outer: Int64[][]@list = [];
          inner: Int64[] = [5_i64, 6_i64];
          outer.append(inner);
          ASSERT outer.length() == 1_i64, "nested container cleanup shape";
          RETURN;
      END
    CHT
  end
end

def ownership_surface_escape_sink_cell(sink)
  case sink
  when :return_value
    <<~CHT
      FN make() RETURNS !String -> RETURN COPY "ret"; END
      FN main() RETURNS Void ->
          s = make();
          ASSERT s == "ret", "return sink";
          RETURN;
      END
    CHT
  when :struct_field_store
    <<~CHT
      STRUCT Holder { name: String }
      FN main() RETURNS Void ->
          MUTABLE h = Holder{ name: "" };
          h.name = COPY "field";
          ASSERT h.name == "field", "field store sink";
          RETURN;
      END
    CHT
  when :list_append
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: String[]@list = [];
          xs.append(COPY "list");
          ASSERT xs.length() == 1_i64, "list append sink";
          RETURN;
      END
    CHT
  when :set_insert
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: String[]@set = [];
          xs.insert(COPY "set");
          ASSERT xs.contains?("set"), "set insert sink";
          RETURN;
      END
    CHT
  when :map_put
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: HashMap<Int64> = {};
          xs["k"] = 7_i64;
          ASSERT xs["k"] OR_ELSE 0_i64 == 7_i64, "map put sink";
          RETURN;
      END
    CHT
  when :pool_insert
    <<~CHT
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool = [];
          id = pool.insert(Item{ value: 7_i64 });
          ASSERT pool.get(id) != NIL, "pool insert sink";
          RETURN;
      END
    CHT
  when :collection_literal
    <<~CHT
      FN main() RETURNS Void ->
          xs: String[] = [COPY "lit"];
          ASSERT xs[0_i64] == "lit", "collection literal sink";
          RETURN;
      END
    CHT
  when :function_arg
    <<~CHT
      FN len(s: String) RETURNS Int64 -> RETURN s.length(); END
      FN main() RETURNS Void ->
          ASSERT len(COPY "arg") == 3_i64, "function arg sink";
          RETURN;
      END
    CHT
  when :bg_handle_return
    <<~CHT
      FN work() RETURNS ~Int64 -> RETURN BG { 7_i64; }; END
      FN main() RETURNS Void ->
          h = work();
          v: Int64 = NEXT h;
          ASSERT v == 7_i64, "bg handle return sink";
          RETURN;
      END
    CHT
  when :bg_handle_field_store
    <<~CHT
      STRUCT Holder { h: ~Int64 }
      FN main() RETURNS Void ->
          holder = Holder{ h: BG { 8_i64; } };
          v: Int64 = NEXT holder.h;
          ASSERT v == 8_i64, "bg handle field sink";
          RETURN;
      END
    CHT
  when :bg_capture
    <<~CHT
      FN main() RETURNS Void ->
          x: Int64 = 9_i64;
          h = BG { x; };
          v: Int64 = NEXT h;
          ASSERT v == 9_i64, "bg capture sink";
          RETURN;
      END
    CHT
  when :do_capture
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          counter = Counter{ value: 0_i64 } @locked;
          DO {
              WITH EXCLUSIVE counter AS c { c.value = c.value + 1_i64; },
              WITH EXCLUSIVE counter AS c { c.value = c.value + 1_i64; }
          }
          WITH counter AS c {
              ASSERT c.value == 2_i64, "do capture sink";
          }
          RETURN;
      END
    CHT
  when :bg_stream_capture
    <<~CHT
      FN main() RETURNS Void ->
          x: Int64 = 11_i64;
          s: ~Int64[INF] = BG STREAM { WHILE TRUE DO YIELD x; END };
          v: Int64 = NEXT s;
          ASSERT v == 11_i64, "bg stream capture sink";
          RETURN;
      END
    CHT
  end
end

def ownership_surface_contract_cell(contract)
  case contract
  when :promotion_on_escape
    <<~CHT
      FN make() RETURNS !String -> RETURN "promote" $+ 1_i64.toString(); END
      FN main() RETURNS Void ->
          s = make();
          ASSERT s.length() > 0_i64, "promotion on escape";
          RETURN;
      END
    CHT
  when :cleanup_on_all_paths
    <<~CHT
      FN main() RETURNS Void ->
          IF TRUE THEN
              s = "then" $+ 1_i64.toString();
              ASSERT s.length() > 0_i64, "then cleanup";
          ELSE
              s = "else" $+ 1_i64.toString();
              ASSERT s.length() > 0_i64, "else cleanup";
          END
          RETURN;
      END
    CHT
  when :loop_frame_rewind
    <<~CHT
      FN main() RETURNS Void ->
          FOR i IN (1_i64 ..= 4_i64) DO
              s = "loop" $+ i.toString();
              ASSERT s.length() > 0_i64, "loop rewind";
          END
          RETURN;
      END
    CHT
  when :error_path_allocator_identity
    <<~CHT
      FN maybe(raise_it: Bool) RETURNS !String ->
          s = "err" $+ 1_i64.toString();
          IF raise_it THEN RAISE; END
          RETURN s;
      END
      FN main() RETURNS Void ->
          maybe(TRUE) OR_ELSE PASS;
          s = maybe(FALSE);
          ASSERT s.length() > 0_i64, "error path allocator identity";
          RETURN;
      END
    CHT
  when :move_suppresses_cleanup
    <<~CHT
      FN consume!(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END
      FN main() RETURNS Void ->
          s = COPY "move";
          ASSERT consume!(GIVE s) == 4_i64, "move suppresses cleanup";
          RETURN;
      END
    CHT
  when :alias_non_escape
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN leak() RETURNS !Counter ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          WITH EXCLUSIVE c AS ref {
              RETURN ref;
          }
      END
      FN main() RETURNS Void -> _ = leak(); RETURN; END
    CHT
  when :bg_lifetime_enforcement
    <<~CHT
      FN leak() RETURNS ~String ->
          s = COPY "local";
          RETURN BG { s; };
      END
      FN main() RETURNS Void -> _ = leak(); RETURN; END
    CHT
  when :collection_mutation_visible_to_mir
    <<~CHT
      FN add!(MUTABLE xs: Int64[]@list) RETURNS !Void ->
          xs.append(1_i64);
          RETURN;
      END
      FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          add!(xs);
          ASSERT xs.length() == 1_i64, "collection mutation visible";
          RETURN;
      END
    CHT
  when :non_copy_requires_explicit_move_or_copy
    <<~CHT
      FN consume!(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END
      FN main() RETURNS Void ->
          s = COPY "owned";
          _ = consume!(s);
          RETURN;
      END
    CHT
  end
end
