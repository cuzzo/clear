require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'stringio'
require_relative '../ruby/tools/pprof' unless defined?(Pprof::Profile)
require_relative '../ruby/tools/pprof_converter' unless defined?(PprofConverter)

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

  def first_message(root, field)
    parse(root.fetch(field).first)
  end

  def sample_messages(root)
    root[2].map { |bytes| parse(bytes) }
  end

  def string_table(root)
    root[6]
  end

  def label_entries(root, sample)
    strings = string_table(root)
    sample[3].map do |bytes|
      label = parse(bytes)
      {
        key: strings.fetch(label[1].first),
        str: label[2].empty? ? nil : strings.fetch(label[2].first),
        num: label[3].first,
      }
    end
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
    expect(described_class.varint(128)).to eq("\x80\x01".b)
    expect(described_class.varint(129)).to eq("\x81\x01".b)
    expect(described_class.varint(16_384)).to eq("\x80\x80\x01".b)
  end

  it 'rejects negative values' do
    expect { described_class.varint(-1) }.to raise_error(ArgumentError)
  end

  it 'composes a varint field tag and value' do
    expect(described_class.field_varint(14, 300)).to eq("\x70\xac\x02".b)
  end

  it 'composes a length-delimited field' do
    bytes = described_class.field_bytes(6, 'hi')
    expect(bytes).to eq("\x32\x02hi".b) # tag=(6<<3|2)=0x32, len=2, "hi"
  end

  it 'composes a string field as length-delimited bytes' do
    expect(described_class.field_string(6, 'hi')).to eq("\x32\x02hi".b)
  end
end

