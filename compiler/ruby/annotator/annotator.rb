# typed: strict
# frozen_string_literal: true

require_relative "phases/type_analysis_session"

# Compatibility construction boundary. Existing callers keep using
# SemanticAnnotator.new while receiving the phase-owned executor directly;
# no annotator-wide receiver or duplicate state is created here.
class SemanticAnnotator
  class << self
    extend T::Sig

    sig do
      params(
        importer: T.nilable(ModuleImporter),
        compiler: T.nilable(ModuleImporter),
        source_dir: T.nilable(String),
        strict_test: T::Boolean,
        source_code: T.nilable(String)
      ).returns(Annotator::Phases::TypeAnalysisSession)
    end
    def new(importer: nil, compiler: nil, source_dir: nil, strict_test: false, source_code: nil)
      Annotator::Phases::TypeAnalysisSession.new(
        importer: importer,
        compiler: compiler,
        source_dir: source_dir,
        strict_test: strict_test,
        source_code: source_code
      )
    end
  end

  ReceiverState = Annotator::Phases::TypeAnalysisSession::TraversalState
  HeldLockEntry = Annotator::Phases::TypeAnalysisSession::HeldLockEntry
  HeldLockTypeEntry = Annotator::Phases::TypeAnalysisSession::HeldLockTypeEntry
  DeadlockEscape = T.type_alias { Annotator::Phases::TypeAnalysisSession::DeadlockEscape }
  BG_SOURCE_OPAQUE_AST_NODES = Annotator::Phases::TypeAnalysisSession::BG_SOURCE_OPAQUE_AST_NODES
  SYNC_DOES_NOT_BIND_CAPTURE = Annotator::Phases::TypeAnalysisSession::SYNC_DOES_NOT_BIND_CAPTURE
  STORAGE_OUTLIVES_DECLARING_SCOPE = Annotator::Phases::TypeAnalysisSession::STORAGE_OUTLIVES_DECLARING_SCOPE
end
