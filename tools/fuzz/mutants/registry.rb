# Targeted safety mutants for the fuzz harness.
#
# These are not broad source-level mutations. Each entry deliberately disables
# one ownership-safety rule and names the fuzz templates that should notice.

module FuzzMutants
  ROOT = File.expand_path('../../..', __dir__)
  PATCH_DIR = File.expand_path('patches', __dir__)

  Mutant = Struct.new(
    :name,
    :description,
    :invariant,
    :patch,
    :templates,
    :kill,
    keyword_init: true
  )

  REGISTRY = [
    Mutant.new(
      name: :allow_with_alias_return,
      description: 'Disable RETURN rejection for WITH-scoped aliases.',
      invariant: :alias_non_escape,
      patch: File.join(PATCH_DIR, 'allow_with_alias_return.patch'),
      templates: [:access_gate],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :lower_if_cond_pending_leak,
      description: 'Stop lower_if draining the condition\'s @pending_stmts ' \
                   'before lowering the then-body. Hoisted temps from a ' \
                   '`maybe() OR ""` cond then leak into the then-body, ' \
                   'declared after the cond that references them. The ' \
                   'cond_or_fallback :if cells fail to compile (Zig: ' \
                   'use of undeclared identifier __tmp_N).',
      invariant: :bug1_hoist_ordering,
      patch: File.join(PATCH_DIR, 'lower_if_cond_pending_leak.patch'),
      templates: [:cond_or_fallback],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :cleanup_required_finalizer,
      description: 'Disable MIRChecker cleanup-required finalizer validation. ' \
                   'A frame AllocMark whose Type owns cleanup-bearing data can ' \
                   'then pass without Cleanup/ErrCleanup/TransferMark.',
      invariant: :cleanup_required_finalizer,
      patch: File.join(PATCH_DIR, 'cleanup_required_finalizer.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
  ].freeze

  def self.find(name)
    REGISTRY.find { |m| m.name == name.to_sym }
  end
end
