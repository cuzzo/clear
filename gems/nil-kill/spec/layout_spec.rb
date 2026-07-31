# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill package layout" do
  # Ruby's collector is the extension itself: there is no Ruby tracer to load
  # into a traced program, and no shared Ruby emitter for a language to branch
  # inside. Both were checked by reading files that no longer exist.
  it "collects Ruby through the extension and not through a Ruby tracer" do
    expect(NilKill::COLLECTOR_EXTENSION).to end_with(".so")
    expect(
      Dir.glob(File.join(NilKill::ROOT, "gems/nil-kill/lib/nil_kill/**/runtime_scip_trace.rb"))
    ).to be_empty
    expect(
      Dir.glob(File.join(NilKill::ROOT, "gems/nil-kill/lib/nil_kill/runtime/scip_emitter.rb"))
    ).to be_empty
  end

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
