# Template: string-interpolation matrix — ENUMERATED, not sampled.
#
# `"${expr}"` interpolation allocates a heap string at runtime; the compiler
# is string-building-heavy, so every interpolation shape is crossed with
# every owning consumer position. Each cell carries a Ruby-declared expected
# value: a failing :pass cell is a SURFACED miscompile or leak, never noise.
#
# Axes:
#   value  — what is interpolated (verified surface syntax only):
#     :str_var      "Hello, ${name}!"           (string variable)
#     :int_tostring "x is ${x.toString()}"      (Int64 through .toString())
#     :two_vars     "${a} and ${b}"             (multiple holes)
#     :bare_dollar  "costs $5"                  ($ without { is literal)
#     :chained_call "len ${s.length().toString()}" (method-chain hole)
#   consumer — where the interpolated string flows:
#     :local_assert  local binding compared in place
#     :fn_return     returned as !String, TRY'd by the caller
#     :arg           passed borrowed into a length-taking callee
#     :list_elem     appended to []String, read back by index
#     :struct_field  stored in an owned String field
#     :loop_concat   folded with $+ across three loop iterations

SIM_VALUES = {
  str_var: {
    setup: 'name = "World";',
    expr: '"Hello, ${name}!"',
    expected: 'Hello, World!',
  },
  int_tostring: {
    setup: 'x: Int64 = 7;',
    expr: '"x is ${x.toString()}"',
    expected: 'x is 7',
  },
  two_vars: {
    setup: "a = \"foo\";\n    b = \"bar\";",
    expr: '"${a} and ${b}"',
    expected: 'foo and bar',
  },
  bare_dollar: {
    setup: '',
    expr: '"costs $5"',
    expected: 'costs $5',
  },
  chained_call: {
    setup: 's = "abc";',
    expr: '"len ${s.length().toString()}"',
    expected: 'len 3',
  },
}.freeze

SIM_CONSUMERS = %i[local_assert fn_return arg list_elem struct_field loop_concat].freeze

SIM_CELLS = SIM_VALUES.keys.product(SIM_CONSUMERS).map do |value, consumer|
  { value: value, consumer: consumer }
end

def sim_body(setup, expr, expected, consumer)
  setup_block = setup.empty? ? '' : "    #{setup}\n"
  case consumer
  when :local_assert
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    got = #{expr};
          ASSERT got == "#{expected}";
      END
    CLEAR
  when :fn_return
    <<~CLEAR
      FN render() RETURNS !String ->
      #{setup_block}    RETURN #{expr};
      END

      FN main() RETURNS Void ->
          got = TRY render();
          ASSERT got == "#{expected}";
      END
    CLEAR
  when :arg
    <<~CLEAR
      FN takeLen(s2: String) RETURNS Int64 ->
          RETURN s2.length();
      END

      FN main() RETURNS Void ->
      #{setup_block}    ASSERT takeLen(#{expr}) == #{expected.length};
      END
    CLEAR
  when :list_elem
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    MUTABLE xs: []String = [];
          &xs.append(#{expr});
          ASSERT xs[0] == "#{expected}";
      END
    CLEAR
  when :struct_field
    <<~CLEAR
      STRUCT SimMsg { text: String }

      FN main() RETURNS Void ->
      #{setup_block}    m = SimMsg{ text: #{expr} };
          ASSERT m.text == "#{expected}";
      END
    CLEAR
  when :loop_concat
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    MUTABLE acc = "";
          FOR i IN (0 ..< 3) DO
              acc = acc $+ #{expr};
          END
          ASSERT acc == "#{expected * 3}";
      END
    CLEAR
  end
end

FuzzGenerator.register(:string_interpolation_matrix, cells: SIM_CELLS) do |params|
  value = SIM_VALUES.fetch(params[:value])
  sim_body(value[:setup], value[:expr], value[:expected], params[:consumer])
end
