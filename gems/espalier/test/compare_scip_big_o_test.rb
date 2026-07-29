# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class CompareScipBigOTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  FACT_MINE = File.join(ROOT, "gems/fact-mine/target/debug/fact-mine-rust")
  SCRIPT = File.join(ROOT, "gems/espalier/script/compare_scip_big_o.rb")

  def test_accepts_profiles_with_paths_relative_to_the_declared_source_root
    Dir.mktmpdir("espalier-scip-comparison", ROOT) do |root|
      source = File.join(root, "repository", "lib", "worker.rb")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, <<~RUBY)
        class Worker
          def run
            1
          end
        end
      RUBY

      profile, error, status = Open3.capture3(
        FACT_MINE, "profile", "espalier", "repository/lib/worker.rb", chdir: root
      )
      assert status.success?, error
      assert_equal "repository/lib/worker.rb", JSON.parse(profile).fetch("methods").first.fetch("path")

      profile_path = File.join(root, "profile.json")
      File.write(profile_path, profile)
      output, comparison_error, comparison_status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--source-root", root, "--repository", "repository", profile_path, profile_path
      )

      assert comparison_status.success?, comparison_error
      comparison = JSON.parse(output)
      assert_equal 1, comparison.dig("baseline", "functions")
      assert_equal 1, comparison.dig("scip", "functions")
    end
  end
end
