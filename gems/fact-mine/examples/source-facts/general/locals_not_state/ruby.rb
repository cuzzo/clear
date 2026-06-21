# frozen_string_literal: true

class SourceFactLocalsNotState
  def build(values, config)
    key = "HOME"
    path = ENV[key]
    total = 0
    values.each do |value|
      total = total + value
    end
    config[:path] = path
    assert_empty values
    [path, total, config]
  end
end
