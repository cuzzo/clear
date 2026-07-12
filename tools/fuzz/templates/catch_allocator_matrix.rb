# Template: catch / OR_ELSE-rescue allocator-identity matrix (the P0).
#
# Targets src/mir/mir_lowering.rb#infer_catch_value_allocator (12/12
# dark -- invariant #9: error paths must preserve allocator identity)
# + #lower_or_else. The decision is: when `v = mayFail() OR_ELSE fallback`,
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
CAM_VALUE   = %i[string int list struct]      # value type flowing out
CAM_SUCCESS = %i[heap]                        # success path: COPY -> heap
CAM_FALLBK  = %i[heap_empty literal frame_var] # fallback allocator shape
CAM_TAKEN   = %i[success failure]             # which path the input forces

CAM_VALUE.each do |vt|
  CAM_FALLBK.each do |fb|
    CAM_TAKEN.each do |taken|
      # primitive/struct values do not have an empty-heap literal form.
      next if %i[int struct].include?(vt) && fb == :heap_empty
      CAM_CELLS << { value: vt, fallback: fb, taken: taken }
    end
  end
end

def cam_inner(vt)
  if vt == :string
    "FN maybe(s: String) RETURNS !String ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    RETURN COPY s;\nEND"
  elsif vt == :int
    "FN maybe(s: String) RETURNS !Int64 ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    RETURN s.length();\nEND"
  elsif vt == :list
    "FN maybe(s: String) RETURNS !Int64[]@list ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    MUTABLE xs: Int64[]@list = [];\n" \
    "    xs.append(s.length());\n" \
    "    RETURN xs;\nEND"
  else
    "STRUCT Box { name: String }\n\n" \
    "FN maybe(s: String) RETURNS !Box ->\n" \
    "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
    "    RETURN Box{ name: COPY s };\nEND"
  end
end

def cam_fallback_expr(vt, fb)
  if vt == :string
    case fb
    when :heap_empty then "\"\""
    when :literal    then "\"fb\""
    when :frame_var  then "fbv"
    end
  elsif vt == :int
    fb == :frame_var ? "fbv" : "0_i64"
  elsif vt == :list
    case fb
    when :heap_empty then "[]"
    when :literal    then "[0_i64]"
    when :frame_var  then "fbv"
    end
  else
    fb == :frame_var ? "fbv" : 'Box{ name: "fb" }'
  end
end

def cam_fallback_setup(vt, fb)
  return "" unless fb == :frame_var

  case vt
  when :string then "    fbv: String = \"fb\";"
  when :int    then "    fbv: Int64 = 0_i64;"
  when :list
    "    MUTABLE fbv: Int64[]@list = [];\n    fbv.append(0_i64);"
  else
    "    fbv: Box = Box{ name: \"fb\" };"
  end
end

def cam_call_arg(taken) = (taken == :success ? "\"X\"" : "\"\"")

def cam_assert(vt, taken)
  if vt == :string
    taken == :success ? "ASSERT r.length() == 1_i64, \"success heap value\";" \
                       : "ASSERT r.length() >= 0_i64, \"fallback value live\";"
  elsif vt == :int
    taken == :success ? "ASSERT r == 1_i64, \"success int value\";" \
                       : "ASSERT r >= 0_i64, \"fallback int live\";"
  elsif vt == :list
    taken == :success ? "ASSERT r.length() == 1_i64, \"success list value\";" \
                       : "ASSERT r.length() >= 0_i64, \"fallback list live\";"
  else
    taken == :success ? "ASSERT r.name.length() == 1_i64, \"success struct value\";" \
                       : "ASSERT r.name.length() >= 0_i64, \"fallback struct live\";"
  end
end

FuzzGenerator.register(:catch_allocator_matrix, cells: CAM_CELLS) do |p|
  setup = cam_fallback_setup(p[:value], p[:fallback])
  setup_line = setup.empty? ? "" : "#{setup}\n"
  <<~CHT
    #{cam_inner(p[:value])}

    FN main() RETURNS Void ->
    #{setup_line}    r = maybe(#{cam_call_arg(p[:taken])}) OR_ELSE #{cam_fallback_expr(p[:value], p[:fallback])};
        #{cam_assert(p[:value], p[:taken])}
        RETURN;
    END
  CHT
end
