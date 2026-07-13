require 'tmpdir'
require 'fileutils'
require 'open3'

# Spec for `clear doctor`'s saturation-warning surface.
#
# The runtime profile modules (alloc-profile, lock-profile,
# mvcc-profile) emit a `# WARNING: N samples dropped (cap=...)`
# line when their fixed-size open-addressed table fills up. The
# doctor should surface that warning at the top of the relevant
# section so the user knows to rebuild with `--profile-max=N`
# rather than silently looking at incomplete data.

RSpec.describe 'clear doctor — profile-table saturation warning' do
  let(:clear_bin) { File.expand_path('../../clear', __dir__) }

  def run_doctor(dir)
    out, _, status = Open3.capture3(clear_bin, 'doctor', dir)
    expect(status.exitstatus).to eq(0)
    out
  end

  describe 'mvcc.txt warning' do
    it 'surfaces the dropped-samples warning at the top of the MVCC section' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        FileUtils.mkdir_p(profile_dir)
        File.write(File.join(profile_dir, 'mvcc.txt'), <<~MVCC)
          # mvcc-profile v1
          # WARNING: 47 samples dropped (cap=1024; rebuild with `clear profile --profile-max=N`)
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xabc\t8\t10000\t1000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).to include('MVCC Cells')
        expect(out).to include('47 samples dropped')
        expect(out).to include('--profile-max=N')
      end
    end

    it 'does not emit the warning when the file has none' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        FileUtils.mkdir_p(profile_dir)
        File.write(File.join(profile_dir, 'mvcc.txt'), <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xabc\t8\t10000\t1000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).not_to include('samples dropped')
      end
    end
  end

  describe 'locks.txt warning' do
    it 'surfaces the warning at the top of the Lock section' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        FileUtils.mkdir_p(profile_dir)
        File.write(File.join(profile_dir, 'locks.txt'), <<~LOCKS)
          # lock-profile v2
          # WARNING: 12 samples dropped (cap=1024; rebuild with `clear profile --profile-max=N`)
          # addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns
          0xdef\t1000\t10\t100\t10\t1000\t100\t0\t0\t0\t0
        LOCKS
        out = run_doctor(profile_dir)
        expect(out).to include('Lock Hold')
        expect(out).to include('12 samples dropped')
      end
    end
  end

  describe 'alloc.txt warning' do
    it 'surfaces the warning at the top of the Allocation Profile section' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        FileUtils.mkdir_p(profile_dir)
        File.write(File.join(profile_dir, 'alloc.txt'), <<~ALLOC)
          # alloc-profile v1
          # total_allocs: 5000
          # WARNING: 3 samples dropped (cap=1024; rebuild with `clear profile --profile-max=N`)
          # addr alloc_count alloc_bytes free_count free_bytes live_bytes
          0xaaa 100 10000 100 10000 0
        ALLOC
        out = run_doctor(profile_dir)
        expect(out).to include('Allocation Profile')
        expect(out).to include('3 samples dropped')
      end
    end
  end
end
