# Template: execution-boundary admission rules.
# What can / can't cross BG / DO / BG STREAM with and without @parallel
# (or @pinned)?
#
# This is the broader matrix from formal-verification-testing.md TODO #2,
# focused on the modifier × ownership cross-product. The narrower
# stream_into_boundary template covers move-mode + sync-wrapper variation;
# this one is about the modifier rules from src/ast/diagnostic_registry.rb.
#
# Diagnostic rules under test (per src/ast/diagnostic_registry.rb):
#   - "@local variable cannot be used in @parallel block — it requires
#     single-scheduler affinity."
#   - "@multiowned (Rc) variable cannot be used in @parallel block — Rc
#     uses a non-atomic reference count. Use @shared (Arc) for cross-
#     scheduler sharing."
#   - "@arena cannot be combined with @parallel — arena memory is
#     thread-local and cannot be stolen."
#   - "BG block inside @pinned scope captures local variables but is not
#     @pinned." (deferred to a separate cell category — needs nesting)
#
# Cell schema:
#   { boundary:, modifier:, ownership:, expected: }
#
#   boundary  ∈ {:bg, :do, :bg_stream}
#   modifier  ∈ {:none, :parallel, :pinned}
#   ownership ∈ {:local, :shared_locked, :multiowned}
#
# 3 × 3 × 3 = 27 cells.
#
# Expected (per docs + diagnostic registry):
#   - (any boundary, :parallel, :local)      → :compile_error
#   - (any boundary, :parallel, :multiowned) → :compile_error
#   - (any boundary, :parallel, :shared_lck) → :pass
#   - all :none and :pinned cells            → :pass
#
# Reality may differ (DO + @local was found to fail at codegen even
# without @parallel in the stream_into_boundary template). The matrix
# documents which cells fall through.

EXECUTION_BOUNDARY_CELLS = []

EB_BOUNDARIES = [:bg, :do, :bg_stream]
EB_MODIFIERS  = [:none, :parallel, :pinned]
EB_OWNERSHIPS = [:plain, :local, :multiowned, :shared, :shared_locked, :locked, :write_locked, :versioned, :atomic_int]

EB_BOUNDARIES.each do |b|
  EB_MODIFIERS.each do |m|
    EB_OWNERSHIPS.each do |o|
      cell = { boundary: b, modifier: m, ownership: o }
      cell[:expected] =
        if b == :bg_stream && m != :none
          :compile_error
        elsif m == :parallel && [:local, :multiowned, :locked, :write_locked, :versioned].include?(o)
          :compile_error
        else
          :pass
        end
      EXECUTION_BOUNDARY_CELLS << cell
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

def eb_value_decl(o)
  case o
  when :plain         then "MUTABLE c = Counter{ value: 0_i64 };"
  when :local         then "MUTABLE c = Counter{ value: 0_i64 } @local;"
  when :shared        then "c = Counter{ value: 0_i64 } @shared;"
  when :shared_locked then "c = Counter{ value: 0_i64 } @shared:locked;"
  when :locked        then "c = Counter{ value: 0_i64 } @locked;"
  when :write_locked  then "c = Counter{ value: 0_i64 } @writeLocked;"
  when :versioned     then "c = Counter{ value: 0_i64 } @versioned;"
  when :atomic_int    then "MUTABLE c: Int64 = 0_i64 @shared:atomic;"
  when :multiowned    then "c = Counter{ value: 0_i64 } @multiowned;"
  end
end

# Body fragment that uses `c` and produces an Int64. Different ownerships
# need different access patterns:
#   @local         → direct read/write on c.value
#   @shared:locked → WITH EXCLUSIVE c AS x { ... }
#   @multiowned    → WITH c AS val { val.value } (Rc is read-only)
def eb_body_int(o)
  # Body for BG — must produce an Int64. Use inner_r to avoid shadowing
  # main's r. Returns a complete multi-statement fragment.
  case o
  when :plain, :local, :shared then "c.value"
  when :shared_locked then "MUTABLE inner_r: Int64 = 0_i64; WITH EXCLUSIVE c AS x { inner_r = x.value; } inner_r"
  when :locked, :write_locked then "MUTABLE inner_r: Int64 = 0_i64; WITH EXCLUSIVE c AS x { inner_r = x.value; } inner_r"
  when :versioned     then "MUTABLE inner_r: Int64 = 0_i64; WITH SNAPSHOT c AS x { inner_r = x.value; } inner_r"
  when :atomic_int    then "c"
  when :multiowned    then "MUTABLE inner_r: Int64 = 0_i64; WITH c { inner_r = c.value; } inner_r"
  end
