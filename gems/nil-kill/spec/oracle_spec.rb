require_relative "spec_helper"
require "json"

RSpec.describe "NilKill Oracle Tests" do
  fixtures_dir = File.join(__dir__, "fixtures", "oracle")
  
  if Dir.exist?(fixtures_dir)
    Dir.glob(File.join(fixtures_dir, "*", "input.json")).each do |input_file|
      hash = File.basename(File.dirname(input_file))
      output_file = File.join(File.dirname(input_file), "output.json")
      
      it "matches oracle output for fixture #{hash}" do
        input_data = JSON.parse(File.read(input_file))
        expected_output = JSON.parse(File.read(output_file))
        
        isolated_env("NIL_KILL_TARGETS" => "/dev/null") do
          infer = NilKill::Infer.new(["--no-sorbet"])
          
          # Run the deterministic Rust action builder against the fixture state.
          infer.send(:delegate_to_rust, input_data)

          # Extract the result
          actual_actions = infer.store.actions
          
          expect(actual_actions).to match_array(expected_output["actions"])
          # we can ignore diagnostics for the strict oracle unless they matter, but let's check actions first
        end
      end
    end
  else
    it "has no oracle fixtures available" do
      skip "Run `bundle exec ruby tools/extract_nil_kill_oracle.rb` first"
    end
  end
end
