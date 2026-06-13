require_relative "../tools/mutants/support"

RSpec.describe MutationTesting do
  describe ".parse_mutant_summary" do
    it "parses mutant's final summary block" do
      output = <<~OUT
        Mutant environment:
        Selected-Tests:  37
        Mutations:       2378
        Results:         2378
        Kills:           1814
        Alive:           564
        Timeouts:        59
        Coverage:        76.28%
      OUT

      summary = described_class.parse_mutant_summary(output)

      expect(summary.mutations).to eq(2378)
      expect(summary.kills).to eq(1814)
      expect(summary.alive).to eq(564)
      expect(summary.timeouts).to eq(59)
      expect(summary.selected_tests).to eq(37)
      expect(summary.coverage).to eq(76.28)
    end

    it "returns nil for unparsable output" do
      expect(described_class.parse_mutant_summary("boom")).to be_nil
    end
  end

  describe ".parse_fuzz_summary" do
    it "parses the fuzz runner summary line" do
      summary = described_class.parse_fuzz_summary(
        "Summary: 50 run, 46 ok, 1 fail, 2 leak, 3 mir-error, 4 unexpected-pass\n"
      )

      expect(summary).to include(
        run: 50,
        ok: 46,
        fail: 1,
        leak: 2,
        mir_error: 3,
        unexpected_pass: 4
      )
    end
  end
end
