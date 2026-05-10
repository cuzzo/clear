# Template: BG / BG STREAM handle that captures a lifetime-bound source
# must be rejected on escape.
#
# Source mechanism: src/annotator.rb:6449 `bg_lifetime_sources` stamps a
# lifetime on the BG handle's symbol when it captures a binding whose
# sync ∈ {:atomic, :locked, :write_locked, :local} or storage == :multiowned.
# Plain @shared (Arc, no sync) is NOT lifetime-bound — refcount handles it.
#
# This matrix verifies STAMPING translates into ENFORCEMENT. A by-hand
# probe (RETURN BG{capture}, with `c @local`) compiled cleanly and then
# crashed at runtime with SIGABRT — so the gap is real.
#
# Cell shape:
#   { consumer:, ownership:, escape:, expected: }
#
# - consumer ∈ {:bg, :bg_stream}
# - ownership ∈ {:local, :atomic_int, :locked} — three lifetime-bound shapes
#   covering: raw *T (@local), bare Atomic primitive (@shared:atomic Int64),
#   Arc(Locked(struct)) (@locked struct).
# - escape ∈ {:await_in_scope, :return_handle, :store_in_field}
#   - :await_in_scope is the positive baseline (canonical safe pattern)
#   - :return_handle is the negative case ⇒ expected :compile_error
#   - :store_in_field is the negative case (heap-struct field stores
#     a captured handle) ⇒ expected :compile_error

LIFETIMED_RETURN_CELLS = []

# v1 active: :local ownership only — exercises the @local lifetime-stamp
# path in src/annotator.rb:6457 and immediately surfaced two real bugs
# (return_handle and store_in_field both UNEXPECTED-PASS at compile,
# crash with SIGABRT at runtime).
#
# v1 in_dev: :atomic_int and :locked. The await_in_scope baseline for
# both currently fails compilation because BG capture of @shared:atomic
# / @locked does not auto-unwrap inside the BG body (you get a *AtomicInt
# / Arc(Locked) pointer where an Int64 is expected). That's a separate
# bug class from lifetime enforcement; folding it in here would conflate
# findings. Flip these to :pass once the BG-body unwrap path lands.
[:bg, :bg_stream].each do |consumer|
  [:local, :atomic_int, :locked].each do |ownership|
    [:await_in_scope, :return_handle, :store_in_field].each do |escape|
      cell = { consumer: consumer, ownership: ownership, escape: escape }
      cell[:expected] = (escape == :await_in_scope) ? :pass : :compile_error
      cell[:expected] = :in_dev if ownership != :local
      LIFETIMED_RETURN_CELLS << cell
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

# Declares the captured value with the given ownership inside a function
# body. Returns: [decl_lines, value_expr_inside_bg_body].
#
# - :local       → `MUTABLE c = Counter{} @local;` ; capture reads `c.value`
# - :atomic_int  → `MUTABLE c: Int64 = 0_i64 @shared:atomic;` ; capture reads `c`
# - :locked      → `c = Counter{ value: 0 } @locked;` ; capture reads
#                  via `WITH EXCLUSIVE c AS x { x.value }`
def lifetime_value_setup(ownership)
  case ownership
  when :local
    decl = "    MUTABLE c = Counter{ value: 0_i64 } @local;"
    use  = "c.value"
  when :atomic_int
    decl = "    MUTABLE c: Int64 = 0_i64 @shared:atomic;"
    use  = "c"
  when :locked
    decl = "    c = Counter{ value: 0_i64 } @locked;"
    use  = "WITH EXCLUSIVE c AS x { x.value }"
  end
  [decl, use]
end

FuzzGenerator.register(:lifetimed_return, cells: LIFETIMED_RETURN_CELLS) do |p|
  decl, use = lifetime_value_setup(p[:ownership])

  # Yield-shape inside the consumer body — :bg returns the value once;
  # :bg_stream YIELDs the value forever and main reads two iterations.
  bg_body = case p[:consumer]
  when :bg        then "#{use}; "
  when :bg_stream then "WHILE TRUE DO YIELD #{use}; END"
  end

  bg_decl_type = case p[:consumer]
  when :bg        then "~Int64"
  when :bg_stream then "~Int64[INF]"
  end

  bg_lit = "BG#{p[:consumer] == :bg_stream ? ' STREAM' : ''} { #{bg_body} }"

  case p[:escape]
  when :await_in_scope
    # Positive baseline — declare, capture, await IN SAME SCOPE. Should pass.
    consume_block = case p[:consumer]
    when :bg
      <<~CHT.chomp
        bg: #{bg_decl_type} = #{bg_lit};
            r: Int64 = NEXT bg;
            ASSERT r == 0_i64, "await produced a value";
      CHT
    when :bg_stream
      <<~CHT.chomp
        bg: #{bg_decl_type} = #{bg_lit};
            a: Int64 = NEXT bg;
            b: Int64 = NEXT bg;
            ASSERT a == 0_i64, "stream first";
            ASSERT b == 0_i64, "stream second";
      CHT
    end

    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
      #{decl}
          #{consume_block}
          RETURN;
      END
    CHT

  when :return_handle
    # Negative case — helper declares the source, returns a BG that captures
    # it. Source dies before BG is awaited. Today's compiler accepts; runtime
    # crashes (SIGABRT in scheduler). Should be rejected at compile.
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN spawn() RETURNS #{bg_decl_type} ->
      #{decl}
          RETURN #{bg_lit};
      END

      FN main() RETURNS Void ->
          bg = spawn();
          #{p[:consumer] == :bg ? 'r: Int64 = NEXT bg;' : 'a: Int64 = NEXT bg;'}
          RETURN;
      END
    CHT

  when :store_in_field
    # Negative case — heap-allocated holder stores a BG handle that
    # captures the source. Holder outlives source ⇒ UAF on later NEXT.
    <<~CHT
      STRUCT Counter { value: Int64 }
      STRUCT Holder { bg: #{bg_decl_type} }

      FN main() RETURNS Void ->
      #{decl}
          MUTABLE h: Holder = Holder{ bg: #{bg_lit} };
          #{p[:consumer] == :bg ? 'r: Int64 = NEXT h.bg;' : 'a: Int64 = NEXT h.bg;'}
          RETURN;
      END
    CHT
  end
end
