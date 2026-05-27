# Template: reassign-through-fallible-expression matrix.
#
# Targets src/mir/mir_lowering.rb#walk_catch_body_for_reassigns (12/13
# fuzz_axis dark). The decision: an outer MUTABLE binding is reassigned
# from a fallible expression `acc = maybe(...) OR acc;`. On the error
# path the binding keeps its OLD value/allocator; on success it takes
# the new one. If lowering mishandles the reassignment cleanup across
# the success/error split, that is a double-free or leak (invariant
# #9). The corpus never reassigned an outer binding through OR-rescue.
#
# var_kind x value_type x path-taken. Both paths exercised. expected
# :pass; a leak / mir-error on a :pass cell is the SURFACED bug.

CRM_CELLS = []
CRM_VARKIND = %i[local struct_field]
CRM_VALUE   = %i[string int list struct]
CRM_TAKEN   = %i[success failure]

CRM_VARKIND.each do |vk|
  CRM_VALUE.each do |vt|
    CRM_TAKEN.each do |tk|
      CRM_CELLS << { var: vk, value: vt, taken: tk }
    end
  end
end

def crm_ret(vt)
  case vt
  when :string then "!String"
  when :int    then "!Int64"
  when :list   then "!Int64[]@list"
  when :struct then "!Box"
  end
end

def crm_succ(vt)
  case vt
  when :string then "RETURN COPY s;"
  when :int    then "RETURN s.length();"
  when :list
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(s.length());\n    RETURN xs;"
  when :struct then "RETURN Box{ name: COPY s };"
  end
end
def crm_arg(tk)  = (tk == :success ? "\"X\"" : "\"\"")

def crm_inner(vt)
  prelude = vt == :struct ? "STRUCT Box { name: String }\n\n" : ""
  prelude + "FN maybe(s: String) RETURNS #{crm_ret(vt)} ->\n" \
  "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
  "    #{crm_succ(vt)}\nEND"
end

def crm_init(vt)
  case vt
  when :string then "\"init\""
  when :int    then "7_i64"
  when :list   then "[7_i64]"
  when :struct then "Box{ name: \"init\" }"
  end
end

def crm_assert(vt, tk)
  if vt == :string
    tk == :success ? "ASSERT acc.length() == 1_i64, \"reassigned to success\";" \
                    : "ASSERT acc.length() == 4_i64, \"kept old value on failure\";"
  elsif vt == :int
    tk == :success ? "ASSERT acc == 1_i64, \"reassigned to success\";" \
                    : "ASSERT acc == 7_i64, \"kept old value on failure\";"
  elsif vt == :list
    "ASSERT acc.length() == 1_i64, \"list remains live after reassign\";"
  else
    tk == :success ? "ASSERT acc.name.length() == 1_i64, \"struct reassigned to success\";" \
                    : "ASSERT acc.name.length() == 4_i64, \"struct kept old value on failure\";"
  end
end

FuzzGenerator.register(:catch_reassign_matrix, cells: CRM_CELLS) do |p|
  if p[:var] == :local
    init = if p[:value] == :list
             "MUTABLE acc: Int64[]@list = [];\n        acc.append(7_i64);"
           else
             "MUTABLE acc = #{crm_init(p[:value])};"
           end
    <<~CHT
      #{crm_inner(p[:value])}

      FN main() RETURNS Void ->
          #{init}
          acc = maybe(#{crm_arg(p[:taken])}) OR acc;
          #{crm_assert(p[:value], p[:taken])}
          RETURN;
      END
    CHT
  else
    field_t = case p[:value]
              when :string then "String"
              when :int    then "Int64"
              when :list   then "Int64[]@list"
              when :struct then "Box"
              end
    rd = case p[:value]
         when :string then "h.acc.length()"
         when :int    then "h.acc"
         when :list   then "h.acc.length()"
         when :struct then "h.acc.name.length()"
         end
    exp = case p[:value]
          when :string then p[:taken] == :success ? "1_i64" : "4_i64"
          when :int    then p[:taken] == :success ? "1_i64" : "7_i64"
          when :list   then "1_i64"
          when :struct then p[:taken] == :success ? "1_i64" : "4_i64"
          end
    holder_init = if p[:value] == :list
                    "MUTABLE start: Int64[]@list = [];\n        start.append(7_i64);\n        MUTABLE h = Holder{ acc: start };"
                  else
                    "MUTABLE h = Holder{ acc: #{crm_init(p[:value])} };"
                  end
    <<~CHT
      #{crm_inner(p[:value])}

      STRUCT Holder { acc: #{field_t} }

      FN main() RETURNS Void ->
          #{holder_init}
          h.acc = maybe(#{crm_arg(p[:taken])}) OR h.acc;
          ASSERT #{rd} == #{exp}, "struct field reassign #{p[:taken]}";
          RETURN;
      END
    CHT
  end
end
