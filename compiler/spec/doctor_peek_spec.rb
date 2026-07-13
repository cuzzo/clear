require "rspec"
require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../ruby/tools/doctor" unless defined?(Doctor)

# Exercises --peek (callers + callees of a function) and --ignore
# (inverse of --focus). Profiles are synthesized; addr2line resolution
# is unavailable in tests (no real binary), so we use raw hex addrs
# as the function-name fallback baked into parse_alloc_for_diff and
# the heap reader. The peek tests then match against those addrs.

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

  describe ".run --ignore" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @profile_dir = File.join(dir, "p.profile")
        FileUtils.mkdir_p(@profile_dir)
        File.write(File.join(@profile_dir, "alloc.txt"), <<~ALLOC)
          # alloc-profile v2
          0xaaa   100   1000   0   0   100
          0xbbb,0xaaa   50   500    0   0   100
        ALLOC
        ex.run
      end
    end

    it "drops sites whose trace touches the ignore regex" do
      out = capture_stdout { described_class.run(@profile_dir, ignore: /aaa/) }
      expect(out).to include("Ignore:")
      expect(out).not_to match(/^\s*1\. 0xaaa/)
    end

    it "keeps sites that do not match the ignore regex" do
      out = capture_stdout { described_class.run(@profile_dir, ignore: /no_match/) }
      expect(out).to include("0xaaa")
    end

    it "shows both Focus and Ignore lines when both flags are set" do
      out = capture_stdout { described_class.run(@profile_dir, focus: /a/, ignore: /no/) }
      expect(out).to include("Focus:")
      expect(out).to include("Ignore:")
    end
  end

  describe ".run --peek" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @profile_dir = File.join(dir, "p.profile")
        FileUtils.mkdir_p(@profile_dir)
        # Three samples sharing a common ancestor 0xparent. The peek
        # target 0xfoo appears as a leaf in two and mid-stack in one.
        File.write(File.join(@profile_dir, "alloc.txt"), <<~ALLOC)
          # alloc-profile v2
          0xfoo,0xparent              5  500  0  0  500
          0xfoo,0xparent              3  300  0  0  300
          0xleaf,0xfoo,0xparent       2  200  0  0  200
        ALLOC
        ex.run
      end
    end

    it "aggregates self-bytes across all samples touching the function" do
      out = capture_stdout { described_class.run(@profile_dir, peek: /0xfoo/) }
      expect(out).to include("Peek")
      expect(out).to match(/Self bytes:\s+1000 B \(across 10 alloc/)
    end

    it "surfaces the caller (frame above) of the matched function" do
      out = capture_stdout { described_class.run(@profile_dir, peek: /0xfoo/) }
      expect(out).to include("Callers (frames above")
      expect(out).to match(/0xparent\s+1000 B/)
    end

    it "surfaces callees only when the function appears non-leaf" do
      out = capture_stdout { described_class.run(@profile_dir, peek: /0xfoo/) }
      expect(out).to include("Callees (frames below")
      expect(out).to match(/0xleaf\s+200 B/)
    end

    it "attributes leaf-only samples to <root> when there is no caller frame" do
      File.write(File.join(@profile_dir, "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0xsolo   4  400  0  0  400
      ALLOC

      out = capture_stdout { described_class.run(@profile_dir, peek: /0xsolo/) }
      expect(out).to match(/<root>\s+400 B/)
    end

    it "tells the user when no samples matched" do
      out = capture_stdout { described_class.run(@profile_dir, peek: /no_match/) }
      expect(out).to include("No samples matched")
    end

    it "exits 1 when run on a missing directory" do
      old_stderr = $stderr
      $stderr = StringIO.new
      expect {
        described_class.run("/nonexistent", peek: /foo/)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    ensure
      $stderr = old_stderr
    end

    it "exits 1 when run_peek is called directly on a missing directory" do
      old_stderr = $stderr
      $stderr = StringIO.new
      expect {
        described_class.send(:run_peek, "/nonexistent", /foo/)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    ensure
      $stderr = old_stderr
    end
  end

  describe ".run --by sample-type pivoting" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @profile_dir = File.join(dir, "p.profile")
        FileUtils.mkdir_p(@profile_dir)
        # Two sites: 0xbig has few large allocs, 0xsmall has many tiny.
        # Sorted by bytes, 0xbig wins; sorted by allocs, 0xsmall wins.
        File.write(File.join(@profile_dir, "alloc.txt"), <<~ALLOC)
          # alloc-profile v2
          0xbig     2  10000  0  0  10000
          0xsmall   200  200  0  0  200
        ALLOC
        ex.run
      end
    end

    it "default sort is by bytes (largest sites first)" do
      out = capture_stdout { described_class.run(@profile_dir) }
      first_idx = out.index("0xbig")
      second_idx = out.index("0xsmall")
      expect(first_idx).to be < second_idx
    end

    it "--by=allocs sorts by allocation count" do
      out = capture_stdout { described_class.run(@profile_dir, by: :allocs) }
      expect(out).to include("Top sites by allocations:")
      first_idx = out.index("0xsmall")
      second_idx = out.index("0xbig")
      expect(first_idx).to be < second_idx
    end

    it "--by=inuse_bytes computes alloc_bytes - free_bytes" do
      File.write(File.join(@profile_dir, "alloc.txt"), <<~ALLOC)
        # alloc-profile v2
        0xleak     1  1000   0    0    1000
        0xpaired   1  1000   1    1000   0
      ALLOC
      out = capture_stdout { described_class.run(@profile_dir, by: :inuse_bytes) }
      expect(out).to include("Top sites by in-use bytes")
      expect(out.index("0xleak")).to be < out.index("0xpaired")
    end
  end

  describe "runtime-function attribution" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @profile_dir = File.join(dir, "p.profile")
        FileUtils.mkdir_p(@profile_dir)
        # Synthesize a transpiled.zig with one CLR marker, then test
        # that addresses NOT in this file aren't credited a clear_line.
        File.write(File.join(@profile_dir, "transpiled.zig"), <<~ZIG)
          // header
          // CLR:42
          some_zig_code();
        ZIG
        ex.run
      end
    end

    it "leaves clear_line nil when the file is not the user transpiled.zig" do
      # Doctor's resolver runs against a real binary which we don't have
      # in tests, so resolve_addrs returns no entries — the absence of
      # `is_user_zig` mis-attribution is what matters in production. This
      # test pins the logic via a direct file_is_transpiled_zig? check.
      require_relative "../ruby/tools/pprof_converter" unless defined?(PprofConverter)
      expect(
        PprofConverter.send(:file_is_transpiled_zig?, "/tmp/runtime.zig:100", "/tmp/transpiled.zig")
      ).to be false
      expect(
        PprofConverter.send(:file_is_transpiled_zig?, "/build/cache/._clear_tmp_litedb.zig:60", "/p/transpiled.zig")
      ).to be true
      expect(
        PprofConverter.send(:file_is_transpiled_zig?,
          "/build/cache/._clear_tmp_litedb.zig:176 (discriminator 4)", "/p/transpiled.zig")
      ).to be true
    end
  end
end
