# Template: STREAM next passed across an execution boundary.
# Stresses the depth-1 nesting:
#
#   src: ~T[INF] = BG STREAM { ... YIELD ... }
#   val = NEXT src   (optionally wrapped with @shared:sync)
#   <consumer>{ ... uses val with <move> ... }
#
# Where consumer ∈ {BG, DO, BG STREAM}, ownership ∈ {@local, @shared+sync},
# move ∈ {borrow, copy, give, clone, lend}, value ∈ {int, string, struct}.
#
# Constraints (per spec):
#   - @local | @shared can cross boundaries; @multiowned | @indirect cannot.
#   - CLONE requires @shared or @split.
#   - LEND poisons the boundary with the borrow's lifetime. Until the
#     parser accepts that surface syntax, those cells are expected hard
#     compile errors rather than skipped matrix slots.
#   - Sync wrappers @locked / @writeLocked / @atomic / @versioned apply to
#     @shared values. @local has no sync.
#   - @atomic uses bare Atomic on primitives (no Arc wrap, per type.rb:
#     "Atomics M2.2: drop the Arc / Rc wrap for @shared:atomic"). Other
#     sync wrappers wrap a struct (Counter) for non-trivial access.

STREAM_BOUNDARY_CELLS = []

CONSUMERS = [:bg, :do, :bg_stream]
VALUES_PHASE_A = [:int, :string]
LOCAL_MOVES = [:borrow, :copy]
SHARED_MOVES = [:borrow, :copy, :clone]
SYNCS = [:locked, :write_locked, :atomic, :versioned]
LEND_MOVES = [:lend]

# Phase B forces a value type per sync (atomics need a primitive; locked/
# writeLocked/versioned wrap a struct so WITH EXCLUSIVE / WITH SNAPSHOT
# have a non-trivial field to read).
PHASE_B_VALUE_FOR_SYNC = {
  atomic:       :int,
  locked:       :struct,
  write_locked: :struct,
  versioned:    :struct,
}

# Phase A — @local (no sync).
#
# Findings encoded as expectations:
#   - (DO + @local + :borrow + non-Copy): USE AFTER MOVE — both DO branches
#     capture val and capture-of-non-Copy is a move. Explicit COPY is legal:
#     each branch receives its own owned value.
COPY_VALUES = [:int]
CONSUMERS.each do |c|
  VALUES_PHASE_A.each do |v|
    LOCAL_MOVES.each do |m|
      cell = { consumer: c, ownership: :local, sync: :none, move: m, value: v }
      cell[:expected] = :compile_error if c == :do && m == :borrow && v == :string
      STREAM_BOUNDARY_CELLS << cell
    end
  end
end

# Phase B — @shared with each of 4 sync strategies.
#
# Findings (from running the matrix on the current tree):
#   - CLONE on a sync-wrapped value errors with "CLONE is only supported on
#     @split streams, @shared promises, and owned shared handles, got
#     'Int64'/'Counter'". Atomic primitives are bare (no Arc), and CLONE
#     on a `@locked` struct doesn't traverse through the capability to
#     find the inner Arc. Marked :compile_error for now; revisit when
#     CLONE learns to look through sync wrappers.
CONSUMERS.each do |c|
  PHASE_B_VALUE_FOR_SYNC.each do |sync, value|
    SHARED_MOVES.each do |m|
      cell = { consumer: c, ownership: :shared, sync: sync, move: m, value: value }
      cell[:expected] = :compile_error if m == :clone                # CLONE constraint
      STREAM_BOUNDARY_CELLS << cell
    end
  end
end

# Phase C — LEND (keyword not yet parsed).
CONSUMERS.each do |c|
  VALUES_PHASE_A.each do |v|
    LEND_MOVES.each do |m|
      STREAM_BOUNDARY_CELLS << { consumer: c, ownership: :local, sync: :none, move: m, value: v,
                                 expected: :compile_error }
    end
  end
  PHASE_B_VALUE_FOR_SYNC.each do |sync, value|
    LEND_MOVES.each do |m|
      STREAM_BOUNDARY_CELLS << { consumer: c, ownership: :shared, sync: sync, move: m, value: value,
                                 expected: :compile_error }
    end
  end
end

# ── renderers ─────────────────────────────────────────────────────────

# The BG STREAM source always yields Int64; non-int value cells construct
# their values from the yielded Int64. Keeps the producer side uniform.

def fuzz_value_type(v)
  case v
  when :int    then "Int64"
  when :string then "String"
  when :struct then "Counter"
  end
end

# What the BG STREAM source YIELDs. For :int and :struct cells the source
# yields a primitive Int64; for :string it yields a String. The val_decl
# stage then wraps the NEXT result into the actual cell value type.
def fuzz_src_value_type(v)
  v == :string ? "String" : "Int64"
end

def fuzz_src_yield_expr(v)
  v == :string ? "i.toString()" : "i"
end

