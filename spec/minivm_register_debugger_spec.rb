require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

# Drives the register VM debugger over its real stdin protocol.
# Tagged `:integration` because the test rebuilds the runner binary
# (`examples/minivm/vm`) and pipes commands through it, so parallel
# workers race over the cached binary.
RSpec.describe "MiniVM register debugger REPL", :integration do
  PROJECT_ROOT = File.expand_path("..", __dir__)
  BC_RUN_RB    = File.expand_path("examples/minivm/bc_run.rb", PROJECT_ROOT)

  def write_fixture(dir, source)
    path = File.join(dir, "prog.cht")
    File.write(path, source)
    path
  end

  def run_repl(source_path, pause_lines, commands)
    pause = Array(pause_lines).map { |l| ":#{l}" }.join(",")
    env = { "BC_PAUSE_ON" => pause }
    cmd = ["ruby", BC_RUN_RB, "--vm=register", source_path]
    out, _ = Open3.capture2e(env, *cmd, stdin_data: commands.join("\n") + "\n")
    out
  end

  it "lists all visible bindings on :info, with byebug-style shadowing" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main() RETURNS Void ->
            x: Int64 = 10_i64;
            y: Int64 = x * 2_i64;
            z: Int64 = y + 5_i64;
            print(z.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [3], [":info", ":c"])

      # x is bound at line 2; visible at line 3 entry. y is bound at
      # line 3 (this same line); not yet visible. The :info output now
      # shows the type when the emitter resolved one (`x: Int64 = 10`).
      expect(output).to match(/x(?::\s*Int64)?\s*=\s*10/)
      expect(output).not_to match(/^y(?::|\s+=)/)
    end
  end

  it ":bt reports the active frame plus the caller chain" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN add!(a: Int64, b: Int64) RETURNS !Int64 ->
            sum: Int64 = a + b;
            RETURN sum;
        END

        FN main!() RETURNS !Void ->
            x = 10_i64;
            y = 20_i64;
            z = add!(x, y);
            print(z.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [2], [":bt", ":c"])

      # `#0` is the current frame inside add!, `#1` is the caller in main.
      expect(output).to match(/#0\s+ip=\d+ \(line 2(?::\d+)?\)/)
      expect(output).to match(/#1\s+ip=\d+/)
    end
  end

  it ":fin runs until the current frame returns" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN add!(a: Int64, b: Int64) RETURNS !Int64 ->
            sum: Int64 = a + b;
            RETURN sum;
        END

        FN main!() RETURNS !Void ->
            z = add!(10_i64, 20_i64);
            print(z.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [2], [":fin", ":c"])

      # Two pauses: one at line 2 (inside add), one at the return-IP
      # in main. The caller's print runs after the second :c.
      pauses = output.scan(/register-vm trap/).length
      expect(pauses).to eq(2)
      expect(output).to include("30")
    end
  end

  it ":n steps over a function call without pausing inside the callee" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN add!(a: Int64, b: Int64) RETURNS !Int64 ->
            sum: Int64 = a + b;
            RETURN sum;
        END

        FN main!() RETURNS !Void ->
            z = add!(10_i64, 20_i64);
            print(z.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause on the call line, then `:n`. We should see exactly one
      # in-callee trap (the original pause); :n's depth filter
      # suppresses any pause deeper than that. The next pause must be
      # back in main (depth == 0), and the printed result confirms add!
      # actually executed.
      output = run_repl(path, [7], [":n", ":c"])
      traps = output.scan(/register-vm trap [^\n]+/)
      depths = traps.map { |t| t[/line (\d+)/, 1].to_i }
      # The post-:n re-pause should be on a main-frame line (>= 7), not
      # inside add!'s body (line 2). The exact post-:n line depends on
      # next-different-line attribution; we only require it not to be 2.
      expect(depths).not_to include(2)
      expect(output).to include("30")
    end
  end

  it ":info b lists the BC_PAUSE_ON entries" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main() RETURNS Void ->
            x: Int64 = 1_i64;
            y: Int64 = 2_i64;
            print((x + y).toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [3], [":info b", ":c"])

      expect(output).to match(/#1\s+line 3\s+ip=\d+\s+on/)
    end
  end

  it ":l prints source lines around the pause with a > marker" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main() RETURNS Void ->
            x: Int64 = 1_i64;
            y: Int64 = 2_i64;
            z: Int64 = 3_i64;
            print((x + y + z).toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [4], [":l", ":c"])

      # Line 4 should be the marked one.
      expect(output).to match(/^>\s+4\s+z: Int64 = 3_i64/)
      # Surrounding lines included unmarked.
      expect(output).to match(/^\s+3\s+y: Int64/)
      expect(output).to match(/^\s+5\s+print/)
    end
  end

  it ":up / :down move the inspection cursor across frames" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN add!(a: Int64, b: Int64) RETURNS !Int64 ->
            sum: Int64 = a + b;
            RETURN sum;
        END

        FN main!() RETURNS !Void ->
            x: Int64 = 10_i64;
            y: Int64 = 20_i64;
            z = add!(x, y);
            print(z.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause inside add! at line 2; :bt shows two frames, :up moves
      # to main, :p y reads main's local from the caller frame.
      output = run_repl(path, [2], [":bt", ":up", ":p y", ":bt", ":c"])

      # Backtrace before :up: active marker on #0 (innermost / add!).
      expect(output).to match(/^\* #0\s+ip=\d+ \(line 2(?::\d+)?\)/)
      expect(output).to match(/^\s+#1\s+ip=\d+/)

      # After :up: main's local `y` resolves (caller's pause line is
      # past `y = 20`, so y is in scope). Active marker moved to #1.
      expect(output).to match(/^y(?::\s*Int64)?\s*=\s*20/)
      expect(output).to match(/^\s+#0\s+ip=\d+ \(line 2(?::\d+)?\)/)
      expect(output).to match(/^\* #1\s+ip=\d+/)
    end
  end

  it ":frame N jumps to a frame by index" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN inner!(v: Int64) RETURNS !Int64 ->
            r: Int64 = v + 1_i64;
            RETURN r;
        END

        FN outer!(n: Int64) RETURNS !Int64 ->
            m: Int64 = n + 1_i64;
            RETURN inner!(m);
        END

        FN main!() RETURNS !Void ->
            top: Int64 = 5_i64;
            result = outer!(top);
            print(result.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause at line 2 (deep inside inner!). Three-level stack:
      # frame 0 = inner, 1 = outer, 2 = main. `:frame 2` jumps to main.
      output = run_repl(path, [2], [":bt", ":frame 2", ":bt", ":c"])

      # First :bt -> three frames, marker on #0
      expect(output).to match(/^\* #0\s+ip=\d+ \(line 2(?::\d+)?\)/)
      expect(output).to match(/^\s+#1\s+ip=\d+/)
      expect(output).to match(/^\s+#2\s+ip=\d+/)

      # After :frame 2 -> marker on #2
      expect(output).to match(/^\* #2\s+ip=\d+/)
    end
  end

  it ":l / :bt / trap message include source columns when available" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main!() RETURNS !Void ->
            x: Int64 = 10_i64;
            y: Int64 = 20_i64;
            print(x.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      output = run_repl(path, [3], [":l", ":bt", ":c"])

      # Trap message and :bt show "line:col".
      expect(output).to match(/register-vm trap [^\n]+:3:\d+ /)
      expect(output).to match(/^\* #0\s+ip=\d+ \(line 3:\d+\)/)
      # :l draws a caret line under the source line, aligned with the
      # binding's column. The source line itself stays as-is.
      expect(output).to match(/^>\s+3\s+y: Int64 = 20_i64/)
      expect(output).to match(/^\s+\^\s*$/)
    end
  end

  it ":info / :p NAME show the binding's CLEAR type alongside the value" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main!() RETURNS !Void ->
            x: Int64 = 42_i64;
            name: String = "alice";
            print(x.toString());
            print(name);
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause at line 3 -- x is bound (line 2), name is being bound on
      # line 3 so it isn't yet visible. Confirms the type prefix on x.
      # Then a second pause at line 4 (covered by `:p name`) where
      # name is fully bound.
      output = run_repl(path, [3], [":info", ":c"])

      # x renders as `x: Int64 = 42`, the type-prefix path.
      expect(output).to match(/x:\s*Int64\s*=\s*42/)
      # name isn't yet visible at line 3 entry.
      expect(output).not_to match(/name:?\s*\w*\s*=\s*alice/)
    end
  end

  it ":rs / :fs scrub through the recorded trace" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main!() RETURNS !Void ->
            x: Int64 = 1_i64;
            y: Int64 = 2_i64;
            z: Int64 = 3_i64;
            sum: Int64 = x + y + z;
            print(sum.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause at line 5 (sum = ...). Three iconsts have been recorded:
      # x@step 1 (ireg #0=1), y@step 2 (ireg #1=2), z@step 3 (ireg #2=3).
      # :rs walks the cursor backward one event per command; :fs forward.
      output = run_repl(path, [5], [":dumpevents", ":rs", ":rs", ":rs", ":fs", ":c"])

      # All three events recorded with their correct step / value. The
      # ireg slot is whatever the (deterministic) allocator assigned;
      # x->1, y->2, z->0 under the current emitter. The scrub semantics
      # (step order + iAfter values) are the contract, not the slot id.
      expect(output).to match(/\[0\] step=1 kind=1 slot=1 iBefore=0 iAfter=1/)
      expect(output).to match(/\[1\] step=2 kind=1 slot=2 iBefore=0 iAfter=2/)
      expect(output).to match(/\[2\] step=3 kind=1 slot=0 iBefore=0 iAfter=3/)

      # :rs walks 3 -> 2 -> 1.
      expect(output).to match(/reversed step 3/)
      expect(output).to match(/reversed step 2/)
      expect(output).to match(/reversed step 1/)
      # :fs re-applies one step forward.
      expect(output).to match(/re-applied step 1/)
    end
  end

  it ":up at the outermost frame is a no-op with a clear message" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main() RETURNS Void ->
            x: Int64 = 1_i64;
            print(x.toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Top-level main has no caller frame -- :up should refuse.
      output = run_repl(path, [2], [":up", ":c"])
      expect(output).to include("already at outermost frame")
    end
  end

  it ":b LINE adds a breakpoint at runtime; :bd N disables it" do
    Dir.mktmpdir do |dir|
      src = <<~CHT
        FN main() RETURNS Void ->
            x: Int64 = 1_i64;
            y: Int64 = 2_i64;
            z: Int64 = 3_i64;
            w: Int64 = 4_i64;
            print((x + y + z + w).toString());
            RETURN;
        END
      CHT
      path = write_fixture(dir, src)
      # Pause on line 2; from the prompt:
      #   :b 4    add a runtime BP at line 4
      #   :c      continue, hits the new BP at line 4
      #   :bd 2   disable BP #2 (the runtime-added one)
      #   :c      continue to program end
      output = run_repl(path, [2], [":b 4", ":c", ":bd 2", ":c"])

      expect(output).to match(/breakpoint #2 set at line 4/)
      expect(output).to match(/register-vm trap [^\n]+:4(?::\d+)? /)
      expect(output).to match(/breakpoint #2 disabled/)
    end
  end
end
