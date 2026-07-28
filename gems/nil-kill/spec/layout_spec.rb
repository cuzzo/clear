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

  it "keeps runtime SCIP tracing implementations inside language providers" do
    shared = File.read(
      File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime", "scip_emitter.rb")
    )

    expect(shared).not_to match(/\b(?:if|case)\s+language\b/)
    expect(shared).not_to match(/provider_for\(\s*["']/)
    expect(
      Dir.glob(
        File.join(
          NilKill::ROOT,
          "gems",
          "nil-kill",
          "lib",
          "nil_kill",
          "languages",
          "providers",
          "*",
          "runtime_scip_trace.rb"
        )
      )
    ).not_to be_empty
  end
end
