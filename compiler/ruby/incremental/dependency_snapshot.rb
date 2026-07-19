# typed: strict
# frozen_string_literal: true

require "digest"
require "sorbet-runtime"

module Incremental
  class DependencyFingerprint < T::Struct
    const :path, String
    const :digest, String
  end

  # Immutable content fingerprints for every source dependency compiled by a
  # retained ModuleImporter. Content hashes avoid mtime resolution races and
  # make edit/revert behavior deterministic.
  class DependencySnapshot
    extend T::Sig

    sig { returns(T::Array[DependencyFingerprint]) }
    attr_reader :entries

    sig { params(entries: T::Array[DependencyFingerprint]).void }
    def initialize(entries)
      @entries = T.let(entries.sort_by(&:path).freeze, T::Array[DependencyFingerprint])
    end

    sig { params(paths: T::Enumerable[String]).returns(DependencySnapshot) }
    def self.capture(paths)
      entries = paths.map { |path| File.expand_path(path) }.uniq.sort.map do |path|
        DependencyFingerprint.new(path: path, digest: file_digest(path))
      end
      new(entries)
    end

    sig { returns(T::Array[String]) }
    def changed_paths
      @entries.filter_map do |entry|
        entry.path unless self.class.file_digest(entry.path) == entry.digest
      end
    end

    sig { returns(T::Boolean) }
    def current?
      changed_paths.empty?
    end

    sig { params(path: String).returns(String) }
    def self.file_digest(path)
      return "missing" unless File.file?(path)

      Digest::SHA256.file(path).hexdigest
    end
  end
end
