# Template: lambda / USE-capture matrix — ENUMERATED, not sampled.
#
# Lambdas are the lowering target for translated Ruby blocks, so every
# capture shape is crossed with every call context. Expected values are
# Ruby-declared; a failing :pass cell is a SURFACED bug.
#
# Axes:
#   shape — lambda literal form (verified surface syntax only):
#     :plain          %(n: Int64) -> n * 2
#     :use_int        USE(base) borrow of an Int64
#     :use_two        USE(a, b) two borrows
#     :use_string     USE(s) borrow of a String read via .length()
#     :default_param  %(n=4: Int64) -> n * 3, called with and without arg
#   context — how the lambda is invoked:
#     :direct       assigned to an inferred-type local and called
#     :typed_var    assigned to an explicit FN(Int64) -> Int64 local
#     :loop         called across FOR iterations, results folded
#     :higher_order passed as a FN(Int64) -> Int64 argument and applied
#
# Capture reads after the calls pin borrow (not move) semantics.

LCM_SHAPES = {
  plain: {
    setup: '',
    lambda: '%(n: Int64) -> n * 2',
    arg: 3,
    expected: 6,
  },
  use_int: {
    setup: 'base: Int64 = 100;',
    lambda: '%(n: Int64) USE(base) -> n + base',
    arg: 5,
    expected: 105,
  },
  use_two: {
    setup: "a: Int64 = 10;\n    b: Int64 = 4;",
    lambda: '%(n: Int64) USE(a, b) -> n + a - b',
    arg: 1,
    expected: 7,
  },
  use_string: {
    setup: 's = "abc";',
    lambda: '%(n: Int64) USE(s) -> n + s.length()',
    arg: 2,
    expected: 5,
  },
  default_param: {
    setup: '',
    lambda: '%(n=4: Int64) -> n * 3',
    arg: 2,
    expected: 6,
  },
}.freeze

LCM_CONTEXTS = %i[direct typed_var loop higher_order].freeze

LCM_CELLS = LCM_SHAPES.keys.product(LCM_CONTEXTS).map do |shape, context|
  { shape: shape, context: context }
end

def lcm_body(shape_key, context)
  shape = LCM_SHAPES.fetch(shape_key)
  setup_block = shape[:setup].empty? ? '' : "    #{shape[:setup]}\n"
  # A zero-arg default call is only legal through an inferred-type binding:
  # an explicit FN(Int64) -> Int64 annotation pins the arity to 1.
  default_extra =
    if shape_key == :default_param && context == :direct
      "    ASSERT f() == 12;\n"
    else
      ''
    end
  case context
  when :direct
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    f = #{shape[:lambda]};
          ASSERT f(#{shape[:arg]}) == #{shape[:expected]};
      #{default_extra}END
    CLEAR
  when :typed_var
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    f: FN(Int64) -> Int64 = #{shape[:lambda]};
          ASSERT f(#{shape[:arg]}) == #{shape[:expected]};
      #{default_extra}END
    CLEAR
  when :loop
    <<~CLEAR
      FN main() RETURNS Void ->
      #{setup_block}    f = #{shape[:lambda]};
          MUTABLE total: Int64 = 0;
          FOR i IN (0 ..< 3) DO
              total = total + f(#{shape[:arg]});
          END
          ASSERT total == #{shape[:expected] * 3};
      END
    CLEAR
  when :higher_order
    <<~CLEAR
      FN lcmApply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
          RETURN cb(x);
      END

      FN main() RETURNS Void ->
      #{setup_block}    f = #{shape[:lambda]};
          got = TRY lcmApply(f, #{shape[:arg]});
          ASSERT got == #{shape[:expected]};
      END
    CLEAR
  end
end

FuzzGenerator.register(:lambda_capture_matrix, cells: LCM_CELLS) do |params|
  lcm_body(params[:shape], params[:context])
end
