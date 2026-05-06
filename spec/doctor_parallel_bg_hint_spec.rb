require 'tmpdir'
require 'fileutils'
require 'open3'

RSpec.describe 'clear doctor — @parallel BG hint' do
  let(:clear_bin) { File.expand_path('../../clear', __FILE__) }

  def run_doctor(dir)
    out, _, status = Open3.capture3(clear_bin, 'doctor', dir)
    expect(status.exitstatus).to eq(0)
    out
  end

  def write_profile(dir, source:, zig:, site_dispatch: 'local')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'fibers.txt'), <<~FIBERS)
      # fiber-profile v1
      total_fibers: 4
      short_fibers_under_1ms: 0
      vshort_fibers_under_10us: 0
      total_lifetime_ns: 4000000
      max_lifetime_ns: 1000000
      # per-scheduler fibers-run
      # sched\tfibers
      0\t0
      1\t0
      2\t0
      3\t4
      # per-site fibers
      # site\tspawns\truns\texits\ttotal_lifetime_ns\tmax_lifetime_ns\tdispatch\tform\tschedulers
      1\t4\t4\t4\t4000000\t1000000\t#{site_dispatch}\tfsm\t3:4
    FIBERS
    File.write(File.join(dir, 'source.cht'), source)
    File.write(File.join(dir, 'transpiled.zig'), zig)
  end

  it 'points local BG worker fanout at @parallel when all work runs on one scheduler' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      write_profile(
        profile_dir,
        source: <<~CHT,
          FN main() RETURNS Void ->
              workers = threadCount();
              WHILE workers > 0 DO
                  BG {
                      doCpuWork();
                  };
              END
          END
        CHT
        zig: <<~ZIG
          pub fn bg0() void {}
          // CLEAR_PROFILE_TASK_SITE id=1 kind=BG line=4 column=9 dispatch=local form=fsm
          try rt.getSched().submitFsmSpawn(__bg0_ctx.task);
        ZIG
      )

      out = run_doctor(profile_dir)
      expect(out).to include('Scheduler imbalance')
      expect(out).to include('Exact imbalanced local BG task sites')
      expect(out).to include('BG { @parallel -> ... }')
      expect(out).to include('line 4')
      expect(out).to include('site=1 form=fsm runs=4')
    end
  end

  it 'does not suggest @parallel when the source already uses it' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      write_profile(
        profile_dir,
        source: <<~CHT,
          FN main() RETURNS Void ->
              BG { @parallel ->
                  doCpuWork();
              };
          END
        CHT
        site_dispatch: 'parallel',
        zig: <<~ZIG
          pub fn bg0() void {}
          // CLEAR_PROFILE_TASK_SITE id=1 kind=BG line=2 column=5 dispatch=parallel form=fsm
          try CheatHeader.spawnFsmBest(__bg0_ctx.task);
        ZIG
      )

      out = run_doctor(profile_dir)
      expect(out).to include('Scheduler imbalance')
      expect(out).not_to include('BG { @parallel -> ... }')
      expect(out).not_to include('Candidate BG sites')
    end
  end
end
