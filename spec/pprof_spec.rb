require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'stringio'
require_relative '../src/tools/pprof'
require_relative '../src/tools/pprof_converter'

# Exercises both the pprof wire-format encoder and the converter that
# turns `clear profile` text dumps into pprof `.pb.gz` files. We do not
# require pprof itself to be installed -- a tiny in-test decoder
# verifies the bytes we emit match what we mean to encode.

# Minimal protobuf decoder for the subset of the schema the encoder
# uses. Verifies field tags, wire types, and lengths. Returns nested
# hashes keyed by field number.
module ProtoTestDecoder
  module_function

  def parse(bytes)
    bytes = bytes.b
    io = StringIO.new(bytes)
    out = Hash.new { |h, k| h[k] = [] }
    until io.eof?
      tag = read_varint(io)
      field = tag >> 3
      wire = tag & 7
      val =
        case wire
        when 0 then read_varint(io)
        when 2 then io.read(read_varint(io)).to_s.b
        when 1 then io.read(8)
        when 5 then io.read(4)
        else raise "unsupported wire type #{wire} for field #{field}"
        end
      out[field] << val
    end
    out
  end

  def read_varint(io)
    n = 0
    shift = 0
    loop do
      b = io.read(1)&.unpack1('C')
      raise 'truncated varint' if b.nil?
      n |= (b & 0x7F) << shift
      return n if (b & 0x80).zero?
      shift += 7
      raise 'varint too long' if shift > 63
    end
  end

  # Decode a packed varint field (Sample.location_id, Sample.value).
  def parse_packed_varints(bytes)
    io = StringIO.new(bytes.b)
    out = []
    out << read_varint(io) until io.eof?
    out
  end
end

RSpec.describe Pprof::Wire do
  it 'encodes single-byte varints unchanged' do
    expect(described_class.varint(0)).to eq("\x00".b)
    expect(described_class.varint(1)).to eq("\x01".b)
    expect(described_class.varint(127)).to eq("\x7f".b)
  end

  it 'encodes multi-byte varints with the continuation bit' do
    # 300 = 0b1_0010_1100 -> bytes [0xAC, 0x02]
    expect(described_class.varint(300)).to eq("\xac\x02".b)
  end

  it 'rejects negative values' do
    expect { described_class.varint(-1) }.to raise_error(ArgumentError)
  end

  it 'composes a length-delimited field' do
    bytes = described_class.field_bytes(6, 'hi')
    expect(bytes).to eq("\x32\x02hi".b) # tag=(6<<3|2)=0x32, len=2, "hi"
  end
end

RSpec.describe Pprof::Profile do
  it 'reserves string_table[0] = "" so pprof readers parse correctly' do
    pb = described_class.new
    bytes = pb.encode
    decoded = ProtoTestDecoder.parse(bytes)
    expect(decoded[6].first).to eq('') # string_table is field 6
  end

  it 'deduplicates strings, functions, and string columns' do
    pb = described_class.new
    pb.add_function(name: 'foo', filename: 'a.cht')
    second_id = pb.add_function(name: 'foo', filename: 'a.cht')
    expect(second_id).to eq(1)
    decoded = ProtoTestDecoder.parse(pb.encode)
    expect(decoded[5].length).to eq(1) # one Function entry only
  end

  it 'encodes a roundtrippable single-sample profile' do
    pb = described_class.new
    pb.add_sample_type('alloc_objects', 'count')
    pb.add_sample_type('alloc_space',   'bytes')
    pb.set_period_type('space', 'bytes', 1)
    fid = pb.add_function(name: 'allocBlob', filename: 'foo.cht')
    lid = pb.add_location(function_id: fid, line: 42, address: 0x1234)
    pb.add_sample([lid], [10, 1024], addr: '0x1234')

    bytes = pb.encode
    decoded = ProtoTestDecoder.parse(bytes)

    expect(decoded[1].length).to eq(2)              # 2 sample_types
    expect(decoded[2].length).to eq(1)              # 1 sample
    expect(decoded[4].length).to eq(1)              # 1 location
    expect(decoded[5].length).to eq(1)              # 1 function
    expect(decoded[11].length).to eq(1)             # period_type set
    expect(decoded[12].first).to eq(1)              # period

    # Sample.value should be packed varints [10, 1024]
    sample = ProtoTestDecoder.parse(decoded[2].first)
    values_bytes = sample[2].first
    expect(ProtoTestDecoder.parse_packed_varints(values_bytes)).to eq([10, 1024])

    location_bytes = sample[1].first
    expect(ProtoTestDecoder.parse_packed_varints(location_bytes)).to eq([1])
  end

  it 'gzips the output with a valid gzip magic' do
    pb = described_class.new
    bytes = pb.encode_gzip
    expect(bytes[0, 2].bytes).to eq([0x1f, 0x8b])
    # Round-trip through Zlib to confirm
    inflated = Zlib::GzipReader.new(StringIO.new(bytes)).read
    expect(inflated.b).to eq(pb.encode.b)
  end
