# Template: catch / OR-rescue allocator-identity matrix (the P0).
#
# Targets src/mir/mir_lowering.rb#infer_catch_value_allocator (12/12
# dark -- invariant #9: error paths must preserve allocator identity)
# + #lower_or_rescue. The decision is: when `v = mayFail() OR fallback`,
# the success value and the fallback value may have DIFFERENT
# allocators (heap COPY vs frame literal vs primitive). If lowering
# binds one allocator on success and a different one on the error path,
# that is a UAF / double-free / leak. The corpus never crossed
# success_alloc x fallback_alloc.
#
# Both success and failure paths are exercised (call arg "" forces the
# RAISE -> fallback path; non-empty forces success). expected :pass;
# any leak / mir-error on a :pass cell is the invariant-#9 bug class.

CAM_CELLS = []
CAM_VALUE   = %i[string int]                 # value type flowing out
CAM_SUCCESS = %i[heap]                        # success path: COPY -> heap
CAM_FALLBK  = %i[heap_empty literal frame_var] # fallback allocator shape
CAM_TAKEN   = %i[success failure]             # which path the input forces

CAM_VALUE.each do |vt|
  CAM_FALLBK.each do |fb|
    CAM_TAKEN.each do |taken|
      # int value: only the primitive fallback shapes make sense.
      next if vt == :int && fb == :heap_empty
      CAM_CELLS << { value: vt, fallback: fb, taken: taken }
    end
  end
end

def cam_inner(vt)
  if vt == :string
    "FN maybe(s: String) RETURNS !String ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    RETURN COPY s;\nEND"
  else
    "FN maybe(s: String) RETURNS !Int64 ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    RETURN s.length();\nEND"
  end
end

def cam_fallback_expr(vt, fb)
  if vt == :string
    case fb
    when :heap_empty then "\"\""
    when :literal    then "\"fb\""
    when :frame_var  then "fbv"
    end
  else
    fb == :frame_var ? "fbv" : "0_i64"
  end
end

def cam_fallback_setup(vt, fb)
  return "" unless fb == :frame_var

  vt == :string ? "    fbv: String = \"fb\";" : "    fbv: Int64 = 0_i64;"
end

def cam_call_arg(taken) = (taken == :success ? "\"X\"" : "\"\"")

def cam_assert(vt, taken)
  if vt == :string
    taken == :success ? "ASSERT r.length() == 1_i64, \"success heap value\";" \
                       : "ASSERT r.length() >= 0_i64, \"fallback value live\";"
  else
    taken == :success ? "ASSERT r == 1_i64, \"success int value\";" \
                       : "ASSERT r >= 0_i64, \"fallback int live\";"
  end
end

FuzzGenerator.register(:catch_allocator_matrix, cells: CAM_CELLS) do |p|
  setup = cam_fallback_setup(p[:value], p[:fallback])
  setup_line = setup.empty? ? "" : "#{setup}\n"
  <<~CHT
    #{cam_inner(p[:value])}

    FN main() RETURNS Void ->
    #{setup_line}    r = maybe(#{cam_call_arg(p[:taken])}) OR #{cam_fallback_expr(p[:value], p[:fallback])};
        #{cam_assert(p[:value], p[:taken])}
        RETURN;
    END
  CHT
end
