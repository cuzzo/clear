# frozen_string_literal: true

# Independent contract for SELECT's ordered effect/tense modifier.  This model
# intentionally does not call Type, the parser, or the annotator: its output is
# the oracle against which those compiler layers are checked.
module SelectTenseSemantics
  VALID_ORDERS = ['', '!', '?', '!?', '~', '~!', '~?', '~!?',
                  '!~', '!~!', '!~?', '!~!?'].freeze
  INVALID_ORDERS = ['?!', '?~', '!?~', '~?!', '~~'].freeze

  SOURCE_SHAPES = {
    list: { type: '[]Int64', cardinality: nil },
    finite: { type: '[~]Int64', cardinality: '' },
    bounded: { type: '[~2]Int64', cardinality: '2' },
    infinite: { type: '[~INF]Int64', cardinality: 'INF' },
  }.freeze

  module_function

  def selector_helpers
    <<~CLEAR
      FN selectFallible(value: Int64) RETURNS !Int64 -> RETURN value; END
      FN selectOptional(value: Int64) RETURNS ?Int64 -> RETURN value; END
      FN selectBoth(value: Int64) RETURNS !?Int64 -> RETURN value; END
    CLEAR
  end

  def selector_expression(order)
    suffix = order.include?('~') ? order.split('~', 2).last : order
    inner = case suffix
            when '' then 'value'
            when '!' then 'selectFallible(value)'
            when '?' then 'selectOptional(value)'
            when '!?' then 'selectBoth(value)'
            else raise "unsupported SELECT item order #{suffix.inspect}"
            end
    order.include?('~') ? "BG { #{inner}; }" : inner
  end

  def wrap(order, type)
    "#{order}#{type}"
  end

  def stream(cardinality, item)
    marker = cardinality.to_s
    "[~#{marker}]#{item}"
  end

  def expected_result(source_shape, order)
    source = SOURCE_SHAPES.fetch(source_shape)
    unless order.include?('~')
      item = wrap(order, 'Int64')
      return "[]#{item}" if source_shape == :list

      return stream(source.fetch(:cardinality), item)
    end

    outer, item_order = order.split('~', 2)
    cardinality = source.fetch(:cardinality) || ''
    wrap(outer, stream(cardinality, wrap(item_order, 'Int64')))
  end

  def modifier(order)
    order.empty? ? 'SELECT' : "SELECT:#{order}"
  end

  def validate!
    raise 'SELECT modifier oracle has duplicates' unless VALID_ORDERS.uniq == VALID_ORDERS
    raise 'SELECT invalid modifier oracle has duplicates' unless INVALID_ORDERS.uniq == INVALID_ORDERS
    raise 'SELECT valid and invalid modifiers overlap' unless (VALID_ORDERS & INVALID_ORDERS).empty?
    raise 'SELECT oracle accidentally admits ? before a tense boundary' if VALID_ORDERS.any? { |order| order.match?(/\?.*~/) }
    raise 'SELECT oracle accidentally admits !? before a tense boundary' if VALID_ORDERS.any? { |order| order.include?('!?~') }
    VALID_ORDERS.each { |order| selector_expression(order) }
    true
  end
end
