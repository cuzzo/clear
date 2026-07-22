# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "sorbet-runtime"

module TestMiser
  module Evidence
    class EvidenceScopeMismatch < ArgumentError; end
    class RevisionResolutionError < ArgumentError; end

    class RevisionResolver
      extend T::Sig

      sig { params(repository: String, revision: String).returns(String) }
      def self.resolve!(repository:, revision:)
        stdout, stderr, status = Open3.capture3(
          "git", "rev-parse", "--verify", "#{revision}^{commit}", chdir: repository,
        )
        resolved = stdout.strip
        return resolved if status.success? && resolved.match?(/\A[0-9a-f]{40,64}\z/)

        raise RevisionResolutionError, "could not resolve #{revision.inspect} in #{repository}: #{stderr.strip}"
      rescue Errno::ENOENT => error
        raise RevisionResolutionError, "could not resolve #{revision.inspect} in #{repository}: #{error.message}"
      end
    end

    class SafeSourcePath
      extend T::Sig

      sig { params(path: String).returns(String) }
      def self.relative!(path)
        value = String(path)
        pathname = Pathname.new(value)
        components = value.split(/[\\\/]/)
        if value.empty? || value.include?("\0") || pathname.absolute? || components.include?("..")
          raise RevisionResolutionError, "source path must be a relative path inside the revision: #{path.inspect}"
        end

        normalized = pathname.cleanpath.to_s
        if normalized == "." || normalized == ".." || normalized.start_with?("../")
          raise RevisionResolutionError, "source path must be a relative path inside the revision: #{path.inspect}"
        end

        normalized
      rescue TypeError, ArgumentError => error
        raise RevisionResolutionError, "invalid source path #{path.inspect}: #{error.message}"
      end

      sig { params(root: String, path: String).returns(String) }
      def self.inside!(root, path)
        relative = relative!(path)
        root_real = File.realpath(root)
        candidate = File.join(root_real, relative)
        candidate_real = File.realpath(candidate)
        prefix = "#{root_real}#{File::SEPARATOR}"
        unless candidate_real.start_with?(prefix) && File.file?(candidate_real)
          raise RevisionResolutionError, "source path escapes the archived revision: #{path.inspect}"
        end

        candidate_real
      rescue SystemCallError => error
        raise RevisionResolutionError, "source path is not present in the archived revision: #{path.inspect}: #{error.message}"
      end
    end

    class EvidenceScope < T::Struct
      extend T::Sig

      const :revision, String
      const :selection_scope, String
      const :mutant_corpus_fingerprint, String
      const :test_set_identity, String

      sig do
        params(
          revision: String,
          selection_scope: String,
          mutants: T::Array[T::Hash[String, T.untyped]],
          test_ids: T::Array[String],
          repository: T.nilable(String),
        ).returns(EvidenceScope)
      end
      def self.from_parts(revision:, selection_scope:, mutants:, test_ids:, repository: nil)
        new(
          revision: resolve_revision(revision, repository),
          selection_scope: selection_scope,
          mutant_corpus_fingerprint: digest(mutants.map(&:dup).sort_by { |mutant| JSON.generate(mutant) }),
          test_set_identity: digest(test_ids.uniq.sort),
        )
      end

      sig { returns(String) }
      def fingerprint
        fingerprint_without_self
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "revision" => revision,
          "selection_scope" => selection_scope,
          "mutant_corpus_fingerprint" => mutant_corpus_fingerprint,
          "test_set_identity" => test_set_identity,
          "fingerprint" => fingerprint_without_self,
        }
      end

      sig { params(other: T.nilable(EvidenceScope)).returns(T::Boolean) }
      def compatible?(other)
        !other.nil? && revision == other.revision &&
          selection_scope == other.selection_scope &&
          mutant_corpus_fingerprint == other.mutant_corpus_fingerprint &&
          test_set_identity == other.test_set_identity
      end

      class << self
        extend T::Sig

        sig { params(value: T.untyped).returns(String) }
        def digest(value)
          Digest::SHA256.hexdigest(JSON.generate(value))
        end

        sig { params(revision: String, repository: T.nilable(String)).returns(String) }
        def resolve_revision(revision, repository)
          return revision if repository.nil? || revision == "unknown" || revision.match?(/\A[0-9a-f]{40,64}\z/)

          RevisionResolver.resolve!(repository: repository, revision: revision)
        end
      end

      private

      sig { returns(String) }
      def fingerprint_without_self
        self.class.digest({
          "revision" => revision,
          "selection_scope" => selection_scope,
          "mutant_corpus_fingerprint" => mutant_corpus_fingerprint,
          "test_set_identity" => test_set_identity,
        })
      end
    end
  end
end
