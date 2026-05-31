# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/boobytrap"

class MethodGapTest < Minitest::Test
  def test_ranks_mostly_dark_stateful_methods
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/src")
      file = "#{dir}/src/compiler.rb"
      File.write(file, <<~RUBY)
        class Compiler
          def dark_stateful(x)
            @state = x
            if x
              @count += 1
            else
              @items << x
            end
            @state
          end

          def covered
            1
            2
            3
            4
            5
          end
        end
      RUBY
      lines = Array.new(18)
      [2, 3, 11, 12, 13, 14, 15, 16, 17].each { |i| lines[i - 1] = 1 }
      [4, 5, 6, 7, 8, 9].each { |i| lines[i - 1] = 0 }
      rs = {
        "RSpec" => { "coverage" => {
          file => {
            "lines" => lines,
            "branches" => {
              "[:if,0,4,0,8,3]" => {
                "[:then,1,5,0,6,10]" => 0,
                "[:else,2,7,0,8,10]" => 0
              }
            }
          }
        } }
      }
      path = "#{dir}/.resultset.json"
      File.write(path, JSON.dump(rs))

      score = Boobytrap::DecomplexRisk::Score.new(
        score: 7,
        findings: 3,
        detectors: ["False Simplicity", "Neglected Updates"]
      )
      rows = Boobytrap::MethodGap.from_resultset(
        path,
        root: dir,
        decomplex_scores: { ["src/compiler.rb", "dark_stateful"] => score }
      )
      dark = rows.find { |r| r.name == "dark_stateful" }

      assert_equal "src/compiler.rb", dark.file
      assert_equal 7, dark.executable_lines
      assert_equal 2, dark.covered_lines
      assert_equal 5, dark.missed_lines
      assert_equal 3, dark.state_writes
      assert_equal 2, dark.uncovered_branches
      assert_equal 7, dark.decomplex_score
      assert_equal 3, dark.decomplex_findings
      assert_equal ["False Simplicity", "Neglected Updates"], dark.decomplex_detectors
      assert_operator dark.risk, :>, 0
      refute_includes dark.members, :complexity
      refute rows.any? { |r| r.name == "covered" }
    end
  end
end
