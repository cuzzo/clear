# typed: strict
# frozen_string_literal: true

require "fileutils"
require "msgpack"
require "sorbet-runtime"

require_relative "dependency_snapshot"
require_relative "program_artifact"

module Incremental
  class PortableCompilation < T::Struct
    const :source, String
    const :artifact, ProgramArtifact
    const :function_counter_snapshots, T::Hash[String, MIRLoweringCounterSnapshot]
    const :dependency_snapshot, DependencySnapshot
  end

  # Versioned, language-independent cache records. Only MessagePack primitive
  # values cross this boundary; live compiler object graphs are never stored.
  class PortableCache
    extend T::Sig

    FORMAT_VERSION = T.let(1, Integer)
    MAX_BYTES = T.let(128 * 1024 * 1024, Integer)

    sig { params(path: String, module_path: String, compiler_fingerprint: String).void }
    def initialize(path:, module_path:, compiler_fingerprint:)
      @path = T.let(File.expand_path(path), String)
      @module_path = T.let(File.expand_path(module_path), String)
      @compiler_fingerprint = T.let(compiler_fingerprint, String)
    end

    sig { returns(T.nilable(PortableCompilation)) }
    def load
      return nil unless File.file?(@path)
      return nil if File.size(@path) > MAX_BYTES

      record = T.let(MessagePack.unpack(File.binread(@path)), T.untyped)
      return nil unless record.is_a?(Hash)
      return nil unless record["format_version"] == FORMAT_VERSION
      return nil unless record["module_path"] == @module_path
      return nil unless record["compiler_fingerprint"] == @compiler_fingerprint

      dependencies = decode_dependencies(record.fetch("dependencies"))
      return nil unless dependencies.current?

      PortableCompilation.new(
        source: String(record.fetch("source")),
        artifact: decode_artifact(record.fetch("artifact")),
        function_counter_snapshots: decode_counter_snapshots(record.fetch("function_counter_snapshots")),
        dependency_snapshot: dependencies,
      )
    rescue Errno::ENOENT, MessagePack::MalformedFormatError, MessagePack::UnknownExtTypeError,
      KeyError, TypeError, ArgumentError
      nil
    end

    sig do
      params(
        source: String,
        artifact: ProgramArtifact,
        function_counter_snapshots: T::Hash[String, MIRLoweringCounterSnapshot],
        dependencies: DependencySnapshot,
      ).void
    end
    def write(source:, artifact:, function_counter_snapshots:, dependencies:)
      record = {
        "format_version" => FORMAT_VERSION,
        "module_path" => @module_path,
        "compiler_fingerprint" => @compiler_fingerprint,
        "source" => source,
        "artifact" => encode_artifact(artifact),
        "function_counter_snapshots" => encode_counter_snapshots(function_counter_snapshots),
        "dependencies" => encode_dependencies(dependencies),
      }
      bytes = MessagePack.pack(record)
      raise ArgumentError, "incremental cache exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES

      FileUtils.mkdir_p(File.dirname(@path))
      temporary = "#{@path}.tmp.#{$$}"
      begin
        File.binwrite(temporary, bytes)
        File.rename(temporary, @path)
      ensure
        FileUtils.rm_f(temporary)
      end
    end

    private

    sig { params(artifact: ProgramArtifact).returns(T::Hash[String, T.untyped]) }
    def encode_artifact(artifact)
      {
        "error_name_enum" => artifact.error_name_enum,
        "footer" => artifact.footer,
        "final_state" => encode_emission_state(artifact.final_state),
        "items" => artifact.items.map do |item|
          {
            "key" => item.key,
            "kind" => item.kind.to_s,
            "name" => item.name,
            "code" => item.code,
            "state_before" => encode_emission_state(item.state_before),
            "state_after" => encode_emission_state(item.state_after),
          }
        end,
      }
    end

    sig { params(value: T.untyped).returns(ProgramArtifact) }
    def decode_artifact(value)
      record = hash!(value)
      items = array!(record.fetch("items")).map do |raw_item|
        item = hash!(raw_item)
        raw_name = item["name"]
        EmittedItem.new(
          key: String(item.fetch("key")),
          kind: String(item.fetch("kind")).to_sym,
          name: raw_name.nil? ? nil : String(raw_name),
          code: String(item.fetch("code")),
          state_before: decode_emission_state(item.fetch("state_before")),
          state_after: decode_emission_state(item.fetch("state_after")),
        )
      end
      ProgramArtifact.new(
        error_name_enum: String(record.fetch("error_name_enum")),
        footer: String(record.fetch("footer")),
        items: items,
        final_state: decode_emission_state(record.fetch("final_state")),
      )
    end

    sig { params(state: MIREmitter::EmissionState).returns(T::Hash[String, T.untyped]) }
    def encode_emission_state(state)
      {
        "symbol_literals" => state.symbol_literals,
        "uses_c_callback" => state.uses_c_callback,
        "if_bind_counter" => state.if_bind_counter,
        "discard_counter" => state.discard_counter,
        "deep_copy_counter" => state.deep_copy_counter,
        "items_block_counter" => state.items_block_counter,
        "owned_slice_counter" => state.owned_slice_counter,
      }
    end

    sig { params(value: T.untyped).returns(MIREmitter::EmissionState) }
    def decode_emission_state(value)
      record = hash!(value)
      raw_symbols = hash!(record.fetch("symbol_literals"))
      symbols = T.let({}, T::Hash[String, String])
      raw_symbols.each { |key, name| symbols[String(key)] = String(name) }
      counter = record["if_bind_counter"]
      MIREmitter::EmissionState.new(
        symbol_literals: symbols,
        uses_c_callback: boolean!(record.fetch("uses_c_callback")),
        if_bind_counter: counter.nil? ? nil : Integer(counter),
        discard_counter: Integer(record.fetch("discard_counter")),
        deep_copy_counter: Integer(record.fetch("deep_copy_counter")),
        items_block_counter: Integer(record.fetch("items_block_counter")),
        owned_slice_counter: Integer(record.fetch("owned_slice_counter")),
      )
    end

    sig { params(snapshots: T::Hash[String, MIRLoweringCounterSnapshot]).returns(T::Hash[String, T.untyped]) }
    def encode_counter_snapshots(snapshots)
      snapshots.transform_values do |snapshot|
        snapshot.values.to_h { |kind, value| [kind.serialize, value] }
      end
    end

    sig { params(value: T.untyped).returns(T::Hash[String, MIRLoweringCounterSnapshot]) }
    def decode_counter_snapshots(value)
      result = T.let({}, T::Hash[String, MIRLoweringCounterSnapshot])
      hash!(value).each do |name, raw_snapshot|
        values = T.let({}, T::Hash[MIRLoweringCounterKind, Integer])
        hash!(raw_snapshot).each do |kind, counter|
          values[MIRLoweringCounterKind.deserialize(String(kind))] = Integer(counter)
        end
        result[String(name)] = MIRLoweringCounterSnapshot.new(values: values)
      end
      result
    end

    sig { params(snapshot: DependencySnapshot).returns(T::Array[T::Hash[String, String]]) }
    def encode_dependencies(snapshot)
      snapshot.entries.map { |entry| { "path" => entry.path, "digest" => entry.digest } }
    end

    sig { params(value: T.untyped).returns(DependencySnapshot) }
    def decode_dependencies(value)
      entries = array!(value).map do |raw_entry|
        entry = hash!(raw_entry)
        DependencyFingerprint.new(
          path: String(entry.fetch("path")),
          digest: String(entry.fetch("digest")),
        )
      end
      DependencySnapshot.new(entries)
    end

    sig { params(value: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
    def hash!(value)
      raise TypeError, "expected cache map" unless value.is_a?(Hash)

      value
    end

    sig { params(value: T.untyped).returns(T::Array[T.untyped]) }
    def array!(value)
      raise TypeError, "expected cache array" unless value.is_a?(Array)

      value
    end

    sig { params(value: T.untyped).returns(T::Boolean) }
    def boolean!(value)
      raise TypeError, "expected cache boolean" unless value == true || value == false

      value
    end
  end
end
