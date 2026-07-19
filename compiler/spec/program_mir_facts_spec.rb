# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler"

RSpec.describe ProgramMIRFacts do
  def compile(source)
    ZigTranspiler.new(source_dir: Dir.pwd).compile_mir_program(source).frontend.program_mir_facts
  end

  it "publishes the caller-visible runtime contract" do
    facts = compile(<<~CLEAR)
      FN allocate() RETURNS String ->
        value = "owned";
        RETURN COPY value;
      END
      FN caller() RETURNS String -> RETURN allocate(); END
    CLEAR

    expect(facts.functions.keys).to eq(["allocate", "caller"])
    expect(facts.functions.fetch("allocate").needs_runtime).to be(true)
    expect(facts.functions.fetch("caller").needs_runtime).to be(true)
    expect(facts.functions.fetch("caller")).not_to respond_to(
      :cleanup_binding_count,
      :heap_binding_count,
      :frame_binding_count,
    )
    expect(facts.functions.fetch("caller").fingerprint).to match(/\A[0-9a-f]{64}\z/)
  end

  it "uses annotation call summaries for transitive runtime propagation" do
    facts = compile(<<~CLEAR)
      FN leaf() RETURNS String -> RETURN COPY "value"; END
      FN middle() RETURNS String -> RETURN leaf(); END
      FN root() RETURNS String -> RETURN middle(); END
    CLEAR

    expect(facts.functions.values.map(&:needs_runtime)).to all(eq(true))
  end
end
