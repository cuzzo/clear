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
      name: :escape_struct_field_walker,
      description: 'Revert StructLit/UnionVariantLit/ListLit recursion in ' \
                   'LoopFrameAnalysis.escapes_to_outer?. A frame-local ' \
                   'wrapped in a struct field initialiser then stops ' \
                   'looking like an escape; the wrap_kind=:struct_field ' \
                   'cells in nested_loop_escape fail (double-free at ' \
                   'runtime).',
      invariant: :inv_5_frame_escape,
      patch: File.join(PATCH_DIR, 'escape_struct_field_walker.patch'),
      templates: [:nested_loop_escape],
      kill: { bucket: :fail, min_delta: 1 }
    ),
  ].freeze

  def self.find(name)
    REGISTRY.find { |m| m.name == name.to_sym }
  end
end
