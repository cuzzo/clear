# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

class PprofToHotnessTest < Minitest::Test
  SCRIPT = File.expand_path("../tools/pprof_to_hotness.rb", __dir__)

  def convert(*argv)
    stdout, stderr, status = Open3.capture3("ruby", SCRIPT, *argv)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def test_parses_pprof_top_lines_with_tiers_and_prefix_strip
    Dir.mktmpdir do |dir|
      top = File.join(dir, "top.txt")
      File.write(top, <<~TOP)
        File: server
        Type: cpu
        Showing nodes accounting for 900ms, 90.00% of 1000ms total
              flat  flat%   sum%        cum   cum%
             400ms 40.00% 40.00%      600ms 60.00%  main.(*Server).handle /app/server.go:42
             300ms 30.00% 70.00%      300ms 30.00%  runtime.memmove
               4ms  0.40% 70.40%        6ms  0.60%  main.warmish /app/warm.go:7
               1ms  0.10% 70.50%        2ms  0.20%  main.cold /app/cold.go:3
      TOP

      doc = convert("--pprof-top=#{top}", "--strip-prefix=/app", "--commit=abc123")

      assert_equal "profile-hotness/v1", doc["schema"]
      assert_equal "pprof", doc["source"]
      assert_equal "abc123", doc["commit"]

      by_function = doc["entries"].to_h { |entry| [entry["function"], entry] }
      handle = by_function.fetch("main.(*Server).handle")
      assert_equal "server.go", handle["path"]
      assert_equal 42, handle["line"]
      assert_equal "critical", handle["tier"]
      assert_in_delta 0.6, handle["cum_share"], 1e-9

      assert_equal "warm", by_function.fetch("main.warmish")["tier"]
      assert_equal "cold", by_function.fetch("main.cold")["tier"]
      assert_nil by_function.fetch("runtime.memmove")["path"]

      # Sorted by descending cumulative share.
      assert_equal "main.(*Server).handle", doc["entries"].first["function"]
    end
  end

  def test_parses_stackprof_json
    Dir.mktmpdir do |dir|
      dump = File.join(dir, "stackprof.json")
      File.write(dump, JSON.generate(
        "samples" => 1000,
        "frames" => {
          "1" => { "name" => "Worker#run", "file" => "/repo/lib/worker.rb", "line" => 5,
                   "samples" => 80, "total_samples" => 120 },
          "2" => { "name" => "Helper#tiny", "file" => "/repo/lib/helper.rb", "line" => 9,
                   "samples" => 1, "total_samples" => 1 },
          "3" => { "name" => "Never#ran", "file" => "/repo/lib/never.rb", "line" => 1,
                   "samples" => 0, "total_samples" => 0 }
        }
      ))

      doc = convert("--stackprof=#{dump}", "--strip-prefix=/repo")

      by_function = doc["entries"].to_h { |entry| [entry["function"], entry] }
      run = by_function.fetch("Worker#run")
      assert_equal "lib/worker.rb", run["path"]
      assert_equal "critical", run["tier"]
      assert_in_delta 0.12, run["cum_share"], 1e-9
      assert_equal "cold", by_function.fetch("Helper#tiny")["tier"]
      refute by_function.key?("Never#ran")
    end
  end

  def test_parses_perf_script_stacks_with_srclines
    Dir.mktmpdir do |dir|
      script = File.join(dir, "script.txt")
      File.write(script, <<~SCRIPT)
        bench 111 12.34: 250000 cycles:
        \t7f01 ParkingLot.acquire+0x10 (bench)
          /repo/zig/lib/parking-lot.zig:42
        \t7f02 main (bench)
          :0

        bench 111 12.35: 250000 cycles:
        \t7f02 main (bench)
          :0

      SCRIPT

      doc = convert("--perf-script=#{script}", "--strip-prefix=/repo/")

      assert_equal "perf", doc["source"]
      assert_equal 2, doc["total"]
      by_function = doc["entries"].to_h { |entry| [entry["function"], entry] }

      acquire = by_function.fetch("ParkingLot.acquire")
      assert_equal "zig/lib/parking-lot.zig", acquire["path"]
      assert_equal 42, acquire["line"]
      assert_in_delta 0.5, acquire["cum_share"], 1e-9
      assert_in_delta 0.5, acquire["flat_share"], 1e-9

      main = by_function.fetch("main")
      assert_nil main["path"]
      assert_in_delta 1.0, main["cum_share"], 1e-9
      assert_in_delta 0.5, main["flat_share"], 1e-9
      assert_equal "critical", main["tier"]
    end
  end

  def test_path_prefix_filters_out_harness_frames
    Dir.mktmpdir do |dir|
      dump = File.join(dir, "stackprof.json")
      File.write(dump, JSON.generate(
        "samples" => 100,
        "frames" => {
          "1" => { "name" => "Compiler#run", "file" => "/repo/compiler/ruby/run.rb", "line" => 3,
                   "samples" => 50, "total_samples" => 90 },
          "2" => { "name" => "<main>", "file" => "/repo/tools/harness.rb", "line" => 1,
                   "samples" => 1, "total_samples" => 100 }
        }
      ))

      doc = convert("--stackprof=#{dump}", "--strip-prefix=/repo", "--path-prefix=compiler/")
      assert_equal ["Compiler#run"], doc["entries"].map { |entry| entry["function"] }
    end
  end

  def test_profile_hotness_tool_lists_targets
    script = File.expand_path("../../../tools/profile_hotness.rb", __dir__)
    stdout, stderr, status = Open3.capture3("ruby", script, "--list")
    assert status.success?, stderr
    %w[compiler boobytrap fact-mine zig espalier slopcop].each do |target|
      assert_includes stdout.lines.map(&:strip), target
    end

    _stdout, stderr, status = Open3.capture3("ruby", script, "--target=nonexistent")
    refute status.success?
    assert_includes stderr, "unknown target"
  end

  def test_rejects_unrecognized_input
    Dir.mktmpdir do |dir|
      empty = File.join(dir, "empty.txt")
      File.write(empty, "no rows here\n")
      _stdout, stderr, status = Open3.capture3("ruby", SCRIPT, "--pprof-top=#{empty}")
      refute status.success?
      assert_includes stderr, "no pprof -top rows recognized"
    end
  end
end
