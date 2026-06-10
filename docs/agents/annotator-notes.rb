# typed: strict
# frozen_string_literal: true

# Annotator cleanup notes:
#
# - Error messages like in emit_service_required_error! should be in a common
#   mapping file.
# - $stderr.puts should not exist. The annotator should route diagnostics through
#   error! or another explicit diagnostic channel.
# - Why do we have Kernel.raise instead of error!?
# - Why do we have raise ... instead of error!?
# - error!(..., hint: ...) hints should also be stored in the mapping table and
#   looked up by string.
# - If needed, hints can be looked up by ID/Symbol and provided with context. Do
#   not build large error strings or hints in the annotator or its helpers.
# - Why is visit_FunctionDef directly in annotator instead of in the function
#   analysis helper? Look for all things like this which should belong elsewhere.
# - Legacy @reentrant bridging should not exist. There should be no legacy
#   @reentrant syntax; there is only EFFECTS reentrant.
# - visit() accepts a Symbol sometimes. Figure out why this exists; it seems
#   wrong and should likely be fixed at the source.
# - Builtin special cases should not live directly in the annotator. Handle this
#   properly in std_lib.rb and allow the annotator to register anything from that
#   registry without hardcoded special cases.
# - Why does semantic_index need to be an ivar? It may be better to pass it
#   directly to the functions that need it.
#
# Current pass status:
#
# - Fixed: emit_service_required_error! no longer builds the large diagnostic
#   body in the annotator. The message is now DiagnosticRegistry data keyed by
#   STACK_NEEDS_SERVICE_FIXABLE.
# - Fixed: REQUIRE importer guidance no longer passes an ad-hoc hint string;
#   the complete guidance is in DiagnosticRegistry.
# - Fixed: the direct $stderr.puts stack-sizing warning in the annotator now
#   routes through warning! with registry-backed text.
# - Fixed: builtin globals and builtin resource/static-call types are registered
#   from std_lib.rb environment data instead of hardcoded annotator setup.
# - Fixed: visit() no longer accepts Symbol and silently ignores it. Traversal is
#   typed to AST::Node; type symbols should be fixed at the caller.
# - Fixed: visit_FunctionDef and visit_LambdaLit moved to the function-analysis
#   helper.
# - Fixed: tail-call and fiber-stack reentrance validation moved out of the
#   annotator shell and into ReentranceBridge, where the reentrance policy
#   already lives.
# - Fixed: @service clear-fix generation now uses the concrete AST::BgBlock
#   token contract instead of dynamic respond_to? probing.
# - Fixed: RequireNode import resolution moved from the annotator shell into
#   Annotator::Phases::ImportResolution.
# - Fixed: UnionVariantLit visiting moved from the annotator shell into
#   UnionAnalysis beside union schema and field validation.
# - Fixed: held-lock tracking now uses the typed AST::Locatable token contract
#   instead of probing capability targets with respond_to?(:token).
# - Fixed: annotator error hints no longer embed local string literals. Existing
#   source-error guidance now lives in DiagnosticRegistry templates/fix_hint
#   metadata.
# - Fixed: an architecture invariant now blocks reintroducing local
#   `hint: "..."` strings under src/annotator.
# - Fixed: observable terminal mismatch now routes through
#   :OBSERVABLE_TERMINAL_MISMATCH instead of constructing CompilerError
#   directly in the annotator.
# - Fixed: an architecture invariant now blocks direct CompilerError.new under
#   src/annotator.
# - Not changed: Kernel.raise / raise sites that enforce compiler invariants
#   stay as hard failures. They are not source diagnostics and should not route
#   through error! unless they become recoverable user-facing errors.
# - Not changed: legacy @reentrant bridging. The parser, clear-fix migration,
#   function-type constraints, and stack/FSM tests still intentionally exercise
#   the migration path. Deleting it is a separate language compatibility change.
# - Not changed: semantic_index remains the frontend result handoff used by the
#   compiler frontend and importer. Removing the ivar should be part of a broader
#   API change that returns an annotation result object.
# - Follow-up: non-fatal note! telemetry strings remain in lock, pipeline, and
#   async auto-pinning paths. They are informational compiler telemetry rather
#   than source errors; move them to a note registry only if/when notes become
#   first-class diagnostic codes.