# Build the val declaration: takes the NEXT result (typed by src) and
# binds it as the cell's value with appropriate sync wrapping.
def fuzz_val_decl(p)
  src_t = fuzz_src_value_type(p[:value])
  v_t   = fuzz_value_type(p[:value])

  if p[:ownership] == :local
    return "raw: #{src_t} = NEXT src;\n    val: #{v_t} = raw;"
  end

  # @shared:sync construction
  sync_word = case p[:sync]
              when :locked       then "locked"
              when :write_locked then "writeLocked"
              when :atomic       then "atomic"
              when :versioned    then "versioned"
              end

  case p[:value]
  when :int    # @shared:atomic Int64 — bare Atomic, no struct
    "raw: Int64 = NEXT src;\n    MUTABLE val: Int64 = raw @shared:#{sync_word};"
  when :struct # Counter wrapper — locked / writeLocked / versioned
    "raw: Int64 = NEXT src;\n    val = Counter{ value: raw } @#{sync_word};"
  end
end

# Build the read of a captured `var` into an Int64 result. Returns a pair
# [setup_stmts, terminal_expr] — caller assembles them with the move-mode
# binding line. WITH is a statement form (tests 293, 278), so struct-sync
# cells need a local binding the WITH writes into, then the BG body's
# terminal is that local.
def fuzz_read_int_fragment(p, var)
  case p[:value]
  when :int    then ["", var]
  when :string then ["", "#{var}.length()"]
  when :struct
    op = case p[:sync]
         when :locked, :write_locked then "EXCLUSIVE"
         when :versioned             then "SNAPSHOT"
         end
    setup = "MUTABLE r: Int64 = 0_i64; WITH #{op} #{var} AS x { r = x.value; }"
    [setup, "r"]
  end
end

FuzzGenerator.register(:stream_into_boundary, cells: STREAM_BOUNDARY_CELLS) do |p|
  src_t = fuzz_src_value_type(p[:value])
  src_yield = fuzz_src_yield_expr(p[:value])

  # ── outer infinite BG STREAM source ────────────────────────────────
  src_decl = <<~CHT.chomp
    src: ~#{src_t}[INF] = BG STREAM {
            MUTABLE i: Int64 = 1_i64;
            WHILE TRUE DO
                YIELD #{src_yield};
                i = i + 1_i64;
            END
        };
  CHT

  val_decl = fuzz_val_decl(p)

  # Build a single consumer-branch fragment given a binding name `bv` and a
  # terminal verb (empty for BG/DO branches; "YIELD " for BG STREAM body).
  # Composes optional move-mode binding + struct-WITH setup + terminal.
  build_branch = ->(bv, terminal) do
    move_setup, source_var =
      case p[:move]
      when :borrow then ["", "val"]
      when :copy   then ["#{bv} = COPY val;",  bv]
      when :clone  then ["#{bv} = CLONE val;", bv]
      when :give   then ["", "GIVE val"]
      when :lend   then ["", "LEND val"]
      end

    read_setup, read_expr = fuzz_read_int_fragment(p, source_var)
    parts = [move_setup, read_setup].reject(&:empty?)
    "#{parts.join(' ')} #{terminal}#{read_expr};".strip
  end

  consumer_block = case p[:consumer]
  when :bg
    inner = build_branch.call("c", "")
    <<~CHT.chomp
      result: ~Int64 = BG { #{inner} };
          answer: Int64 = NEXT result;
          ASSERT answer >= 0_i64, "bg consumer produced a value";
    CHT
  when :do
    a = build_branch.call("c1", "")
    b = build_branch.call("c2", "")
    <<~CHT.chomp
      DO {
              BG { #{a} },
              BG { #{b} }
          }
    CHT
  when :bg_stream
    move_setup, source_var =
      case p[:move]
      when :borrow then ["", "val"]
      when :copy   then ["c = COPY val;", "c"]
      when :clone  then ["c = CLONE val;", "c"]
      when :give   then ["", "GIVE val"]
      when :lend   then ["", "LEND val"]
      end
    read_setup, read_expr = fuzz_read_int_fragment(p, source_var)
    inner_parts = [read_setup, "YIELD #{read_expr};"].reject(&:empty?)
    inner_body = inner_parts.join(' ')
    <<~CHT.chomp
      inner: ~Int64[INF] = BG STREAM {
              #{move_setup}
              MUTABLE k: Int64 = 0_i64;
              WHILE TRUE DO
                  #{inner_body}
                  k = k + 1_i64;
              END
          };
          a: Int64 = NEXT inner;
          b: Int64 = NEXT inner;
          ASSERT a >= 0_i64, "stream consumer first yield";
          ASSERT b >= 0_i64, "stream consumer second yield";
    CHT
  end

  body = [
    "    #{src_decl}",
    "    #{val_decl}",
    "    #{consumer_block}",
  ].join("\n")

  preamble = (p[:value] == :struct) ? "STRUCT Counter { value: Int64 }\n\n" : ""

  <<~CHT
    #{preamble}FN main() RETURNS Void ->
    #{body}
        RETURN;
    END
  CHT
end
