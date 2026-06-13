# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class CoverageGapTest < Minitest::Test
  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def with_resultset(hash)
    f = Tempfile.new(["rs", ".json"])
    f.write(JSON.dump(hash))
    f.close
    yield f.path
  ensure
    f&.unlink
  end

  # two commands; file X: arm taken in cmd B though zero in cmd A
  # (merge => covered). file Y: one arm never taken => gap 0.5.
  def test_merge_across_entries_and_gap_fraction
    rs = {
      "RSpec-1" => { "coverage" => {
        "/root/src/x.rb" => { "branches" => {
          "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0, "[:else,2,1,5,1,9]" => 3 }
        } },
        "/root/src/y.rb" => { "branches" => {
          "[:if,0,2,0,2,9]" => { "[:then,3,2,0,2,4]" => 1, "[:else,4,2,5,2,9]" => 0 }
        } }
      } },
      "RSpec-2" => { "coverage" => {
        "/root/src/x.rb" => { "branches" => {
          "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 5, "[:else,2,1,5,1,9]" => 0 }
        } }
      } }
    }
    with_resultset(rs) do |p|
      g = Boobytrap::CoverageGap.from_resultset(p, root: "/root")
      # x: both arms taken once merged => gap 0
      assert_equal 0.0, g["src/x.rb"].gap
      assert_equal 2, g["src/x.rb"].total
      # y: else never taken => 1/2
      assert_in_delta 0.5, g["src/y.rb"].gap, 1e-9
      assert_equal 1, g["src/y.rb"].uncovered
    end
  end

  def test_files_without_branches_are_excluded
    rs = { "C" => { "coverage" => {
      "/root/src/z.rb" => { "lines" => [1, 0, nil] }
    } } }
    with_resultset(rs) do |p|
      g = Boobytrap::CoverageGap.from_resultset(p, root: "/root")
      assert_empty g
    end
  end

  def test_paths_outside_root_kept_absolute
    rs = { "C" => { "coverage" => {
      "/elsewhere/a.rb" => { "branches" => {
        "[:if,0,1,0,1,9]" => { "[:then,1,1,0,1,4]" => 0 }
      } }
    } } }
    with_resultset(rs) do |p|
      g = Boobytrap::CoverageGap.from_resultset(p, root: "/root")
      assert g.key?("/elsewhere/a.rb")
      assert_equal 1.0, g["/elsewhere/a.rb"].gap
    end
  end

  def test_kcov_cobertura_uses_tree_sitter_branch_arms
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter kcov test" unless grammar && File.file?(grammar)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/worker.zig"
      File.write(file, <<~ZIG)
        fn run(x: i32) bool {
            if (x > 0) {
                return true;
            } else {
                return false;
            }
        }
      ZIG
      coverage = "#{dir}/cobertura.xml"
      File.write(coverage, <<~XML)
        <?xml version="1.0" ?>
        <coverage>
          <sources><source>#{dir}</source></sources>
          <packages><package name=""><classes>
            <class name="worker" filename="src/worker.zig">
              <lines>
                <line number="2" hits="1"/>
                <line number="3" hits="1"/>
                <line number="5" hits="0"/>
              </lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      with_env("DECOMPLEX_PARSER", "tree_sitter") do
        gap = Boobytrap::CoverageGap.from_resultset(coverage, root: dir).fetch("src/worker.zig")

        assert_operator gap.total, :>=, 2
        assert_operator gap.uncovered, :>=, 1
        assert_operator gap.gap, :>, 0.0
      end
    end
  end
end