end

RSpec.describe PprofConverter do
  around do |ex|
    Dir.mktmpdir do |dir|
      @profile_dir = File.join(dir, 'foo.profile')
      FileUtils.mkdir_p(@profile_dir)
      ex.run
    end
  end

  describe '.convert_alloc' do
    it 'returns nil when alloc.txt is missing' do
      expect(described_class.convert_alloc(@profile_dir, nil)).to be_nil
    end

    it 'writes heap.pb.gz with four sample-type columns' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        # site          allocs    bytes  frees  free_bytes  live
        0x401234        1000      40000  500    20000       500
        0x402000        2000      80000  2000   80000       0
      PROF
      out = described_class.convert_alloc(@profile_dir, nil)
      expect(out).to eq(File.join(@profile_dir, 'heap.pb.gz'))
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      expect(decoded[1].length).to eq(4) # alloc_objects, alloc_space, inuse_*, inuse_*
      expect(decoded[2].length).to eq(2) # one sample per site
    end

    it 'computes inuse columns from (allocs-frees) and (bytes-free_bytes)' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        0x401234   1000   40000   200   8000   800
      PROF
      out = described_class.convert_alloc(@profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      values = ProtoTestDecoder.parse_packed_varints(sample[2].first)
      # alloc_objects, alloc_space, inuse_objects, inuse_space
      expect(values).to eq([1000, 40000, 800, 32000])
    end

    it 'tags each sample with its source address as a label' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        0xdeadbeef   1   16   0   0   1
      PROF
      out = described_class.convert_alloc(@profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      # The address 0xdeadbeef should appear in string_table.
      expect(bytes).to include('0xdeadbeef')
    end
  end

  describe '.convert_locks' do
    it 'returns nil for empty input' do
      File.write(File.join(@profile_dir, 'locks.txt'), "# header only\n")
      expect(described_class.convert_locks(@profile_dir, nil)).to be_nil
    end

    it 'sums read+write contention into the contentions column' do
      File.write(File.join(@profile_dir, 'locks.txt'), <<~PROF)
        # addr  acq cont total_wait max_wait total_hold max_hold r_acq r_cont r_wait r_max
        0x500   100 5    50000      1000     200000     5000     50    2      10000  500
      PROF
      out = described_class.convert_locks(@profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      values = ProtoTestDecoder.parse_packed_varints(sample[2].first)
      # contentions, delay, hold, acquisitions
      expect(values).to eq([5 + 2, 50000 + 10000, 200000, 100 + 50])
    end
  end

  describe '.convert_mvcc' do
    it 'computes cow_bytes as struct_size * (commits + retries)' do
      File.write(File.join(@profile_dir, 'mvcc.txt'), <<~PROF)
        0x600   128   5000   1000   200   10
      PROF
      out = described_class.convert_mvcc(@profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      values = ProtoTestDecoder.parse_packed_varints(sample[2].first)
      # reads, commits, retries, cow_bytes
      expect(values).to eq([5000, 1000, 200, 128 * (1000 + 200)])
    end

    it 'tolerates the optional 7th `multi_commits` column' do
      File.write(File.join(@profile_dir, 'mvcc.txt'), <<~PROF)
        0x700   64   100   50   5   0   3
      PROF
      out = described_class.convert_mvcc(@profile_dir, nil)
      expect(out).to eq(File.join(@profile_dir, 'mvcc.pb.gz'))
    end
  end

  describe '.convert_perf' do
    it 'returns nil when perf_to_profile is unavailable or perf.data is missing' do
      # No perf.data => nil regardless of perf_to_profile presence.
      expect(described_class.convert_perf(@profile_dir, nil)).to be_nil
    end
  end

  describe '.convert_all' do
    it 'returns the set of files actually emitted' do
      File.write(File.join(@profile_dir, 'alloc.txt'), "0x100  1  16  0  0  1\n")
      File.write(File.join(@profile_dir, 'mvcc.txt'),  "0x200  64  10  5  1  0\n")
      out = described_class.convert_all(@profile_dir)
      expect(out.keys).to contain_exactly(:heap, :mvcc)
      expect(out[:heap]).to eq(File.join(@profile_dir, 'heap.pb.gz'))
      expect(out[:mvcc]).to eq(File.join(@profile_dir, 'mvcc.pb.gz'))
    end

    it 'returns an empty hash for a directory with no profile files' do
      expect(described_class.convert_all(@profile_dir)).to eq({})
    end

    it 'returns an empty hash for a missing directory' do
      expect(described_class.convert_all('/nonexistent')).to eq({})
    end
  end
end
