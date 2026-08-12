# typed: strict
# frozen_string_literal: true

require "digest"
require "fileutils"
require "sorbet-runtime"

module Incremental
  # On-disk cache of compiled REQUIRE units, keyed by content.
  #
  # `clear`'s existing transpile cache keys the WHOLE program on the union of
  # its sources, so touching one file recompiles every imported module. This
  # cache sits one level down: each unit (a file, or a multi-file package
  # group) is stored under a key derived from its own sources, and a stored
  # record stays valid while every source it transitively read is unchanged.
  # Editing one module then recompiles that module and its dependents only.
  #
  # A stored unit is a Marshal image of ModuleImporter::CompiledModule. That
  # graph is plain compiler data apart from intrinsic `validate:` lambdas,
  # which FunctionSignature::AnalysisFacts serializes by registry name.
  class ModuleCache
    extend T::Sig

    DIR_ENV = "CLEAR_MODULE_CACHE_DIR"
    KEY_ENV = "CLEAR_MODULE_CACHE_KEY"
    FORMAT_VERSION = "1"
    # A unit image is large (whole annotated AST) and every compiler edit
    # starts a fresh generation, so cap the directory and drop the coldest
    # records rather than filling the disk. One self-hosted-parser generation
    # is ~330MB, so this holds a few and no more.
    MAX_BYTES = T.let(512 * 1024 * 1024, Integer)

    SourceDigests = T.type_alias { T::Hash[String, String] }

    # Configured cache, or nil when the environment does not ask for one.
    # Only `clear` sets these: every other entry point (specs, fmt, fix)
    # keeps compiling from scratch.
    sig { returns(T.nilable(ModuleCache)) }
    def self.from_env
      dir = ENV[DIR_ENV]
      key = ENV[KEY_ENV]
      return nil if dir.nil? || dir.empty? || key.nil? || key.empty?

      new(dir: dir, compiler_key: key)
    end

    sig { params(dir: String, compiler_key: String).void }
    def initialize(dir:, compiler_key:)
      @dir = T.let(File.expand_path(dir), String)
      @compiler_key = T.let(compiler_key, String)
      # Sources read while compiling the unit currently on top of the stack,
      # so a stored record knows its whole transitive input set.
      @frames = T.let([], T::Array[SourceDigests])
      @digests = T.let({}, SourceDigests)
      # What each unit read, so a unit the importer serves from its in-process
      # cache still contributes its sources to whoever imports it next.
      @sources_by_unit = T.let({}, T::Hash[String, SourceDigests])
    end

    # Record a unit the importer resolved without calling `fetch` -- its
    # in-process cache already had it. Skipping this would let the enclosing
    # unit be stored with an incomplete source list, and so be reused after one
    # of those sources changed.
    sig { params(unit_key: String).void }
    def reuse(unit_key)
      sources = @sources_by_unit[unit_key]
      record_sources(sources) if sources
      nil
    end

    # Return the stored unit when every source behind it is unchanged,
    # otherwise compile it and store the result.
    sig do
      type_parameters(:U)
        .params(unit_key: String, member_paths: T::Array[String], block: T.proc.returns(T.type_parameter(:U)))
        .returns(T.type_parameter(:U))
    end
    def fetch(unit_key, member_paths, &block)
      own = T.let({}, SourceDigests)
      member_paths.each { |path| own[File.expand_path(path)] = digest_of(File.expand_path(path)) }
      path = record_path(unit_key, own)

      stored = load_record(path)
      if stored
        sources = T.cast(stored.fetch("sources"), SourceDigests)
        @sources_by_unit[unit_key] = sources
        record_sources(sources)
        return T.unsafe(stored.fetch("unit"))
      end

      @frames.push({})
      unit = begin
        block.call
      rescue StandardError
        # A failed compile still leaves the stack balanced; nothing is stored.
        @frames.pop
        raise
      end
      sources = T.must(@frames.pop).merge(own)
      @sources_by_unit[unit_key] = sources
      store_record(path, sources, unit)
      record_sources(sources)
      unit
    end

    private

    # Fold a finished unit's sources into whatever unit is compiling it.
    sig { params(sources: SourceDigests).void }
    def record_sources(sources)
      parent = @frames.last
      parent&.merge!(sources)
      nil
    end

    sig { params(path: String).returns(String) }
    def digest_of(path)
      cached = @digests[path]
      return cached if cached

      @digests[path] = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"
    end

    sig { params(unit_key: String, own: SourceDigests).returns(String) }
    def record_path(unit_key, own)
      digest = Digest::SHA256.hexdigest(
        [FORMAT_VERSION, @compiler_key, unit_key, own.sort.flatten.join("\0")].join("\0")
      )
      File.join(@dir, "#{digest}.unit")
    end

    sig { params(path: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def load_record(path)
      return nil unless File.file?(path)

      record = T.let(Marshal.load(File.binread(path)), T.untyped)
      return nil unless record.is_a?(Hash)

      sources = record["sources"]
      return nil unless sources.is_a?(Hash)
      # A record is only usable while every source it read still hashes the
      # same, which is what makes a dependency edit invalidate its dependents.
      return nil unless sources.all? { |source, digest| digest_of(source) == digest }

      record
    rescue ArgumentError, TypeError, Errno::ENOENT
      # Stale image from an older compiler build: recompile and overwrite.
      nil
    end

    sig { params(path: String, sources: SourceDigests, unit: T.untyped).void }
    def store_record(path, sources, unit)
      bytes = Marshal.dump({ "sources" => sources, "unit" => unit })
      FileUtils.mkdir_p(@dir)
      temporary = "#{path}.tmp.#{Process.pid}"
      begin
        File.binwrite(temporary, bytes)
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary)
      end
      prune!
    rescue TypeError => error
      # Something in the graph is not serializable. Compilation is still
      # correct without a stored record, so warn once and carry on.
      warn "[clear] module cache disabled for #{File.basename(path)}: #{error.message}"
    end

    # Drop the least recently used records once the directory outgrows its cap.
    sig { void }
    def prune!
      records = Dir.glob(File.join(@dir, "*.unit")).filter_map do |path|
        stat = File.stat(path)
        [path, stat.size, stat.mtime]
      rescue Errno::ENOENT
        nil
      end
      total = records.sum { |record| record[1] }
      return if total <= MAX_BYTES

      records.sort_by! { |record| record[2] }
      records.each do |path, size, _mtime|
        break if total <= MAX_BYTES

        FileUtils.rm_f(path)
        total -= size
      end
      nil
    end
  end
end
