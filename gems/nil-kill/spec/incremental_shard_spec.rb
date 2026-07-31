# frozen_string_literal: true

require_relative "spec_helper"
require "rbconfig"

RSpec.describe "NilKill incremental test shards" do
  it "selects affected functions/tests, adds and subtracts test evidence, and reruns support dependents" do
    Dir.mktmpdir("nil-kill-shards") do |root|
      fixture = File.join(NilKill::ROOT, "gems/nil-kill/spec/fixtures/incremental_shards")
      FileUtils.cp_r("#{fixture}/.", root)
      runtime = File.join(root, ".nil-kill", "runtime")
      executable = File.join(NilKill::ROOT, "gems/nil-kill/lib/nil_kill.rb")
      source = File.join(root, "lib", "calculator.rb")
      env = {
        "NIL_KILL_ROOT" => root,
        "NIL_KILL_TARGETS" => File.join(root, "lib"),
        "NIL_KILL_TMP_DIR" => File.join(root, ".nil-kill"),
        "FACT_MINE_RUST_BINARY" =>
          File.join(NilKill::ROOT, "gems/fact-mine/target/release/fact-mine-rust"),
      }
      loader = "Dir[#{File.join(root, "test", "*_test.rb").inspect}].sort.each { |file| require file }"
      workload = [RbConfig.ruby, "-I", File.join(root, "lib"), "-e", loader]
      collect = lambda do |fast: false, continue_on_error: false|
        args = [RbConfig.ruby, executable, "collect"]
        args << "--fast" if fast
        args << "--continue-on-error" if continue_on_error
        Open3.capture3(env, *args, "--", *workload)
      end
      manifest_path = File.join(runtime, NilKill::Runtime::Snapshot::MANIFEST)
      manifest = -> { NilKill::Runtime::JsonIO.parse(manifest_path) }

      stdout, stderr, status = collect.call
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      full = manifest.call
      expect(full.dig("workload", "mode")).to eq("test_files")
      expect(full.dig("workload", "shards").length).to eq(2)
      expect(full.fetch("dependencies").length).to eq(2)
      expect(full.fetch("dependencies").values).to all(satisfy { |keys| !keys.empty? })
      expect(full.fetch("callsites").length).to eq(2)
      expect(full.fetch("callsites").values).to all(satisfy { |sites| !sites.empty? })
      shard_runs = Dir.glob(File.join(runtime, "shard-evidence", "*.json.gz")).map do |path|
        NilKill::Runtime::JsonIO.parse(path).fetch("runs")
      end
      expect(shard_runs.flatten.uniq.length).to eq(2)

      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("workload skipped")

      File.write(source, File.read(source).sub("value - 1", "value + -1"))
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("1 changed functions", "0 traced shards")
      expect(manifest.call).to include(
        "complete" => true,
        "selected_shards" => []
      )

      File.write(source, File.read(source).sub("value * 2", "value + value"))
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("1 traced shards")
      changed_function = manifest.call
      double_shard = changed_function.dig("workload", "shards").find do |_id, shard|
        shard["test_path"].end_with?("double_test.rb")
      end.first
      expect(changed_function.fetch("selected_shards")).to eq([double_shard])
      expect(changed_function.fetch("changed_functions").length).to eq(1)
      expect(changed_function["potentially_stale"]).to be(false)

      triple_test = File.join(root, "test", "triple_test.rb")
      File.write(triple_test, File.read(triple_test).sub("assert_equal 9", "assert_equal 12").sub("triple(3)", "triple(4)"))
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("1 changed tests, 1 traced shards")
      expect(manifest.call.fetch("changed_tests")).to eq(["test/triple_test.rb"])

      added_test = File.join(root, "test", "added_test.rb")
      File.write(added_test, <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/calculator"
        class ShardAddedTest < Minitest::Test
          def test_added
            assert_equal 10, ShardCalculator.new.double(5)
          end
        end
      RUBY
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("1 changed tests, 1 traced shards")
      expect(Dir.glob(File.join(runtime, "shard-evidence", "*.json.gz")).length).to eq(3)

      File.write(File.join(root, "test", "test_helper.rb"), "SHARD_HELPER_VERSION = 1\n")
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("3 traced shards")
      expect(manifest.call).to include(
        "support_changed" => true,
        "fallback_full" => true,
        "potentially_stale" => false
      )

      double_test = File.join(root, "test", "double_test.rb")
      passing_double_test = File.read(double_test)
      canonical = File.join(runtime, NilKill::Runtime::TraceArtifact::EVIDENCE_NAME)
      canonical_before_failure = Digest::SHA256.file(canonical).hexdigest
      File.write(double_test, passing_double_test.sub("assert_equal 8", "raise \"trace failure\""))
      File.write(File.join(root, "test", "test_helper.rb"), "SHARD_HELPER_VERSION = 2\n")
      stdout, stderr, status = collect.call(fast: true, continue_on_error: true)
      expect(status).not_to be_success
      expect("#{stdout}\n#{stderr}").to include("canonical evidence was not replaced")
      expect(manifest.call).to include(
        "complete" => false,
        "potentially_stale" => true
      )
      expect(manifest.call.fetch("stale_reason")).to include("required trace shard")
      expect(Digest::SHA256.file(canonical).hexdigest).to eq(canonical_before_failure)

      File.write(double_test, passing_double_test)
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("3 traced shards")
      expect(manifest.call).to include(
        "complete" => true,
        "potentially_stale" => false
      )

      File.delete(added_test)
      stdout, stderr, status = collect.call(fast: true)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include("0 traced shards")
      expect(manifest.call.fetch("deleted_tests")).to eq(["test/added_test.rb"])
      expect(Dir.glob(File.join(runtime, "shard-evidence", "*.json.gz")).length).to eq(2)
    end
  end
end
