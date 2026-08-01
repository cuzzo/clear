# Template: top-level CONST (module constant) matrix - ENUMERATED, not sampled.
#
# Targets the CONST feature end to end: lexer keyword, parser parse_const_decl
# (compiler/ruby/ast/parser/declarations_and_definitions.rb), the module_const
# lowering path (compiler/ruby/mir/lowering/variables.rb#lower_module_const),
# and container-scope emission with `rt` bound to `undefined`
# (compiler/ruby/backends/mir_emitter.rb#emit_let).
#
# Positive cells (:pass) cross the comptime-pure const value shape
#   {int, bool, struct} against the reference position
#   {bare read, struct-field read, call argument, default parameter}. A comptime
#   const initialized by an rt-threaded constructor must fold at Zig comptime and
#   read back its exact value at every position. A failing :pass cell is a bug.
#
# Negative cells (:compile_error) pin the fail-closed boundaries:
#   - a non-SCREAMING_CASE name            -> CONST_NEEDS_CAPS   (parser)
#   - a missing type annotation            -> CONST_NEEDS_TYPE   (parser)
#   - a missing initializer                -> CONST_NEEDS_VALUE   (parser)
#   - a heap-owning value (Tier 2, unsupported) must not compile (any path;
#     CLEAR has no module init/deinit lifetime for a runtime-built constant).

MCM_CELLS = []
%i[int bool struct].each do |vt|
  refs = vt == :struct ? %i[bare field arg default] : %i[bare arg default]
  refs.each { |ref| MCM_CELLS << { value: vt, ref: ref, expected: :pass } }
end
# Runtime-initialized (heap) CONST: not comptime-foldable, so it is emitted as a
# container-scope var, constructed once at clearMain top, and freed at exit.
# Positive cells run under leak detection - the program-lifetime storage must be
# released. Cover a borrow read, a later const reading an earlier one, and COPY
# into a TAKES sink.
MCM_CELLS << { value: :rt_heap,     ref: :borrow,  expected: :pass }
MCM_CELLS << { value: :rt_heap,     ref: :derived, expected: :pass }
MCM_CELLS << { value: :rt_heap,     ref: :copy,    expected: :pass }
MCM_CELLS << { value: :neg_caps,     ref: :none, expected: :compile_error }
MCM_CELLS << { value: :neg_type,     ref: :none, expected: :compile_error }
MCM_CELLS << { value: :neg_value,    ref: :none, expected: :compile_error }
MCM_CELLS << { value: :neg_fallible, ref: :none, expected: :compile_error }
MCM_CELLS << { value: :neg_consume,  ref: :none, expected: :compile_error }

# Preamble: the type + a constructor (for the struct value) and the CONST decl.
def mcm_preamble(value)
  case value
  when :int    then "CONST K: Int64 = 7_i64;"
  when :bool   then "CONST K: Bool = TRUE;"
  when :struct
    <<~CHT.chomp
      STRUCT Caps { rank: Int64, flag: Bool }
      FN caps__new(r: Int64) RETURNS Caps ->
        RETURN Caps{ rank: r, flag: TRUE };
      END
      CONST K: Caps = caps__new(7_i64);
    CHT
  end
end

# A helper that reads the const through the exercised reference position, plus
# the ASSERT that pins the observed value.
def mcm_ref(value, ref)
  read, expect, note =
    case value
    when :int    then ["K", "7_i64", "int const"]
    when :bool   then ["K", "TRUE", "bool const"]
    when :struct then ["K.rank", "7_i64", "struct const field"]
    end
  case ref
  when :bare
    ["", "    ASSERT #{read} == #{expect}, \"#{note} bare\";"]
  when :field
    ["", "    ASSERT K.rank == 7_i64, \"struct const field read\";\n    ASSERT K.flag == TRUE, \"struct const bool field\";"]
  when :arg
    ty = value == :struct ? "Caps" : (value == :bool ? "Bool" : "Int64")
    passed = value == :struct ? "c.rank" : "c"
    cmp = value == :bool ? "== TRUE" : "== 7_i64"
    [
      "FN take_#{value}(c: #{ty}) RETURNS Bool ->\n  RETURN #{passed} #{cmp};\nEND",
      "    ASSERT take_#{value}(K), \"#{note} arg\";",
    ]
  when :default
    ty = value == :struct ? "Caps" : (value == :bool ? "Bool" : "Int64")
    body = value == :struct ? "c.rank == 7_i64" : (value == :bool ? "c == TRUE" : "c == 7_i64")
    [
      "FN dflt_#{value}(c: #{ty} = K) RETURNS Bool ->\n  RETURN #{body};\nEND",
      "    ASSERT dflt_#{value}(), \"#{note} default param\";",
    ]
  end
