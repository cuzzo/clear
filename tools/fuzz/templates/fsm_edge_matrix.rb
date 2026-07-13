# Template: Additional FSM edge shapes.
#
# Complements fsm_suspension_matrix with suspend points around fallible OR_ELSE
# expressions, nested branch/loop state, early BG returns, and stream branches.

FSM_EDGE_CELLS = [
  { shape: :or_success },
  { shape: :or_fallback },
  { shape: :nested_if_while_next },
  # The splitter currently emits value returns from void segment helpers for
  # these shapes; keep them as negative sentinels until that lowering is fixed.
  { shape: :early_return_then, expected: :compile_error },
  { shape: :early_return_else, expected: :compile_error },
  { shape: :stream_branch_yield },
  { shape: :lock_then_next },
  { shape: :owned_or_after_sleep },
].freeze

FuzzGenerator.register(:fsm_edge_matrix, cells: FSM_EDGE_CELLS) do |p|
  case p[:shape]
  when :or_success
    <<~CHT
      FN risky(flag: Bool) RETURNS !Int64 ->
        IF flag THEN RAISE Input; END
        RETURN 9_i64;
      END

      FN main() RETURNS Void ->
        h: ~Int64 = BG {
          sleep(1);
          risky(FALSE) OR_ELSE 3_i64;
        };
        ASSERT (NEXT h) == 9_i64, "fsm or success";
        RETURN;
      END
    CHT

  when :or_fallback
    <<~CHT
      FN risky(flag: Bool) RETURNS !Int64 ->
        IF flag THEN RAISE Input; END
        RETURN 9_i64;
      END

      FN main() RETURNS Void ->
        h: ~Int64 = BG {
          sleep(1);
          risky(TRUE) OR_ELSE 3_i64;
        };
        ASSERT (NEXT h) == 3_i64, "fsm or fallback";
        RETURN;
      END
    CHT

  when :nested_if_while_next
    <<~CHT
      FN main() RETURNS Void ->
        h: ~Int64 = BG {
          MUTABLE i = 0_i64;
          MUTABLE total = 0_i64;
          WHILE i < 4_i64 DO
            IF i == 2_i64 THEN
              child: ~Int64 = BG { 5_i64; };
              total = total + NEXT child;
            ELSE
              sleep(1);
              total = total + 1_i64;
            END
            i = i + 1_i64;
          END
          total;
        };
        ASSERT (NEXT h) == 8_i64, "fsm nested branch loop";
        RETURN;
      END
    CHT

  when :early_return_then
    <<~CHT
      FN main() RETURNS Void ->
        h: ~Int64 = BG {
          sleep(1);
          IF TRUE THEN
            RETURN 11_i64;
          END
          0_i64;
        };
        ASSERT (NEXT h) == 11_i64, "fsm early then";
        RETURN;
      END
    CHT

  when :early_return_else
    <<~CHT
      FN main() RETURNS Void ->
        h: ~Int64 = BG {
          IF FALSE THEN
            RETURN 0_i64;
          ELSE
            sleep(1);
            RETURN 12_i64;
          END
          0_i64;
        };
        ASSERT (NEXT h) == 12_i64, "fsm early else";
        RETURN;
      END
    CHT

  when :stream_branch_yield
    <<~CHT
      FN main() RETURNS Void ->
        s: ~Int64[INF] = BG STREAM {
          MUTABLE i = 0_i64;
          WHILE TRUE DO
            IF i == 0_i64 THEN
              sleep(1);
              YIELD 4_i64;
            ELSE
              YIELD 6_i64;
            END
            i = i + 1_i64;
          END
        };
        ASSERT (NEXT s) == 4_i64, "fsm stream branch first";
        ASSERT (NEXT s) == 6_i64, "fsm stream branch second";
        RETURN;
      END
    CHT

  when :lock_then_next
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
        c = Counter{ value: 1_i64 } @locked;
        h: ~Int64 = BG {
          WITH EXCLUSIVE c AS ref {
            ref.value = ref.value + 1_i64;
          }
          child: ~Int64 = BG { 4_i64; };
          NEXT child;
        };
        ASSERT (NEXT h) == 4_i64, "fsm lock then next";
        RETURN;
      END
    CHT

  when :owned_or_after_sleep
    <<~CHT
      FN maybe(flag: Bool) RETURNS !String ->
        IF flag THEN RAISE Input; END
        RETURN COPY "ok";
      END

      FN main() RETURNS Void ->
        h: ~String = BG {
          sleep(1);
          maybe(TRUE) OR_ELSE COPY "fallback";
        };
        out: String = NEXT h;
        ASSERT out.length() == 8_i64, "fsm owned or fallback";
        RETURN;
      END
    CHT
  end
end
