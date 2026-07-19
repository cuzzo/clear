# Template: FSM suspension shapes.
#
# Covers the recursive FSM splitter by placing suspend points inside every
# control-flow shape it claims to support: linear NEXT, loops, foreach,
# IF/ELSE, WITH lock acquisition, and BG STREAM YIELD.

FSM_SUSPENSION_CELLS = []

[:linear_next, :bare_next, :while_next, :while_zero, :for_range_sleep,
 :foreach_array_sleep, :foreach_list_sleep, :foreach_pool_sleep,
 :if_then_sleep, :if_else_sleep, :if_both_sleep, :with_single_lock,
 :with_two_locks, :bg_stream_yield, :owned_string_suspend,
 :owned_list_suspend, :nested_while_next, :lock_and_owned_result,
 :stream_owned_cleanup].each do |shape|
  [1, 3].each { |size| FSM_SUSPENSION_CELLS << { shape: shape, size: size } }
end

FuzzGenerator.register(:fsm_suspension_matrix, cells: FSM_SUSPENSION_CELLS) do |p|
  n = p[:size]

  case p[:shape]
  when :linear_next
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          seed = #{n}_i64;
          inner: ~Int64 = BG { seed + 10_i64; };
          got = NEXT inner;
          got + seed;
        };
        ASSERT (NEXT outer) == #{(n * 2) + 10}_i64, "fsm linear next";
        RETURN;
      END
    CHT

  when :bare_next
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Void = BG {
          inner: ~Void = BG { RETURN; };
          NEXT inner;
        };
        NEXT outer;
        RETURN;
      END
    CHT

  when :while_next
    expected = n * (n + 1) / 2
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE i = 0_i64;
          MUTABLE total = 0_i64;
          WHILE i < #{n}_i64 DO
            child: ~Int64 = BG { i + 1_i64; };
            v = NEXT child;
            total = total + v;
            i = i + 1_i64;
          END
          total;
        };
        ASSERT (NEXT outer) == #{expected}_i64, "fsm while next";
        RETURN;
      END
    CHT

  when :while_zero
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE i = 0_i64;
          MUTABLE total = 99_i64;
          WHILE i < 0_i64 DO
            child: ~Int64 = BG { 1_i64; };
            total = total + NEXT child;
            i = i + 1_i64;
          END
          total;
        };
        ASSERT (NEXT outer) == 99_i64, "fsm zero loop";
        RETURN;
      END
    CHT

  when :for_range_sleep
    expected = n * (n + 1) / 2
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE total = 0_i64;
          FOR i IN (1_i64 ..= #{n}_i64) DO
            sleep(1);
            total = total + i;
          END
          total;
        };
        ASSERT (NEXT outer) == #{expected}_i64, "fsm for range sleep";
        RETURN;
      END
    CHT

  when :foreach_array_sleep
    <<~CHT
      FN main() RETURNS Void ->
        items = [1_i64, 2_i64, 3_i64];
        outer: ~Int64 = BG {
          MUTABLE total = 0_i64;
          FOR v IN items DO
            sleep(1);
            total = total + v;
          END
          total;
        };
        ASSERT (NEXT outer) == 6_i64, "fsm foreach array";
        RETURN;
      END
    CHT

  when :foreach_list_sleep
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE items: Int64[]@list = [];
          &items.append(1_i64); &items.append(2_i64); &items.append(3_i64);
          MUTABLE total = 0_i64;
          FOR v IN items DO
            sleep(1);
            total = total + v;
          END
          total;
        };
        ASSERT (NEXT outer) == 6_i64, "fsm foreach list";
        RETURN;
      END
    CHT

  when :foreach_pool_sleep
    <<~CHT
      STRUCT Entity { value: Int64 }

      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE pool: Entity[8]@pool = [];
          &pool.insert(Entity{ value: 1_i64 });
          &pool.insert(Entity{ value: 2_i64 });
          &pool.insert(Entity{ value: 3_i64 });
          MUTABLE total = 0_i64;
          FOR e IN pool DO
            sleep(1);
            total = total + e.value;
          END
          total;
        };
        ASSERT (NEXT outer) == 6_i64, "fsm foreach pool";
        RETURN;
      END
    CHT

  when :if_then_sleep, :if_else_sleep, :if_both_sleep
    cond = p[:shape] == :if_else_sleep ? "FALSE" : "TRUE"
    then_sleep = %i[if_then_sleep if_both_sleep].include?(p[:shape]) ? "sleep(1);" : ""
    else_sleep = %i[if_else_sleep if_both_sleep].include?(p[:shape]) ? "sleep(1);" : ""
    expected = cond == "TRUE" ? 10 : 20
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE out = 0_i64;
          IF #{cond} THEN
            #{then_sleep}
            out = 10_i64;
          ELSE
            #{else_sleep}
            out = 20_i64;
          END
          out;
        };
        ASSERT (NEXT outer) == #{expected}_i64, "fsm if suspend";
        RETURN;
      END
    CHT

  when :with_single_lock
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
        c = Counter{ value: 0_i64 } @locked;
        outer: ~Void = BG {
          delta = #{n}_i64;
          WITH EXCLUSIVE c AS inner {
            inner.value = inner.value + delta;
          }
        };
        NEXT outer;
        WITH EXCLUSIVE c AS inner {
          ASSERT inner.value == #{n}_i64, "fsm with single lock";
        }
        RETURN;
      END
    CHT

  when :with_two_locks
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
        a = Counter{ value: 0_i64 } @locked;
        b = Counter{ value: 10_i64 } @locked;
        outer: ~Void = BG {
          WITH EXCLUSIVE a AS la, EXCLUSIVE b AS lb {
            la.value = la.value + #{n}_i64;
            lb.value = lb.value - #{n}_i64;
          }
        };
        NEXT outer;
        WITH EXCLUSIVE a AS la { ASSERT la.value == #{n}_i64, "fsm lock a"; }
        WITH EXCLUSIVE b AS lb { ASSERT lb.value == #{10 - n}_i64, "fsm lock b"; }
        RETURN;
      END
    CHT

  when :bg_stream_yield
    <<~CHT
      FN main() RETURNS Void ->
        s: ~Int64[INF] = BG STREAM {
          MUTABLE i = 0_i64;
          WHILE TRUE DO
            YIELD i + #{n}_i64;
            i = i + 1_i64;
          END
        };
        ASSERT (NEXT s) == #{n}_i64, "fsm stream first";
        ASSERT (NEXT s) == #{n + 1}_i64, "fsm stream second";
        RETURN;
      END
    CHT
  when :owned_string_suspend
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~String = BG {
          sleep(1);
          s: String = COPY "abc";
          s;
        };
        out: String = NEXT outer;
        ASSERT out.length() == 3_i64, "fsm owned string suspend";
        RETURN;
      END
    CHT

  when :owned_list_suspend
    <<~CHT
      FN main() RETURNS Void ->
        outer:~ = BG {
          sleep(1);
          MUTABLE xs: Int64[]@list = [];
          &xs.append(#{n}_i64);
          xs;
        };
        out: Int64[]@list = NEXT outer;
        ASSERT out[0_i64] == #{n}_i64, "fsm owned list suspend";
        RETURN;
      END
    CHT

  when :nested_while_next
    expected = n * 3
    <<~CHT
      FN main() RETURNS Void ->
        outer: ~Int64 = BG {
          MUTABLE i = 0_i64;
          MUTABLE total = 0_i64;
          WHILE i < #{n}_i64 DO
            MUTABLE j = 0_i64;
            WHILE j < 3_i64 DO
              child: ~Int64 = BG { 1_i64; };
              total = total + NEXT child;
              j = j + 1_i64;
            END
            i = i + 1_i64;
          END
          total;
        };
        ASSERT (NEXT outer) == #{expected}_i64, "fsm nested while next";
        RETURN;
      END
    CHT

  when :lock_and_owned_result
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
        c = Counter{ value: #{n}_i64 } @locked;
        outer: ~String = BG {
          WITH EXCLUSIVE c AS x {
            x.value = x.value + 1_i64;
          }
          sleep(1);
          COPY "done";
        };
        out: String = NEXT outer;
        ASSERT out.length() == 4_i64, "fsm lock and owned result";
        RETURN;
      END
    CHT

  when :stream_owned_cleanup
    <<~CHT
      FN main() RETURNS Void ->
        s: ~String[INF] = BG STREAM {
          MUTABLE i = 0_i64;
          WHILE TRUE DO
            v: String = i.toString();
            YIELD v;
            i = i + 1_i64;
          END
        };
        first: String = NEXT s;
        second: String = NEXT s;
        ASSERT first.length() == 1_i64, "fsm stream owned first";
        ASSERT second.length() == 1_i64, "fsm stream owned second";
        RETURN;
      END
    CHT
  end
end
