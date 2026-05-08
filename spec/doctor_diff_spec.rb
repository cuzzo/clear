require "rspec"
require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../src/tools/doctor"

# Exercises the new --diff / --cumulative / --focus flags. Profiles
# are synthesized as plain text files in a tmpdir; the binary at
# `<dir>.profile`'s sibling path is left absent so addr2line returns
# `??` and we exercise the fallback-to-raw-addr keying.

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

  describe ".run --diff" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @before = File.join(dir, "before.profile")
        @after  = File.join(dir, "after.profile")
        FileUtils.mkdir_p([@before, @after])
        ex.run
      end
    end

    it "highlights heap regressions with directional arrows" do
      File.write(File.join(@before, "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0x100   100   1000   0   0   100
      ALLOC
      File.write(File.join(@after,  "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0x100   200   2000   0   0   200
      ALLOC

      out = capture_stdout { described_class.run(@after, diff: @before) }
      expect(out).to include("Heap Δ")
      expect(out).to include("↑")           # regression
    end

    it "calls out brand-new allocation sites" do
      File.write(File.join(@before, "alloc.txt"), "# alloc-profile v2\n")
      File.write(File.join(@after,  "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0xabc   50   500   0   0   500
      ALLOC

      out = capture_stdout { described_class.run(@after, diff: @before) }
      expect(out).to include("New allocation sites")
    end

    it "calls out eliminated allocation sites" do
      File.write(File.join(@before, "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0xdead   10   100   0   0   100
      ALLOC
      File.write(File.join(@after, "alloc.txt"), "# alloc-profile v2\n")

      out = capture_stdout { described_class.run(@after, diff: @before) }
      expect(out).to include("Eliminated allocation sites")
    end

    it "respects --focus by skipping non-matching functions" do
      File.write(File.join(@before, "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0x100   100   1000   0   0   100
      ALLOC
      File.write(File.join(@after,  "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0x100   200   2000   0   0   200
      ALLOC

      # focus that matches nothing → no Heap Δ table emitted.
      out = capture_stdout { described_class.run(@after, diff: @before, focus: /no_such_function/) }
      expect(out).not_to include("Heap Δ")
    end

    it "emits a lock Δ table when contention shifts" do
      tab = "\t"
      hdr = "# lock-profile v3\n"
      # Wait_ns from 0 -> 5_000_000 (5ms), contention 0 -> 3
      File.write(File.join(@before, "locks.txt"),
                 hdr + "0x500#{tab}10#{tab}0#{tab}0#{tab}0#{tab}1000#{tab}500#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n")
      File.write(File.join(@after,  "locks.txt"),
                 hdr + "0x500#{tab}10#{tab}3#{tab}5000000#{tab}2000000#{tab}1000#{tab}500#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n")

      out = capture_stdout { described_class.run(@after, diff: @before) }
      expect(out).to include("Lock Δ")
      expect(out).to include("newly contended")
    end

    it "emits an MVCC Δ table when retries appear" do
      tab = "\t"
      hdr = "# mvcc-profile v2\n"
      File.write(File.join(@before, "mvcc.txt"),
                 hdr + "0x600#{tab}64#{tab}1000#{tab}10#{tab}0#{tab}0#{tab}0#{tab}-\n")
      File.write(File.join(@after,  "mvcc.txt"),
                 hdr + "0x600#{tab}64#{tab}1000#{tab}10#{tab}500#{tab}0#{tab}0#{tab}-\n")

      out = capture_stdout { described_class.run(@after, diff: @before) }
      expect(out).to include("MVCC Δ")
      expect(out).to include("new retry storm")
    end

    it "exits 1 when either dir does not exist" do
      old_stderr = $stderr
      $stderr = StringIO.new
      expect {
        described_class.run(@after, diff: "/nonexistent")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    ensure
      $stderr = old_stderr
    end
  end
end
