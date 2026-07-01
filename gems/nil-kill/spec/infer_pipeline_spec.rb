# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill infer pipeline" do
  it "indexes Ruby source facts through static evidence providers" do
    Dir.mktmpdir("nil-kill-static-provider", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        class StaticProviderExample
          extend T::Sig

          const :name, T.untyped

          sig { params(reason: String).returns(String) }
          def call(reason)
            reason.nil?
            reason
          end
        end
      RUBY

      isolated_env("NIL_KILL_TARGETS" => dir) do
        infer = NilKill::Infer.new(["--no-sorbet"])
        infer.index_sources

        store = infer.store
        expect(store.facts["existing_sigs"]).to include(a_hash_including(
          "path" => source,
          "class" => "StaticProviderExample",
          "method" => "call",
          "non_nil_params" => include("reason")
        ))
        expect(store.facts["type_definitions"]).to include(a_hash_including(
          "kind" => "state_field",
          "owner" => "StaticProviderExample",
          "name" => "name",
          "declared_type" => "T.untyped"
        ))
        # expect(store.facts["dead_nil_checks"]).to include(a_hash_including(
        #   "path" => source,
        #   "kind" => "nil_check",
        #   "code" => "reason.nil?"
        # ))
      end
    end
  end

  it "indexes Python through the static provider without Ruby-specific enrichment" do
    Dir.mktmpdir("nil-kill-python-provider", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.py")
      File.write(source, <<~PYTHON)
        class StaticProviderExample:
            def call(self, reason: str) -> str:
                return reason
      PYTHON

      isolated_env("NIL_KILL_TARGETS" => dir) do
        infer = NilKill::Infer.new(["--no-sorbet"])
        infer.index_sources

        store = infer.store
        expect(store.facts["existing_sigs"]).to include(a_hash_including(
          "path" => source,
          "language" => "python",
          "class" => "StaticProviderExample",
          "method" => "call",
          "params" => include(a_hash_including("name" => "reason", "type" => "str"))
        ))
        expect(store.facts["dead_nil_checks"]).to be_empty
      end
    end
  end

  it "loads runtime evidence, indexes sources, builds actions, and writes a report" do
    Dir.mktmpdir("nil-kill-pipeline", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, <<~RUBY)
        class PipelineExample
          extend T::Sig

          sig { params(items: T::Array[T.untyped], reason: String).returns(T.untyped) }
          def call(items, reason)
            reason.nil?
            items
          end

          def unsigned(value)
            value
          end
        end
      RUBY

      runtime_dir = NilKill::RUNTIME_DIR
      FileUtils.rm_rf(runtime_dir)
      FileUtils.mkdir_p(runtime_dir)
      File.write(File.join(runtime_dir, "methods-test.jsonl"), JSON.generate(
        "class" => "PipelineExample",
        "method" => "call",
        "kind" => "instance",
        "path" => source,
        "line" => 5,
        "calls" => 25,
        "ok_calls" => 25,
        "raised_calls" => 0,
        "params_by_name" => { "items" => ["Array"], "reason" => ["String"] },
        "params_ok" => { "items" => ["Array"], "reason" => ["String"] },
        "params_raised" => {},
        "param_sites" => {},
        "param_sites_ok" => {},
        "param_sites_raised" => {},
        "param_traces" => {},
        "param_traces_ok" => {},
        "param_traces_raised" => {},
        "param_elem" => { "items" => ["String"] },
        "param_kv" => {},
        "returns" => ["Array"],
        "return_elem" => ["String"],
        "return_kv" => [[], []],
        "raised" => []
      ) + "\n")

      isolated_env("NIL_KILL_TARGETS" => dir) do
        expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
      end

      evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
      actions = evidence["actions"]

      expect(actions).to include(a_hash_including("kind" => "fix_sig_return", "confidence" => "review"))
      expect(actions).to include(a_hash_including("kind" => "narrow_generic_param", "confidence" => "high"))
      expect(actions).to include(a_hash_including("kind" => "add_sig", "path" => source))
      # expect(actions).to include(a_hash_including("kind" => "replace_dead_nil_check", "confidence" => "review"))
      expect(File.read(NilKill::REPORT_PATH)).to include("PipelineExample#call")
    end
  end

  it "loads and merges runtime method-edge evidence" do
    Dir.mktmpdir("nil-kill-pipeline-edges", NilKill::ROOT) do |dir|
      source = File.join(dir, "edges.rb")
      File.write(source, <<~RUBY)
        class RuntimeEdgePipeline
          def caller
            callee
          end

          def callee
            "ok"
          end
        end
      RUBY

      runtime_dir = NilKill::RUNTIME_DIR
      FileUtils.rm_rf(runtime_dir)
      FileUtils.mkdir_p(runtime_dir)
      File.write(File.join(runtime_dir, "method-edges-a.jsonl"), JSON.generate(
        "caller" => {"class" => "RuntimeEdgePipeline", "method" => "caller", "kind" => "instance", "path" => source, "line" => 2},
        "callee" => {"class" => "RuntimeEdgePipeline", "method" => "callee", "kind" => "instance", "path" => source, "line" => 6},
        "calls" => 2,
        "ok_calls" => 2,
        "raised_calls" => 0
      ) + "\n")
      File.write(File.join(runtime_dir, "method-edges-b.jsonl"), JSON.generate(
        "caller" => {"class" => "RuntimeEdgePipeline", "method" => "caller", "kind" => "instance", "path" => source, "line" => 2},
        "callee" => {"class" => "RuntimeEdgePipeline", "method" => "callee", "kind" => "instance", "path" => source, "line" => 6},
        "calls" => 3,
        "ok_calls" => 1,
        "raised_calls" => 2
      ) + "\n")

      isolated_env("NIL_KILL_TARGETS" => dir) do
        expect { NilKill::Infer.new(["--no-sorbet"]).run }.to output(/Nil Kill Report/).to_stdout
      end

      evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
      expect(evidence.dig("facts", "runtime_call_edges")).to contain_exactly(a_hash_including(
        "caller" => a_hash_including("class" => "RuntimeEdgePipeline", "method" => "caller"),
        "callee" => a_hash_including("class" => "RuntimeEdgePipeline", "method" => "callee"),
        "calls" => 5,
        "ok_calls" => 3,
        "raised_calls" => 2
      ))
    end
  end
end
