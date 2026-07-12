# Template: a loop body uses a method-call result as a per-iteration temp
# that never escapes the iteration. Surfaces the FRAME_NO_REWIND lowering
# gap catalogued in docs/agents/clear-bug123-forensic.md #2.
#
# Existing fuzz coverage:
#   - `loop_carry_collection`  — list built INSIDE loop, used AFTER loop.
#   - `nested_loop_escape`     — list built INSIDE loop, captured into
#                                 an outer collection.
# Neither covers "method-call result bound inside loop body, used only
# within the same iteration, never escapes." That's bug #2.
#
# The shape that triggers the bug:
#
#   FN main() RETURNS !Void ->
#     haystack = "a b c d e";
#     MUTABLE i: Int64 = 0;
#     WHILE i < 3 DO
#       parts = haystack.split(" ");        # frame-alloc inside loop
#       IF parts.length() == 5 THEN ... END  # used only this iteration
#       i = i + 1;
#     END
#     RETURN;
#   END
#
# `LoopFrameAnalysis.analyze_loop_node!` should detect `parts` as a
# frame-local decl and set `mark_per_iter = true` so a per-iteration
# `saveLoopMark`/`restoreLoopMark` defer pair is emitted. Today it
# doesn't — the MIRChecker correctly fires INV-FRAME-REWIND, but the
# lowering hasn't synthesised the rewind. Result: compile fails.
#
# Cell schema:
#   { method: :split | :concat | :substring,
#     loop_kind: :while | :for_range,
#     binding: :immutable | :mutable_decl }

LLMT_METHODS    = [:split, :concat, :substring]
LLMT_LOOP_KINDS = [:while, :for_range]
LLMT_BINDINGS   = [:immutable, :mutable_decl]

LOOP_LOCAL_METHOD_TEMP_CELLS = []
LLMT_METHODS.each do |m|
  LLMT_LOOP_KINDS.each do |l|
    LLMT_BINDINGS.each do |b|
      LOOP_LOCAL_METHOD_TEMP_CELLS << { method: m, loop_kind: l, binding: b }
    end
  end
end

def llmt_setup(method)
  case method
  when :split, :concat, :substring then "haystack = \"a b c d e\";"
  end
end

def llmt_method_call(method)
  # Each method returns a frame-allocated value that we then peek at via
  # a method call (length / charAt) but never assign anywhere outliving
  # the iteration.
  case method
  when :split     then "haystack.split(\" \")"
  when :concat    then "haystack $+ \"-suffix\""
  when :substring then "haystack.substr(0_i64, 3_i64)"
  end
end

def llmt_peek(method)
  case method
  when :split, :substring then "length(temp)"
  when :concat            then "temp.length()"
  end
end

def llmt_binding(method, b)
  call = llmt_method_call(method)
  case b
  when :immutable   then "temp = #{call};"
  when :mutable_decl then "MUTABLE temp = #{call};"
  end
end

def llmt_loop(p, inner_body)
  case p[:loop_kind]
  when :while
    <<~LOOP.chomp
      MUTABLE i: Int64 = 0_i64;
          WHILE i < 3_i64 DO
              #{inner_body}
              i = i + 1_i64;
          END
    LOOP
  when :for_range
    <<~LOOP.chomp
      FOR i IN (0_i64 ..< 3_i64) DO
              #{inner_body}
          END
    LOOP
  end
end

FuzzGenerator.register(:loop_local_method_temp, cells: LOOP_LOCAL_METHOD_TEMP_CELLS) do |p|
  setup  = llmt_setup(p[:method])
  bind   = llmt_binding(p[:method], p[:binding])
  peek   = llmt_peek(p[:method])
  # Use `temp` via `peek` so the binding isn't dead, but never actually
  # raise — the cell is testing per-iteration frame rewind, not error
  # paths. (`peek` is a non-negative length, so the guard never fires.)
  inner  = <<~BODY.chomp
    #{bind}
              IF #{peek} < 0_i64 THEN RAISE "unreached"; END
  BODY
  loop = llmt_loop(p, inner)

  <<~CHT
    FN main() RETURNS !Void ->
        #{setup}
        #{loop}
        RETURN;
    END
  CHT
end
