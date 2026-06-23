# ruby_shapes.rb

class RubyShapes
  MY_CONST = {
    :sym => :symbol,
    "str" => "string",
    123 => 1.5,
    true => false,
    nil => nil,
    CustomClass => nil
  }

  def initialize
    [1, "two", :three, true, nil, CustomClass]
  end
end
