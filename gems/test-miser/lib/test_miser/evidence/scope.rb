# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "sorbet-runtime"

module TestMiser
  module Evidence
    class EvidenceScopeMismatch < ArgumentError; end

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
        ).returns(EvidenceScope)
      end
      def self.from_parts(revision:, selection_scope:, mutants:, test_ids:)
        new(
          revision: revision,
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
