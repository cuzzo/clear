# DEFAULT ownership-elision matrix. Mutation expectations deliberately use
# compiler metadata (stdlib/user signatures); this corpus contains no mutator
# name table and therefore catches drift between call resolution and aliasing.

AUTO_OWNERSHIP_TRANSPORT_CELLS = [
  { shape: :local_borrow, expected: :pass },
  { shape: :takes_snapshot, expected: :pass },
  { shape: :struct_snapshot, expected: :pass },
  { shape: :direct_mutation, expected: :compile_error },
  { shape: :stdlib_mutation, expected: :compile_error },
  { shape: :user_method_mutation, expected: :compile_error },
  { shape: :user_function_mutation, expected: :compile_error },
  { shape: :exclusive_branches, expected: :pass },
  { shape: :loop_backedge, expected: :compile_error },
  { shape: :rc_mutation, expected: :compile_error },
  { shape: :boundary_plain_mutation, expected: :compile_error },
  { shape: :boundary_local_mutation, expected: :compile_error },
  { shape: :boundary_rc_mutation, expected: :compile_error },
  { shape: :boundary_read, expected: :pass },
].freeze

FuzzGenerator.register(:auto_ownership_transport_matrix, cells: AUTO_OWNERSHIP_TRANSPORT_CELLS) do |p|
  case p[:shape]
  when :local_borrow
    <<~CLEAR
      STRUCT U { name: String }
      FN main() RETURNS Void ->
        x = U{ name: "a" }; y = x;
        ASSERT y.name == "a"; ASSERT x.name == "a";
      END
    CLEAR
  when :takes_snapshot
    <<~CLEAR
      STRUCT U { name: String }
      FN take(TAKES u: U) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        x = U{ name: "a" }; take(x); ASSERT x.name == "a";
      END
    CLEAR
  when :struct_snapshot
    <<~CLEAR
      STRUCT U { name: String }
      STRUCT H { u: U }
      FN main() RETURNS Void ->
        x = U{ name: "a" }; h = H{ u: x };
        ASSERT h.u.name == "a"; ASSERT x.name == "a";
      END
    CLEAR
  when :direct_mutation
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN main() RETURNS Void ->
        MUTABLE x = U{ n: 1, label: "a" }; y = x; x.n = 2_i64; ASSERT y.n == 1;
      END
    CLEAR
  when :stdlib_mutation
    <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE x: Int64[]@list = [1]; y = x; x.append(2); ASSERT y[0] == 1;
      END
    CLEAR
  when :user_method_mutation
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN setN!(MUTABLE u: U, n: Int64) RETURNS Void -> u.n = n; END
      FN main() RETURNS Void ->
        MUTABLE x = U{ n: 1, label: "a" }; y = x; x.setN!(2); ASSERT y.n == 1;
      END
    CLEAR
  when :user_function_mutation
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN setN!(MUTABLE u: U, n: Int64) RETURNS Void -> u.n = n; END
      FN main() RETURNS Void ->
        MUTABLE x = U{ n: 1, label: "a" }; y = x; setN!(x, 2); ASSERT y.n == 1;
      END
    CLEAR
  when :exclusive_branches
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN main() RETURNS Void ->
        flag = 1_i64 == 1_i64; MUTABLE x = U{ n: 1, label: "a" }; y = x;
        IF flag THEN x.n = 2_i64; ELSE ASSERT y.n == 1; END
      END
    CLEAR
  when :loop_backedge
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN main() RETURNS Void ->
        MUTABLE x = U{ n: 1, label: "a" }; y = x; MUTABLE i = 0_i64;
        WHILE i < 2 DO ASSERT y.n > 0; x.n = x.n + 1; i = i + 1; END
      END
    CLEAR
  when :rc_mutation
    <<~CLEAR
      STRUCT U { n: Int64 }
      FN main() RETURNS Void ->
        MUTABLE x = U{ n: 1 } @multiowned; y = x; x.n = 2_i64; ASSERT y.n == 2;
      END
    CLEAR
  when :boundary_plain_mutation, :boundary_local_mutation, :boundary_rc_mutation
    suffix = case p[:shape]
    when :boundary_local_mutation then " @local"
    when :boundary_rc_mutation then " @multiowned"
    else ""
    end
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN setN!(MUTABLE u: U, n: Int64) RETURNS Void -> u.n = n; END
      FN main() RETURNS !Void ->
        MUTABLE x = U{ n: 1, label: "a" }#{suffix}; y = x;
        pending: ~Void = BG { setN!(x, 2); };
        ASSERT y.n == 1; NEXT pending; RETURN;
      END
    CLEAR
  when :boundary_read
    <<~CLEAR
      STRUCT U { n: Int64, label: String }
      FN read(u: U) RETURNS Int64 -> RETURN u.n; END
      FN main() RETURNS !Void ->
        x = U{ n: 1, label: "a" }; y = x;
        pending: ~Int64 = BG { read(x); };
        ASSERT y.n == 1; n = NEXT pending; ASSERT n == 1; RETURN;
      END
    CLEAR
  end
end
