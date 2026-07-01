# typed: strict
# frozen_string_literal: true

# CaptureStrategy -- classifies how a BG (and other fiber-like) capture
# must be lowered, based on the capture's type and user-supplied
# capture-site annotations (GIVE / COPY).
#
# The central claim is that every capture falls into exactly ONE of the
# five strategies below, and each strategy dictates the complete
# treatment: the ctx-struct field Zig type, the ctx-init RHS, and which
# MIRChecker marker nodes must be emitted. With this classifier, the
# existing capture paths in mir_lowering.lower_bg_block (pointer_captures,
# resource_captures, promoted_names, capture_close_plans, ad-hoc per-type
# forks) collapse to: classify -> dispatch.
#
# Why a classifier and not piecewise decisions:
# - Today the lowering asks "is this a pointer?" / "is this a string?" /
#   "is this a resource?" separately, with each answer driving a
#   different hash/set. The piecewise default ("none of the above -> byte
#   copy the header") is the gap that lets borrows slip through into
#   async scopes and UAF at runtime.
# - A single exhaustive classifier has no silent default: everything
#   outside an explicit strategy maps to Refuse, which raises a
#   CLEAR-level diagnostic at lowering time.
#
# Why this keeps MIRChecker simple:
# - Strategies prescribe which existing marker nodes (MoveMark,
#   AllocMark, Cleanup) the lowering must emit. The existing seven
#   invariants of MIRChecker then catch any misuse. No new invariant is
#   required; the checker stays fixed.
#
# Migration stance: this file is PURE CLASSIFICATION. Step 1 of the
# migration plan (docs/agents/vm-bugs.md) adds it but does not call it
# from lower_bg_block yet. Step 2 onwards converts the emission.

require "sorbet-runtime"