RSpec.describe Pprof::Profile do
  it 'reserves string_table[0] = "" so pprof readers parse correctly' do
    pb = described_class.new
    bytes = pb.send(:encode)
    decoded = ProtoTestDecoder.parse(bytes)
    expect(decoded[6].first).to eq('') # string_table is field 6
  end

  it 'deduplicates strings, functions, and string columns' do
    pb = described_class.new
    pb.add_function(name: 'foo', filename: 'a.cht')
    second_id = pb.add_function(name: 'foo', filename: 'a.cht')
    expect(second_id).to eq(1)
    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[5].length).to eq(1) # one Function entry only
  end

  it 'keeps functions distinct by system name and filename' do
    pb = described_class.new
    first_id = pb.add_function(name: 'foo', filename: 'a.cht', system_name: 'foo.impl')
    second_id = pb.add_function(name: 'foo', filename: 'b.cht', system_name: 'foo.impl')
    third_id = pb.add_function(name: 'foo', filename: 'a.cht', system_name: 'foo.other')

    expect([first_id, second_id, third_id]).to eq([1, 2, 3])
    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[5].length).to eq(3)
  end

  it 'keeps functions distinct by source name even when system name and filename match' do
    pb = described_class.new
    first_id = pb.add_function(name: 'foo', filename: 'a.cht', system_name: 'same.impl')
    second_id = pb.add_function(name: 'bar', filename: 'a.cht', system_name: 'same.impl')

    expect([first_id, second_id]).to eq([1, 2])
    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[5].length).to eq(2)
  end

  it 'encodes function and location defaults exactly' do
    pb = described_class.new
    fid = pb.add_function(name: 'foo')
    first_lid = pb.add_location(function_id: fid)
    second_lid = pb.add_location(function_id: fid)

    expect([first_lid, second_lid]).to eq([1, 2])

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    function = ProtoTestDecoder.first_message(decoded, 5)
    expect(function[1]).to eq([fid])
    expect(function[4]).to eq([0])
    expect(function[5]).to eq([0])

    location = ProtoTestDecoder.first_message(decoded, 4)
    expect(location[1]).to eq([first_lid])
    expect(location[2]).to be_empty
    expect(location[3]).to be_empty
    line = ProtoTestDecoder.first_message(location, 4)
    expect(line[1]).to eq([fid])
    expect(line[2]).to eq([0])
  end

  it 'encodes every core profile field with schema-correct tags and indexes' do
    pb = described_class.new
    pb.time_nanos = 123
    pb.duration_nanos = 456
    pb.add_sample_type('alloc_space', 'bytes')
    pb.set_period_type('space', 'bytes', 99)
    pb.default_sample_type = 'alloc_space'
    mapping_id = pb.add_mapping(binary: 'bin', build_id: 'build')
    fid = pb.add_function(name: 'foo', filename: 'a.cht', system_name: 'Foo.sys', start_line: 7)
    lid = pb.add_location(function_id: fid, line: 42, address: 0x1234)
    pb.add_sample([lid], [10], label: 'hot', count: 3)

    encoded = pb.send(:encode)
    expect(encoded.encoding).to eq(Encoding::ASCII_8BIT)
    expect(encoded.bytes).to eq([
      10, 4, 8, 1, 16, 2, 18, 18, 10, 1, 1, 18, 1, 10, 26, 4,
      8, 9, 16, 10, 26, 4, 8, 11, 24, 3, 26, 12, 8, 1, 40, 4,
      48, 5, 56, 1, 64, 1, 72, 1, 34, 13, 8, 1, 16, 1, 24, 180,
      36, 34, 4, 8, 1, 16, 42, 42, 10, 8, 1, 16, 6, 24, 7, 32,
      8, 40, 7, 50, 0, 50, 11, 97, 108, 108, 111, 99, 95, 115, 112, 97,
      99, 101, 50, 5, 98, 121, 116, 101, 115, 50, 5, 115, 112, 97, 99, 101,
      50, 3, 98, 105, 110, 50, 5, 98, 117, 105, 108, 100, 50, 3, 102, 111,
      111, 50, 7, 70, 111, 111, 46, 115, 121, 115, 50, 5, 97, 46, 99, 104,
      116, 50, 5, 108, 97, 98, 101, 108, 50, 3, 104, 111, 116, 50, 5, 99,
      111, 117, 110, 116, 72, 123, 80, 200, 3, 90, 4, 8, 3, 16, 2, 96,
      99, 112, 1,
    ])

    decoded = ProtoTestDecoder.parse(encoded)
    expect(decoded.keys).to include(1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 14)
    expect(decoded[6]).to eq([
      '',
      'alloc_space',
      'bytes',
      'space',
      'bin',
      'build',
      'foo',
      'Foo.sys',
      'a.cht',
      'label',
      'hot',
      'count',
    ])
    expect(decoded[9]).to eq([123])
    expect(decoded[10]).to eq([456])
    expect(decoded[12]).to eq([99])
    expect(decoded[14]).to eq([1])

    sample_type = ProtoTestDecoder.first_message(decoded, 1)
    expect(sample_type[1]).to eq([1])
    expect(sample_type[2]).to eq([2])

    period_type = ProtoTestDecoder.first_message(decoded, 11)
    expect(period_type[1]).to eq([3])
    expect(period_type[2]).to eq([2])

    mapping = ProtoTestDecoder.first_message(decoded, 3)
    expect(mapping[1]).to eq([mapping_id])
    expect(mapping[5]).to eq([4])
    expect(mapping[6]).to eq([5])
    expect(mapping[7]).to eq([1])
    expect(mapping[8]).to eq([1])
    expect(mapping[9]).to eq([1])
    expect(mapping[2]).to be_empty
    expect(mapping[3]).to be_empty
    expect(mapping[4]).to be_empty

    function = ProtoTestDecoder.first_message(decoded, 5)
    expect(function[1]).to eq([fid])
    expect(function[2]).to eq([6])
    expect(function[3]).to eq([7])
    expect(function[4]).to eq([8])
    expect(function[5]).to eq([7])

    location = ProtoTestDecoder.first_message(decoded, 4)
    expect(location[1]).to eq([lid])
    expect(location[2]).to eq([mapping_id])
    expect(location[3]).to eq([0x1234])
    line = ProtoTestDecoder.first_message(location, 4)
    expect(line[1]).to eq([fid])
    expect(line[2]).to eq([42])

    sample = ProtoTestDecoder.first_message(decoded, 2)
    expect(ProtoTestDecoder.parse_packed_varints(sample[1].first)).to eq([lid])
    expect(ProtoTestDecoder.parse_packed_varints(sample[2].first)).to eq([10])
    labels = sample[3].map { |bytes| ProtoTestDecoder.parse(bytes) }
    expect(labels.map { |label| [label[1].first, label[2].first, label[3].first] }).to eq([
      [9, 10, nil],
      [11, nil, 3],
    ])
  end

  it 'encodes a roundtrippable single-sample profile' do
    pb = described_class.new
    pb.add_sample_type('alloc_objects', 'count')
    pb.add_sample_type('alloc_space',   'bytes')
    pb.set_period_type('space', 'bytes', 1)
    fid = pb.add_function(name: 'allocBlob', filename: 'foo.cht')
    lid = pb.add_location(function_id: fid, line: 42, address: 0x1234)
    pb.add_sample([lid], [10, 1024], addr: '0x1234')

    bytes = pb.send(:encode)
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

  it 'omits empty packed sample fields but keeps labels' do
    pb = described_class.new
    pb.add_sample([], [], label: 'empty')

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    sample = ProtoTestDecoder.first_message(decoded, 2)
    expect(sample[1]).to be_empty
    expect(sample[2]).to be_empty
    expect(sample[3].length).to eq(1)
  end

  it 'encodes negative sample values as unsigned int64 varints' do
    pb = described_class.new
    pb.add_sample_type('delta', 'count')
    pb.add_sample([], [-1])

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    sample = ProtoTestDecoder.first_message(decoded, 2)
    expect(ProtoTestDecoder.parse_packed_varints(sample[2].first)).to eq([(1 << 64) - 1])
  end

  it 'omits optional scalar fields when they are unset or zero' do
    pb = described_class.new
    pb.time_nanos = 0
    pb.duration_nanos = 0

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[9]).to be_empty
    expect(decoded[10]).to be_empty
    expect(decoded[11]).to be_empty
    expect(decoded[12]).to be_empty
    expect(decoded[14]).to be_empty
  end

  it 'emits a Mapping when one is registered, and Locations point at it' do
    pb = described_class.new
    pb.add_mapping(binary: '/path/to/litedb', build_id: 'abc123')
    pb.add_sample_type('alloc_space', 'bytes')
    fid = pb.add_function(name: 'foo', filename: 'foo.cht')
    lid = pb.add_location(function_id: fid, line: 1, address: 0x100)
    pb.add_sample([lid], [10])

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[3].length).to eq(1)            # one Mapping
    mapping = ProtoTestDecoder.parse(decoded[3].first)
    expect(mapping[1].first).to eq(1)             # Mapping.id
    expect(mapping[7].first).to eq(1)             # has_functions = true
    expect(mapping[8].first).to eq(1)             # has_filenames = true
    expect(mapping[9].first).to eq(1)             # has_line_numbers = true

    location = ProtoTestDecoder.parse(decoded[4].first)
    expect(location[2].first).to eq(1)            # Location.mapping_id = 1
  end

  it 'increments mapping ids while keeping the first mapping primary for locations' do
    pb = described_class.new
    first_id = pb.add_mapping(binary: 'first')
    second_id = pb.add_mapping(binary: 'second')
    fid = pb.add_function(name: 'foo')
    pb.add_location(function_id: fid)

    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    mappings = decoded[3].map { |bytes| ProtoTestDecoder.parse(bytes) }
    expect([first_id, second_id]).to eq([1, 2])
    expect(mappings.map { |mapping| mapping[1].first }).to eq([1, 2])
    location = ProtoTestDecoder.first_message(decoded, 4)
    expect(location[2].first).to eq(1)
  end

  it 'omits the Mapping field entirely when none is registered' do
    pb = described_class.new
    pb.add_sample_type('count', 'samples')
    decoded = ProtoTestDecoder.parse(pb.send(:encode))
    expect(decoded[3]).to be_empty
  end

  it 'gzips the output with a valid gzip magic' do
    pb = described_class.new
    bytes = pb.send(:encode_gzip)
    expect(bytes[0, 2].bytes).to eq([0x1f, 0x8b])
    # Round-trip through Zlib to confirm
    inflated = Zlib::GzipReader.new(StringIO.new(bytes)).read
    expect(inflated.b).to eq(pb.send(:encode).b)
  end

  it 'writes gzipped output to disk' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'profile.pb.gz')
      pb = described_class.new
      pb.add_sample_type('count', 'samples')
      pb.write_gzip(path)

      inflated = Zlib::GzipReader.new(StringIO.new(File.binread(path))).read
      expect(inflated.b).to eq(pb.send(:encode).b)
    end
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

  def decoded_gzip_profile(path)
    ProtoTestDecoder.parse(Zlib::GzipReader.new(StringIO.new(File.binread(path))).read)
  end

  describe '.convert_alloc' do
    it 'returns nil when alloc.txt is missing' do
      expect(described_class.send(:convert_alloc, @profile_dir, nil)).to be_nil
    end

    it 'writes heap.pb.gz with four sample-type columns' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        # site          allocs    bytes  frees  free_bytes  live
        0x401234        1000      40000  500    20000       500
        0x402000        2000      80000  2000   80000       0
      PROF
      out = described_class.send(:convert_alloc, @profile_dir, nil)
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
      out = described_class.send(:convert_alloc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      values = ProtoTestDecoder.parse_packed_varints(sample[2].first)
      # alloc_objects, alloc_space, inuse_objects, inuse_space
      expect(values).to eq([1000, 40000, 800, 32000])
    end

    it 'clamps negative inuse columns to zero' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        0x401234   10   100   20   200   0
      PROF
      out = described_class.send(:convert_alloc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.sample_messages(decoded).first

      expect(ProtoTestDecoder.parse_packed_varints(sample[2].first)).to eq([10, 100, 0, 0])
    end

    it 'parses comma-separated multi-frame stack traces (alloc-profile v2)' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        # alloc-profile v2 (multi-frame, comma-separated leaf-first)
        0x401234,0x402000,0x403000   1000  40000  500  20000  500
      PROF
      out = described_class.send(:convert_alloc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      # Three Locations (one per unique addr), three Functions
      expect(decoded[4].length).to eq(3)
      expect(decoded[5].length).to eq(3)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      stack = ProtoTestDecoder.parse_packed_varints(sample[1].first)
      expect(stack.length).to eq(3)            # 3-frame trace in Sample.location_id
    end

    it 'shares Locations across samples that include the same frame' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        # alloc-profile v2
        0x10,0x20    100  1000  0  0  100
        0x30,0x20    100  1000  0  0  100
      PROF
      out = described_class.send(:convert_alloc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      # 0x20 should be ONE Location/Function reused by both samples.
      expect(decoded[4].length).to eq(3)       # 0x10, 0x20, 0x30
      expect(decoded[5].length).to eq(3)
      expect(decoded[2].length).to eq(2)
    end

    it 'tags each sample with its source address as a label' do
      File.write(File.join(@profile_dir, 'alloc.txt'), <<~PROF)
        0xdeadbeef   1   16   0   0   1
      PROF
      out = described_class.send(:convert_alloc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.sample_messages(decoded).first

      expect(ProtoTestDecoder.label_entries(decoded, sample)).to include(
        { key: 'addr', str: '0xdeadbeef', num: nil },
      )
    end
  end

  describe '.convert_locks' do
    it 'returns nil when locks.txt is missing' do
      expect(described_class.send(:convert_locks, @profile_dir, nil)).to be_nil
    end

    it 'returns nil for empty input' do
      File.write(File.join(@profile_dir, 'locks.txt'), "# header only\n")
      expect(described_class.send(:convert_locks, @profile_dir, nil)).to be_nil
    end

    it 'returns nil when all lock rows have zero activity' do
      File.write(File.join(@profile_dir, 'locks.txt'), "0x500 0 0 0 0 0 0 0 0 0 0\n")
      expect(described_class.send(:convert_locks, @profile_dir, nil)).to be_nil
    end

    it 'sums read+write contention into the contentions column' do
      File.write(File.join(@profile_dir, 'locks.txt'), <<~PROF)
        # addr  acq cont total_wait max_wait total_hold max_hold r_acq r_cont r_wait r_max
        0x500   100 5    50000      1000     200000     5000     50    2      10000  500
      PROF
      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      values = ProtoTestDecoder.parse_packed_varints(sample[2].first)
      # contentions, delay, hold, acquisitions
      expect(values).to eq([5 + 2, 50000 + 10000, 200000, 100 + 50])
    end

    it 'parses caller_trace = "-" as no trace (sync-callstacks off)' do
      tab = "\t"
      content = "# lock-profile v3\n" \
                "0x500#{tab}100#{tab}5#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n"
      File.write(File.join(@profile_dir, 'locks.txt'), content)
      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      stack = ProtoTestDecoder.parse_packed_varints(sample[1].first)
      expect(stack.length).to eq(1)             # only the lock-pointer leaf
    end

    it 'parses caller_trace as multi-frame stack (sync-callstacks on)' do
      tab = "\t"
      content = "# lock-profile v3\n" \
                "0x500#{tab}100#{tab}5#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0" \
                "#{tab}0xC1,0xC2,0xC3\n"
      File.write(File.join(@profile_dir, 'locks.txt'), content)
      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      stack = ProtoTestDecoder.parse_packed_varints(sample[1].first)
      # leaf (lock 0x500) + 3 caller frames
      expect(stack.length).to eq(4)
    end

    it 'emits a separate sample per (lock, caller-trace) row' do
      tab = "\t"
      content = "# lock-profile v3\n" \
                "0x500#{tab}40#{tab}2#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0xA\n" \
                "0x500#{tab}10#{tab}1#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0xB\n"
      File.write(File.join(@profile_dir, 'locks.txt'), content)
      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      expect(decoded[2].length).to eq(2)        # one Sample per (lock,caller) row
    end

    it 'labels read-dominant lock rows as read samples' do
      tab = "\t"
      content = "0x500#{tab}1#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}5#{tab}1#{tab}10#{tab}0#{tab}-\n"
      File.write(File.join(@profile_dir, 'locks.txt'), content)

      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.sample_messages(decoded).first

      expect(ProtoTestDecoder.label_entries(decoded, sample)).to include(
        { key: 'kind', str: 'read', num: nil },
        { key: 'addr', str: '0x500', num: nil },
      )
    end

    it 'labels write-dominant lock rows as write samples' do
      tab = "\t"
      content = "0x501#{tab}5#{tab}1#{tab}10#{tab}0#{tab}0#{tab}0#{tab}1#{tab}0#{tab}0#{tab}0#{tab}-\n"
      File.write(File.join(@profile_dir, 'locks.txt'), content)

      out = described_class.send(:convert_locks, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.sample_messages(decoded).first

      expect(ProtoTestDecoder.label_entries(decoded, sample)).to include(
        { key: 'kind', str: 'write', num: nil },
        { key: 'addr', str: '0x501', num: nil },
      )
    end
  end

  describe '.convert_mvcc' do
    it 'returns nil when mvcc.txt is missing or contains no active cells' do
      expect(described_class.send(:convert_mvcc, @profile_dir, nil)).to be_nil

      File.write(File.join(@profile_dir, 'mvcc.txt'), "0x600 128 0 0 0 0\n")
      expect(described_class.send(:convert_mvcc, @profile_dir, nil)).to be_nil
    end

    it 'computes cow_bytes as struct_size * (commits + retries)' do
      File.write(File.join(@profile_dir, 'mvcc.txt'), <<~PROF)
        0x600   128   5000   1000   200   10
      PROF
      out = described_class.send(:convert_mvcc, @profile_dir, nil)
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
      out = described_class.send(:convert_mvcc, @profile_dir, nil)
      expect(out).to eq(File.join(@profile_dir, 'mvcc.pb.gz'))
    end

    it 'parses caller_trace as multi-frame stack (sync-callstacks on)' do
      tab = "\t"
      content = "# mvcc-profile v2\n" \
                "0x700#{tab}64#{tab}1000#{tab}50#{tab}5#{tab}0#{tab}3#{tab}0xC1,0xC2,0xC3\n"
      File.write(File.join(@profile_dir, 'mvcc.txt'), content)
      out = described_class.send(:convert_mvcc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      stack = ProtoTestDecoder.parse_packed_varints(sample[1].first)
      # leaf (cell 0x700) + 3 caller frames
      expect(stack.length).to eq(4)
    end

    it 'parses caller_trace = "-" as no trace and labels struct size/address' do
      tab = "\t"
      content = "0x700#{tab}64#{tab}1000#{tab}50#{tab}5#{tab}0#{tab}3#{tab}-\n"
      File.write(File.join(@profile_dir, 'mvcc.txt'), content)
      out = described_class.send(:convert_mvcc, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.parse(decoded[2].first)
      stack = ProtoTestDecoder.parse_packed_varints(sample[1].first)

      expect(stack.length).to eq(1)
      expect(ProtoTestDecoder.label_entries(decoded, sample)).to include(
        { key: 'struct_size', str: nil, num: 64 },
        { key: 'addr', str: '0x700', num: nil },
      )
    end
  end

  describe '.convert_channels' do
    it 'returns nil when channels.txt is missing' do
      expect(described_class.send(:convert_channels, @profile_dir, nil)).to be_nil
    end

    it 'returns nil for an empty channels.txt' do
      File.write(File.join(@profile_dir, 'channels.txt'), <<~PROF)
        # channel-profile v1
        # id pushes pops push_blocked pop_blocked max_depth capacity
      PROF
      expect(described_class.send(:convert_channels, @profile_dir, nil)).to be_nil
    end

    it 'returns nil when all channel rows have zero pushes and pops' do
      tab = "\t"
      File.write(File.join(@profile_dir, 'channels.txt'), "0#{tab}0#{tab}0#{tab}1#{tab}2#{tab}3#{tab}4\n")
      expect(described_class.send(:convert_channels, @profile_dir, nil)).to be_nil
    end

    it 'emits one Sample per registered channel' do
      tab = "\t"
      File.write(File.join(@profile_dir, 'channels.txt'), <<~PROF)
        # channel-profile v1
        0#{tab}5#{tab}5#{tab}0#{tab}2#{tab}5#{tab}8#{tab}future
        1#{tab}9#{tab}9#{tab}0#{tab}3#{tab}9#{tab}16
      PROF
      out = described_class.send(:convert_channels, @profile_dir, nil)
      expect(out).to eq(File.join(@profile_dir, 'channels.pb.gz'))
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      expect(decoded[1].length).to eq(5)             # 5 sample-type columns
      expect(decoded[2].length).to eq(2)             # 2 samples
      expect(bytes).to include('channel#0')
      expect(bytes).to include('channel#1')
    end

    it 'encodes channel sample values and numeric labels in column order' do
      tab = "\t"
      File.write(File.join(@profile_dir, 'channels.txt'),
                 "7#{tab}11#{tab}13#{tab}17#{tab}19#{tab}23#{tab}29\n")

      out = described_class.send(:convert_channels, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      decoded = ProtoTestDecoder.parse(bytes)
      sample = ProtoTestDecoder.sample_messages(decoded).first

      expect(ProtoTestDecoder.parse_packed_varints(sample[2].first)).to eq([11, 13, 17, 19, 23])
      expect(ProtoTestDecoder.label_entries(decoded, sample)).to include(
        { key: 'capacity', str: nil, num: 29 },
        { key: 'id', str: nil, num: 7 },
      )
    end

    it 'tags each sample with the channel capacity' do
      tab = "\t"
      File.write(File.join(@profile_dir, 'channels.txt'),
                 "# channel-profile v1\n0#{tab}5#{tab}5#{tab}0#{tab}2#{tab}5#{tab}8\n")
      out = described_class.send(:convert_channels, @profile_dir, nil)
      bytes = Zlib::GzipReader.new(StringIO.new(File.binread(out))).read
      expect(bytes).to include('capacity')
    end
  end

  it 'adds binary mappings to each emitted protobuf profile when a binary path is available' do
    binary = File.join(File.dirname(@profile_dir), 'foo')
    File.write(binary, 'binary')
    tab = "\t"
    File.write(File.join(@profile_dir, 'alloc.txt'), "0x100 1 16 0 0 1\n")
    File.write(File.join(@profile_dir, 'locks.txt'),
               "0x500#{tab}100#{tab}5#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n")
    File.write(File.join(@profile_dir, 'mvcc.txt'), "0x600 64 10 5 1 0\n")
    File.write(File.join(@profile_dir, 'channels.txt'),
               "7#{tab}11#{tab}13#{tab}17#{tab}19#{tab}23#{tab}29\n")

    outputs = [
      described_class.send(:convert_alloc, @profile_dir, binary),
      described_class.send(:convert_locks, @profile_dir, binary),
      described_class.send(:convert_mvcc, @profile_dir, binary),
      described_class.send(:convert_channels, @profile_dir, binary),
    ]

    outputs.each do |path|
      decoded = decoded_gzip_profile(path)
      expect(decoded[3].length).to eq(1)
      expect(ProtoTestDecoder.string_table(decoded)).to include(binary)
    end
  end

  describe '.convert_perf' do
    it 'returns nil when perf_to_profile is unavailable or perf.data is missing' do
      # No perf.data => nil regardless of perf_to_profile presence.
      expect(described_class.send(:convert_perf, @profile_dir)).to be_nil
    end

    it 'returns nil when perf.data exists but perf_to_profile is unavailable' do
      File.write(File.join(@profile_dir, 'perf.data'), 'perf bytes')
      allow(described_class).to receive(:system)
        .with('which perf_to_profile > /dev/null 2>&1')
        .and_return(false)

      expect(described_class.send(:convert_perf, @profile_dir)).to be_nil
    end

    it 'writes cpu.pb.gz when perf_to_profile succeeds' do
      File.write(File.join(@profile_dir, 'perf.data'), 'perf bytes')
      allow(described_class).to receive(:system) do |*args|
        if args == ['which perf_to_profile > /dev/null 2>&1']
          true
        else
          File.write(args[4], 'profile')
          true
        end
      end

      expect(described_class.send(:convert_perf, @profile_dir)).to eq(File.join(@profile_dir, 'cpu.pb.gz'))
    end
  end

  describe '.convert_all' do
    it 'returns an empty hash for nil input' do
      expect(described_class.convert_all(nil)).to eq({})
    end

    it 'returns the set of files actually emitted' do
      File.write(File.join(@profile_dir, 'alloc.txt'), "0x100  1  16  0  0  1\n")
      File.write(File.join(@profile_dir, 'mvcc.txt'),  "0x200  64  10  5  1  0\n")
      out = described_class.convert_all(@profile_dir)
      expect(out.keys).to contain_exactly(:heap, :mvcc)
      expect(out[:heap]).to eq(File.join(@profile_dir, 'heap.pb.gz'))
      expect(out[:mvcc]).to eq(File.join(@profile_dir, 'mvcc.pb.gz'))
    end

    it 'derives binary mappings from a trailing-slash profile directory' do
      binary = File.join(File.dirname(@profile_dir), 'foo')
      File.write(binary, 'binary')
      tab = "\t"
      File.write(File.join(@profile_dir, 'alloc.txt'), "0x100 1 16 0 0 1\n")
      File.write(File.join(@profile_dir, 'locks.txt'),
                 "0x500#{tab}100#{tab}5#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n")
      File.write(File.join(@profile_dir, 'mvcc.txt'), "0x600 64 10 5 1 0\n")
      File.write(File.join(@profile_dir, 'channels.txt'),
                 "7#{tab}11#{tab}13#{tab}17#{tab}19#{tab}23#{tab}29\n")

      out = described_class.convert_all("#{@profile_dir}/")

      expect(out.keys).to contain_exactly(:heap, :lock, :mvcc, :channels)
      out.values.each do |path|
        decoded = decoded_gzip_profile(path)
        expect(decoded[3].length).to eq(1)
        expect(ProtoTestDecoder.string_table(decoded)).to include(binary)
      end
    end

    it 'omits binary mappings when the derived binary is absent' do
      File.write(File.join(@profile_dir, 'alloc.txt'), "0x100 1 16 0 0 1\n")

      out = described_class.convert_all(@profile_dir)
      decoded = decoded_gzip_profile(out.fetch(:heap))

      expect(decoded[3]).to eq([])
    end

    it 'includes lock, channel, and cpu profiles when those converters emit files' do
      tab = "\t"
      File.write(File.join(@profile_dir, 'locks.txt'),
                 "0x500#{tab}100#{tab}5#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}0#{tab}-\n")
      File.write(File.join(@profile_dir, 'channels.txt'),
                 "0#{tab}5#{tab}5#{tab}0#{tab}2#{tab}5#{tab}8\n")
      allow(described_class).to receive(:convert_perf)
        .and_return(File.join(@profile_dir, 'cpu.pb.gz'))

      out = described_class.convert_all(@profile_dir)

      expect(out).to include(
        lock: File.join(@profile_dir, 'lock.pb.gz'),
        channels: File.join(@profile_dir, 'channels.pb.gz'),
        cpu: File.join(@profile_dir, 'cpu.pb.gz'),
      )
    end

    it 'returns an empty hash for a directory with no profile files' do
      expect(described_class.convert_all(@profile_dir)).to eq({})
    end

    it 'returns an empty hash for a missing directory' do
      expect(described_class.convert_all('/nonexistent')).to eq({})
    end
  end

  describe '.resolve_addrs' do
    it 'returns an empty map when there is no binary or no address' do
      expect(described_class.send(:resolve_addrs, [], '/tmp/fake-bin', @profile_dir)).to eq({})
      expect(described_class.send(:resolve_addrs, ['0x10'], nil, @profile_dir)).to eq({})
    end

    it 'maps user Zig frames back to CLEAR source lines and leaves runtime frames on Zig lines' do
      File.write(File.join(@profile_dir, 'transpiled.zig'), <<~ZIG)
        // CLR:10
        const a = 1;
        const b = 2;
      ZIG
      allow(IO).to receive(:popen).and_return(
        "._clear_tmp_foo.main__anon_123\n/build/._clear_tmp_foo.zig:3 (discriminator 1)\n" \
        "entryWrapper\n/runtime/scheduler.zig:44\n"
      )

      resolved = described_class.send(:resolve_addrs, %w[0x10 0x20], '/tmp/fake-bin', @profile_dir)

      expect(resolved['0x10']).to include(func: 'main', clear_line: 10, is_user_zig: true)
      expect(resolved['0x20']).to include(func: 'entryWrapper', clear_line: nil, is_user_zig: false)
    end
  end

  describe '.build_location_index' do
    it 'uses resolved function names, filenames, line numbers, and fallback addresses' do
      source = File.join(@profile_dir, 'source.cht')
      File.write(source, 'FN main() RETURNS Void -> RETURN; END')
      pb = Pprof::Profile.new
      resolved = {
        '0x10' => { func: 'userMain', file: '/build/._clear_tmp_foo.zig:7', clear_line: 3, is_user_zig: true },
        '0x20' => { func: 'entryWrapper', file: '/runtime/scheduler.zig:44', clear_line: nil, is_user_zig: false },
      }

      index = described_class.send(:build_location_index, pb, %w[0x10 0x20 0x30], resolved, @profile_dir)
      decoded = ProtoTestDecoder.parse(pb.send(:encode))
      locations = decoded[4].map { |bytes| ProtoTestDecoder.parse(bytes) }
      lines = locations.map { |location| ProtoTestDecoder.first_message(location, 4)[2].first }

      expect(index).to eq('0x10' => 1, '0x20' => 2, '0x30' => 3)
      expect(lines).to eq([3, 44, 0])
      expect(ProtoTestDecoder.string_table(decoded)).to include('userMain', 'entryWrapper', '0x30', source, '/runtime/scheduler.zig')
    end
  end

  describe '.clear_source_path' do
    it 'uses source.cht in legacy auto-detect mode when present' do
      source = File.join(@profile_dir, 'source.cht')
      File.write(source, 'FN main() RETURNS Void -> RETURN; END')

      expect(described_class.send(:clear_source_path, @profile_dir, '/build/file.zig:3')).to eq(source)
    end

    it 'falls back to addr2line path in legacy auto-detect mode without source.cht' do
      expect(described_class.send(:clear_source_path, @profile_dir, '/build/file.zig:3')).to eq('/build/file.zig')
    end

    it 'returns source.cht for user Zig frames when present' do
      source = File.join(@profile_dir, 'source.cht')
      File.write(source, 'FN main() RETURNS Void -> RETURN; END')

      expect(described_class.send(:clear_source_path, @profile_dir, '/build/._clear_tmp_foo.zig:3', is_user_zig: true)).to eq(source)
    end

    it 'returns the addr2line file path for non-user frames' do
      expect(described_class.send(:clear_source_path, @profile_dir, '/runtime/scheduler.zig:44', is_user_zig: false)).to eq('/runtime/scheduler.zig')
    end
  end

  describe 'helper parsers' do
    it 'parses whitespace rows while skipping comments, blanks, and short rows' do
      path = File.join(@profile_dir, 'columns.txt')
      File.write(path, "# header\n\n0x1 1 2\nshort\n0x2 3 4 trailing\n")

      expect(described_class.send(:parse_columns, path, 3)).to eq([
        %w[0x1 1 2],
        %w[0x2 3 4 trailing],
      ])
    end

    it 'parses tabbed rows and falls back to whitespace splitting' do
      path = File.join(@profile_dir, 'tabbed.txt')
      File.write(path, "# header\n0x1\t1\t2\n0x2 3 4\n")

      expect(described_class.send(:parse_tabbed_columns, path, 3)).to eq([
        %w[0x1 1 2],
        %w[0x2 3 4],
      ])
    end

    it 'parses hex and decimal addresses and extracts Zig line numbers' do
      expect(described_class.send(:parse_addr, '0x10')).to eq(16)
      expect(described_class.send(:parse_addr, '42')).to eq(42)
      expect(described_class.send(:extract_zig_line, '/tmp/file.zig:123 (discriminator 1)')).to eq(123)
      expect(described_class.send(:extract_zig_line, '/tmp/file.zig')).to eq(0)
    end
  end
end
