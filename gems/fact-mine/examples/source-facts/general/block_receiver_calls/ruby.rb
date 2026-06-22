# frozen_string_literal: true

class SourceFactBlockReceiverCalls
  def collect(items)
    names = []
    items.flat_map do |item|
      names << item.name
      item.children.each { |child| child.name }
    end
    names
  end
end
