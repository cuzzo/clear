# Template: collection iteration/storage matrix.
#
# Exercises collection placement and cleanup through FOR iteration, mutation,
# nested loops, early exits, and post-loop reads for every supported container
# family.

COLLECTION_ITER_STORAGE_CELLS = []

[:array, :list, :set, :map, :pool, :nested_list, :soa_list].each do |container|
  [:plain_iter, :nested_iter, :break_iter, :continue_iter, :store_outer, :return_from_fn].each do |mode|
    next if mode == :continue_iter && container == :map
    COLLECTION_ITER_STORAGE_CELLS << { container: container, mode: mode }
  end
end

COLLECTION_ITER_STORAGE_CELLS << { container: :list, mode: :while_bind_pop_continue }
COLLECTION_ITER_STORAGE_CELLS << { container: :list, mode: :while_bind_pop_move, expected: :compile_error }

FuzzGenerator.register(:collection_iteration_storage_matrix, cells: COLLECTION_ITER_STORAGE_CELLS) do |p|
  case p[:container]
  when :array
    decl = "items: Int64[] = [1_i64, 2_i64, 3_i64];"
    iter = "items"
    value = "v"
    sum_assert = "6_i64"
  when :list
    decl = "MUTABLE items: Int64[]@list = []; &items.append(1_i64); &items.append(2_i64); &items.append(3_i64);"
    iter = "items"
    value = "v"
    sum_assert = "6_i64"
  when :set
    decl = "MUTABLE items: Int64[]@set = []; &items.insert(1_i64); &items.insert(2_i64); &items.insert(3_i64);"
    iter = "items"
    value = "v"
    sum_assert = "6_i64"
  when :map
    decl = 'MUTABLE items: HashMap<Int64> = {}; items["a"] = 1_i64; items["b"] = 2_i64; items["c"] = 3_i64;'
    iter = "items"
    value = "(items[v] OR_ELSE 0_i64)"
    sum_assert = "6_i64"
  when :pool
    decl = "MUTABLE items: Item[8]@pool = []; &items.insert(Item{ value: 1_i64 }); &items.insert(Item{ value: 2_i64 }); &items.insert(Item{ value: 3_i64 });"
    iter = "items"
    value = "v.value"
    sum_assert = "6_i64"
  when :nested_list
    decl = "MUTABLE items: Box[]@list = []; MUTABLE a: Int64[]@list = []; &a.append(1_i64); &a.append(2_i64); &items.append(Box{ values: a }); MUTABLE b: Int64[]@list = []; &b.append(3_i64); &items.append(Box{ values: b });"
    iter = "items"
    value = "v.values.length()"
    sum_assert = "3_i64"
  when :soa_list
    decl = "MUTABLE items: Item[]@list:soa = []; &items.append(Item{ value: 1_i64 }); &items.append(Item{ value: 2_i64 }); &items.append(Item{ value: 3_i64 });"
    iter = "items"
    value = "v.value"
    sum_assert = "6_i64"
  end

  prelude = %i[pool soa_list].include?(p[:container]) ? "STRUCT Item { value: Int64 }\n" : ""
  prelude += "STRUCT Box { values: Int64[]@list }\n" if p[:container] == :nested_list

  case p[:mode]
  when :plain_iter
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
        #{decl}
        MUTABLE total = 0_i64;
        FOR v IN #{iter} DO
          total = total + #{value};
        END
        ASSERT total == #{sum_assert}, "collection plain iter";
        RETURN;
      END
    CHT

  when :nested_iter
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
        #{decl}
        MUTABLE total = 0_i64;
        FOR i IN (1_i64 ..= 2_i64) DO
          FOR v IN #{iter} DO
            total = total + #{value};
          END
        END
        ASSERT total == (#{sum_assert} * 2_i64), "collection nested iter";
        RETURN;
      END
    CHT

  when :break_iter
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
        #{decl}
        MUTABLE total = 0_i64;
        FOR v IN #{iter} DO
          total = total + #{value};
          BREAK;
        END
        ASSERT total >= 1_i64, "collection break iter";
        RETURN;
      END
    CHT

  when :continue_iter
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
        #{decl}
        MUTABLE total = 0_i64;
        FOR v IN #{iter} DO
          IF #{value} == 2_i64 THEN CONTINUE; END
          total = total + #{value};
        END
        ASSERT total >= 1_i64, "collection continue iter";
        RETURN;
      END
    CHT

  when :store_outer
    if p[:container] == :nested_list
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
          #{decl}
          MUTABLE outer: Int64[]@list = [];
          FOR v IN #{iter} DO
            &outer.append(v.values.length());
          END
          ASSERT outer.length() >= 1_i64, "collection store outer";
          RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
          #{decl}
          MUTABLE outer: Int64[]@list = [];
          FOR v IN #{iter} DO
            &outer.append(#{value});
          END
          ASSERT outer.length() >= 1_i64, "collection store outer";
          RETURN;
        END
      CHT
    end

  when :return_from_fn
    <<~CHT
      #{prelude}FN run() RETURNS !Int64 ->
        #{decl}
        MUTABLE total = 0_i64;
        FOR v IN #{iter} DO
          total = total + #{value};
        END
        RETURN total;
      END

      FN main() RETURNS !Void ->
        ASSERT (run() OR_ELSE RAISE) == #{sum_assert}, "collection return fn";
        RETURN;
      END
    CHT

  when :while_bind_pop_continue
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE items: Int64[]@list = [];
        &items.append(1_i64);
        &items.append(2_i64);
        MUTABLE total = 0_i64;
        WHILE &items.pop() EXISTS AS v DO
          IF v == 1_i64 THEN CONTINUE; END
          total = total + v;
        END
        ASSERT total == 2_i64, "while bind pop continue";
        RETURN;
      END
    CHT

  when :while_bind_pop_move
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE items: String[]@list = [];
        &items.append(COPY "a");
        WHILE &items.pop() EXISTS AS v DO
          GIVE v;
          GIVE v;
        END
        RETURN;
      END
    CHT
  end
end
