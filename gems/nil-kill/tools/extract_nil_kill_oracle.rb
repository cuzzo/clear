require "rspec/core"
require_relative "../spec/spec_helper"
require_relative "../lib/nil_kill/infer"
require "fileutils"
require "json"
require "digest"

module NilKill
  class Infer
    alias_method :original_run, :run

    def oracle_fixture_name(input_state, input_json)
      methods = Array(input_state["methods"])
      file_names = methods.filter_map do |method|
        source_path = method.dig("source", "path") || method.dig("key", 3)
        File.basename(source_path.to_s, ".rb") unless source_path.to_s.empty?
      end.uniq
      method_names = methods.filter_map do |method|
        class_name = method.dig("source", "class") || method.dig("key", 0)
        method_name = method.dig("source", "method") || method.dig("key", 1)
        next if class_name.to_s.empty? || method_name.to_s.empty?

        "#{class_name}-#{method_name}"
      end.uniq
      base = (file_names.first(2) + method_names.first(2)).join("-")
      base = "nil-kill-actions" if base.empty?
      slug = base.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
      "#{slug}-#{Digest::SHA256.hexdigest(input_json)[0..7]}"
    end

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
      dir = File.expand_path("../spec/fixtures/oracle/#{oracle_fixture_name(input_state, input_json)}", __dir__)
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
