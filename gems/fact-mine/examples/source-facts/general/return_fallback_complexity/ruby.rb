# frozen_string_literal: true

class SourceFactReturnFallbackComplexity
  def state_type_for(receiver, state_types)
    return state_types[receiver] if state_types.key?(receiver)

    if receiver.start_with?("self.", "this.")
      field = receiver.split(".")[1]
      return state_types[field] || state_types["@#{field}"]
    end

    nil
  end
end