end

# A leak-checked runtime-init heap CONST program exercising one use position.
def rt_heap_program(ref)
  prelude = <<~CHT.chomp
    STRUCT Box { name: String }
    FN box__new(n: String) RETURNS Box ->
      RETURN Box{ name: COPY n };
    END
    FN box_len(b: Box) RETURNS Int64 -> RETURN b.name.length(); END
    FN eat(TAKES b: Box) RETURNS Int64 -> RETURN b.name.length(); END
    CONST GREETING: Box = box__new("hello");
  CHT
  case ref
  when :borrow
    "#{prelude}\nFN main() RETURNS Void ->\n" \
    "    ASSERT box_len(GREETING) == 5_i64, \"rt heap const borrow\";\n    RETURN;\nEND\n"
  when :derived
    "#{prelude}\nCONST DERIVED: Box = box__new(GREETING.name);\nFN main() RETURNS Void ->\n" \
    "    ASSERT DERIVED.name == \"hello\", \"rt heap derived const\";\n    RETURN;\nEND\n"
  when :copy
    "#{prelude}\nFN main() RETURNS Void ->\n" \
    "    ASSERT eat(COPY GREETING) == 5_i64, \"rt heap const COPY into TAKES\";\n" \
    "    ASSERT GREETING.name == \"hello\", \"rt heap const readable after COPY\";\n    RETURN;\nEND\n"
  end
end

FuzzGenerator.register(:module_const_matrix, cells: MCM_CELLS) do |p|
  case p[:value]
  when :neg_caps
    { source: "CONST lower_name: Int64 = 1_i64;\nFN main() RETURNS Void -> RETURN; END\n",
      error_code: :CONST_NEEDS_CAPS, diagnostic_code_required: true }
  when :neg_type
    { source: "CONST NOTYPE = 1_i64;\nFN main() RETURNS Void -> RETURN; END\n",
      error_code: :CONST_NEEDS_TYPE, diagnostic_code_required: true }
  when :neg_value
    { source: "CONST NOVAL: Int64;\nFN main() RETURNS Void -> RETURN; END\n",
      error_code: :CONST_NEEDS_VALUE, diagnostic_code_required: true }
  when :neg_fallible
    # A CONST has no error channel: a RAISE-able initializer is rejected.
    { source: "FN risky() RETURNS !String -> RAISE; END\nCONST BAD: String = risky();\n" \
              "FN main() RETURNS Void -> RETURN; END\n",
      error_code: :CONST_INIT_FALLIBLE, diagnostic_code_required: true }
  when :neg_consume
    # A CONST is immutable and program-lifetime: it may be borrowed but never
    # moved out. Consuming it into a TAKES sink must fail to compile.
    { source: "STRUCT Box { name: String }\n" \
              "FN box__new(n: String) RETURNS Box -> RETURN Box{ name: COPY n }; END\n" \
              "FN eat(TAKES b: Box) RETURNS Int64 -> RETURN b.name.length(); END\n" \
              "CONST GREETING: Box = box__new(\"hi\");\n" \
              "FN main() RETURNS Void -> MUTABLE r: Int64 = eat(GIVE GREETING); RETURN; END\n",
      diagnostic_code_required: false }
  when :rt_heap
    rt_heap_program(p[:ref])
  else
    helper, assertion = mcm_ref(p[:value], p[:ref])
    <<~CHT
      #{mcm_preamble(p[:value])}
      #{helper}
      FN main() RETURNS Void ->
      #{assertion}
          RETURN;
      END
    CHT
  end
end
