# Template: MIR lowering boundary matrix.
#
# Exercises high-gap lowering helper families with valid source programs:
# stdlib ownership contracts, WITH, BG, DO, NEXT, and pipeline terminals.

LBM_CELLS = []

%i[string list struct].each do |shape|
  %i[normal_call takes_call stdlib_append return_from_call].each do |call|
    next if shape == :list && call == :stdlib_append

    LBM_CELLS << { family: :call_contract, shape: shape, call: call }
  end
end

%i[exclusive snapshot shared_read multi_lock].each do |mode|
  LBM_CELLS << { family: :with_block, mode: mode }
end

%i[
  bg_value bg_return_handle do_two_tasks next_owned_string next_stream_string
  pipeline_collect pipeline_collect_inline pipeline_collect_distinct
  pipeline_recover_success pipeline_recover_fallback
  pipeline_catch_identifier pipeline_catch_func_call pipeline_index
].each do |mode|
  LBM_CELLS << { family: :execution, mode: mode }
end

def lbm_shape(shape)
  case shape
  when :string
    ["", "String", 'COPY "abc"', "x.length()", "3_i64"]
  when :list
    ["", "Int64[]@list", "mkList() OR_ELSE RAISE", "x.length()", "2_i64"]
  when :struct
    ["STRUCT Box { label: String }\n", "Box", 'Box{ label: COPY "abc" }', "x.label.length()", "3_i64"]
  end
end

def lbm_helpers(shape)
  return "" unless shape == :list

  <<~CHT
    FN mkList() RETURNS !Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        &xs.append(1_i64);
        &xs.append(2_i64);
        RETURN xs;
    END
  CHT
end

