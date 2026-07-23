# typed: strict
# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::ProofBoundaryInput do
  describe ".review" do
    it "marks absent coverage evidence as unknown with an explicit blocker" do
      coverage = described_class.review(input_completeness: nil, blocker_kinds: [])

      expect(coverage.input_completeness).to eq("unknown")
      expect(coverage.blockers).to eq([{ "kind" => "missing_evidence" }])
    end

    it "preserves modeled partial evidence" do
      coverage = described_class.review(
        input_completeness: nil,
        blocker_kinds: ["call_resolution"]
      )

      expect(coverage.input_completeness).to eq("partial")
      expect(coverage.blockers).to eq([{ "kind" => "call_resolution" }])
    end
  end

  describe ".explain_unknown" do
    it "does not replace an existing explanation" do
      coverage = described_class.explain_unknown(
        input_completeness: "unknown",
        blocker_kinds: ["open_corpus"]
      )

      expect(coverage.blockers).to eq([{ "kind" => "open_corpus" }])
    end
  end
end
