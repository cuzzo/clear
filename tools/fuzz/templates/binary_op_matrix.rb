# Template: binary-operator lowering matrix.
#
# Targets src/mir/mir_lowering.rb#lower_binary_op + #lower_or_rescue.
# The dark arms are the operator x operand-type combinations the corpus
# never wrote: MOD on i64, string comparison (eql / strcmp branches),
# heap-string operands (the hoist_alloc path), concat, and the
# OR-rescue fallback. Operands come from a fn so constant-folding does
# not erase the decision.
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

BOM_CELLS = []
BOM_OPS    = %i[eq neq lt gte mod concat or_fallback]
BOM_TYPES  = %i[int float str_lit heap_str]

BOM_OPS.each do |op|
  BOM_TYPES.each do |t|
    # MOD: integers only. concat / or_fallback: strings only.
    next if op == :mod    && t != :int
    next if op == :concat && !%i[str_lit heap_str].include?(t)
    next if op == :or_fallback && !%i[str_lit heap_str].include?(t)
    # float ordering only exercises lt/gte/eq/neq.
    next if t == :float && %i[concat or_fallback mod].include?(op)
    BOM_CELLS << { op: op, type: t }
  end
end

# lhs is ALWAYS the strictly-smaller operand and rhs the larger, for
# every type, so the oracle is uniform: lt true, gte false, eq false,
# neq true. (MOD has its own dedicated operands below.)
def bom_provider(t)
  case t
  when :int      then "FN lhs() RETURNS Int64 -> RETURN 3_i64; END\nFN rhs() RETURNS Int64 -> RETURN 10_i64; END"
  when :float    then "FN lhs() RETURNS Float64 -> RETURN 1.5; END\nFN rhs() RETURNS Float64 -> RETURN 2.5; END"
  when :str_lit  then "FN lhs() RETURNS String -> RETURN \"abc\"; END\nFN rhs() RETURNS String -> RETURN \"abd\"; END"
  when :heap_str then "FN lhs() RETURNS !String -> RETURN COPY \"abc\"; END\nFN rhs() RETURNS !String -> RETURN COPY \"abd\"; END"
  end
end

def bom_lhs(t) = (t == :heap_str ? "(lhs())" : "lhs()")
def bom_rhs(t) = (t == :heap_str ? "(rhs())" : "rhs()")

def bom_body(op, t)
  l = bom_lhs(t)
  r = bom_rhs(t)
  case op
  when :eq   then "    ASSERT (#{l} == #{r}) == FALSE, \"eq #{t}\";"
  when :neq  then "    ASSERT (#{l} != #{r}), \"neq #{t}\";"
  when :lt   then "    ASSERT (#{l} < #{r}), \"lt #{t}\";"
  when :gte  then "    ASSERT (#{l} >= #{r}) == FALSE, \"gte #{t}\";"
  when :mod  then "    ASSERT (10_i64 MOD 3_i64) == 1_i64, \"mod #{t}\";"
  when :concat
    "    t: String = #{l} + #{r};\n    ASSERT t.length() == 6_i64, \"concat #{t}\";"
  when :or_fallback
    # lhs() is non-fallible here; exercise the OR fallback shape with a
    # fallible callee so lower_or_rescue lowers.
    "    v: String = mightFail() OR \"fb\";\n    ASSERT v.length() >= 2_i64, \"or fallback #{t}\";"
  end
end

def bom_extra_fn(op)
  return "" unless op == :or_fallback

  "FN mightFail() RETURNS !String ->\n    RETURN COPY \"ok\";\nEND\n"
end

FuzzGenerator.register(:binary_op_matrix, cells: BOM_CELLS) do |p|
  <<~CHT
    #{bom_provider(p[:type])}
    #{bom_extra_fn(p[:op])}FN main() RETURNS Void ->
    #{bom_body(p[:op], p[:type])}
        RETURN;
    END
  CHT
end
