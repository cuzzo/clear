require_relative "spec_helper"
require "json"

RSpec.describe "NilKill Oracle Tests" do
  fixture_roots = %w[oracle evidence_oracle].map { |name| File.join(__dir__, "fixtures", name) }

  if fixture_roots.any? { |root| Dir.exist?(root) }
    fixture_roots.flat_map { |root| Dir.glob(File.join(root, "*", "input.json")) }.each do |input_file|
      hash = File.basename(File.dirname(input_file))
      output_file = File.join(File.dirname(input_file), "output.json")
      
      it "matches oracle output for fixture #{hash}" do
        input_data = JSON.parse(File.read(input_file))
        expected_output = JSON.parse(File.read(output_file))
        
        isolated_env("NIL_KILL_TARGETS" => "/dev/null") do
          actual_actions = if NilKill::Schema::EvidenceBundle.v2?(input_data)
            NilKill::Analyzers::RuntimeEvidenceAnalyzer.new(input_data).analyze
          else
            infer = NilKill::Infer.new(["--no-sorbet"])

            # Run the deterministic Rust action builder against the fixture state.
            infer.send(:delegate_to_rust, input_data)
            infer.store.actions
          end

          expect(actual_actions).to match_array(expected_output["actions"])
        end
      end
    end
  else
    it "has no oracle fixtures available" do
      skip "Run `bundle exec ruby tools/extract_nil_kill_oracle.rb` first"
    end
  end
end
