require "rspec"
require "tmpdir"
require "stringio"
require_relative "../src/tools/doctor"

RSpec.describe Doctor do
  def capture_stdout
    old_stdout = $stdout
    out = StringIO.new
    $stdout = out
    yield
    out.string
  ensure
    $stdout = old_stdout
  end

  it "loads from the tools path" do
    expect(defined?(Doctor)).to eq("constant")
  end

  it "returns the first profile saturation warning without the comment prefix" do
    Dir.mktmpdir do |dir|
      file = File.join(dir, "alloc.txt")
      File.write(file, <<~PROFILE)
        # header
        # WARNING: 12 samples dropped because the table saturated
        # WARNING: ignored second warning
      PROFILE

      expect(Doctor.saturation_warning(file)).to eq("WARNING: 12 samples dropped because the table saturated")
      expect(Doctor.saturation_warning(File.join(dir, "missing.txt"))).to be_nil
    end
  end

  it "prints a usage error and exits for a missing profile directory" do
    old_stderr = $stderr
    stderr = StringIO.new
    $stderr = stderr
    expect {
      Doctor.run(nil)
    }.to raise_error(SystemExit) { |err| expect(err.status).to eq(1) }
    $stderr = old_stderr

    expect(stderr.string).to include("Usage: clear doctor <profile-dir>")
  ensure
    $stderr = old_stderr if old_stderr
  end

  it "prints a clear no-profile message for an empty profile directory" do
    Dir.mktmpdir do |dir|
      out = capture_stdout { Doctor.section_heap(dir, nil) }

      expect(out).to include("No heap profile found")
      expect(out).to include(File.join(dir, "alloc.txt"))
    end
  end

  it "formats sort keys and values for all doctor --by modes" do
    Doctor.instance_variable_set(:@opts, { by: :inuse_allocs })
    expect(Doctor.sort_key).to eq(:inuse_allocs)
    expect(Doctor.sort_label).to eq("in-use allocations (alloc - free)")
    expect(Doctor.fmt_sort_value(inuse_allocs: 12_345)).to eq("12,345 allocs")

    Doctor.instance_variable_set(:@opts, { by: :unknown })
    expect(Doctor.sort_key).to eq(:bytes)
    expect(Doctor.fmt_sort_value(bytes: 512)).to eq("512 B")
  ensure
    Doctor.instance_variable_set(:@opts, nil)
  end

  it "parses heap profile rows, sorts by bytes, and surfaces saturation warnings" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "alloc.txt"), <<~PROFILE)
        # total_allocs 12345
        # WARNING: 2 allocation samples dropped
        0xaaa 10 3200 10 3200 0
        0xbbb 200 4000 0 0 4000
      PROFILE

      sites = nil
      out = capture_stdout do
        sites, = Doctor.section_heap(dir, nil)
      end

      expect(sites.map { |s| s[:addr] }).to eq(["0xbbb", "0xaaa"])
      expect(sites.first).to include(allocs: 200, bytes: 4000, frees: 0, free_bytes: 0, live: 4000)
      expect(out).to include("Allocation Profile (12,345 allocs)")
      expect(out).to include("*** WARNING: 2 allocation samples dropped")
      expect(out).to match(/Top sites by (bytes|in-use bytes \(alloc - free\)):/)
      expect(out).to include("(heap rc) = @multiowned RC allocation tracked by rcCreate")
    end
  end

  it "resolves heap addresses, prints source locations, and supports cumulative ranking" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "app.profile")
      Dir.mkdir(dir)
      binary = File.join(root, "app")
      File.write(binary, "")
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLR:10
        const a = 1;
        const b = 2;
      ZIG
      File.write(File.join(dir, "alloc.txt"), <<~PROFILE)
        # total_allocs 4
        0x1,0x2 3 512 1 128 2
        0x3 1 2048 0 0 1
      PROFILE
      allow(IO).to receive(:popen).and_return(
        "mod.makeNode__anon_1\n/build/._clear_tmp_app.zig:3\n" \
        "runtime.entryWrapper\n/runtime/runtime.zig:44\n" \
        "mod.bigAlloc\n/build/._clear_tmp_app.zig:2\n"
      )

      Doctor.instance_variable_set(:@opts, { cumulative: false, by: :bytes })
      flat = capture_stdout { Doctor.section_heap(dir, binary) }
      expect(flat).to include("makeNode (line 10)")
      expect(flat).to include("entryWrapper (runtime.zig:44)")

      Doctor.instance_variable_set(:@opts, { cumulative: true, by: :bytes })
      cumulative = capture_stdout { Doctor.section_heap(dir, binary) }
      expect(cumulative).to include("Top functions by cumulative bytes")
      expect(cumulative).to include("2.0 KB cum")
      expect(cumulative).to include("512 B  cum")
    end
  ensure
    Doctor.instance_variable_set(:@opts, nil)
  end

  it "prints CPU samples and maps perf srclines back to CLEAR hot lines" do
    Dir.mktmpdir do |dir|
      perf_data = File.join(dir, "perf.data")
      File.write(perf_data, "perf")
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLR:2
        user_pipeline();
      ZIG
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        FN main() RETURNS Void ->
          xs |> map(fn);
        END
      CLEAR
      allow(Doctor).to receive(:`) do |cmd|
        if cmd.include?("--sort=srcline")
          "  12.5%  samples  /build/._clear_tmp_app.zig:2\n" \
            "  30.0%  samples  /zig/std.zig:10\n"
        else
          "  99.0%  hot_symbol\n"
        end
      end

      out = capture_stdout { Doctor.section_cpu(dir, perf_data) }

      expect(out).to include("CPU Profile")
      expect(out).to include("99.0%  hot_symbol")
      expect(out).to include("CLEAR Source Hot Lines")
      expect(out).to include("[pipeline stage]")
    end
  end

  it "prints a CPU no-samples fallback when perf has no top rows" do
    Dir.mktmpdir do |dir|
      perf_data = File.join(dir, "perf.data")
      File.write(perf_data, "perf")
      allow(Doctor).to receive(:`).and_return("")

      out = capture_stdout { Doctor.section_cpu(dir, perf_data) }

      expect(out).to include("no samples collected")
    end
  end

  it "prints exact @parallel recommendations for imbalanced local BG sites" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), "FN main() ->\n  x = BG { 1 };\nEND\n")
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLEAR_PROFILE_TASK_SITE id=7 kind=BG line=2 column=7 dispatch=local form=fsm
      ZIG
      rows = [{
        id: 7,
        runs: 10,
        exits: 5,
        total_lifetime_ns: 15_000,
        scheds: { 0 => 9, 1 => 1 },
        dispatch: "local",
        form: "fsm",
      }]

      out = capture_stdout { Doctor.emit_parallel_bg_hint!(dir, rows) }

      expect(out).to include("Exact imbalanced local BG task sites")
      expect(out).to include("line 2: x = BG { 1 };")
      expect(out).to include("site=7 form=fsm runs=10 sched=0 90% avg=3.0us")
      expect(out).to include("Use `BG { @parallel -> ... }`")
    end
  end

  it "falls back to source scanning when profile metadata has local dispatches" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        FN main() ->
          a = BG { 1 };
          b = BG { @parallel -> 2 };
        END
      CLEAR
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        try rt.getSched().submitSpawn(...);
        try rt.getSched().submitSpawn(...);
        try CheatHeader.spawnBest(...);
      ZIG

      out = capture_stdout { Doctor.emit_parallel_bg_hint!(dir, []) }

      expect(out).to include("Profile contains local BG dispatches")
      expect(out).to include("Candidate BG sites:")
      expect(out).to include("line 2: a = BG { 1 };")
      expect(out).not_to include("line 3: b = BG")
    end
  end

  it "parses task metadata and handles missing source lines" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLEAR_PROFILE_TASK_SITE id=0 kind=BG line=1 column=1 dispatch=local form=fsm
        // CLEAR_PROFILE_TASK_SITE id=12 kind=BG line=4 column=9 dispatch=parallel form=stack
      ZIG

      expect(Doctor.task_site_metadata(dir)[12]).to include(
        kind: "BG",
        line: 4,
        column: 9,
        dispatch: "parallel",
        form: "stack",
      )
      expect(Doctor.source_line(dir, "?")).to eq("")
      expect(Doctor.source_line(dir, 4)).to eq("")
    end
  end

  it "diagnoses channel backpressure shapes from runtime counters" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "channels.txt"), <<~PROFILE)
        # id pushes pops push_blocked pop_blocked max_depth capacity
        1 100 20 35 0 95 100
        2 20 100 0 40 10 100
        3 100 100 10 10 20 100
        4 100 100 25 0 30 100
      PROFILE

      out = capture_stdout { Doctor.section_channels(dir) }

      expect(out).to include("Channel Saturation")
      expect(out).to include("slow consumer")
      expect(out).to include("slow producer")
      expect(out).to include("backpressure")
      expect(out).to include("balanced")
    end
  end

  it "diagnoses short fibers, scheduler imbalance, and exact local BG sites" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        FN main() RETURNS Void ->
          work = BG { 1 };
          other = BG { @parallel -> 2 };
          RETURN;
        END
      CLEAR
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLEAR_PROFILE_TASK_SITE id=4 kind=BG line=2 column=10 dispatch=local form=fsm
      ZIG
      File.write(File.join(dir, "fibers.txt"), <<~PROFILE)
        total_fibers: 100
        short_fibers_under_1ms: 90
        vshort_fibers_under_10us: 75
        total_lifetime_ns: 500000
        max_lifetime_ns: 20000
        # per-scheduler fibers
        0 95
        1 5
        # per-site fibers
        4\t100\t100\t50\t150000\t5000\tlocal\tfsm\t0:95,1:5
      PROFILE

      out = capture_stdout { Doctor.section_fibers(dir) }

      expect(out).to include("Fibers")
      expect(out).to include("finished in under 10us")
      expect(out).to include("Scheduler imbalance")
      expect(out).to include("line 2: work = BG { 1 };")
      expect(out).to include("Use `BG { @parallel -> ... }`")
    end
  end

  it "covers remaining lock diagnosis branches" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "locks.txt"), <<~PROFILE)
        # addr acq cont wait max_wait hold max_hold read_acq read_cont read_wait read_max
        0xptr\t800\t100\t1000\t1000\t800000\t1000\t1200\t100\t1000\t1000\t-
        0xhotlong\t10\t3\t1000\t1000\t20000000\t3000000\t0\t0\t0\t0\t-
        0xcont\t10\t3\t1000\t1000\t10000\t1000\t0\t0\t0\t0\t-
        0xlong\t10\t0\t0\t0\t20000000\t3000000\t0\t0\t0\t0\t-
        0xok\t10\t0\t0\t0\t10000\t1000\t0\t0\t0\t0\t-
      PROFILE

      out = capture_stdout { Doctor.section_locks(dir) }

      expect(out).to include("contended lock")
      expect(out).to include("hot lock + long hold")
      expect(out).to include("contended — consider")
      expect(out).to include("long critical section")
      expect(out).to include("ok")
    end
  end

  it "cross-checks lock contention against atomic, atomic-ptr, and MVCC static advice" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        STRUCT Counter { value: Int64 }
        STRUCT Cfg { host: String, port: Int64 }

        FN main!() RETURNS !Void ->
          c = Counter{ value: 0 } @shared:locked;
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }

          MUTABLE cfg = Cfg{ host: "a", port: 1 } @shared:writeLocked;
          WITH EXCLUSIVE cfg AS view { view = Cfg{ host: "b", port: 2 }; }
          RETURN;
        END
      CLEAR
      File.write(File.join(dir, "locks.txt"), <<~PROFILE)
        # WARNING: 4 lock samples dropped
        0xread\t100\t0\t0\t0\t1000\t1000\t9000\t1000\t5000000\t800000\t-
        0xwrite\t100000\t0\t0\t0\t9000000\t2000000\t0\t0\t0\t0\t-
        0xcont\t2000\t500\t4000000\t1000000\t8000000\t2000000\t0\t0\t0\t0\t-
      PROFILE

      out = capture_stdout { Doctor.section_locks(dir) }

      expect(out).to include("Lock Hold & Contention")
      expect(out).to include("WARNING: 4 lock samples dropped")
      expect(out).to include("read-heavy")
      expect(out).to include("Atomic fit detected")
      expect(out).to include("'c: Counter' @shared:locked")
    end
  end

  it "renders atomic-ptr migration advice for whole-struct publish candidates" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE cfg = Cfg{ host: "a", port: 1 } @shared:writeLocked;
          WITH EXCLUSIVE cfg AS view { view = Cfg{ host: "b", port: 2 }; }
          RETURN;
        END
      CLEAR

      out = capture_stdout { Doctor.emit_atomic_ptr_migration!(dir) }

      expect(out).to include("AtomicPtr fit detected")
      expect(out).to include("'cfg: Cfg' @shared:writeLocked")
      expect(out).to include("WITH SNAPSHOT MUTABLE")
    end
  end

  it "renders atomic-ptr migration advice for @shared:locked candidates" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN main!() RETURNS !Void ->
          cfg = Cfg{ host: "a", port: 1 } @shared:locked;
          WITH EXCLUSIVE cfg AS view { _ = view.host; }
          RETURN;
        END
      CLEAR

      out = capture_stdout { Doctor.emit_atomic_ptr_migration!(dir) }

      expect(out).to include("'cfg: Cfg' @shared:locked")
    end
  end

  it "diagnoses MVCC COW thrash, misuse, retry pressure, and atomic-ptr upgrade candidates" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), <<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE cfg = Cfg{ host: "a", port: 1 } @shared:versioned;
          WITH SNAPSHOT cfg AS MUTABLE view { view = Cfg{ host: "b", port: 2 }; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      File.write(File.join(dir, "mvcc.txt"), <<~PROFILE)
        # WARNING: 7 mvcc samples dropped
        0xcow\t512\t50000\t250000\t0\t0\t1\t-
        0xmisuse\t64\t10\t2000\t0\t0\t1\t-
        0xretry\t64\t5000\t1000\t1500\t0\t1\t-
        0xfail\t64\t5000\t500\t0\t3\t1\t-
        0xsingle\t64\t5000\t2000\t0\t0\t0\t-
        0xok\t64\t1\t0\t0\t0\t1\t-
      PROFILE

      out = capture_stdout { Doctor.section_mvcc(dir) }

      expect(out).to include("MVCC Cells")
      expect(out).to include("WARNING: 7 mvcc samples dropped")
      expect(out).to include("COW thrash")
      expect(out).to include("MVCC misuse detected")
      expect(out).to include("high retry")
      expect(out).to include("UpdateRetriesExhausted")
      expect(out).to include("AtomicPtr upgrade-from-MVCC detected")
      expect(out).to include("'cfg: Cfg' @shared:versioned")
      expect(out).to include("0B")
      expect(out).to include("ok")
    end
  end

  it "renders atomic escape findings surfaced by the doctor" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "source.cht"), "FN main() RETURNS Void -> RETURN; END\n")
      require_relative "../src/tools/atomic_escape_suggester"
      allow(AtomicEscapeSuggester).to receive(:analyze).and_return([
        { line: nil, kind: :return },
        { line: 5, kind: :store },
        { line: 6, kind: :other },
      ])

      out = capture_stdout { Doctor.section_atomic_escape(dir) }

      expect(out).to include("Atomic Escape")
      expect(out).to include("RETURN escapes atomic-tied value")
      expect(out).to include("store/append escapes atomic-tied value")
      expect(out).to include("atomic-tied lifetime escape")
    end
  end

  it "prints syscall summaries, hardware analysis, and FREEZE opportunities from profile files" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "syscalls.txt"), <<~PROFILE)
          70.00 0.010000 10 read
          30.00 0.005000 5 write
        total 0.015000 15
      PROFILE
      File.write(File.join(dir, "perf-stat.txt"), <<~PROFILE)
             1,000      cycles:u
             2,500      instructions:u
             10,000     branches:u
             1,000      branch-misses:u
             4,000      cache-references:u
             1,000      cache-misses:u
             <not supported> LLC-loads:u
      PROFILE
      File.write(File.join(dir, "transpiled.zig"), <<~ZIG)
        // CLR:77
        const p = try rcCreate(T, allocator);
      ZIG
      sites = [{
        addr: "0xnode",
        trace: ["0xnode"],
        allocs: 6_000,
        bytes: 192_000,
        frees: 0,
        free_bytes: 0,
        live: 192_000,
        inuse_allocs: 6_000,
        inuse_bytes: 192_000,
      }]

      syscalls = capture_stdout { Doctor.section_syscalls(dir) }
      llc_rate = nil
      hardware = capture_stdout { llc_rate = Doctor.section_hardware(dir) }
      freeze = capture_stdout { Doctor.section_freeze(dir, sites, { "0xnode" => { func: "entryWrapper" } }, llc_rate) }

      expect(syscalls).to include("Syscalls")
      expect(syscalls).to include("total")
      expect(hardware).to include("IPC: 2.5")
      expect(hardware).to include("LLC miss rate: 25.0%")
      expect(hardware).to include("Branch miss rate: 10.0%")
      expect(freeze).to include("FREEZE Opportunity")
      expect(freeze).to include("line 77")
    end
  end

  it "prints moderate LLC analysis and freeze locations from clear_line, function, and raw address" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "perf-stat.txt"), <<~PROFILE)
             1,000      LLC-loads:u
               150      LLC-load-misses:u
      PROFILE

      hardware = capture_stdout { Doctor.section_hardware(dir) }
      expect(hardware).to include("LLC miss rate: 15.0% (moderate)")

      sites = [
        { addr: "0xline", allocs: 6_000, bytes: 192_000 },
        { addr: "0xfunc", allocs: 6_000, bytes: 192_000 },
        { addr: "0xraw", allocs: 6_000, bytes: 192_000 },
      ]
      resolved = {
        "0xline" => { func: "makeNode", clear_line: 12 },
        "0xfunc" => { func: "buildTree" },
        "0xraw" => { func: "" },
      }
      freeze = capture_stdout { Doctor.section_freeze(dir, sites, resolved, 25.0) }

      expect(freeze).to include("line 12")
      expect(freeze).to include("buildTree")
      expect(freeze).to include("0xraw")
    end
  end
end
