# typed: true
require "sorbet-runtime"

module AST
    extend T::Sig

  # Single source of truth for CLEAR error kinds and types.
  #
  # ErrorKind is the closed taxonomy of 6 coarse categories. It mirrors
  # runtime.zig's ErrorKind enum exactly.
  #
  # ErrorType is an open, auto-registered set. The stdlib seeds it with
  # the lock-safety types at stable low IDs (LockTimeout=1, LockCycle=2,
  # Deadlock=3). User types get ids from 4 onwards in order of first
  # use. First use requires a kind (at RAISE / OR EXIT); subsequent uses
  # can provide only the type and the kind is looked up. Collisions
  # (same type, different kind) produce a diagnostic pointing at the
  # first registration site.
  #
  # The enum IDs are emitted at compile time as a per-program Zig header:
  #   pub const ErrorName = enum(u32) { None = 0, LockTimeout = 1, ... };
  # runtime.zig stores ErrorContext.error_name as plain u32; dispatch in
  # generated user code compares to @intFromEnum(ErrorName.<Sym>).

  ERROR_KINDS = %i[Transient Input System NotFound Permission Canceled].freeze

  # Stable stdlib-type IDs. runtime.zig's zigErrorToName hardcodes these
  # when mapping a Zig error (`error.LockTimeout`, etc) to a u32
  # ErrorName id. Keep these in sync with the ids baked into the
  # generated ErrorName enum.
  ERROR_NAME_NONE                 = 0
  ERROR_NAME_LOCK_TIMEOUT         = 1
  ERROR_NAME_LOCK_CYCLE           = 2
  ERROR_NAME_DEADLOCK             = 3
  ERROR_NAME_UNEXPECTED_RECURSION = 4
  ERROR_NAME_MAX_DEPTH_EXCEEDED   = 5
  # True-Sync-Polymorphism (#324): the legacy `Conflict` is split into
  # `MvccConflict` (versioned commit retry exhausted) and
  # `AtomicConflict` (atomic CAS retry exhausted). MvccConflict
  # inherits the legacy id=6 because it's the closest semantic
  # successor (the same bridging path: error.UpdateRetriesExhausted ->
  # MvccConflict). AtomicConflict is brand-new at id=7. Internal caps
  # land in #330 (atomic_ptr 256, versioned 64).
  ERROR_NAME_MVCC_CONFLICT        = 6
  ERROR_NAME_ATOMIC_CONFLICT      = 7
  ERROR_NAME_GUARD_FAIL           = 8
  ERROR_NAME_PRECONDITION_FAIL  = 9
  ERROR_NAME_USER_FIRST           = 10

  # Mutable registry. Seeded with the five stdlib types and extended
  # by the annotator on first use. Hash shape:
  #   <type_sym> => {
  #     kind: :Kind,
  #     zig_name: "<TypeName>",
  #     id: <u32>,
  #     first_site: <Token|nil>,  # for collision diagnostics
  #   }
  # Not thread-safe; the compiler is single-threaded per-program.
  ERROR_TYPES = {
    LockTimeout:         { kind: :Transient, zig_name: "LockTimeout",         id: ERROR_NAME_LOCK_TIMEOUT,         first_site: nil },
    LockCycle:           { kind: :Transient, zig_name: "LockCycle",           id: ERROR_NAME_LOCK_CYCLE,           first_site: nil },
    Deadlock:            { kind: :System,    zig_name: "Deadlock",            id: ERROR_NAME_DEADLOCK,             first_site: nil },
    UnexpectedRecursion: { kind: :System,    zig_name: "UnexpectedRecursion", id: ERROR_NAME_UNEXPECTED_RECURSION, first_site: nil },
    MaxDepthExceeded:    { kind: :System,    zig_name: "MaxDepthExceeded",    id: ERROR_NAME_MAX_DEPTH_EXCEEDED,   first_site: nil },
    MvccConflict:        { kind: :Transient, zig_name: "MvccConflict",        id: ERROR_NAME_MVCC_CONFLICT,        first_site: nil },
    AtomicConflict:      { kind: :Transient, zig_name: "AtomicConflict",      id: ERROR_NAME_ATOMIC_CONFLICT,      first_site: nil },
    GuardFail:           { kind: :Transient, zig_name: "GuardFail",           id: ERROR_NAME_GUARD_FAIL,           first_site: nil },
    PreconditionFail:  { kind: :Input,     zig_name: "PreconditionFail",  id: ERROR_NAME_PRECONDITION_FAIL,  first_site: nil },
  }

  # Counter for the next user-type id. Reset on a per-program basis via
  # reset_user_types! (called at the start of each SemanticAnnotator run
  # so parallel rspec runs don't bleed state).
  @next_user_id = ERROR_NAME_USER_FIRST
  @stdlib_frozen = ERROR_TYPES.keys.to_set
  class << self
    attr_reader :next_user_id, :stdlib_frozen
  end

  sig { params(sym: T.nilable(Symbol)).returns(T::Boolean) }
  def self.error_kind?(sym)
    ERROR_KINDS.include?(sym)
  end

  sig { params(sym: T.nilable(Symbol)).returns(T::Boolean) }
  def self.error_type?(sym)
    ERROR_TYPES.key?(sym)
  end

  sig { params(sym: Symbol).returns(T.nilable(Symbol)) }
  def self.kind_of_type(sym)
    ERROR_TYPES.dig(sym, :kind)
  end

  sig { params(sym: Symbol).returns(T.nilable(String)) }
  def self.zig_name_of_type(sym)
    ERROR_TYPES.dig(sym, :zig_name)
  end

  sig { params(sym: Symbol).returns(T.untyped) }
  def self.id_of_type(sym)
    ERROR_TYPES.dig(sym, :id)
  end

  # Register a user-defined type with its kind. First call for a given
  # sym seeds the entry and assigns an id; subsequent calls verify the
  # kind matches. On mismatch, yields a diagnostic (the caller emits it
  # via error!); on stdlib-collision (user tries to redefine a stdlib
  # type with a different kind), same.
  #
  # Returns [existed?, conflict?]. conflict is a Hash
  #   { existing_kind:, given_kind:, first_site:, is_stdlib: }
  # or nil when registration succeeded (or was a no-op re-use).
  sig { params(type_sym: Symbol, kind_sym: Symbol, site_token: T.untyped).returns(Array) }
  def self.register_type!(type_sym, kind_sym, site_token: nil)
    entry = ERROR_TYPES[type_sym]
    if entry.nil?
      id = @next_user_id
      @next_user_id += 1
      ERROR_TYPES[type_sym] = {
        kind: kind_sym,
        zig_name: type_sym.to_s,
        id: id,
        first_site: site_token,
      }
      return [false, nil]
    end
    return [true, nil] if entry[:kind] == kind_sym
    [true, {
      existing_kind: entry[:kind],
      given_kind:    kind_sym,
      first_site:    entry[:first_site],
      is_stdlib:     @stdlib_frozen.include?(type_sym),
    }]
  end

  # Reset the user-registered portion of the registry. Called at the
  # start of every SemanticAnnotator run so test runs don't leak state
  # from one parsed program into the next. Stdlib entries are preserved.
  sig { returns(Integer) }
  def self.reset_user_types!
    ERROR_TYPES.keys.each do |sym|
      ERROR_TYPES.delete(sym) unless @stdlib_frozen.include?(sym)
    end
    @next_user_id = ERROR_NAME_USER_FIRST
  end

  # Enum-ready list of (sym, id) pairs. Used by mir-lowering to emit
  # the `pub const ErrorName = enum(u32) { ... };` header at the top
  # of the generated Zig program. Sorted by id so the emitted enum is
  # deterministic across runs.
  sig { returns(Array) }
  def self.enum_entries
    [[:None, ERROR_NAME_NONE]] + ERROR_TYPES.map { |sym, meta| [sym, meta[:id]] }.sort_by(&:last)
  end

  # Returns the Array of error-type Symbols whose :kind == kind. Used by
  # the annotator to expand kind selectors into their member types.
  sig { params(kind: Symbol).returns(T::Array[Symbol]) }
  def self.types_for_kind(kind)
    ERROR_TYPES.select { |_, meta| meta[:kind] == kind }.keys
  end
end
