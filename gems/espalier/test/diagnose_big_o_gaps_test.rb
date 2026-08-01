# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require_relative "../lib/espalier/static_evidence"
require "tmpdir"

class DiagnoseBigOGapsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  # Whichever profile is built, the way every other caller resolves it. CI
  # builds --release, so naming the debug path made these tests error rather
  # than run.
  FACT_MINE = Espalier::StaticEvidence::FACT_MINE_RUST_BINARY
  SCRIPT = File.join(ROOT, "gems/espalier/script/diagnose_big_o_gaps.rb")

  def test_accepts_fact_mine_profiles_with_paths_relative_to_source_root
    Dir.mktmpdir("espalier-gap-diagnostics", ROOT) do |root|
      source_root = File.join(root, "repository")
      FileUtils.mkdir_p(File.join(source_root, "lib"))
      File.write(File.join(source_root, "lib", "worker.rb"), <<~RUBY)
        class Worker
          def run
            1
          end
        end
      RUBY

      profile, profile_error, profile_status = Open3.capture3(
        FACT_MINE, "profile", "espalier", "repository/lib/worker.rb", chdir: root
      )
      assert profile_status.success?, profile_error
      assert_equal "repository/lib/worker.rb", JSON.parse(profile).fetch("methods").first.fetch("path")

      Dir.chdir(root) do
        profile_path = File.join(root, "profile.json")
        File.write(profile_path, profile)
        output, error, status = Open3.capture3(
          RbConfig.ruby, SCRIPT, "--source-root", root, "--repository", "repository", profile_path
        )

        assert status.success?, error
        report = JSON.parse(output)
        assert_equal 1, report.dig("summary", "functions")
      end
    end
  end

  def test_distinguishes_unobserved_runtime_calls_from_failed_semantic_identity_joins
    Dir.mktmpdir("espalier-gap-runtime-observation", ROOT) do |root|
      source_root = File.join(root, "repository")
      FileUtils.mkdir_p(File.join(source_root, "lib"))
      File.write(File.join(source_root, "lib", "worker.rb"), <<~RUBY)
        class Worker
          def run(value)
            value.unmodeled
          end
        end
      RUBY

      profile_json, profile_error, profile_status = Open3.capture3(
        FACT_MINE, "profile", "espalier", "repository/lib/worker.rb", chdir: root
      )
      assert profile_status.success?, profile_error
      profile = JSON.parse(profile_json)
      assert_equal 1, profile.fetch("calls").length

      profile_path = File.join(root, "profile.json")
      File.write(profile_path, JSON.generate(profile))
      unobserved_output, unobserved_error, unobserved_status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--source-root", root, "--repository", "repository", profile_path
      )
      assert unobserved_status.success?, unobserved_error
      unobserved = JSON.parse(unobserved_output)
      assert_equal 1, unobserved.dig("call_resolution", "runtime_callsite_unobserved", "calls")
      assert_nil unobserved.dig("call_resolution", "semantic_identity_missing")
      assert_includes(
        unobserved.dig("root_cause_categories", "runtime_callsite_unobserved", "call_examples"),
        {
          "path" => "repository/lib/worker.rb",
          "line" => 3,
          "receiver" => "value",
          "message" => "unmodeled",
          "semantic_symbol" => nil,
          "unresolved_reason" => "receiver_requires_corpus_resolution"
        }
      )

      profile.fetch("calls").first["runtime_evidence_observed"] = true
      File.write(profile_path, JSON.generate(profile))
      observed_output, observed_error, observed_status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--source-root", root, "--repository", "repository", profile_path
      )
      assert observed_status.success?, observed_error
      observed = JSON.parse(observed_output)
      assert_equal 1, observed.dig("call_resolution", "semantic_identity_missing", "calls")
      assert_nil observed.dig("call_resolution", "runtime_callsite_unobserved")
    end
  end
end
