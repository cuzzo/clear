# Template: pipeline/source shape matrix.
#
# Crosses bound vs inline sources, finite/open/infinite/bounded producers,
# ownership-bearing string results, and common pipeline terminals.

PIPELINE_SOURCE_CELLS = []

[:range_bound, :range_inline, :bg_stream_bound, :bg_stream_inline,
 :bounded_promises, :list_bound, :string_stream].each do |source|
  [:sum, :count, :select_sum, :where_reduce, :limit_sum].each do |op|
    next if op == :limit_sum && !%i[bg_stream_bound bg_stream_inline string_stream].include?(source)
    next if source == :string_stream && !%i[count].include?(op)
    next if source == :bounded_promises && op != :where_reduce
    cell = { source: source, op: op }
    cell[:expected] = :compile_error if op == :select_sum && %i[bg_stream_bound bg_stream_inline].include?(source)
    PIPELINE_SOURCE_CELLS << cell
  end
end

[:find_int, :distinct_int, :index_struct].each do |op|
  [:bg_stream_bound].each { |source| PIPELINE_SOURCE_CELLS << { source: source, op: op } }
end

FuzzGenerator.register(:pipeline_source_shape_matrix, cells: PIPELINE_SOURCE_CELLS) do |p|
  observable_source = %i[range_bound range_inline bg_stream_bound bg_stream_inline bounded_promises string_stream].include?(p[:source])

  case p[:op]
  when :sum
    source_decl, source_expr = case p[:source]
    when :range_bound
      ["s: ~Int64[] = 1_i64 ..< 5_i64;", "s"]
    when :range_inline
      ["s: ~Int64[] = 1_i64 ..< 5_i64;", "s"]
    when :bg_stream_bound
      ["s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };", "s"]
    when :bg_stream_inline
      ["s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };", "s"]
    when :list_bound
      ["s: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];", "s"]
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
    else
      decl = p[:source] == :list_bound ? "s: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];" : "s: ~Int64[] = 1_i64 ..< 5_i64;"
      if observable_source
        decl = "s: ~?Int64[] = BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END };"
        decl = "s: ~Int64[] = 1_i64 ..< 5_i64;" if %i[range_bound range_inline].include?(p[:source])
        <<~CHT
          FN main() RETURNS Void ->
            #{decl}
            running: ~Int64@observable = s |> COUNT _ > 2_i64;
            n = NEXT running;
            ASSERT n == 2_i64, "pipeline count";
            RETURN;
          END
        CHT
      else
        <<~CHT
          FN main() RETURNS Void ->
            #{decl}
            n = s |> COUNT _ > 2_i64;
            ASSERT n == 2_i64, "pipeline count";
            RETURN;
          END
        CHT
      end
    end

  when :select_sum
    if %i[bg_stream_bound bg_stream_inline].include?(p[:source])
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
      decl = "s: ~Int64[] = 1_i64 ..< 5_i64;"
      <<~CHT
        FN main() RETURNS Void ->
          #{decl}
          total = s |> SELECT _ * 2_i64 |> SUM _;
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
  end
end
