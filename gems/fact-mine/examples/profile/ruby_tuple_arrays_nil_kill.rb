# typed: strict

class TupleArrayEvidence
  extend T::Sig

  sig { params(name: String, node: Integer).returns(T::Array[T.untyped]) }
  def build(name, node)
    consume(:CHAR, ">")
    [[name, node], current]
  end

  sig { params(kind: Symbol, text: String).void }
  def consume(kind, text); end
end
