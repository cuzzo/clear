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
CRM_VALUE   = %i[string int]
CRM_TAKEN   = %i[success failure]

CRM_VARKIND.each do |vk|
  CRM_VALUE.each do |vt|
    CRM_TAKEN.each do |tk|
      CRM_CELLS << { var: vk, value: vt, taken: tk }
    end
  end
end

def crm_ret(vt)  = (vt == :string ? "!String" : "!Int64")
def crm_succ(vt) = (vt == :string ? "RETURN COPY s;" : "RETURN s.length();")
def crm_arg(tk)  = (tk == :success ? "\"X\"" : "\"\"")

def crm_inner(vt)
  "FN maybe(s: String) RETURNS #{crm_ret(vt)} ->\n" \
  "    IF s.length() == 0_i64 THEN RAISE \"empty\"; END\n" \
  "    #{crm_succ(vt)}\nEND"
end

def crm_init(vt) = (vt == :string ? "\"init\"" : "7_i64")

def crm_assert(vt, tk)
  if vt == :string
    tk == :success ? "ASSERT acc.length() == 1_i64, \"reassigned to success\";" \
                    : "ASSERT acc.length() == 4_i64, \"kept old value on failure\";"
  else
    tk == :success ? "ASSERT acc == 1_i64, \"reassigned to success\";" \
                    : "ASSERT acc == 7_i64, \"kept old value on failure\";"
  end
end

FuzzGenerator.register(:catch_reassign_matrix, cells: CRM_CELLS) do |p|
  if p[:var] == :local
    <<~CHT
      #{crm_inner(p[:value])}

      FN main() RETURNS Void ->
          MUTABLE acc = #{crm_init(p[:value])};
          acc = maybe(#{crm_arg(p[:taken])}) OR acc;
          #{crm_assert(p[:value], p[:taken])}
          RETURN;
      END
    CHT
  else
    field_t = p[:value] == :string ? "String" : "Int64"
    rd = p[:value] == :string ? "h.acc.length()" : "h.acc"
    exp = if p[:value] == :string
            p[:taken] == :success ? "1_i64" : "4_i64"
          else
            p[:taken] == :success ? "1_i64" : "7_i64"
          end
    <<~CHT
      #{crm_inner(p[:value])}

      STRUCT Holder { acc: #{field_t} }

      FN main() RETURNS Void ->
          MUTABLE h = Holder{ acc: #{crm_init(p[:value])} };
          h.acc = maybe(#{crm_arg(p[:taken])}) OR h.acc;
          ASSERT #{rd} == #{exp}, "struct field reassign #{p[:taken]}";
          RETURN;
      END
    CHT
  end
end
