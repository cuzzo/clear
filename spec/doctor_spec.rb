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
      expect(out).to include("Top sites by bytes:")
      expect(out).to include("(heap rc) = @multiowned RC allocation tracked by rcCreate")
    end
  end
end