module CaptureStrategy
    extend T::Sig

  class AllocMarkPlan < T::Struct
    const :ctx_init_name, String
    const :alloc_sym, Symbol
  end

  class CleanupPlan < T::Struct
    const :ctx_init_name, String
    const :alloc_sym, Symbol
  end

  class MoveMarkPlan < T::Struct
    const :source_name, String
  end

  MarkerPlanEntry = T.type_alias { T.any(AllocMarkPlan, CleanupPlan, MoveMarkPlan) }

  # A capture that can be byte-copied into the ctx struct: primitives,
  # rodata strings, enums, small all-primitive structs. No markers
  # required; no runtime ownership transfer; the fiber sees a value
  # equal to but independent of the outer binding.
  class ByValue < T::Struct
    extend T::Sig
    const :zig_type, String
    const :ctx_init_name, String

    sig { returns(T::Array[MarkerPlanEntry]) }
    def marker_plan = []
    sig { returns(T::Boolean) }
    def needs_capture_site_annotation? = false
  end

  # A capture of an @multiowned or @shared (Rc/Arc) container. The BG
  # capture clones the reference count; the fiber holds its own strong
  # ref, which is released on fiber cleanup via the existing
  # retain/release machinery. No new markers required beyond the
  # existing RC discipline.
  class RcClone < T::Struct
    extend T::Sig
    const :zig_type, String
    const :ctx_init_name, String

    sig { returns(T::Array[MarkerPlanEntry]) }
    def marker_plan = []
    sig { returns(T::Boolean) }
    def needs_capture_site_annotation? = false
  end

  # Explicit deep-copy at the BG capture site (user wrote COPY x). The
  # fiber's ctx owns a freshly-allocated heap copy; the outer binding is
  # untouched. Emits a new AllocMark inside the BG body and pairs it
  # with a fiber-scope Cleanup. INV #1 / INV #2 verify the pair.
  class FreshHeapCopy < T::Struct
    extend T::Sig
    const :zig_type, String
    const :ctx_init_name, String
    const :alloc_sym, Symbol

    sig { returns(T::Array[MarkerPlanEntry]) }
    def marker_plan
      [
        AllocMarkPlan.new(ctx_init_name: ctx_init_name, alloc_sym: alloc_sym),
        CleanupPlan.new(ctx_init_name: ctx_init_name, alloc_sym: alloc_sym),
      ]
    end
    sig { returns(T::Boolean) }
    def needs_capture_site_annotation? = true
  end

  # Explicit ownership transfer at the BG capture site (user wrote GIVE
  # x). The outer binding's Cleanup is suppressed (MoveMark on the
  # source) and the ctx takes over. The existing INV #2 guard-check
  # machinery already covers this: after MoveMark, the outer Cleanup
  # must be guarded (defer if (!x_moved) cleanup(x)), and the ctx's
  # cleanup path takes over on fiber exit.
  class MoveInto < T::Struct
    extend T::Sig
    const :zig_type, String
    const :ctx_init_name, String
    const :source_name, String

    sig { returns(T::Array[MarkerPlanEntry]) }
    def marker_plan
      [MoveMarkPlan.new(source_name: source_name)]
    end
    sig { returns(T::Boolean) }
    def needs_capture_site_annotation? = true
  end

  # Fail-closed classification: a heap-backed or borrow-like capture
  # reached the classifier without the user providing COPY/GIVE. Raise
  # at lowering time; do not produce MIR. The diagnostic is a
  # CLEAR-level error with a source span, so the user sees their own
  # code, not a Zig type error later.
  class Refuse < T::Struct
    extend T::Sig
    const :reason, Symbol
    const :owner_name, String

    sig { returns(T::Array[MarkerPlanEntry]) }
    def marker_plan = []
    sig { returns(T::Boolean) }
    def needs_capture_site_annotation? = false
  end

  Strategy = T.type_alias { T.any(ByValue, RcClone, FreshHeapCopy, MoveInto, Refuse) }

  # Carries the per-capture user-supplied annotations (COPY / GIVE)
  # collected at the BG site. Populated by the parser / AST walker; read
  # here. Until capture-site GIVE / COPY surface syntax lands, both sets
  # are empty and the classifier will Refuse heap-backed captures.
  #
  # copied_names  : Set<String>   -- names the user wrapped in COPY at BG site
  # moved_names   : Set<String>   -- names the user wrapped in GIVE at BG site
  class CaptureSiteInfo < T::Struct
    extend T::Sig
    const :copied_names, T::Set[String]
    const :moved_names, T::Set[String]

    sig { params(name: String).returns(T::Boolean) }
    def copied?(name) = copied_names.include?(name)
    sig { params(name: String).returns(T::Boolean) }
    def moved?(name)  = moved_names.include?(name)

    sig { returns(CaptureStrategy::CaptureSiteInfo) }
    def self.empty
      new(copied_names: Set.new, moved_names: Set.new)
    end
  end

  # Primary entry point. Returns exactly one of the five strategies above.
  #
  # name           : String          -- capture name (for diagnostics + marker naming)
  # type           : Type            -- the capture's static type (unwrapped)
  # site_info      : CaptureSiteInfo -- what the user wrote at the BG site
  # is_resource    : Boolean         -- true when escape-analysis already
  #                                     flagged this capture as a resource
  #                                     (File, TCPClient, etc.); the
  #                                     existing resource_captures machinery
  #                                     handles the ownership transfer.
  sig { params(name: String, type: Type, site_info: CaptureStrategy::CaptureSiteInfo, is_resource: T::Boolean, schema_lookup: T.nilable(Proc)).returns(Strategy) }
  def self.classify(name:, type:, site_info:, is_resource: false, schema_lookup: nil)
    zig_t = field_zig_type(type)

    # 1. Explicit user annotation wins: COPY/GIVE apply regardless of
    #    type, as long as the type supports the operation. (We don't
    #    second-guess: if the user wrote GIVE on a primitive, MoveInto
    #    still works because MoveMark on a primitive is a no-op.)
    if site_info.moved?(name)
      return MoveInto.new(zig_type: zig_t, ctx_init_name: name, source_name: name)
    end

    if site_info.copied?(name)
      alloc_sym = fiber_copy_alloc_for(type)
      return FreshHeapCopy.new(zig_type: zig_t, ctx_init_name: name, alloc_sym: alloc_sym)
    end

    # 2. Resource captures (File, TCPClient, etc.) already have their
    #    ownership transfer tracked by escape_analysis; the BG body's
    #    close_plans machinery emits the right defer for the fiber.
    #    Treat as MoveInto so the outer scope's cleanup is suppressed.
    if is_resource
      return MoveInto.new(zig_type: zig_t, ctx_init_name: name, source_name: name)
    end

    # 3. A plain promise handle (~T) is an owned affine capability. Capturing
    #    it into a fiber transfers the one right to NEXT it. Shared promises
    #    and stream cursors are handled by their own sharing/resource rules.
    if owned_affine_promise_handle?(type)
      return MoveInto.new(zig_type: zig_t, ctx_init_name: name, source_name: name)
    end

    # 4. @multiowned / @shared / @locked / @writeLocked / @local clone
    #    their ref-count (Rc/Arc) automatically and cross fiber boundaries
    #    safely via the existing retain/release discipline.
    return RcClone.new(zig_type: zig_t, ctx_init_name: name) if safe_shared_across_fibers?(type)

    # 4b. Scheduler-affine synchronized collections are safe only when
    #     the boundary analysis pins the fiber. They are not Rc/Arc values
    #     and must fall through to FiberCtxBuilder's pointer-capture path.
    return ByValue.new(zig_type: zig_t, ctx_init_name: name) if pinned_sync_collection?(type)

    # 5. Value-like captures are always safe: primitives, rodata
    #    strings, enums, plus structs
    #    whose fields are all themselves value-like (resolved via
    #    schema_lookup).
    return ByValue.new(zig_type: zig_t, ctx_init_name: name) if value_like?(type, schema_lookup)

    # 6. Owned aggregate values that are safe to duplicate get a fresh
    #    fiber-owned copy. The predicate is type-driven and recursive:
    #    structs/unions/lists are admitted only through Type's cleanup
    #    shape knowledge, so field additions do not require capture
    #    classifier edits.
    if deep_copy_capture?(type, schema_lookup)
      alloc_sym = fiber_copy_alloc_for(type)
      return FreshHeapCopy.new(zig_type: zig_t, ctx_init_name: name, alloc_sym: alloc_sym)
    end

    # 7. Anything else (heap-backed, borrow, pointer-passed) requires
    #    explicit transfer at the capture site. Refuse with the reason.
    Refuse.new(reason: refuse_reason_for(type), owner_name: name)
  end

  # --- Helpers: purely local predicates, no external side effects. ---

  sig { params(type: Type).returns(T::Boolean) }
  def self.owned_affine_promise_handle?(type)
    return false unless type.respond_to?(:future?) && type.future?
    return false if type.respond_to?(:stream?) && type.stream?
    return false if type.respond_to?(:shared_promise?) && type.shared_promise?
    return false if type.respond_to?(:promise_list?) && type.promise_list?
    return false if type.respond_to?(:observable?) && type.observable?
    true
  end

  # True iff the capture's data fits entirely in the union/value header,
  # with no aliased heap backing. Safe to byte-copy into the ctx struct.
  sig { params(type: Type, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.value_like?(type, schema_lookup = nil)
    return true if type.primitive?
    return true if type.respond_to?(:string?) && type.string? && type.rodata?
    return false if type.respond_to?(:string?) && type.string?
    # Id<T> handles are opaque u64 indices into a pool — the pool owns the
    # data; the Id is just a key. Byte-copy is always safe.
    if type.respond_to?(:id_handle?) && type.id_handle?
      return true
    end
    # Plain structs / enums / unions whose fields are all
    # implicitly-Copy: byte-copying the value into the fiber's ctx
    # struct is safe (no heap aliasing). Requires the program's
    # schema lookup; without it, fall back to the schema-less
    # `copyable?` (which only succeeds for primitive-like values here;
    # managed strings are handled above so they cannot slip through as
    # slice-header copies).
    if schema_lookup && type.respond_to?(:implicitly_copyable?)
      return true if type.implicitly_copyable?(schema_lookup)
    end
    return true if type.respond_to?(:copyable?) && type.copyable?
    false
  end

  sig { params(type: Type, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.deep_copy_capture?(type, schema_lookup = nil)
    return false if type.needs_pointer_passing?
    return false if type.future? || type.any_sync? || type.any_rc? || type.resource?
    return false if type.borrowed_reference?

    type.ownership_bearing?(schema_lookup)
  end

  # True iff the capture can be cloned (Rc/Arc retain) into the fiber's
  # context without new ownership analysis. @multiowned is Rc;
  # @shared is Arc; @locked/@writeLocked/@local are sync wrappers on
  # top of these; @sharded/@striped are Arc-containing container
  # topologies. All of these preserve the safe-sharing guarantee.
  sig { params(type: Type).returns(T::Boolean) }
  def self.safe_shared_across_fibers?(type)
    zig = type.zig_type
    zig.start_with?("CheatLib.Arc(") || zig.start_with?("CheatLib.Rc(")
  end

  sig { params(type: Type).returns(T::Boolean) }
  def self.pinned_sync_collection?(type)
    type.collection? && type.any_sync?
  end

  # Where the fiber's deep-copy should live when the user writes COPY.
  # Fibers outlive the spawning scope, so heap is the safe default.
  sig { params(_type: Type).returns(Symbol) }
  def self.fiber_copy_alloc_for(_type)
    :heap
  end

  # Narrow Zig-field type selection. Reuses Type#zig_type(is_field: true)
  # so dynamic arrays render as []T (slices) rather than ArrayListUnmanaged.
  # Pointer-passed types render as *T in the field (same as historical
  # behavior for @pool / @map captures).
  sig { params(type: Type).returns(String) }
  def self.field_zig_type(type)
    base = type.zig_type(is_field: true)
    (type.respond_to?(:needs_pointer_passing?) && type.needs_pointer_passing?) ? "*#{base}" : base
  end

  sig { params(type: Type).returns(Symbol) }
  def self.refuse_reason_for(type)
    return :pointer_passed_without_transfer if type.respond_to?(:needs_pointer_passing?) && type.needs_pointer_passing?
    return :list_borrow_without_transfer   if type.list_collection?
    return :pool_borrow_without_transfer   if type.pool?
    return :array_borrow_without_transfer  if type.array?
    return :heap_backed_without_transfer   if type.respond_to?(:heap?) && type.heap?
    :unclassified_capture
  end
end
