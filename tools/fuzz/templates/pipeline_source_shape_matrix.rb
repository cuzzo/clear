# Template: pipeline/source shape matrix.
#
# Crosses bound vs inline sources, finite/open/infinite/bounded producers,
# ownership-bearing string results, and common pipeline terminals.

PIPELINE_SOURCE_CELLS = []

[:range_bound, :range_inline, :bg_stream_bound,
 :bounded_promises, :list_bound, :list_inline, :split_inline, :string_stream].each do |source|
  [:sum, :count, :select_sum, :where_reduce, :limit_sum].each do |op|
    next if op == :limit_sum && !%i[bg_stream_bound string_stream].include?(source)
    next if source == :string_stream && !%i[count].include?(op)
    next if source == :bounded_promises && op != :where_reduce
    next if source == :split_inline && !%i[count].include?(op)
    cell = { source: source, op: op }
    cell[:expected] = :compile_error if op == :select_sum && source == :bg_stream_bound
    PIPELINE_SOURCE_CELLS << cell
  end
end

[:find_int, :distinct_int, :index_struct].each do |op|
  [:bg_stream_bound].each { |source| PIPELINE_SOURCE_CELLS << { source: source, op: op } }
end

[:max_int, :min_int, :average_int, :any_int, :all_int, :collect_sum,
 :collect_distinct, :batch_window_list, :batch_window_open, :join_lambda,
 :tap_inf, :shard_each_string, :shard_each_numeric,
 :concurrent_bounded_select, :concurrent_bounded_where,
 :concurrent_stream_select, :concurrent_stream_where].each do |op|
  PIPELINE_SOURCE_CELLS << { source: :bg_stream_bound, op: op }
end