FuzzGenerator.register(:lowering_boundary_matrix, cells: LBM_CELLS) do |p|
  case p[:family]
  when :call_contract
    prelude, ty, expr, observe, expected = lbm_shape(p[:shape])
    helpers = lbm_helpers(p[:shape])
    case p[:call]
    when :normal_call
      <<~CHT
        #{prelude}#{helpers}
        FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{observe}; END

        FN main() RETURNS !Void ->
            x: #{ty} = #{expr};
            ASSERT observe(x) == #{expected}, "lower normal call";
            RETURN;
        END
      CHT
    when :takes_call
      <<~CHT
        #{prelude}#{helpers}
        FN consume(TAKES x: #{ty}) RETURNS Int64 -> RETURN #{observe}; END

        FN main() RETURNS !Void ->
            x: #{ty} = #{expr};
            ASSERT consume(GIVE x) == #{expected}, "lower takes call";
            RETURN;
        END
      CHT
    when :stdlib_append
      <<~CHT
        #{prelude}#{helpers}
        FN main() RETURNS !Void ->
            MUTABLE out: #{ty}[]@list = [];
            x: #{ty} = #{expr};
            &out.append(x);
            ASSERT out.length() == 1_i64, "lower stdlib append";
            RETURN;
        END
      CHT
    when :return_from_call
      <<~CHT
        #{prelude}#{helpers}
        FN build() RETURNS !#{ty} ->
            x: #{ty} = #{expr};
            RETURN x;
        END

        FN main() RETURNS !Void ->
            x: #{ty} = build() OR_ELSE RAISE;
            ASSERT #{observe} == #{expected}, "lower returned call";
            RETURN;
        END
      CHT
    end

  when :with_block
    case p[:mode]
    when :exclusive
      <<~CHT
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 1_i64 } @locked;
            WITH EXCLUSIVE c AS x { x.value = x.value + 1_i64; }
            WITH EXCLUSIVE c AS x { ASSERT x.value == 2_i64, "with exclusive"; }
            RETURN;
        END
      CHT
    when :snapshot
      <<~CHT
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 3_i64 } @versioned;
            WITH SNAPSHOT c AS x { ASSERT x.value == 3_i64, "with snapshot"; }
            RETURN;
        END
      CHT
    when :shared_read
      <<~CHT
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 4_i64 } @multiowned;
            WITH c { ASSERT c.value == 4_i64, "with shared read"; }
            RETURN;
        END
      CHT
    when :multi_lock
      <<~CHT
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            a = Counter{ value: 1_i64 } @locked;
            b = Counter{ value: 2_i64 } @locked;
            WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y {
                x.value = x.value + y.value;
            }
            WITH EXCLUSIVE a AS x { ASSERT x.value == 3_i64, "with multi lock"; }
            RETURN;
        END
      CHT
    end

  when :execution
    case p[:mode]
    when :bg_value
      %(FN main() RETURNS Void ->\n    h: ~Int64 = BG { 7_i64; };\n    ASSERT (NEXT h) == 7_i64, "bg value";\n    RETURN;\nEND\n)
    when :bg_return_handle
      %(FN make() RETURNS ~Int64 -> RETURN BG { 8_i64; }; END\nFN main() RETURNS Void ->\n    h: ~Int64 = make();\n    ASSERT (NEXT h) == 8_i64, "bg return handle";\n    RETURN;\nEND\n)
    when :do_two_tasks
      %(FN touch(v: Int64) RETURNS Void -> RETURN; END\nFN main() RETURNS Void ->\n    DO { touch(1_i64), touch(2_i64) }\n    RETURN;\nEND\n)
    when :next_owned_string
      %(FN main() RETURNS Void ->\n    h: ~String = BG { COPY "abc"; };\n    s: String = NEXT h;\n    ASSERT s.length() == 3_i64, "next owned string";\n    RETURN;\nEND\n)
    when :next_stream_string
      %(FN ownedString(value: String) RETURNS String -> RETURN COPY value; END\nFN main() RETURNS Void ->\n    s: ~String[INF] = BG STREAM { WHILE TRUE DO YIELD ownedString("abc"); END };\n    x: String = NEXT s;\n    ASSERT x.length() == 3_i64, "next stream string";\n    RETURN;\nEND\n)
    when :pipeline_collect
      %(FN main() RETURNS Void ->\n    s: ~Int64[] = 1_i64 ..< 5_i64;\n    total = s |> SELECT _ * 2_i64 |> SUM _;\n    ASSERT total == 20_i64, "pipeline materialization";\n    RETURN;\nEND\n)
    when :pipeline_collect_inline
      <<~CHT
        FN main() RETURNS Void ->
            total = (BG STREAM { MUTABLE i = 1_i64; WHILE i < 5_i64 DO YIELD i; i = i + 1_i64; END } |> SUM _) |> COLLECT;
            ASSERT total == 10_i64, "pipeline inline collect";
            RETURN;
        END
      CHT
    when :pipeline_collect_distinct
      <<~CHT
        FN main() RETURNS Void ->
            s: ~?Int64[] = BG STREAM {
                YIELD 1_i64;
                YIELD 2_i64;
                YIELD 1_i64;
            };
            out = s |> DISTINCT _ |> COLLECT;
            ASSERT out.length() == 2_i64, "pipeline distinct collect";
            RETURN;
        END
      CHT
    when :pipeline_recover_success
      <<~CHT
        FN risky(flag: Bool) RETURNS !String ->
            IF flag THEN RAISE Input; END
            RETURN COPY "ok";
        END

        FN main() RETURNS Void ->
            s = risky(FALSE) |> RECOVER("fallback");
            ASSERT s == "ok", "pipeline recover success";
            RETURN;
        END
      CHT
    when :pipeline_recover_fallback
      <<~CHT
        FN risky(flag: Bool) RETURNS !String ->
            IF flag THEN RAISE Input; END
            RETURN COPY "ok";
        END

        FN main() RETURNS Void ->
            s = risky(TRUE) |> RECOVER("fallback");
            ASSERT s == "fallback", "pipeline recover fallback";
            RETURN;
        END
      CHT
    when :pipeline_catch_identifier
      <<~CHT
        FN risky(x: Int64) RETURNS !Int64 ->
            IF x < 0_i64 THEN RAISE Input; END
            RETURN x + 1_i64;
        END

        FN wrap(x: Int64) RETURNS !Int64 ->
            out = (x |> risky) OR_ELSE RAISE;
            RETURN out;
        CATCH Input
            RETURN -1_i64;
        END

        FN main() RETURNS Void ->
            ASSERT wrap(4_i64) == 5_i64, "pipeline catch identifier";
            RETURN;
        END
      CHT
    when :pipeline_catch_func_call
      <<~CHT
        FN risky_add(x: Int64, y: Int64) RETURNS !Int64 ->
            IF x < 0_i64 THEN RAISE Input; END
            RETURN x + y;
        END

        FN wrap(x: Int64) RETURNS !Int64 ->
            out = (x |> risky_add(3_i64)) OR_ELSE RAISE;
            RETURN out;
        CATCH Input
            RETURN -1_i64;
        END

        FN main() RETURNS Void ->
            ASSERT wrap(4_i64) == 7_i64, "pipeline catch func call";
            RETURN;
        END
      CHT
    when :pipeline_index
      <<~CHT
        STRUCT Item { key: String, value: Int64 }
        FN item(k: String, v: Int64) RETURNS !Item -> RETURN Item{ key: COPY k, value: v }; END
        FN main() RETURNS !Void ->
            s: ~?Item[] = BG STREAM { YIELD item("a", 1_i64) OR_ELSE RAISE; YIELD item("b", 2_i64) OR_ELSE RAISE; };
            m = s |> INDEX _.key;
            ASSERT m["a"]?.length() == 1_i64, "pipeline index";
            RETURN;
        END
      CHT
    end
  end
end
