# frozen_string_literal: true

class SourceFactMultilineHashLocalFlow
  def summary(label)
    {
      "name" => label,
      "count" => @items.size,
      "active" => @active ? "yes" : "no"
    }
  end
end
