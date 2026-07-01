require 'tmpdir'
require 'fileutils'
require 'open3'

# Spec for `clear doctor`'s read-heavy → @shared:versioned heuristic.
#
# Strategy: synthesize a minimal profile dir with a hand-written
# `locks.txt` in v2 format, run `clear doctor`, assert the diagnosis.
# Avoids the cost (and flakiness) of building a real CHT program and
# running it under perf to produce real telemetry.

RSpec.describe 'clear doctor — MVCC heuristic' do
  let(:clear_bin) { File.expand_path('../../clear', __dir__) }

  def write_locks(dir, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'locks.txt'), content)
  end

  def run_doctor(dir)
    out, _, status = Open3.capture3(clear_bin, 'doctor', dir)
    expect(status.exitstatus).to eq(0)
    out
  end

  it 'recommends @shared:versioned for read-heavy contended workloads' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      # Format: addr  acquires  contended  total_wait  max_wait  total_hold  max_hold
      #         read_acquires  read_contended  read_total_wait  read_max_wait
      # 5K writes (1K contended) + 200K reads (40K contended) = 95% reads, 20% cont.
      write_locks(profile_dir, <<~LOCKS)
        # lock-profile v2
        # addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns
        0xdeadbeef\t5000\t1000\t0\t0\t0\t0\t200000\t40000\t0\t0
      LOCKS
      out = run_doctor(profile_dir)
      expect(out).to include('read-heavy')
      expect(out).to include('try @shared:versioned')
      expect(out).to include('MVCC fit detected')
    end
  end

  it 'does not recommend MVCC for write-heavy workloads' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      # 50% reads, 50% writes — not read-heavy, no MVCC recommendation.
      write_locks(profile_dir, <<~LOCKS)
        # lock-profile v2
        # addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns
        0xcafe\t10000\t2000\t0\t0\t0\t0\t10000\t1000\t0\t0
      LOCKS
      out = run_doctor(profile_dir)
      expect(out).not_to include('try @shared:versioned')
      expect(out).not_to include('MVCC fit detected')
    end
  end

  it 'does not recommend MVCC for read-heavy but uncontended workloads' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      # 99% reads but 0% contention → no benefit from MVCC, no recommendation.
      write_locks(profile_dir, <<~LOCKS)
        # lock-profile v2
        # addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns
        0xfeed\t100\t0\t0\t0\t0\t0\t100000\t0\t0\t0
      LOCKS
      out = run_doctor(profile_dir)
      expect(out).not_to include('try @shared:versioned')
      expect(out).not_to include('MVCC fit detected')
    end
  end

end
