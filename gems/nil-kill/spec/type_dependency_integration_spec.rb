# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "FactMine type dependency prioritization" do
  it "ranks one untyped parameter through copies and multiple downstream reads" do
    Dir.mktmpdir("nil-kill-type-dependencies") do |dir|
      path = File.join(dir, "pipeline.rb")
      File.write(path, <<~RUBY)
        class Pipeline
          def fanout(source)
            first = source
            second = first
            [first, second]
          end

          def passthrough(source)
            copy = source
            copy
          end


          def choose(flag, left, right)
            if flag
              chosen = left
            else
              chosen = right
            end
            chosen
          end
        end
      RUBY

      evidence = NilKill::StaticEvidence.build([path], root: dir, language: :ruby)
      store = NilKill::Store.new
      NilKill::Inference::StaticFactProvider.new.index(store: store, static: evidence, root: dir)
      pressure = NilKill::FlowGraph.dependencies_from_evidence("facts" => store.facts).unlock_pressure
      source = pressure.find do |row|
        row.dig("candidate_data", "name") == "source" && row.dig("counts", "return").to_i.positive?
      end

      expect(evidence.dig("facts", "type_dependencies")).not_to be_empty
      expect(store.facts["type_dependencies"]).to eq(evidence.dig("facts", "type_dependencies"))
      expect(source).not_to be_nil
      expect(source.dig("candidate_data", "candidate_kind")).to eq("parameter")
      expect(source.dig("counts", "flow_read")).to be >= 2
      expect(source.dig("counts", "return")).to be >= 1

      chosen = evidence.dig("facts", "type_dependencies").find do |fact|
        fact["function"] == "choose" && fact["name"] == "chosen" && fact["kind"] == "flow_read"
      end
      left_or_right = pressure.select { |row| %w[left right].include?(row.dig("candidate_data", "name")) }
      expect(chosen.fetch("requirements").size).to eq(2)
      expect(left_or_right).not_to be_empty
      expect(left_or_right).to all(satisfy { |row| !row["unlocked_ids"].include?(chosen["id"]) })
    end
  end
end
