# frozen_string_literal: true

require "msgpack"

require_relative "spec_helper"
require_relative "../ruby/annotator"

RSpec.describe Annotator::Phases::DerivedProgramFacts do
  def facts_for(source)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)
    annotator.annotate!(program)
    T.must(annotator.annotation_products.capability_audit).derived_program
  end

  it "publishes stable portable contracts after whole-program finalization" do
    source = <<~CLEAR
      FN leaf(value: Int64) RETURNS Int64 -> RETURN value; END
      FN root(value: Int64) RETURNS Int64 -> RETURN leaf(value); END
    CLEAR

    facts = facts_for(source)
    root = facts.functions.fetch("root")

    expect(facts.functions.keys).to eq(["leaf", "root"])
    expect(root.return_type_key).to start_with("Int64|")
    expect(root.effects).to be_frozen
    expect(root.requires).to be_frozen
    expect(root.fingerprint).to match(/\A[0-9a-f]{64}\z/)
    expect(MessagePack.unpack(MessagePack.pack(facts.to_h))).to eq(facts.to_h)
  end

  it "is independent of declaration insertion order" do
    left = facts_for(<<~CLEAR)
      FN first() RETURNS Int64 -> RETURN 1; END
      FN second() RETURNS Int64 -> RETURN first(); END
    CLEAR
    right = facts_for(<<~CLEAR)
      FN second() RETURNS Int64 -> RETURN first(); END
      FN first() RETURNS Int64 -> RETURN 1; END
    CLEAR

    expect(right.to_h).to eq(left.to_h)
  end
end