end

# BG STREAM body: returns [setup_stmts, yield_expr]. YIELD requires a single
# expression, so multi-statement bodies (locked/multiowned) need to set up a
# local before the YIELD.
def eb_stream_body(o)
  case o
  when :plain, :local, :shared then ["", "c.value"]
  when :shared_locked then ["MUTABLE inner_r: Int64 = 0_i64; WITH EXCLUSIVE c AS x { inner_r = x.value; }", "inner_r"]
  when :locked, :write_locked then ["MUTABLE inner_r: Int64 = 0_i64; WITH EXCLUSIVE c AS x { inner_r = x.value; }", "inner_r"]
  when :versioned     then ["MUTABLE inner_r: Int64 = 0_i64; WITH SNAPSHOT c AS x { inner_r = x.value; }", "inner_r"]
  when :atomic_int    then ["", "c"]
  when :multiowned    then ["MUTABLE inner_r: Int64 = 0_i64; WITH c { inner_r = c.value; }", "inner_r"]
  end
end

# Single-statement body for DO branches — produces no value, just exercises
# the access path. DO branches don't need an Int64 result.
def eb_body_void(o)
  case o
  when :plain, :local, :shared then "touch(c.value)"
  when :shared_locked then "WITH EXCLUSIVE c AS x { touch(x.value); }"
  when :locked, :write_locked then "WITH EXCLUSIVE c AS x { touch(x.value); }"
  when :versioned     then "WITH SNAPSHOT c AS x { touch(x.value); }"
  when :atomic_int    then "touch(c)"
  when :multiowned    then "WITH c { touch(c.value); }"
  end
end

# Produce the modifier prefix for a BG body / DO branch.
def eb_modifier_prefix(m)
  case m
  when :none     then ""
  when :parallel then "@parallel -> "
  when :pinned   then "@pinned -> "
  end
end

FuzzGenerator.register(:execution_boundary, cells: EXECUTION_BOUNDARY_CELLS) do |p|
  decl = eb_value_decl(p[:ownership])
  prefix = eb_modifier_prefix(p[:modifier])

  consumer = case p[:boundary]
  when :bg
    body = eb_body_int(p[:ownership])
    <<~CHT.chomp
      bg: ~Int64 = BG { #{prefix}#{body}; };
          r: Int64 = NEXT bg;
          ASSERT r >= 0_i64, "bg consumer produced a value";
    CHT
  when :do
    # DO branches need single-statement bodies (no inline MUTABLE binds).
    # Branches separated by `,`. The void body already ends with `;`; strip
    # for the comma-separated form.
    body_no_semi = eb_body_void(p[:ownership]).chomp(';')
    <<~CHT.chomp
      DO {
              #{prefix}#{body_no_semi},
              #{prefix}#{body_no_semi}
          }
    CHT
  when :bg_stream
    setup, yexpr = eb_stream_body(p[:ownership])
    # `prefix` (@parallel / @pinned) does not parse inside BG STREAM bodies
    # — the parser has no equivalent of parse_bg_prefix for streams. Cells
    # using a modifier with bg_stream will fail at parse; left visible.
    <<~CHT.chomp
      s: ~Int64[INF] = BG STREAM {
              #{prefix}WHILE TRUE DO #{setup} YIELD #{yexpr}; END
          };
          a: Int64 = NEXT s;
          ASSERT a >= 0_i64, "stream produced a value";
    CHT
  end

  <<~CHT
    STRUCT Counter { value: Int64 }

    FN touch(v: Int64) RETURNS Void ->
        RETURN;
    END

    FN main() RETURNS Void ->
        #{decl}
        #{consumer}
        RETURN;
    END
  CHT
end
