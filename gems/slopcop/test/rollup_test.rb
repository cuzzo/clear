# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "coverage"
require "fileutils"
require_relative "../lib/slopcop"

class RollupTest < Minitest::Test
  def test_rollup_categorizes_and_surfaces_genuine_with_churn_overlay
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      src = <<~RB
        def shape(x, n)
          return 0 if x.is_a?(String)
          case n
          when 1 then 10
          when 2 then 20
          else 30
          end
        end
        shape(7, 1)
      RB
      path = "#{dir}/src/m.rb"
      File.write(path, src)
      # real git repo so fix-cache churn is computable (no fix commit ->
      # churn 0, score 0, but the genuine bucket still lists).
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.email", "t@t")
      system("git", "-C", dir, "config", "user.name", "t")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-qm", "add", out: File::NULL, err: File::NULL)

      Coverage.start(branches: true)
      load path
      res = Coverage.result
      rs = { "T" => { "coverage" => { path => { "branches" => res.dig(path, :branches) } } } }
      rsf = "#{dir}/.resultset.json"
      File.write(rsf, JSON.dump(rs))

      out = SlopCop::Rollup.run(files: ["src/m.rb"], repo: dir, resultset: rsf)
      assert out[:per_file].key?("src/m.rb")
      fh = out[:per_file]["src/m.rb"]
      assert fh[:total].positive?, "should find dark arms"
      assert(fh[:counts][:type_norm].positive?, "the never-String is_a? guard")
      assert_equal fh[:total], fh[:counts].values.sum, "every arm categorized"
      assert_equal out[:grand], out[:totals].values.sum
    end
  end

  def test_missing_file_is_skipped_not_crashed
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      File.write("#{dir}/rs.json", JSON.dump({ "T" => { "coverage" => {} } }))
      out = SlopCop::Rollup.run(files: ["nope.rb"], repo: dir,
                                  resultset: "#{dir}/rs.json")
      assert_empty out[:per_file]
      assert_empty out[:top_gaps]
    end
  end
end
