# Template: cleanup correctness inside loop bodies.
# Stresses INV-2 (every alloc has a cleanup on every path) + INV-6 (loop
# bodies that frame-allocate have per-iteration mark/rewind) under
# control-flow disruptors that may skip the cleanup point.
#
# Recent bugs in this category that motivated the template:
#   - 9fa21926 fix(mir): cover escaping frame collections in loops
#   - d80e6539 fix(mir): narrow loop escape promotion to strings
#   - 1599bfb1 (loop-local list double-free)
# These bugs all involved a frame-arena alloc inside a loop body and a
# control-flow shape that didn't quite line up with the mark/rewind logic.
#
# Cell schema:
#   { alloc:, disruptor:, dest:, expected: }
#
#   alloc     ∈ ALLOC_KINDS (from _cleanup_dimensions.rb)
#   disruptor ∈ {:none, :break, :continue, :early_return, :raise}
#   dest      ∈ VALUE_DESTS — :locally_cleaned (per-iteration scope-end
#               cleanup) or :appended_to_outer (forces heap promotion)
#
# Expected: :pass for every cell. A leak / Invalid free / UAF / MIR-FAIL
# is the matrix's signal that the alloc/cleanup pairing is broken for
# that combination.

require_relative '_cleanup_dimensions'

LOOP_CLEANUP_CELLS = []

LOOP_DISRUPTORS = [:none, :break, :continue, :early_return, :raise]

CleanupDims::ALLOC_KINDS.each do |a|
  LOOP_DISRUPTORS.each do |d|
    CleanupDims::VALUE_DESTS.each do |dest|
      LOOP_CLEANUP_CELLS << { alloc: a, disruptor: d, dest: dest }
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

# Build the loop-body fragment for a given (alloc, disruptor, dest).
# Returns the body that goes between FOR i IN ... DO and END.
def loop_cleanup_body(p)
  decl = CleanupDims.alloc_decl(p[:alloc], idx_expr: "i")
  use  = CleanupDims.use_stmt(p[:alloc],  idx_expr: "i")

  disruptor = case p[:disruptor]
  when :none         then nil
  when :break        then "IF i == 3_i64 THEN BREAK; END"
  when :continue     then "IF i == 2_i64 THEN CONTINUE; END"
  when :early_return
    return_expr = p[:dest] == :appended_to_outer ? "RETURN outer;" : "RETURN;"
    "IF i == 2_i64 THEN #{return_expr} END"
  when :raise        then "IF i == 2_i64 THEN RAISE; END"
  end

  escape = (p[:dest] == :appended_to_outer) ? "&outer.append(v);" : nil

  # Order matters for the disruptor: continue jumps over the use, so put
  # use BEFORE continue. Other disruptors AFTER decl + use so the alloc
  # is live at the disruptor point.
  case p[:disruptor]
  when :continue
    [decl, disruptor, use, escape].compact
  else
    [decl, use, disruptor, escape].compact
  end.join("\n            ")
end

# What return type and main wrapper the function needs.
def loop_cleanup_fn_wrap(p, body)
  needs_outer = (p[:dest] == :appended_to_outer)
  outer_decl  = needs_outer ? "    #{CleanupDims.outer_decl_for(p[:alloc])}" : nil

  # Always !T — any of our alloc kinds use fallible operations (List.append,
  # String concat with OOM). RETURNS !T propagates the error union; caller
  # handles via `OR_ELSE RAISE`. Avoids per-cell guessing about which bodies are
  # fallible.
  ret_t = if needs_outer
    "!#{CleanupDims.outer_list_type(p[:alloc])}"
  else
    "!Void"
  end

  ret_stmt = needs_outer ? "    RETURN outer;" : "    RETURN;"

  # main absorbs raises so the test exits clean — the matrix oracle is
  # cleanup correctness (no leak), not whether RAISE happens. Without this,
  # raise-disruptor cells exit non-zero just because they raised, which
  # the runner can't distinguish from a real bug.
  inner_call = if needs_outer
    "_ = run() OR_ELSE PASS;"
  else
    "run() OR_ELSE PASS;"
  end

  fn_def = <<~CHT.chomp
    FN run() RETURNS #{ret_t} ->
    #{outer_decl ? outer_decl + "\n" : ''}        FOR i IN (1_i64 ..= 5_i64) DO
                #{body}
            END
    #{ret_stmt}
    END
  CHT

  main = <<~CHT.chomp
    FN main() RETURNS Void ->
        #{inner_call}
        RETURN;
    END
  CHT

  [fn_def, main]
end

FuzzGenerator.register(:loop_cleanup, cells: LOOP_CLEANUP_CELLS) do |p|
  body = loop_cleanup_body(p)
  fn_def, main = loop_cleanup_fn_wrap(p, body)
  "#{fn_def}\n\n#{main}\n"
end
