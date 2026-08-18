require "rspec"
require_relative "../ruby/ast/type"

# CLEAR spells a fallible-optional `!?T`; `?!T` is not a type source can write,
# and TenseOperationPlanner rejects that layer order outright. Type.optional_of
# is the single constructor for the optional layer, so wrapping a fallible
# payload there is what produced the unspellable order -- the optional belongs
# INSIDE the fallible.
RSpec.describe "Type.optional_of over a fallible payload" do
  def order(type)
    type.lifecycle_type_key.split("|").first
  end

  it "keeps the fallible layer outermost" do
    expect(order(Type.optional_of(Type.new(:"!Int64")))).to eq("!?Int64")
  end

  it "leaves a plain payload alone" do
    expect(order(Type.optional_of(Type.new(:Int64)))).to eq("?Int64")
  end

  it "is idempotent on an already fallible-optional type" do
    expect(order(Type.optional_of(Type.new(:"!?Int64")))).to eq("!?Int64")
  end
end
