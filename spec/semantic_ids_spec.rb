require "spec_helper"

require_relative "../src/semantic/semantic_ids" unless defined?(Semantic::SemanticIdIndex)

RSpec.describe Semantic::SemanticIdIndex do
  it "looks up stable function definition and body ids by name" do
    main = Semantic::BodyIdentity.for_ordinal(1)
    helper = Semantic::BodyIdentity.for_ordinal(2)
    index = described_class.new(
      definitions: {
        "main" => main.definition_id,
        "helper" => helper.definition_id,
      },
      bodies: {
        "main" => main.body_id,
        "helper" => helper.body_id,
      }
    )

    expect(index.definition_id_for("main")).to eq(main.definition_id)
    expect(index.body_id_for("main")).to eq(main.body_id)
    expect(index.definition_id_for("helper")).to eq(helper.definition_id)
    expect(index.body_id_for("helper")).to eq(helper.body_id)
    expect(index.definition_id_for("missing")).to be_nil
    expect(index.body_id_for("missing")).to be_nil
  end

  it "creates typed body identities from deterministic ordinals" do
    identity = Semantic::BodyIdentity.for_ordinal(42)

    expect(identity.definition_id.value).to eq(42)
    expect(identity.body_id.value).to eq(42)
    expect(Semantic::BodyIdentity.unassigned.definition_id).to eq(Semantic::UNASSIGNED_DEF_ID)
    expect(Semantic::BodyIdentity.unassigned.body_id).to eq(Semantic::UNASSIGNED_BODY_ID)
  end
end
