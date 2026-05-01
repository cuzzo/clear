# Typed scope entry for Scope.locals.
# Each entry tracks a variable/function binding with its type, storage, and metadata.
# Back-references its owning Scope via `scope` for state operations.
#
# Mutation contract (read before adding a post-annotation mutator):
#
# Most fields are scope-local (live, moved, borrowed_alias, valid, read,
# non_escaping). Mutating them on a nested-scope copy is correct.
#
# Storage-axis fields (storage, sync, type, capabilities) are
# function-global. After annotation, `Scope.dup` has produced one entry
# per nested scope that captured the binding. Any pass that mutates a
# storage-axis field on a parameter (e.g.
# `EscapeAnalysis.propagate_caller_sync!`) MUST mutate
# `param[:symbol]` (the function-level entry), and any consumer that
# reads from a captured SymbolEntry reference must refresh through
# `Scope.live_param_syms(fn)` first. See the doc comment on
# `Scope#initialize_copy` for the full rationale.
class SymbolEntry
  attr_accessor :reg, :type, :mutable, :storage, :sync, :rebindable,
                :size, :capabilities, :valid,
                :invalid_reason, :resource, :close_zig, :read,
                :scope,          # Back-reference to owning Scope (set by Scope#declare)
                :ownership_kind, # :value, :collection, :affine, :resource, :rc, :sync
                :takes,          # true if parameter declared with TAKES (callee owns)
                :is_param,       # true when entry was declared as a function parameter
                :link_source,    # :shared or :multiowned — tracks which strong ref @link was created from
                :non_escaping,   # true for WITH-scoped bindings — cannot be returned, stored, or TAKES'd
                :borrowed_alias  # true only for BORROWED/RESTRICT aliases — fiber capture is stack-UAF

  def initialize(reg:, type:, mutable:, storage:, sync: nil, rebindable: false,
                 size: 0, capabilities: Set.new,
                 valid: true, invalid_reason: nil, resource: nil, close_zig: nil)
    @reg = reg
    @type = type
    @mutable = mutable
    @storage = storage
    @sync = sync
    @rebindable = rebindable
    @size = size
    @capabilities = capabilities
    @valid = valid
    @invalid_reason = invalid_reason
    @resource = resource
    @close_zig = close_zig
  end
end
