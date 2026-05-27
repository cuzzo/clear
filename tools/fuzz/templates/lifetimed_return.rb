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

[:bg, :bg_stream].each do |consumer|
  [:local, :atomic_int, :locked, :write_locked, :multiowned, :shared].each do |ownership|
    [:await_in_scope, :return_handle, :store_in_field].each do |escape|
      cell = { consumer: consumer, ownership: ownership, escape: escape }
      cell[:expected] = (escape == :await_in_scope || ownership == :shared) ? :pass : :compile_error
      LIFETIMED_RETURN_CELLS << cell
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

# Declares the captured value with the given ownership inside a function body.
#
# - :local       → `MUTABLE c = Counter{} @local;` ; capture reads `c.value`
# - :atomic_int  → `MUTABLE c: Int64 = 0_i64 @shared:atomic;` ; capture reads `c`
# - :locked      → `c = Counter{ value: 0 } @locked;` ; capture reads
#                  via statement-form `WITH EXCLUSIVE`
def lifetime_value_setup(ownership)
  case ownership
  when :local
    "    MUTABLE c = Counter{ value: 0_i64 } @local;"
  when :atomic_int
    "    MUTABLE c: Int64 = 0_i64 @shared:atomic;"
  when :locked
    "    c = Counter{ value: 0_i64 } @locked;"
  when :write_locked
    "    c = Counter{ value: 0_i64 } @writeLocked;"
  when :multiowned
    "    c = Counter{ value: 0_i64 } @multiowned;"
  when :shared
    "    c = Counter{ value: 0_i64 } @shared;"
  end
end

def lifetime_bg_value_expr(ownership)
  case ownership
  when :local then "c.value"
  when :atomic_int then "c"
  when :multiowned, :shared then "c.value"
  end
end

def lifetime_locked_read_lines(indent)
  [
    "#{indent}MUTABLE locked_value: Int64 = 0_i64;",
    "#{indent}WITH EXCLUSIVE c AS x { locked_value = x.value; }",
  ]
end

def lifetime_bg_body(consumer, ownership)
  if [:locked, :write_locked].include?(ownership)
    case consumer
    when :bg
      (lifetime_locked_read_lines("    ") + ["    locked_value;"]).join("\n")
    when :bg_stream
      (["WHILE TRUE DO"] +
       lifetime_locked_read_lines("        ") +
       ["        YIELD locked_value;", "    END"]).join("\n")
    end
  else
    value = lifetime_bg_value_expr(ownership)
    case consumer
    when :bg then "#{value};"
    when :bg_stream then "WHILE TRUE DO YIELD #{value}; END"
    end
  end
end

FuzzGenerator.register(:lifetimed_return, cells: LIFETIMED_RETURN_CELLS) do |p|
  decl = lifetime_value_setup(p[:ownership])

  # Yield-shape inside the consumer body — :bg returns the value once;
  # :bg_stream YIELDs the value forever and main reads two iterations.
  bg_body = lifetime_bg_body(p[:consumer], p[:ownership])

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
    # Negative case — helper stores a BG handle in a holder and returns it.
    # The holder outlives the captured source, so later NEXT would read a
    # dead capture unless the compiler rejects the construction.
    <<~CHT
      STRUCT Counter { value: Int64 }
      STRUCT Holder { bg: #{bg_decl_type} }

      FN make_holder() RETURNS !Holder ->
      #{decl}
          RETURN Holder{ bg: #{bg_lit} };
      END

      FN main() RETURNS Void ->
          h = make_holder() OR RAISE;
          #{p[:consumer] == :bg ? 'r: Int64 = NEXT h.bg;' : 'a: Int64 = NEXT h.bg;'}
          RETURN;
      END
    CHT
  end
end
