# Typed scope entry for Scope.locals.
# Each entry tracks a variable/function binding with its type, storage, and metadata.
# Back-references its owning Scope via `scope` for state operations.
class SymbolEntry
  attr_accessor :reg, :type, :mutable, :storage, :sync, :rebindable,
                :size, :capabilities, :valid,
                :invalid_reason, :resource, :close_zig, :read,
                :scope,          # Back-reference to owning Scope (set by Scope#declare)
                :ownership_kind, # :value, :collection, :affine, :resource, :rc, :sync
                :takes,          # true if parameter declared with TAKES (callee owns)
                :link_source     # :shared or :multiowned — tracks which strong ref @link was created from

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
