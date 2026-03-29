# Typed replacement for the raw Hash entries in Scope.locals.
# Backward-compatible: entry[:type], entry[:storage] = :heap, entry.dig(:sync) all work.
class SymbolEntry
  attr_accessor :reg, :type, :mutable, :storage, :sync, :rebindable,
                :size, :capabilities, :borrowed_paths, :valid,
                :invalid_reason, :resource, :close_zig, :read

  FIELD_MAP = {
    reg: :reg, type: :type, mutable: :mutable, storage: :storage,
    sync: :sync, rebindable: :rebindable, size: :size,
    capabilities: :capabilities, borrowed_paths: :borrowed_paths,
    valid: :valid, invalid_reason: :invalid_reason, resource: :resource,
    close_zig: :close_zig, read: :read
  }.freeze

  def initialize(reg:, type:, mutable:, storage:, sync: nil, rebindable: false,
                 size: 0, capabilities: Set.new, borrowed_paths: [],
                 valid: true, invalid_reason: nil, resource: nil, close_zig: nil)
    @reg = reg
    @type = type
    @mutable = mutable
    @storage = storage
    @sync = sync
    @rebindable = rebindable
    @size = size
    @capabilities = capabilities
    @borrowed_paths = borrowed_paths
    @valid = valid
    @invalid_reason = invalid_reason
    @resource = resource
    @close_zig = close_zig
  end

  # --- Hash-compatibility layer (for existing entry[:key] access patterns) ---

  def [](key)
    attr = FIELD_MAP[key]
    attr ? send(attr) : nil
  end

  def []=(key, value)
    attr = FIELD_MAP[key]
    send(:"#{attr}=", value) if attr
  end

  def dig(*keys)
    val = self[keys.first]
    keys.length == 1 ? val : (val.respond_to?(:dig) ? val.dig(*keys[1..]) : nil)
  end

  def key?(key)
    FIELD_MAP.key?(key)
  end
end
