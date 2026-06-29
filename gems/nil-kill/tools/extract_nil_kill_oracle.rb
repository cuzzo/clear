require "rspec/core"
require_relative "../spec/spec_helper"
require_relative "../lib/nil_kill/infer"
require "fileutils"
require "json"
require "digest"

module NilKill
  class Infer
    alias_method :original_run, :run

    def run
      # Capture state before Phase 2
      load_runtime
      index_sources
      load_sorbet if @run_sorbet

      input_state = {
        "methods" => store.instance_variable_get(:@methods).values,
        "tlets" => store.instance_variable_get(:@tlets).values,
        "facts" => store.facts,
        "unused_return_methods_by_location" => unused_return_methods_by_location.to_h { |k, v| [k.to_json, v] }
      }
      
      input_json = JSON.pretty_generate(input_state)

      # Run the rest
      build_flow_graph
      build_fallibility_pressure
      build_hidden_enum_pressure
      build_actions

      output_state = {
        "actions" => store.actions,
        "diagnostics" => store.diagnostics
      }
      output_json = JSON.pretty_generate(output_state)

      # Save to fixtures
      hash = Digest::SHA256.hexdigest(input_json)[0..7]
      dir = File.join(NilKill::ROOT, "spec", "fixtures", "oracle", hash)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "input.json"), input_json)
      File.write(File.join(dir, "output.json"), output_json)

      evidence = @store.to_h
      @store.write(evidence)
      Report.new([], evidence: evidence).run
    end
  end
end

require 'rspec/core'
exit RSpec::Core::Runner.run(['spec/', '--exclude-pattern', 'spec/oracle_spec.rb'])
