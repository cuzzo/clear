# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require_relative "../lib/boobytrap"

class CoverageGapTest < Digest::Test
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
end
