# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"
require_relative "capability_evidence"

module Annotator
  module Phases
    # Complete handoff from body typing to whole-program capability auditing.
    # It prevents callers from mixing facts and configuration from different
    # sessions or invoking the audit before type analysis relinquishes them.
    class CapabilityAuditRequest < T::Struct
      const :inputs, CapabilityAuditInputs
      const :source_code, T.nilable(String)
      const :language_mode, Symbol
      const :strict_test, T::Boolean
    end

    class TypeAnalysisHandoff < T::Struct
      const :typed_program, TypedProgramFacts
      const :audit_request, CapabilityAuditRequest
    end
  end
end
