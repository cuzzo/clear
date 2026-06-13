# typed: false
require "sorbet-runtime"

require 'zlib'
require 'stringio'

# Pure-Ruby pprof v3 profile encoder.
#
# Builds a `Profile` message in the schema defined by
# https://github.com/google/pprof/blob/main/proto/profile.proto and
# emits a gzipped protobuf (`.pb.gz`) suitable for the `pprof` tool
# (`pprof -http=:8080 binary file.pb.gz`).
#
# We hand-roll the wire format (~80 lines) instead of pulling the
# `google-protobuf` C-extension gem so that `clear profile`'s pprof
# emission stays a stdlib-only feature.
#
# Wire-format reference:
#   tag = (field_number << 3) | wire_type
#   wire_type 0 = varint
#   wire_type 2 = length-delimited (length, then bytes)
module Pprof
  module Wire
    extend T::Sig


    sig { params(n: Integer).returns(String) }
    def self.varint(n)
      raise ArgumentError, "negative varint: #{n}" if n.negative?
      out = String.new(encoding: 'ASCII-8BIT')
      loop do
        if n < 0x80
          out << n.chr
          return out
        end
        out << ((n & 0x7F) | 0x80).chr
        n >>= 7
      end
    end

    sig { params(field: Integer, n: Integer).returns(String) }
    def self.field_varint(field, n)
      varint((field << 3) | 0) + varint(n)
    end

    sig { params(field: Integer, bytes: String).returns(String) }
    def self.field_bytes(field, bytes)
      varint((field << 3) | 2) + varint(bytes.bytesize) + bytes.b
    end

    sig { params(field: Integer, s: String).returns(String) }
    def self.field_string(field, s)
      field_bytes(field, s.to_s)
    end
  end

  # Builder for one Profile message. Strings, functions, and locations
  # are deduplicated as added; samples are accumulated and serialized
  # at `encode`.
  class Profile
    extend T::Sig

    sig { void }
    def initialize
      @strings    = T.let({ "" => 0 }, T::Hash[T.untyped, T.untyped])      # string_table[0] is required to be empty
      @functions  = T.let({}, T::Hash[T.untyped, T.untyped])               # key: [name, system_name, filename] -> Function
      @locations  = T.let([], T::Array[T.untyped])
      @samples    = T.let([], T::Array[T.untyped])
      @sample_types = T.let([], T::Array[T.untyped])
      @mappings   = T.let([], T::Array[T.untyped])               # one entry per binary
      @period_type  = nil
      @period       = T.let(0, Integer)
      @time_nanos     = (Time.now.to_f * 1e9).to_i
      @duration_nanos = T.let(0, Integer)
      @default_sample_type_idx = nil
      @next_func_id = T.let(1, Integer)
      @next_loc_id  = T.let(1, Integer)
      @next_mapping_id = T.let(1, Integer)
      @primary_mapping_id = T.let(0, Integer)
    end

    attr_writer :time_nanos, :duration_nanos, :period

    sig { params(s: String).returns(Integer) }
    def intern(s)
      @strings[s.to_s] ||= @strings.size
    end

    # Declare a sample value column. `type` is the metric (e.g.
    # `"alloc_space"`); `unit` is the unit (`"bytes"`, `"count"`,
    # `"nanoseconds"`). The column index matches the order of calls.
    sig { params(type: String, unit: String).void }
    def add_sample_type(type, unit)
      @sample_types << [intern(type), intern(unit)]
    end

    # `period` and `period_type` describe the sampling rate (e.g.
    # 1 sample per N events). Optional; pprof shows it in the header.
    def set_period_type(type, unit, period)
      @period_type = T.let([intern(type), intern(unit)], T::Array[T.untyped])
      @period = period
    end

    # Pick which sample-type column the pprof UI selects by default
    # (`pprof -inuse_space file.pb.gz`). Optional.
    def default_sample_type=(type)
      @default_sample_type_idx = intern(type)
    end

    # Register the binary this profile is about. pprof uses the Mapping
    # to display the binary name in the header (silences "Main binary
    # filename not available") and to set has_functions/has_filenames/
    # has_line_numbers flags so its UI knows symbolization is already
    # done. memory_start/limit are 0 because we do not require pprof
    # to load the binary itself — addr2line resolved everything at
    # convert time. Returns the mapping id; the first call also sets
    # the primary mapping that all Locations attach to by default.
    def add_mapping(binary:, build_id: '')
      mapping = {
        id: @next_mapping_id,
        memory_start: 0,
        memory_limit: 0,
        file_offset: 0,
        filename_idx: intern(binary),
        build_id_idx: intern(build_id),
        has_functions: true,
        has_filenames: true,
        has_line_numbers: true,
      }
      @mappings << mapping
      @next_mapping_id += 1
      @primary_mapping_id = mapping[:id] if @primary_mapping_id.zero?
      mapping[:id]
    end

    # Returns the function id (1-based). Identical (name, system_name,
    # filename) tuples are deduplicated.
    sig { params(name: String, filename: String, system_name: T.nilable(String), start_line: Integer).returns(Integer) }
    def add_function(name:, filename: "", system_name: nil, start_line: 0)
      sys = system_name || name
      key = [name, sys, filename]
      f = @functions[key]
      return f[:id] if f
      f = {
        id: @next_func_id,
        name_idx: intern(name),
        system_name_idx: intern(sys),
        filename_idx: intern(filename),
        start_line: start_line,
      }
      @functions[key] = f
      @next_func_id += 1
      f[:id]
    end

    # Returns the location id (1-based). One Line entry per call.
    # Defaults to the primary Mapping (the binary this profile is for)
    # so symbol metadata propagates without per-Location plumbing.
    sig { params(function_id: Integer, line: Integer, address: Integer).returns(Integer) }
    def add_location(function_id:, line: 0, address: 0)
      id = @next_loc_id
      @next_loc_id += 1
      @locations << {
        id: id,
        address: address,
        function_id: function_id,
        line_no: line,
        mapping_id: @primary_mapping_id,
      }
      id
    end

    # `location_ids` is a stack trace, leaf-first. `values` matches the
    # order/length of `add_sample_type` calls. `labels` is a hash of
    # string key -> string-or-int (str labels are interned; int labels
    # render as numeric).
    sig { params(location_ids: Array, values: Array, labels: Hash).returns(String) }
    def add_sample(location_ids, values, labels = {})
      @samples << { location_ids: location_ids, values: values, labels: labels }
    end

    def encode
      buf = String.new(encoding: 'ASCII-8BIT')

      # field 1: sample_type (repeated ValueType)
      @sample_types.each do |type_idx, unit_idx|
        sub = Wire.field_varint(1, type_idx) + Wire.field_varint(2, unit_idx)
        buf << Wire.field_bytes(1, sub)
      end

      # field 2: sample (repeated Sample)
      @samples.each { |s| buf << Wire.field_bytes(2, encode_sample(s)) }

      # field 3: mapping (repeated Mapping)
      @mappings.each { |m| buf << Wire.field_bytes(3, encode_mapping(m)) }

      # field 4: location (repeated Location)
      @locations.each { |loc| buf << Wire.field_bytes(4, encode_location(loc)) }

      # field 5: function (repeated Function)
      @functions.each_value { |f| buf << Wire.field_bytes(5, encode_function(f)) }

      # field 6: string_table (repeated string)
      @strings.keys.each { |s| buf << Wire.field_string(6, s) }

      # field 9, 10: time_nanos, duration_nanos
      buf << Wire.field_varint(9, @time_nanos) if @time_nanos.positive?
      buf << Wire.field_varint(10, @duration_nanos) if @duration_nanos.positive?

      # field 11: period_type (ValueType), 12: period
      if @period_type
        sub = Wire.field_varint(1, @period_type[0]) + Wire.field_varint(2, @period_type[1])
        buf << Wire.field_bytes(11, sub)
      end
      buf << Wire.field_varint(12, @period) if @period.positive?

      # field 14: default_sample_type
      buf << Wire.field_varint(14, @default_sample_type_idx) if @default_sample_type_idx

      buf
    end

    def encode_gzip
      io = StringIO.new(String.new(encoding: 'ASCII-8BIT'))
      io.set_encoding('ASCII-8BIT')
      Zlib::GzipWriter.wrap(io) { |gz| gz.write(encode) }
      io.string
    end

    def write_gzip(path)
      File.binwrite(path, encode_gzip)
    end

    private :encode

    private

    sig { params(s: Hash).returns(String) }
    def encode_sample(s)
      buf = String.new(encoding: 'ASCII-8BIT')
      # field 1: location_id (repeated uint64) — packed for compactness
      if s[:location_ids].any?
        packed = s[:location_ids].map { |id| Wire.varint(id) }.join
        buf << Wire.field_bytes(1, packed)
      end
      # field 2: value (repeated int64) — packed
      if s[:values].any?
        packed = s[:values].map { |v| Wire.varint(v.to_i.negative? ? v.to_i + (1 << 64) : v.to_i) }.join
        buf << Wire.field_bytes(2, packed)
      end
      # field 3: label (repeated Label)
      s[:labels].each do |k, v|
        lab = Wire.field_varint(1, intern(k.to_s))
        case v
        when Integer
          lab += Wire.field_varint(3, v)
        else
          lab += Wire.field_varint(2, intern(v.to_s))
        end
        buf << Wire.field_bytes(3, lab)
      end
      buf
    end

    sig { params(loc: Hash).returns(String) }
    def encode_location(loc)
      sub = Wire.field_varint(1, loc[:id])
      sub += Wire.field_varint(2, loc[:mapping_id]) if loc[:mapping_id].to_i.positive?
      sub += Wire.field_varint(3, loc[:address]) if loc[:address].to_i.positive?
      line_buf = Wire.field_varint(1, loc[:function_id]) +
                 Wire.field_varint(2, loc[:line_no].to_i)
      sub += Wire.field_bytes(4, line_buf)
      sub
    end

    def encode_mapping(m)
      buf = Wire.field_varint(1, m[:id])
      buf += Wire.field_varint(2, m[:memory_start]) if m[:memory_start].positive?
      buf += Wire.field_varint(3, m[:memory_limit]) if m[:memory_limit].positive?
      buf += Wire.field_varint(4, m[:file_offset]) if m[:file_offset].positive?
      buf += Wire.field_varint(5, m[:filename_idx])
      buf += Wire.field_varint(6, m[:build_id_idx]) if m[:build_id_idx].positive?
      buf += Wire.field_varint(7, 1) if m[:has_functions]
      buf += Wire.field_varint(8, 1) if m[:has_filenames]
      buf += Wire.field_varint(9, 1) if m[:has_line_numbers]
      buf += Wire.field_varint(10, 1) if m[:has_inline_frames]
      buf
    end

    sig { params(f: Hash).returns(String) }
    def encode_function(f)
      Wire.field_varint(1, f[:id]) +
        Wire.field_varint(2, f[:name_idx]) +
        Wire.field_varint(3, f[:system_name_idx]) +
        Wire.field_varint(4, f[:filename_idx]) +
        Wire.field_varint(5, f[:start_line])
    end
      private :encode_gzip
    private :intern

end
end
