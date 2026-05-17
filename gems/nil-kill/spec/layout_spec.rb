# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill package layout" do
  it "keeps tools/nil-kill as a symlink to the gem executable" do
    link = File.join(NilKill::ROOT, "tools", "nil-kill")

    expect(File.symlink?(link)).to be(true)
    expect(File.readlink(link)).to eq("../gems/nil-kill/exe/nil-kill")
  end

  it "loads doctor through the tools/nil-kill symlink under Bundler" do
    _out, err, status = Open3.capture3("bundle", "exec", "tools/nil-kill", "doctor", chdir: NilKill::ROOT)

    expect(status).to be_success, err
  end
end