FuzzGenerator.register(:pipeline_source_shape_matrix, cells: PIPELINE_SOURCE_CELLS) do |p|
  observable_source = %i[range_bound range_inline bg_stream_bound bounded_promises string_stream].include?(p[:source])

  case p[:op]
  when :sum
    source_decl, source_expr = case p[:source]
    when :range_bound
      ["s: ~Int64[] = 1_i64 ..< 5_i64;", "s"]
    when :range_inline
      ["s: ~Int64[] = 1_i64 ..< 5_i64;", "s"]
    when :bg_stream_bound
      ["s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };", "s"]
    when :list_bound
      ["s: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];", "s"]
    when :list_inline
      ["", "[1_i64, 2_i64, 3_i64, 4_i64]"]
    end
    if observable_source
      <<~CHT
        FN main() RETURNS Void ->
          #{source_decl}
          running: ~Int64@observable = #{source_expr} |> SUM _;
          total = NEXT running;
          ASSERT total == 10_i64, "pipeline sum";
          RETURN;
        END
      CHT
    else
      <<~CHT
        FN main() RETURNS Void ->
          #{source_decl}
          total = #{source_expr} |> SUM _;
          ASSERT total == 10_i64, "pipeline sum";
          RETURN;
        END
      CHT
    end

  when :count
    if p[:source] == :string_stream
      <<~CHT
        FN main() RETURNS Void ->
          s: ~?String[] = BG STREAM {
            a: String = COPY "aa";
            b: String = COPY "bbb";
            c: String = COPY "c";
            YIELD a;
            YIELD b;
            YIELD c;
          };
          n: ~Int64@observable = s |> COUNT _.length() >= 2_i64;
          ASSERT (NEXT n) == 2_i64, "pipeline string count";
          RETURN;
        END
      CHT
    elsif p[:source] == :split_inline
      <<~CHT
        FN main() RETURNS Void ->
          n = (COPY "aa b ccc").split(" ") |> COUNT _.length() >= 2_i64;
          ASSERT n == 2_i64, "pipeline inline split count";
          RETURN;
        END
      CHT
    else
      decl =
        case p[:source]
        when :list_bound then "s: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];"
        when :list_inline then ""
        else "s: ~Int64[] = 1_i64 ..< 5_i64;"
        end
      if observable_source
        source_expr = "s"
        if p[:source] == :range_inline
          decl = "s: ~Int64[] = 1_i64 ..< 5_i64;"
          source_expr = "s"
        else
          decl = "s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };"
          decl = "s: ~Int64[] = 1_i64 ..< 5_i64;" if p[:source] == :range_bound
        end
        <<~CHT
          FN main() RETURNS Void ->
            #{decl}
            running: ~Int64@observable = #{source_expr} |> COUNT _ > 2_i64;
            n = NEXT running;
            ASSERT n == 2_i64, "pipeline count";
            RETURN;
          END
        CHT
      else
        source_expr = p[:source] == :list_inline ? "[1_i64, 2_i64, 3_i64, 4_i64]" : "s"
        <<~CHT
          FN main() RETURNS Void ->
            #{decl}
            n = #{source_expr} |> COUNT _ > 2_i64;
            ASSERT n == 2_i64, "pipeline count";
            RETURN;
          END
        CHT
      end
    end

  when :select_sum
    if p[:source] == :bg_stream_bound
      <<~CHT
        FN main() RETURNS Void ->
          s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
          running: ~Int64@observable = s |> SELECT _ * 2_i64 |> SUM _;
          total = NEXT running;
          ASSERT total == 20_i64, "pipeline select sum";
          RETURN;
        END
      CHT
    else
      decl =
        case p[:source]
        when :range_inline, :list_inline then ""
        else "s: ~Int64[] = 1_i64 ..< 5_i64;"
        end
      source_expr =
        case p[:source]
        when :range_inline then "1_i64 ..< 5_i64"
        when :list_inline then "[1_i64, 2_i64, 3_i64, 4_i64]"
        else "s"
        end
      <<~CHT
        FN main() RETURNS Void ->
          #{decl}
          total = #{source_expr} |> SELECT _ * 2_i64 |> SUM _;
          ASSERT total == 20_i64, "pipeline select sum";
          RETURN;
        END
      CHT
    end

  when :where_reduce
    decl = p[:source] == :bounded_promises ? "s: ~Int64[4] = [BG { 1_i64; }, BG { 2_i64; }, BG { 3_i64; }, BG { 4_i64; }];" : "s: ~Int64[] = 1_i64 ..< 5_i64;"
    <<~CHT
      FN main() RETURNS Void ->
        #{decl}
        total = s |> WHERE _ MOD 2_i64 == 0_i64 |> REDUCE(0_i64) acc + _;
        ASSERT total == 6_i64, "pipeline where reduce";
        RETURN;
      END
    CHT

  when :limit_sum
    source = "s"
    decl = "s: ~Int64[INF] = BG STREAM { MUTABLE i = 1_i64; WHILE TRUE DO YIELD i; i = i + 1_i64; END };"
    <<~CHT
      FN main() RETURNS Void ->
        #{decl}
        total = #{source} |> LIMIT 4 |> SUM _;
        ASSERT total == 10_i64, "pipeline limit sum";
        RETURN;
      END
    CHT

  when :find_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~?Int64@observable = s |> FIND _ > 2_i64;
        found = NEXT running;
        ASSERT found != NIL, "pipeline find present";
        ASSERT found == 3_i64, "pipeline find value";
        RETURN;
      END
    CHT

  when :distinct_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 2_i64; YIELD 1_i64; YIELD 2_i64; };
        running: ~Int64[]@set:observable = s |> DISTINCT _;
        vals = NEXT running;
        ASSERT vals.length() == 2_i64, "pipeline distinct";
        RETURN;
      END
    CHT

  when :index_struct
    decl = p[:source] == :bounded_promises ? "s: ~Item[3] = [BG { makeItem(\"a\", 1_i64); }, BG { makeItem(\"b\", 2_i64); }, BG { makeItem(\"a\", 3_i64); }];" : "s: ~?Item[] = BG STREAM { YIELD makeItem(\"a\", 1_i64) OR RAISE; YIELD makeItem(\"b\", 2_i64) OR RAISE; YIELD makeItem(\"a\", 3_i64) OR RAISE; };"
    <<~CHT
      STRUCT Item { category: String, score: Int64 }

      FN makeItem(cat: String, score: Int64) RETURNS !Item ->
        RETURN Item{ category: COPY cat, score: score };
      END

      FN main() RETURNS !Void ->
        #{decl}
        grouped = s |> INDEX _.category;
        ASSERT grouped["a"].length() == 2_i64, "pipeline index a";
        ASSERT grouped["b"].length() == 1_i64, "pipeline index b";
        RETURN;
      END
    CHT

  when :max_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 0_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~Int64@observable = s |> MAX _;
        ASSERT (NEXT running) == 4_i64, "pipeline max";
        RETURN;
      END
    CHT

  when :min_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 5_i64; WHILE i > 0_i64 DO YIELD i; i = i - 1_i64; END };
        running: ~Int64@observable = s |> MIN _;
        ASSERT (NEXT running) == 1_i64, "pipeline min";
        RETURN;
      END
    CHT

  when :average_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 0_i64; WHILE i < 10_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~Float64@observable = s |> AVERAGE _;
        ASSERT (NEXT running) == 4.5, "pipeline average";
        RETURN;
      END
    CHT

  when :any_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 0_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~Bool@observable = s |> ANY _ == 3_i64;
        ASSERT (NEXT running) == TRUE, "pipeline any";
        RETURN;
      END
    CHT

  when :all_int
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 0_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~Bool@observable = s |> ALL _ < 5_i64;
        ASSERT (NEXT running) == TRUE, "pipeline all";
        RETURN;
      END
    CHT

  when :collect_sum
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };
        running: ~Int64@observable = s |> SUM _;
        total = running |> COLLECT;
        ASSERT total == 10_i64, "pipeline collect";
        RETURN;
      END
    CHT
  when :collect_distinct
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 2_i64; YIELD 1_i64; };
        vals = s |> DISTINCT _ |> COLLECT;
        ASSERT vals.length() == 2_i64, "collect distinct";
        RETURN;
      END
    CHT

  when :batch_window_list
    <<~CHT
      FN sumBatch(xs: Int64[]) RETURNS Int64 ->
        MUTABLE total: Int64 = 0_i64;
        xs |> EACH { total = total + _; };
        RETURN total;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];
        sums = xs |> WINDOW(size: 2) sumBatch(_);
        ASSERT sums.length() == 2_i64, "batch window list";
        RETURN;
      END
    CHT

  when :batch_window_open
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 2_i64; YIELD 3_i64; YIELD 4_i64; };
        lens = s |> WINDOW(size: 2) _.length();
        ASSERT lens.length() == 2_i64, "batch window stream";
        RETURN;
      END
    CHT

  when :join_lambda
    <<~CHT
      STRUCT User { id: Int64 }
      STRUCT Order { userId: Int64 }
      FN main() RETURNS Void ->
        users: User[] = [User{ id: 1_i64 }, User{ id: 2_i64 }];
        orders: Order[] = [Order{ userId: 1_i64 }];
        joined = users |> JOIN(orders) %(u, o) -> u.id == o.userId;
        ASSERT joined.length() == 2_i64, "join lambda";
        RETURN;
      END
    CHT

  when :tap_inf
    <<~CHT
      FN main() RETURNS Void ->
        s: ~Int64[INF] = BG STREAM { MUTABLE i = 1_i64; WHILE TRUE DO YIELD i; i = i + 1_i64; END };
        total = s |> TAP { ASSERT _ > 0_i64, "tap inf"; } |> LIMIT 3 |> SUM _;
        ASSERT total == 6_i64, "tap inf sum";
        RETURN;
      END
    CHT

  when :concurrent_bounded_select
    <<~CHT
      FN main() RETURNS Void ->
        s: ~Int64[4] = [BG { 1_i64; }, BG { 2_i64; }, BG { 3_i64; }, BG { 4_i64; }];
        vals = s |> CONCURRENT(workers: 2) SELECT _ * 2_i64;
        ASSERT vals.length() == 4_i64, "concurrent bounded select";
        RETURN;
      END
    CHT

  when :concurrent_bounded_where
    <<~CHT
      FN main() RETURNS Void ->
        s: ~Int64[4] = [BG { 1_i64; }, BG { 2_i64; }, BG { 3_i64; }, BG { 4_i64; }];
        vals = s |> CONCURRENT(workers: 2) WHERE _ > 2_i64;
        ASSERT vals.length() == 2_i64, "concurrent bounded where";
        RETURN;
      END
    CHT

  when :concurrent_stream_select
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM {
          MUTABLE i = 1_i64;
          WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END
        };
        vals = s |> CONCURRENT(workers: 2) SELECT _ * 2_i64;
        ASSERT vals.length() == 4_i64, "concurrent stream select";
        RETURN;
      END
    CHT

  when :concurrent_stream_where
    <<~CHT
      FN main() RETURNS Void ->
        s: ~?Int64[] = BG STREAM {
          MUTABLE i = 1_i64;
          WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END
        };
        vals = s |> CONCURRENT(workers: 2) WHERE _ > 2_i64;
        ASSERT vals.length() == 2_i64, "concurrent stream where";
        RETURN;
      END
    CHT

  when :shard_each_string
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE counts: HashMap<String>@sharded(4) = {};
        (0_i64 ..< 4_i64) |> SHARD("k:${toString(_)}", counts) |> CONCURRENT EACH {
          counts[_] = "seen";
        };
        RETURN;
      END
    CHT

  when :shard_each_numeric
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
        (0_i64 ..< 4_i64) |> SHARD(_ MOD 4_i64, counts) |> CONCURRENT EACH {
          counts[_] = (counts[_] OR 0_i64) + 1_i64;
        };
        RETURN;
      END
    CHT
  end
end
