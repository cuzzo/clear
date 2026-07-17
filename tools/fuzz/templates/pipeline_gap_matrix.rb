# Template: pipeline operators that are still thin in fuzz-only coverage.

PIPELINE_GAP_CELLS = [
  { shape: :take_while_sum },
  { shape: :skip_sum },
  { shape: :window_time_only },
  { shape: :unnest_bind_sum },
  { shape: :unnest_plain_sum },
  { shape: :concurrent_sum },
  { shape: :concurrent_count },
  { shape: :concurrent_average },
].freeze

FuzzGenerator.register(:pipeline_gap_matrix, cells: PIPELINE_GAP_CELLS) do |p|
  case p[:shape]
  when :take_while_sum
    <<~CHT
      FN main() RETURNS Void ->
        data = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64];
        total = data |> TAKE_WHILE _ < 4_i64 |> SUM _;
        ASSERT total == 6_i64, "take while sum";
        RETURN;
      END
    CHT

  when :skip_sum
    <<~CHT
      FN main() RETURNS Void ->
        data = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64];
        total = data |> SKIP 2_i64 |> SUM _;
        ASSERT total == 12_i64, "skip sum";
        RETURN;
      END
    CHT

  when :window_time_only
    <<~CHT
      FN main() RETURNS Void ->
        data = [1_i64, 2_i64, 3_i64, 4_i64];
        lens = data |> WINDOW(time: "1s") _.length();
        ASSERT lens.length() == 1_i64, "window time";
        RETURN;
      END
    CHT

  when :unnest_bind_sum
    <<~CHT
      STRUCT Order { price: Float64 }
      STRUCT User { discount: Float64, orders: Order[] }

      FN main() RETURNS Void ->
        users = [
          User{ discount: 1.0, orders: [Order{ price: 10.0 }, Order{ price: 20.0 }] },
          User{ discount: 2.0, orders: [Order{ price: 5.0 }] },
        ];
        total = users AS $u |> UNNEST $u.orders AS $o |> SUM $o.price * $u.discount;
        ASSERT total == 40.0, "unnest bind sum";
        RETURN;
      END
    CHT

  when :unnest_plain_sum
    <<~CHT
      STRUCT Bucket { values: Int64[] }

      FN main() RETURNS Void ->
        MUTABLE buckets: Bucket[8]@pool = [];
        _ = &buckets.insert(Bucket{ values: [1_i64, 2_i64] });
        _ = &buckets.insert(Bucket{ values: [3_i64, 4_i64] });
        total = buckets |> UNNEST _.values |> SUM toFloat(_);
        ASSERT total == 10.0, "unnest plain sum";
        RETURN;
      END
    CHT

  when :concurrent_sum
    <<~CHT
      FN main() RETURNS Void ->
        vals = [1_i64, 2_i64, 3_i64, 4_i64];
        total = vals |> CONCURRENT(workers: 2) SUM _;
        ASSERT total == 10_i64, "concurrent sum";
        RETURN;
      END
    CHT

  when :concurrent_count
    <<~CHT
      FN main() RETURNS Void ->
        vals = [1_i64, 2_i64, 3_i64, 4_i64];
        n = vals |> CONCURRENT(workers: 2) COUNT _ > 2_i64;
        ASSERT n == 2_i64, "concurrent count";
        RETURN;
      END
    CHT

  when :concurrent_average
    <<~CHT
      FN main() RETURNS Void ->
        vals = [2_i64, 4_i64, 6_i64, 8_i64];
        avg = vals |> CONCURRENT(workers: 2) AVERAGE toFloat(_);
        ASSERT avg == 5.0, "concurrent average";
        RETURN;
      END
    CHT
  end
end
