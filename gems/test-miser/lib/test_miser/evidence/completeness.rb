# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module TestMiser
  module Evidence
    class EvidenceCompleteness < T::Struct
      extend T::Sig

      const :status, T.nilable(T::Boolean)
      const :reason, T.nilable(String)

      sig { returns(T::Boolean) }
      def complete?
        status == true
      end

      sig { returns(String) }
      def label
        return "complete" if status == true
        return "incomplete" if status == false

        "unknown"
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {"status" => label, "complete" => status, "reason" => reason}.compact
      end
    end
  end
end
