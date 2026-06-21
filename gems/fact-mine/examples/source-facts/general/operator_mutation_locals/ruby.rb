# frozen_string_literal: true

class SourceFactOperatorMutationLocals
  def append_all(items)
    out = []
    items.each { |item| out << item }
    out
  end
end
