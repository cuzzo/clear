# Template: cleanup correctness on error paths.
# Stresses INV-9 (error paths preserve allocator identity) plus the
# general invariant that every alloc has a cleanup on every error
# control-flow shape.
#
# Cross-references:
#   - CLAUDE.md INV-9: "If an operation can fail, the error path must not
#     change the allocator identity of any live value."
#   - docs/agents/mir-bugs.md #7 (OrElse Fallback Dupe Fragility)
#   - docs/agents/formal-verification-bugs.md #10 (`x = expr OR_ELSE PASS` leaks
#     for heap-returning fn)
#
# Cell schema:
#   { alloc:, pattern:, expected: }
#
#   alloc   ∈ ALLOC_KINDS (from _cleanup_dimensions.rb)
#   pattern ∈ {
#     :success_or_pass,    # inner returns value, OR_ELSE PASS no-op
#     :raise_or_pass,      # inner raises, OR_ELSE PASS swallows
#     :success_or_raise,   # inner returns value, OR_ELSE RAISE no-op
#     :raise_or_raise,     # inner raises, OR_ELSE RAISE re-propagates
#     :success_or_default, # inner returns value, OR_ELSE <default> no-op
#     :raise_or_default,   # inner raises, fallback value used
#   }

require_relative '_cleanup_dimensions'

ERROR_CLEANUP_CELLS = []

ERROR_PATTERNS = [
  :success_or_pass, :raise_or_pass,
  :success_or_raise, :raise_or_raise,
  :success_or_default, :raise_or_default,
]

CleanupDims::ALLOC_KINDS.each do |a|
  ERROR_PATTERNS.each do |pat|
    ERROR_CLEANUP_CELLS << { alloc: a, pattern: pat }
  end
end

# ── helpers ───────────────────────────────────────────────────────────

def err_inner_fn(alloc, raises:)
  ret_t = "!#{CleanupDims.value_type(alloc)}"
  decl  = CleanupDims.alloc_decl(alloc, varname: "v", idx_expr: "1_i64")
  use   = CleanupDims.use_stmt(alloc,   varname: "v", idx_expr: "1_i64")
  raise_line = raises ? "RAISE;" : nil

  body_lines = [decl, use, raise_line, "RETURN v;"].compact.join("\n        ")
  <<~CHT.chomp
    FN inner() RETURNS #{ret_t} ->
        #{body_lines}
    END
  CHT
end

def err_default_value(alloc)
  case alloc
  when :heap_list, :frame_list           then "[]"
  when :heap_string, :frame_string_concat then "\"\""
  end
end

def err_caller(alloc, pattern)
  vt = CleanupDims.value_type(alloc)
  call = case pattern
  when :success_or_pass, :raise_or_pass
    "result: #{vt} = inner() OR_ELSE PASS;"
  when :success_or_raise, :raise_or_raise
    "result: #{vt} = inner() OR_ELSE RAISE;"
  when :success_or_default, :raise_or_default
    "result: #{vt} = inner() OR_ELSE #{err_default_value(alloc)};"
  end
  call
end

FuzzGenerator.register(:error_cleanup, cells: ERROR_CLEANUP_CELLS) do |p|
  raises = p[:pattern].to_s.start_with?('raise_')
  inner_fn = err_inner_fn(p[:alloc], raises: raises)
  caller_line = err_caller(p[:alloc], p[:pattern])

  # main absorbs any propagated raise via OR_ELSE PASS so the test exits
  # cleanly. The matrix oracle is leak / Invalid-free; not whether the
  # raise propagated.
  <<~CHT
    #{inner_fn}

    FN main() RETURNS Void ->
        run() OR_ELSE PASS;
        RETURN;
    END

    FN run() RETURNS !Void ->
        #{caller_line}
        RETURN;
    END
  CHT
end
