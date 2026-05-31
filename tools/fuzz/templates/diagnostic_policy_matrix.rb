# Template: Diagnostic/policy front-end paths.
#
# Keeps policy-heavy gaps in the fuzz matrix without large bespoke specs:
# reentrancy effects, hold-lock-across-yield, lock-cycle opt-outs, and a few
# fixable ownership/admission rejections.

DIAGNOSTIC_POLICY_CELLS = [
  { shape: :tight_thunk_inside_lock },
  { shape: :max_depth_inside_lock },
  { shape: :multi_resource_lock_order },
  { shape: :lock_timeout_handler },
  { shape: :thunk_inside_lock_reject, expected: :compile_error },
  { shape: :plain_reentrant_inside_lock_reject, expected: :compile_error },
  { shape: :bad_reentrant_variant, expected: :compile_error },
  { shape: :bad_requires_family, expected: :compile_error },
  { shape: :same_lock_nested_reject, expected: :compile_error },
  { shape: :same_type_nested_reject, expected: :compile_error },
  { shape: :deadlock_handler_unreachable, expected: :compile_error },
  { shape: :clone_with_alias_reject, expected: :compile_error },
  { shape: :moved_string_reuse, expected: :compile_error },
  { shape: :double_give_list, expected: :compile_error },
].freeze

FuzzGenerator.register(:diagnostic_policy_matrix, cells: DIAGNOSTIC_POLICY_CELLS) do |p|
  case p[:shape]
  when :tight_thunk_inside_lock
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:TIGHT:THUNK ->
        IF n <= 1_i64 -> RETURN 1_i64;
        RETURN n * factorial(n - 1_i64);
      END

      FN main() RETURNS Void ->
        c = Counter{ value: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref {
          x = factorial(4_i64);
          ref.value = x;
        }
        RETURN;
      END
    CHT

  when :max_depth_inside_lock
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN bounded(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(64) ->
        RETURN n + 1_i64;
      END

      FN main() RETURNS Void ->
        c = Counter{ value: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref {
          ref.value = bounded(4_i64) OR 0_i64;
        }
        RETURN;
      END
    CHT

  when :multi_resource_lock_order
    <<~CHT
      STRUCT C { v: Int64 }

      FN main() RETURNS Void ->
        a = C{ v: 1_i64 } @locked;
        b = C{ v: 2_i64 } @locked;
        WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y {
          x.v = x.v + y.v;
        }
        RETURN;
      END
    CHT

  when :lock_timeout_handler
    <<~CHT
      STRUCT C { v: Int64 }

      FN main() RETURNS Void ->
        c = C{ v: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref { ref.v = 1_i64; } ON LockTimeout PASS
        RETURN;
      END
    CHT

  when :thunk_inside_lock_reject
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 1_i64 -> RETURN 1_i64;
        RETURN n * factorial(n - 1_i64);
      END

      FN main() RETURNS Void ->
        c = Counter{ value: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref {
          ref.value = factorial(4_i64);
        }
        RETURN;
      END
    CHT

  when :plain_reentrant_inside_lock_reject
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN recur(n: Int64) RETURNS Int64
        EFFECTS REENTRANT ->
        IF n <= 0_i64 -> RETURN 0_i64;
        RETURN recur(n - 1_i64);
      END

      FN main() RETURNS Void ->
        c = Counter{ value: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref {
          ref.value = recur(4_i64);
        }
        RETURN;
      END
    CHT

  when :bad_reentrant_variant
    <<~CHT
      FN factorial(n: Int64) RETURNS Int64 EFFECTS REENTRANT:THONK ->
        RETURN n;
      END

      FN main() RETURNS Void -> RETURN; END
    CHT

  when :bad_requires_family
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN incr(MUTABLE c: Counter) RETURNS Void REQUIRES c: LOKKED -> RETURN; END
      FN main() RETURNS Void -> RETURN; END
    CHT

  when :same_lock_nested_reject
    <<~CHT
      STRUCT C { v: Int64 }

      FN main() RETURNS Void ->
        c = C{ v: 0_i64 } @locked;
        WITH EXCLUSIVE c AS outer {
          WITH EXCLUSIVE c AS inner { inner.v = 1_i64; }
        }
        RETURN;
      END
    CHT

  when :same_type_nested_reject
    <<~CHT
      STRUCT C { v: Int64 }

      FN main() RETURNS Void ->
        a = C{ v: 0_i64 } @locked;
        b = C{ v: 0_i64 } @locked;
        WITH EXCLUSIVE a AS x {
          WITH EXCLUSIVE b AS y { y.v = x.v; }
        }
        RETURN;
      END
    CHT

  when :deadlock_handler_unreachable
    <<~CHT
      STRUCT C { v: Int64 }

      FN main() RETURNS Void ->
        c = C{ v: 0_i64 } @locked;
        WITH EXCLUSIVE c AS ref { ref.v = 1_i64; } ON Deadlock PASS
        RETURN;
      END
    CHT

  when :clone_with_alias_reject
    <<~CHT
      STRUCT C { v: String }

      FN leak() RETURNS !C ->
        c = C{ v: COPY "abc" } @locked;
        WITH EXCLUSIVE c AS ref {
          RETURN CLONE ref;
        }
      END

      FN main() RETURNS Void ->
        x = leak() OR EXIT "no";
        RETURN;
      END
    CHT

  when :moved_string_reuse
    <<~CHT
      FN take(TAKES s: String) RETURNS Int64 ->
        RETURN s.length();
      END

      FN main() RETURNS Void ->
        s: String = COPY "abc";
        n = take(GIVE s);
        m = s.length();
        RETURN;
      END
    CHT

  when :double_give_list
    <<~CHT
      FN take(TAKES xs: Int64[]@list) RETURNS Int64 ->
        RETURN xs.length();
      END

      FN main() RETURNS Void ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(1_i64);
        a = take(GIVE xs);
        b = take(GIVE xs);
        RETURN;
      END
    CHT
  end
end
