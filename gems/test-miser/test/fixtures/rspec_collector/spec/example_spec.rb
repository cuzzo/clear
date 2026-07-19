# frozen_string_literal: true

require "example"

RSpec.describe TestMiserRspecFixture do
  subject(:classifier) { described_class.new }

  it "recognizes a positive value" do
    expect(classifier.classify(1)).to eq(:positive)
  end

  it "duplicates the positive assertion" do
    expect(classifier.classify(1)).to eq(:positive)
  end

  it "recognizes a nonpositive value" do
    expect(classifier.classify(0)).to eq(:nonpositive)
  end
end
