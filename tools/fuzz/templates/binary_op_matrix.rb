# Template: binary-operator lowering matrix — ENUMERATED, not sampled.
#
# Targets src/mir/mir_lowering.rb#lower_binary_op + #lower_or_else.
# The cell set is the dispatch's OWN discriminant set read from the
# source: the string-compare `case node.op` has arms
# {EQ,NEQ,LT,LTE,GT,GTE}; POW (**), DIV, MOD, wrapping/checked integer
# arithmetic, concat (+), OR_ELSE (OR_ELSE) are the other op branches. Every
# comparison arm x every operand type is emitted -- exhaustive by construction,
# not a guessed axis.
#
# Surface syntax confirmed from lexer/transpile-tests:
#   == != < <= > >=  ;  **=POW  ;  MOD  ;  + (concat)  ;  OR_ELSE (rescue).
# The symbol-path `case node.op {EQ,NEQ}` is EXCLUDED: CLEAR has no
# surface symbol literal (only a union *variant* named Symbol), so
# those 2 arms are not source-reachable -> accept/invariant_guarded,
# correctly not chased here.
#
# lhs() is ALWAYS strictly less than rhs() for every type, so the
# oracle is uniform: EQ false, NEQ true, LT true, LTE true, GT false,
# GTE false. expected :pass; a failing :pass cell is a SURFACED bug.

BOM_CELLS = []
BOM_CMP   = %i[eq neq lt lte gt gte]
BOM_TYPES = %i[int float str_lit heap_str]

BOM_CMP.each do |op|
  BOM_TYPES.each { |t| BOM_CELLS << { op: op, type: t } }
end
# Non-comparison op branches, each at its valid operand type(s).
BOM_CELLS << { op: :mod,    type: :int }
BOM_CELLS << { op: :div,    type: :int }
BOM_CELLS << { op: :pow,    type: :int }
BOM_CELLS << { op: :pow,    type: :float }
%i[wrap_add wrap_sub wrap_mul check_add check_sub check_mul].each do |op|
  BOM_CELLS << { op: op, type: :int }
end
BOM_CELLS << { op: :concat, type: :str_lit }
BOM_CELLS << { op: :concat, type: :heap_str }
BOM_CELLS << { op: :or_fallback, type: :heap_str }
BOM_CELLS << { op: :logical_and, type: :bool }
BOM_CELLS << { op: :logical_or, type: :bool }
%i[error nil value].each do |outcome|
  BOM_CELLS << { op: :or_nested_fallback, type: outcome }
  BOM_CELLS << { op: :or_nested_managed, type: outcome }
end

def bom_provider(t)
  case t
  when :int      then "FN lhs() RETURNS Int64 -> RETURN 3_i64; END\nFN rhs() RETURNS Int64 -> RETURN 10_i64; END"
  when :float    then "FN lhs() RETURNS Float64 -> RETURN 1.5; END\nFN rhs() RETURNS Float64 -> RETURN 2.5; END"
  when :str_lit  then "FN lhs() RETURNS String -> RETURN \"abc\"; END\nFN rhs() RETURNS String -> RETURN \"abd\"; END"
  when :heap_str then "FN lhs() RETURNS !String -> RETURN COPY \"abc\"; END\nFN rhs() RETURNS !String -> RETURN COPY \"abd\"; END"
  when :bool     then "FN explode() RETURNS Bool -> ASSERT FALSE, \"logical RHS executed\"; RETURN TRUE; END"
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
  when :lte  then "    ASSERT (#{l} <= #{r}), \"lte #{t}\";"
  when :gt   then "    ASSERT (#{l} > #{r}) == FALSE, \"gt #{t}\";"
  when :gte  then "    ASSERT (#{l} >= #{r}) == FALSE, \"gte #{t}\";"
  when :mod  then "    ASSERT (10_i64 MOD 3_i64) == 1_i64, \"mod\";"
  when :div  then "    ASSERT (10_i64 / 3_i64) == 3_i64, \"div\";"
  when :pow
    t == :int ? "    ASSERT (2_i64 ** 3_i64) == 8_i64, \"pow int\";" \
              : "    ASSERT (2.0 ** 3.0) == 8.0, \"pow float\";"
  when :wrap_add then "    ASSERT (7_i64 %+ 5_i64) == 12_i64, \"wrap add\";"
  when :wrap_sub then "    ASSERT (7_i64 %- 5_i64) == 2_i64, \"wrap sub\";"
  when :wrap_mul then "    ASSERT (7_i64 %* 5_i64) == 35_i64, \"wrap mul\";"
  when :check_add then "    a: Int64 = 7_i64;\n    b: Int64 = 5_i64;\n    ASSERT (a !+ b) == 12_i64, \"check add\";"
  when :check_sub then "    a: Int64 = 7_i64;\n    b: Int64 = 5_i64;\n    ASSERT (a !- b) == 2_i64, \"check sub\";"
  when :check_mul then "    a: Int64 = 7_i64;\n    b: Int64 = 5_i64;\n    ASSERT (a !* b) == 35_i64, \"check mul\";"
  when :concat
    "    t: String = #{l} + #{r};\n    ASSERT t.length() == 6_i64, \"concat #{t}\";"
  when :or_fallback
    "    v: String = mightFail() OR_ELSE \"fb\";\n    ASSERT v.length() >= 2_i64, \"or fallback\";"
  when :logical_and
    "    ASSERT !(FALSE AND explode()), \"AND short circuit\";"
  when :logical_or
    "    ASSERT TRUE OR explode(), \"OR short circuit\";"
  when :or_nested_fallback
    mode = { error: 0, nil: 1, value: 2 }.fetch(t)
    expected = { error: 5, nil: 5, value: 11 }.fetch(t)
    "    v: Int64 = nested(#{mode}_i64) OR_ELSE 5_i64;\n    ASSERT v == #{expected}_i64, \"nested OR_ELSE #{t}\";"
  when :or_nested_managed
    mode = { error: 0, nil: 1, value: 2 }.fetch(t)
    expected = t == :value ? "value" : "fallback"
    "    v: String = nestedManaged(#{mode}_i64) OR_ELSE COPY \"fallback\";\n    ASSERT v == \"#{expected}\", \"managed nested OR_ELSE #{t}\";"
  end
end

def bom_extra_fn(op)
  return "FN mightFail() RETURNS !String ->\n    RETURN COPY \"ok\";\nEND\n" if op == :or_fallback
  return <<~CHT if op == :or_nested_fallback
    FN nested(mode: Int64) RETURNS !?Int64 ->
        IF mode == 0_i64 THEN RAISE; END
        IF mode == 1_i64 THEN RETURN NIL; END
        RETURN 11_i64;
    END
  CHT
  return <<~CHT if op == :or_nested_managed
    FN nestedManaged(mode: Int64) RETURNS !?String ->
        IF mode == 0_i64 THEN RAISE; END
        IF mode == 1_i64 THEN RETURN NIL; END
        RETURN COPY "value";
    END
  CHT
  ""
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
