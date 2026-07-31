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
    # Ruby's collector is the extension itself, so no provider owns a tracer
    # that would be loaded into the traced program.
    expect(
      Dir.glob(
        File.join(
          NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "languages",
          "providers", "*", "runtime_scip_trace.rb"
        )
      )
    ).to be_empty
    expect(NilKill::COLLECTOR_EXTENSION).to end_with(".so")
  end

  it "keeps runtime inference in FactMine instead of NilKill" do
    emitter = File.read(
      File.join(
        NilKill::ROOT,
        "gems", "nil-kill", "lib", "nil_kill", "runtime", "scip_emitter.rb"
      )
    )
    ruby_values = File.read(
      File.join(
        NilKill::ROOT,
        "gems", "nil-kill", "lib", "nil_kill", "languages", "providers",
        "ruby", "runtime_value_evidence.rb"
      )
    )
    fact_mine_overlay = File.read(
      File.join(
        NilKill::ROOT, "gems", "fact-mine", "src", "runtime_evidence.rs"
      )
    ).split("#[cfg(test)]", 2).first

    expect(emitter).not_to include(
      "build_documents",
      "token_ranges",
      "runtime_scip_inferred_events"
    )
    expect(ruby_values).not_to include(
      "Prism",
      "File.read",
      "Syntax.parse",
      "TreeSitter",
      "reaching_definitions",
      "control_flow",
      "data_flow"
    )
    # There was a second implementation of the join here, in Ruby, and a spec
    # asserting the two agreed. One join means there is nothing to disagree.
    expect(
      File.exist?(File.join(
        NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime",
        "value_evidence_emitter.rb"
      ))
    ).to be(false)
    expect(fact_mine_overlay).not_to match(/\b(?:if|match)\s+language\s*==\s*[\"']ruby/)
    expect(fact_mine_overlay).not_to include(
      'BTreeSet::from(["Array".to_string()])',
      'BTreeSet::from(["Integer".to_string()])'
    )
  end
end
