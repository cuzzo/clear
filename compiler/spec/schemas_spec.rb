require "rspec"

require_relative "../ruby/ast/schemas"

RSpec.describe Schemas do
  it "uses inline_struct? as a total schema-kind predicate" do
    struct_schema = Schemas::StructSchema.new(fields: {})
    inline_variant = Schemas::InlineStructVariant.new(fields: {})

    expect(described_class.inline_struct?(struct_schema)).to be(false)
    expect(described_class.inline_struct?(inline_variant)).to be(true)
    expect(described_class.inline_struct?(nil)).to be(false)
  end
end
