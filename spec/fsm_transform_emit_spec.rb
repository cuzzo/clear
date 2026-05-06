require "rspec"
require_relative "../src/mir/fsm_transform/emit"

RSpec.describe FsmTransform::Emit do
  it "maps profile dispatch ids and emits task-site comments" do
    expect(described_class.profile_dispatch_id(:local)).to eq(1)
    expect(described_class.profile_dispatch_id(:parallel)).to eq(2)
    expect(described_class.profile_dispatch_id(:shared)).to eq(3)
    expect(described_class.profile_dispatch_id(:unexpected)).to eq(1)

    ctx = { profile_site_id: 11, profile_line: 22, profile_column: 5 }
    expect(described_class.bg_profile_site_comment(ctx, :parallel, :fsm))
      .to eq("// CLEAR_PROFILE_TASK_SITE id=11 kind=BG line=22 column=5 dispatch=parallel form=fsm")
  end
end
