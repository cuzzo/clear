# frozen_string_literal: true

require_relative '../select_tense_semantics'

SelectTenseSemantics.validate!

cells = SelectTenseSemantics::SOURCE_SHAPES.keys.product(
  SelectTenseSemantics::VALID_ORDERS,
).map do |source_shape, order|
  { source_shape: source_shape, order: order }
end

cells.concat(SelectTenseSemantics::INVALID_ORDERS.map do |order|
  { source_shape: :list, order: order, invalid_modifier: true, expected: :compile_error }
end)

cells.concat([
  { direct_pipe: :range_to_future },
  { invalid_type: :optional_stream, expected: :compile_error },
  { invalid_type: :legacy_question_cardinality, expected: :compile_error },
])

FuzzGenerator.register(:select_tense_assignment_matrix, cells: cells.freeze) do |p|
  if p[:direct_pipe]
    next <<~CLEAR
      FN streamBar(input: [~]Int64) RETURNS ~Int64 -> RETURN BG { 9_i64; }; END
      FN main() RETURNS !Void ->
        selected: ~Int64 = (1_i64 ..< 10_i64) |> streamBar();
        ASSERT (NEXT selected) == 9_i64;
        RETURN;
      END
    CLEAR
  end

  if p[:invalid_type]
    bad_type = p.fetch(:invalid_type) == :optional_stream ? '?[~]Int64' : '~Int64[?]'
    next <<~CLEAR
      FN main() RETURNS Void ->
        value: #{bad_type} = DEFAULT;
        RETURN;
      END
    CLEAR
  end

  if p[:invalid_modifier]
    next <<~CLEAR
      FN main() RETURNS Void ->
        input: []Int64 = [1_i64];
        selected = input |> SELECT:#{p.fetch(:order)} _;
        RETURN;
      END
    CLEAR
  end

  shape = SelectTenseSemantics::SOURCE_SHAPES.fetch(p.fetch(:source_shape))
  order = p.fetch(:order)
  selector_type = SelectTenseSemantics.wrap(order, 'Int64')
  result_type = SelectTenseSemantics.expected_result(p.fetch(:source_shape), order)
  source_expr = case p.fetch(:source_shape)
                when :list
                  '[1_i64, 2_i64]'
                when :finite
                  'BG STREAM { YIELD 1_i64; YIELD 2_i64; CLOSE; }'
                when :bounded
                  '[BG { 1_i64; }, BG { 2_i64; }]'
                when :infinite
                  'BG STREAM { WHILE TRUE DO YIELD 1_i64; END }'
                end

  <<~CLEAR
    #{SelectTenseSemantics.selector_helpers}
    FN project(value: Int64) RETURNS #{selector_type} ->
      RETURN #{SelectTenseSemantics.selector_expression(order)};
    END
    FN main() RETURNS !Void ->
      input: #{shape.fetch(:type)} = #{source_expr};
      selected: #{result_type} = input |> #{SelectTenseSemantics.modifier(order)} project(_);
      RETURN;
    END
  CLEAR
end
