# typed: strict
# frozen_string_literal: true

module NilKill
  # Typed policy for the input-completeness portion of a proof boundary.
  # Report rendering remains responsible for adapting JSON hashes, while this
  # module owns the semantic distinction between absent coverage evidence and
  # a modeled partial corpus.
  module ProofBoundaryInput
    extend T::Sig

    class Coverage < T::Struct
      extend T::Sig

      const :input_completeness, String
      const :blocker_kinds, T::Array[String]

      sig { returns(T::Array[T::Hash[String, String]]) }
      def blockers
        blocker_kinds.map { |kind| { "kind" => kind } }
      end
    end

    MISSING_EVIDENCE = T.let("missing_evidence", String)

    sig { returns(Coverage) }
    def self.unknown_without_coverage
      Coverage.new(input_completeness: "unknown", blocker_kinds: [MISSING_EVIDENCE])
    end

    sig { params(input_completeness: T.nilable(String), blocker_kinds: T::Array[String]).returns(Coverage) }
    def self.review(input_completeness:, blocker_kinds:)
      return unknown_without_coverage if input_completeness.nil? && blocker_kinds.empty?

      Coverage.new(
        input_completeness: input_completeness || (blocker_kinds.empty? ? "unknown" : "partial"),
        blocker_kinds: blocker_kinds
      )
    end

    sig { params(input_completeness: String, blocker_kinds: T::Array[String]).returns(Coverage) }
    def self.explain_unknown(input_completeness:, blocker_kinds:)
      return Coverage.new(input_completeness: input_completeness, blocker_kinds: blocker_kinds) unless input_completeness == "unknown" && blocker_kinds.empty?

      unknown_without_coverage
    end
  end
end
