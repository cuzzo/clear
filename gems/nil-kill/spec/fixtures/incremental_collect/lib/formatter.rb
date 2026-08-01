# frozen_string_literal: true

module IncrementalFormatter
  def self.render(value)
    "total=#{value}".strip
  end
end
