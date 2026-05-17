# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill infer pipeline" do
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
      expect(actions).to include(a_hash_including("kind" => "add_sig", "path" => Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s))
      expect(actions).to include(a_hash_including("kind" => "replace_dead_nil_check", "confidence" => "review"))
      expect(File.read(NilKill::REPORT_PATH)).to include("PipelineExample#call")
    end
  end
end
