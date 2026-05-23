# Template: cleanup correctness across IF/ELSE branches.
# Stresses INV-2 (every alloc has a cleanup on every path) when allocations
# happen asymmetrically across branches, with optional early-return
# disruptors that may bypass cleanup for one path.
#
# Cell schema:
#   { alloc:, shape:, disruptor:, expected: }
#
#   alloc     ∈ ALLOC_KINDS (from _cleanup_dimensions.rb)
#   shape     ∈ {
#     :then_only,    # alloc only in THEN branch
#     :else_only,    # alloc only in ELSE branch
#     :both_same,    # alloc in both branches, same kind
#     :both_diff,    # alloc in both branches, but ELSE uses a different kind
#   }
#   disruptor ∈ {:none, :return_from_then, :return_from_else}

require_relative '_cleanup_dimensions'

BRANCH_CLEANUP_CELLS = []

BRANCH_SHAPES = [:then_only, :else_only, :both_same, :both_diff]
BRANCH_DISRUPTORS = [:none, :return_from_then, :return_from_else]

CleanupDims::ALLOC_KINDS.each do |a|
  BRANCH_SHAPES.each do |s|
    BRANCH_DISRUPTORS.each do |d|
      BRANCH_CLEANUP_CELLS << { alloc: a, shape: s, disruptor: d }
    end
  end
end

# Pick an "alternate" alloc kind for the :both_diff shape — distinct from
# the primary so the two branches have genuinely different cleanup paths.
def branch_alt_alloc(primary)
  case primary
  when :heap_list           then :heap_string
  when :heap_string         then :heap_list
  when :frame_string_concat then :frame_list
  when :frame_list          then :frame_string_concat
  end
end

def branch_then_body(p)
  return nil if p[:shape] == :else_only
  decl = CleanupDims.alloc_decl(p[:alloc], varname: "v", idx_expr: "1_i64")
  use  = CleanupDims.use_stmt(p[:alloc],   varname: "v", idx_expr: "1_i64")
  ret  = (p[:disruptor] == :return_from_then) ? "RETURN;" : nil
  [decl, use, ret].compact.join("\n            ")
end

def branch_else_body(p)
  return nil if p[:shape] == :then_only
  alloc = (p[:shape] == :both_diff) ? branch_alt_alloc(p[:alloc]) : p[:alloc]
  decl = CleanupDims.alloc_decl(alloc, varname: "w", idx_expr: "2_i64")
  use  = CleanupDims.use_stmt(alloc,   varname: "w", idx_expr: "2_i64")
  ret  = (p[:disruptor] == :return_from_else) ? "RETURN;" : nil
  [decl, use, ret].compact.join("\n            ")
end

FuzzGenerator.register(:branch_cleanup, cells: BRANCH_CLEANUP_CELLS) do |p|
  then_body = branch_then_body(p)
  else_body = branch_else_body(p)

  if_block = if then_body && else_body
    <<~CHT.chomp
      IF cond THEN
                #{then_body}
            ELSE
                #{else_body}
            END
    CHT
  elsif then_body
    <<~CHT.chomp
      IF cond THEN
                #{then_body}
            END
    CHT
  else
    <<~CHT.chomp
      IF !cond THEN
                #{else_body}
            END
    CHT
  end

  <<~CHT
    FN run(cond: Bool) RETURNS !Void ->
        #{if_block}
        RETURN;
    END

    FN main() RETURNS Void ->
        run(TRUE) OR PASS;
        run(FALSE) OR PASS;
        RETURN;
    END
  CHT
end
