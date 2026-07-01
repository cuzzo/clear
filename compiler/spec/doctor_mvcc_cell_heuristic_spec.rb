require 'tmpdir'
require 'fileutils'
require 'open3'

# Spec for `clear doctor`'s MVCC cell heuristics:
#   - COW thrash      → recommend @indirect on large fields
#   - MVCC misuse     → recommend back to @shared:writeLocked / @shared:locked
#
# Same synthesis strategy as doctor_mvcc_heuristic_spec.rb: hand-write a
# minimal profile dir, run `clear doctor`, assert the diagnosis.

RSpec.describe 'clear doctor — MVCC cell heuristics' do
  let(:clear_bin) { File.expand_path('../../clear', __dir__) }

  def write_profile(dir, mvcc_content, locks_content = nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'mvcc.txt'), mvcc_content)
    File.write(File.join(dir, 'locks.txt'), locks_content) if locks_content
  end

  def run_doctor(dir)
    out, _, status = Open3.capture3(clear_bin, 'doctor', dir)
    expect(status.exitstatus).to eq(0)
    out
  end

  describe 'COW thrash detector' do
    it 'recommends @indirect when large struct + many commits + > 100MB COW' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 320-byte struct, 400K commits, ~128MB COW.
        # Format: addr  struct_size  reads  commits  retries  update_failures
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xbig\t320\t1000000\t400000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).to include('COW thrash')
        expect(out).to include('@indirect')
        expect(out).to include('COW thrash detected')
      end
    end

    it 'does not fire on a small struct even with many commits' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 8-byte struct, 1M commits — tiny COW total. Not a candidate for
        # @indirect; the struct is already pointer-sized.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xsmall\t8\t10000000\t1000000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).not_to include('COW thrash')
        expect(out).not_to include('COW thrash detected')
      end
    end

    it 'does not fire under the 100MB total threshold even with large struct' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 256-byte struct but only 10K commits → 2.6MB total. Below threshold.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xmid\t256\t100000\t10000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).not_to include('COW thrash detected')
      end
    end
  end

  describe 'MVCC misuse detector (write-heavy)' do
    it 'recommends @shared:writeLocked / @shared:locked when commits >= reads' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 100 reads, 5K commits — write-heavy MVCC, paying overhead with no
        # benefit from the lock-free read path.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xwrite\t8\t100\t5000\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).to include('write-heavy')
        expect(out).to include('@shared:writeLocked')
        expect(out).to include('MVCC misuse detected')
      end
    end

    it 'does not fire when reads >= commits (the intended usage)' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # Read-heavy: 50K reads, 100 commits. MVCC is the right fit.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xread\t8\t50000\t100\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).not_to include('MVCC misuse detected')
      end
    end

    it 'does not fire below the 1000-commit floor' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 10 reads, 50 commits — write-skewed but tiny absolute volume.
        # Heuristic shouldn't fire on noise.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xtiny\t8\t10\t50\t0\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).not_to include('MVCC misuse detected')
      end
    end
  end

  describe 'high-retry detector' do
    it 'flags cells with avg retry/commit >= 1' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # 1000 commits, 5000 retries → avg 5 retries/commit. Reads >> commits
        # so misuse detector won't preempt; this is a "right shape, but
        # writers contending" diagnostic.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xcontended\t8\t50000\t100\t500\t0
        MVCC
        out = run_doctor(profile_dir)
        expect(out).to include('high retry')
      end
    end
  end

  describe 'update_failures tracking' do
    it 'reports cells that exhausted the retry budget' do
      Dir.mktmpdir do |dir|
        profile_dir = File.join(dir, 'p.profile')
        # Successfully committed 100, gave up on 5.
        write_profile(profile_dir, <<~MVCC)
          # mvcc-profile v1
          # addr\tstruct_size\treads\tcommits\tretries\tupdate_failures
          0xfail\t8\t1000\t100\t0\t5
        MVCC
        out = run_doctor(profile_dir)
        expect(out).to include('exhausted retries')
      end
    end
  end

  it 'omits the MVCC section entirely when mvcc.txt is absent' do
    Dir.mktmpdir do |dir|
      profile_dir = File.join(dir, 'p.profile')
      FileUtils.mkdir_p(profile_dir)
      out = run_doctor(profile_dir)
      expect(out).not_to include('MVCC Cells')
    end
  end
end
