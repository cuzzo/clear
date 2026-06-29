require_relative "spec_helper"
require "json"

RSpec.describe "NilKill Oracle Tests" do
  fixtures_dir = File.join(NilKill::ROOT, "spec", "fixtures", "oracle")
  
  if Dir.exist?(fixtures_dir)
    Dir.glob(File.join(fixtures_dir, "*", "input.json")).each do |input_file|
      hash = File.basename(File.dirname(input_file))
      output_file = File.join(File.dirname(input_file), "output.json")
      
      it "matches oracle output for fixture #{hash}" do
        input_data = JSON.parse(File.read(input_file))
        expected_output = JSON.parse(File.read(output_file))
        
        isolated_env("NIL_KILL_TARGETS" => "/dev/null") do
          allow(NilKill).to receive(:target_path?).and_return(true)
          allow(NilKill).to receive(:usage_scan_files).and_return([])
          infer = NilKill::Infer.new(["--no-sorbet"])
          
          unused_methods = input_data["unused_return_methods_by_location"] || {}
          unused_methods = unused_methods.to_h { |k, v| [JSON.parse(k), v] } rescue unused_methods
          allow(infer).to receive(:unused_return_methods_by_location).and_return(unused_methods)
          
          # Inject input state
          store = infer.store
          
          # @methods is a hash indexed by rec["key"].join("\0")
          input_data["methods"].each do |rec|
            store.instance_variable_get(:@methods)[rec["key"].join("\0")] = rec
          end
          
          # @tlets is indexed similarly
          input_data["tlets"].each do |rec|
            store.instance_variable_get(:@tlets)[rec["key"].join("\0")] = rec
          end
          
          # Replace facts hash entirely
          store.instance_variable_set(:@facts, input_data["facts"])
          
          # Run the deterministic parts of the pipeline (skip I/O and scraping)
          infer.send(:build_flow_graph)
          infer.send(:build_fallibility_pressure)
          infer.send(:build_hidden_enum_pressure)
          infer.send(:build_actions)
          
          # Extract the result
          actual_actions = store.actions
          actual_diagnostics = store.diagnostics
          
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
