require "rspec"
require_relative "../src/ast/diagnostic_registry" unless defined?(DiagnosticRegistry)
require_relative "../src/ast/diagnostic_examples" unless defined?(DiagnosticExamples::FixScan)

# Audit the `@example_for: CODE` annotation convention. Every annotated
# describe block must (a) reference a real registry code and (b) carry
# both a BAD example (an `it` whose body uses `raise_error`) and a
# GOOD example (an `it` without `raise_error`). Both halves are real
# RSpec tests that have been verified to pass — `clear explain` then
# pulls the heredoc body from the actual test source.
RSpec.describe DiagnosticExamples do
  let(:examples) { DiagnosticExamples.all }

  it "every @example_for: CODE references a real registry code" do
    unknown = examples.keys.reject { |c| DiagnosticRegistry.known?(c) }
    expect(unknown).to be_empty,
      "Examples reference codes that aren't in the registry:\n" +
      unknown.map { |c| "  :#{c}" }.join("\n")
  end

  it "every annotated example has both a bad and a good half" do
    incomplete = examples.reject { |_, e| e[:bad] && e[:good] }
    expect(incomplete).to be_empty,
      "Annotated examples missing one half (bad or good):\n" +
      incomplete.map { |c, e|
        missing = []
        missing << "bad" unless e[:bad]
        missing << "good" unless e[:good]
        "  :#{c} — missing: #{missing.join(', ')} (#{e[:file]}:#{e[:line]})"
      }.join("\n")
  end

  it "every annotated example has a non-empty fix prose" do
    no_fix = examples.reject { |_, e| e[:fix] && !e[:fix].empty? }
    expect(no_fix).to be_empty,
      "Annotated examples missing the @fix: prose:\n" +
      no_fix.map { |c, e| "  :#{c} (#{e[:file]}:#{e[:line]})" }.join("\n")
  end

  describe ".lookup" do
    it "returns nil for an unknown code" do
      expect(DiagnosticExamples.lookup(:NOT_REAL)).to be_nil
    end

    it "returns a populated hash for a code with an example" do
      ex = DiagnosticExamples.lookup(:ENUM_UNKNOWN_VARIANT)
      expect(ex).not_to be_nil
      expect(ex[:bad]).to include("Color.Yellow")
      expect(ex[:good]).to include("Color.Red")
      expect(ex[:fix]).to include("variants declared")
    end
  end

  describe ".scan_fix_lines" do
    it "returns collected fix prose and the next describe candidate index" do
      lines = [
        "# @example_for: ARITY_MISMATCH\n",
        "# @fix: Add the missing argument.\n",
        "# @fix: Keep the call arity aligned.\n",
        "# comment between metadata and describe\n",
        "\n",
        "describe \"example\" do\n",
      ]

      scan = DiagnosticExamples.send(:scan_fix_lines, lines, 1)

      expect(scan.fix_lines).to eq([
        "Add the missing argument.",
        "Keep the call arity aligned.",
      ])
      expect(scan.next_idx).to eq(5)
    end
  end
end
