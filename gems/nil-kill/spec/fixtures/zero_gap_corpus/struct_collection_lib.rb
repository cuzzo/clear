# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# A Struct field (struct_field_runtime signal), a T.let site, and a
# T::Array[T.untyped] collection element -- the non-method evidence
# kinds, so the guarantee covers struct_unobserved / collection_no_*
# alongside the method columns.
Pair = Struct.new(:a, :b)

class StructColl
  extend T::Sig

  sig { params(items: T::Array[T.untyped]).returns(T.untyped) }
  def build(items)
    tag = T.let(items.first.to_s, T.untyped)
    p = Pair.new(tag, items.length)
    p.a = tag.upcase
    p.b = items.sum
    [p, items]
  end
end
