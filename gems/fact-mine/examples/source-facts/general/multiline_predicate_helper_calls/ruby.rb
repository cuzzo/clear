# frozen_string_literal: true

class SourceFactMultilinePredicateHelperCalls
  def summarize(state_names, public_funcs)
    data_carrier = data_carrier?(
      state_count: state_names.size,
      public_methods: public_funcs.size
    )
    data_carrier
  end

  def data_carrier?(state_count:, public_methods:)
    state_count.zero? && public_methods.positive?
  end
end
