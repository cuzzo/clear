# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require_relative "../lib/espalier/static_evidence"
require "rbconfig"
require "tmpdir"

class CheckBigOCoverageTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  # Whichever profile is built, the way every other caller resolves it. CI
  # builds --release, so naming the debug path made these tests error rather
  # than run.
  FACT_MINE = Espalier::StaticEvidence::FACT_MINE_RUST_BINARY
  SCRIPT = File.join(ROOT, "gems/espalier/script/check_big_o_coverage.rb")

  def test_accepts_profile_paths_relative_to_source_root
    Dir.mktmpdir("espalier-big-o-coverage", ROOT) do |root|
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
      output, coverage_error, coverage_status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "--source-root", root, "--repository", "repository", "--minimum", "0", profile_path
      )

      assert coverage_status.success?, coverage_error
      assert_equal 1, JSON.parse(output).dig("coverage", "functions")
    end
  end
end
