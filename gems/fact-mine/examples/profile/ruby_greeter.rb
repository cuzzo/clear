# typed: false
class Greeter
  sig { params(name: String).returns(String) }
  def greet(name)
    @name = name
    "Hello, #{name}"
  end

  sig { returns(T.nilable(String)) }
  def name
    @name
  end
end

module Utils
  sig { params(value: T.untyped).returns(T::Boolean) }
  def self.present?(value)
    !value.nil? && !value.to_s.empty?
  end
end