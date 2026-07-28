# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class DiagnoseBigOGapsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  FACT_MINE = File.join(ROOT, "gems/fact-mine/target/debug/fact-mine-rust")
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
end
