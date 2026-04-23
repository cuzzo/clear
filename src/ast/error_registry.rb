module AST
  # Single source of truth for CLEAR error kinds and specific error types.
  #
  # ErrorKind is the coarse taxonomy users match with `ON <KIND>` (e.g.
  # `ON TRANSIENT`). The 6 kinds mirror the ErrorKind enum in runtime.zig
  # and must stay in sync.
  #
  # ErrorType is a specific error name (e.g. `:LockTimeout`) that users
  # match with `ON :Sym`. Every error type belongs to exactly one kind.
  # `zig_name` is the spelling the Zig runtime uses as `error.<name>`.
  # New stdlib errors are added here and nowhere else.

  ERROR_KINDS = %i[Transient Input System NotFound Permission Canceled].freeze

  ERROR_TYPES = {
    LockTimeout: { kind: :Transient, zig_name: "LockTimeout" },
    LockCycle:   { kind: :Transient, zig_name: "LockCycle"   },
    Deadlock:    { kind: :System,    zig_name: "Deadlock"    },
  }.freeze

  def self.error_kind?(sym)
    ERROR_KINDS.include?(sym)
  end

  def self.error_type?(sym)
    ERROR_TYPES.key?(sym)
  end

  def self.kind_of_type(sym)
    ERROR_TYPES.dig(sym, :kind)
  end

  def self.zig_name_of_type(sym)
    ERROR_TYPES.dig(sym, :zig_name)
  end

  # Returns the Array of error-type Symbols whose :kind == kind. Used by
  # annotator to expand `ON TRANSIENT` into its member types, and by mir
  # lowering to emit the matching Zig error names.
  def self.types_for_kind(kind)
    ERROR_TYPES.select { |_, meta| meta[:kind] == kind }.keys
  end
end
