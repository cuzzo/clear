# typed: strict
require "sorbet-runtime"

require_relative "mir"
require_relative "../ast/symbol_entry"
require_relative "../annotator/helpers/capabilities"
require_relative "../semantic/capture_strategy"

# FiberCtxBuilder
# ===============
#
# Single source of truth for the *capture handling* part of a
# fiber-like context. All four sync-boundary lowerings (BG, BG STREAM,
# DO branches, CONCURRENT EACH/SELECT/WHERE) share an identical
# pattern after the BG capture consolidation work in this branch:
#
#   field type: `name: @TypeOf(name)`
#   init:       `.name = name`
#   body access: `<prefix>.name`
#
# FreshHeapCopy captures may override the field/init shape with MIR setup
# nodes and a typed cleanup plan; see below.
#
# This builder produces a normalized list of CaptureSpec entries that
# each callsite can lower into structural context fields, initializers,
# setup nodes, and cleanup nodes. The capture_map and
# capture_symbols outputs feed `with_fiber_capture_map` so body
# lowerings (especially WITH EXCLUSIVE's Arc-vs-bare dispatch) read the
# live SymbolEntry.
#
# What this REPLACES (4 → 1):
#
#   - lower_bg_block             (was inline)
#   - lower_bg_stream_block      (was inline)
#   - lower_do_block             (was inline)
#   - build_bounded_concurrent_callback{,_pointer} (was inline x2)
#
# Each callsite still owns its site-specific control fields
# (Promise.inner+alloc / WaitGroup / nothing), run-fn signature, and
# runtime spawn API -- those are inherently different. The CAPTURE
# concern is the unified piece.
#
# FreshHeapCopy wiring (Phase 2 of sync-boundary-unification.md / Gap A)
# ---------------------------------------------------------------------
# When a capture's strategy is `CaptureStrategy::FreshHeapCopy` (user
# wrote `COPY x` inside the body), the builder produces:
#
#   * a `dupe_var` (a unique pre-spawn local) and MIR setup nodes that
#     the callsite emits BEFORE the ctx init:
#       const __fc_<id>_<name> = try CheatLib.dupeCaptured(...)
#       errdefer CheatLib.cleanup(...)
#   * the initializer switches to the dupe_var instead of the raw
#     capture name
#   * a typed cleanup plan asks callsites to inject a structural
#     `defer` MIR node INTO the run function so the duped value is
#     released on every exit (success or error).
#
# This works today for plain structs / strings (which `dupeValue`
# handles via its comptime walk over fields). Collections with
# `deinit` (ArrayList / HashMap / Pool) fall through `dupeValue`
# unchanged -- that is the language-level COPY @list bug (258), not
# this builder's concern.
module FiberCtxBuilder
    extend T::Sig

  class CaptureCleanupKind < T::Enum
    enums do
      None = new("none")
      CapturedValue = new("captured_value")
      UniformValue = new("uniform_value")
      RcRelease = new("rc_release")
    end
  end

  class CaptureRcKind < T::Enum
    extend T::Sig

    enums do
      Rc = new("rc")
      Arc = new("arc")
    end

    sig { returns(String) }
    def retain_func
      self == Arc ? "arcRetain" : "rcRetain"
    end

    sig { returns(String) }
    def release_func
      self == Arc ? "arcRelease" : "rcRelease"
    end
  end

  class CaptureCleanupPlan < T::Struct
    extend T::Sig

    const :kind, CaptureCleanupKind
    const :mirror_type, T.nilable(Type), default: nil
    const :rc_kind, T.nilable(CaptureRcKind), default: nil
    const :rc_payload_type_zig, T.nilable(String), default: nil

    sig { returns(CaptureCleanupPlan) }
    def self.none
      new(kind: CaptureCleanupKind::None)
    end

    sig { returns(T::Boolean) }
    def none?
      kind == CaptureCleanupKind::None
    end

    sig { returns(T::Boolean) }
    def guarded?
      captured_value? || uniform_value?
    end

    sig { returns(T::Boolean) }
    def captured_value?
      kind == CaptureCleanupKind::CapturedValue
    end

    private

    sig { returns(T::Boolean) }
    def uniform_value?
      kind == CaptureCleanupKind::UniformValue
    end

    public

    sig { returns(T::Boolean) }
    def rc_release?
      kind == CaptureCleanupKind::RcRelease
    end

    sig { returns(T::Boolean) }
    def emits_cleanup?
      kind != CaptureCleanupKind::None
    end
  end

  class CaptureSpec < T::Struct
    extend T::Sig

    const :name, String
    const :field_type_zig, String
    const :init_value_mir, MIR::Emittable
    const :setup_mir, T::Array[MIR::Emittable]
    const :cleanup_plan, CaptureCleanupPlan

    sig { params(receiver: String).returns(T.nilable(MIR::DeferStmt)) }
    def cleanup_mir_for(receiver)
      return nil unless cleanup_plan.emits_cleanup?

      receiver_expr = MIR::Ident.new(receiver)
      captured_field = MIR::FieldGet.new(receiver_expr, name)
      moved_guard = MIR::FieldGet.new(receiver_expr, "#{name}_moved")
      if cleanup_plan.kind == CaptureCleanupKind::CapturedValue ||
          cleanup_plan.kind == CaptureCleanupKind::UniformValue
        cleanup_call = MIR::Call.new(
          "CheatLib.cleanup",
          [
            MIR::TypeOf.new(captured_field),
            MIR::FieldGet.new(receiver_expr, "alloc"),
            MIR::AddressOf.new(captured_field),
          ],
          false,
          false,
          MIR::CallableContract.no_ownership(3),
        )
        return MIR::DeferStmt.new(MIR::IfStmt.new(
          MIR::UnaryOp.new("!", moved_guard),
          [MIR::ExprStmt.new(cleanup_call, false)],
          nil,
        ))
      end

      return nil unless cleanup_plan.rc_release?

      rc_kind = T.must(cleanup_plan.rc_kind)
      payload_type_zig = T.must(cleanup_plan.rc_payload_type_zig)

      MIR::DeferStmt.new(MIR::RcRelease.new(
        captured_field,
        payload_type_zig,
        rc_kind.release_func,
        MIR::FieldGet.new(receiver_expr, "alloc"),
      ))
    end

    sig { params(receiver: String).returns(T.nilable(MIR::Emittable)) }
    def finalizer_mir_for(receiver)
      return nil unless cleanup_plan.rc_release?

      receiver_expr = MIR::Ident.new(receiver)
      captured_field = MIR::FieldGet.new(receiver_expr, name)
      rc_kind = T.must(cleanup_plan.rc_kind)
      payload_type_zig = T.must(cleanup_plan.rc_payload_type_zig)

      MIR::RcRelease.new(
        captured_field,
        payload_type_zig,
        rc_kind.release_func,
        MIR::FieldGet.new(receiver_expr, "alloc"),
      )
    end

    sig { returns(T::Boolean) }
    def requires_setup?
      !setup_mir.empty?
    end

    sig { returns(T::Boolean) }
    def needs_moved_guard?
      cleanup_plan.guarded?
    end

    sig { returns(T.nilable(Type)) }
    def cleanup_mirror_type
      cleanup_plan.mirror_type
    end
  end

  # specs                : Array<CaptureSpec>
  # capture_map          : Hash<name => "<prefix>.name"> for body identifier rewrites
  # capture_symbols      : Hash<name => SymbolEntry> live entries for storage/sync queries
  # has_fresh_heap_copy? : true if any spec has setup nodes and a cleanup
  #                        plan that moves ownership into the fiber body.
  class Result < T::Struct
    extend T::Sig

    const :specs, T::Array[CaptureSpec]
    const :capture_map, T::Hash[String, String]
    const :capture_symbols, T::Hash[String, SymbolEntry]

    sig { returns(T::Boolean) }
    def has_fresh_heap_copy?
      specs.any? { |s| s.cleanup_plan.captured_value? && s.requires_setup? }
    end
  end

  # Build the capture spec for a fiber-like ctx struct.
  #
  # `analysis`            -- a CaptureAnalysis (already populated by
  #                          BgCaptureClassifier in the annotator pass).
  # `body_access_prefix`  -- the Zig identifier the body uses to reach
  #                          captured fields (e.g. "ctx" for DO/CONCURRENT,
  #                          "__ctx_<id>" for BG).
  # `promoted_names`      -- legacy compatibility override map. New escape
  #                          placement should prefer FreshHeapCopy captures.
  # `fresh_heap_alloc`    -- Zig variable name for the allocator that
  #                          owns FreshHeapCopy dupes. Required for
  #                          FreshHeapCopy emission; when nil, FreshHeapCopy
  #                          captures fall back to the byte-copy path
  #                          (callsite has no allocator to use).
  # `fresh_heap_id`       -- numeric id used to make dupe_var names unique
  #                          across multiple fiber blocks in the same
  #                          function. Default: 0.
  sig { params(analysis: T.nilable(CapabilityHelper::CaptureAnalysis), body_access_prefix: String, promoted_names: T::Hash[String, String], fresh_heap_alloc: T.nilable(String), fresh_heap_id: Integer, source_overrides: T::Hash[String, String], schema_lookup: T.nilable(Proc)).returns(FiberCtxBuilder::Result) }
  def self.build(analysis, body_access_prefix:, promoted_names: {},
                 fresh_heap_alloc: nil, fresh_heap_id: 0, source_overrides: {}, schema_lookup: nil)
    captured = analysis&.captures || {}
    strategies = analysis&.strategies || {}
    pointer_captures = analysis&.pointer_captures || Set.new
    specs = captured.map do |name, _type_obj|
      strat = strategies[name]
      if promoted_names[name]
        CaptureSpec.new(
          name: name,
          field_type_zig: "[]const u8",
          init_value_mir: MIR::Ident.new(promoted_names[name]),
          setup_mir: [],
          cleanup_plan: CaptureCleanupPlan.none,
        )
      elsif strat.is_a?(CaptureStrategy::FreshHeapCopy) && fresh_heap_alloc
        dupe_var = "__fc_#{fresh_heap_id}_#{name}"
        source_ref = source_overrides[name] || name
        source_mir = MIR::Ident.new(source_ref)
        capture_symbol = analysis&.capture_symbols&.dig(name)
        needs_cleanup = needs_fresh_heap_capture_cleanup?(_type_obj, schema_lookup, capture_symbol)
        setup_mir = T.let([
          MIR::Let.new(
            dupe_var,
            MIR::Call.new(
              "CheatLib.dupeCaptured",
              [MIR::TypeOf.new(source_mir), source_mir, MIR::Ident.new(fresh_heap_alloc)],
              true,
              false,
              MIR::CallableContract.no_ownership(3),
            ),
            false,
            nil,
            nil,
          ),
        ], T::Array[MIR::Emittable])
        if needs_cleanup
          setup_mir << MIR::ErrDeferStmt.new(MIR::Call.new(
            "CheatLib.cleanup",
            [
              MIR::TypeOf.new(MIR::Ident.new(dupe_var)),
              MIR::Ident.new(fresh_heap_alloc),
              MIR::AddressOf.new(MIR::Ident.new(dupe_var)),
            ],
            false,
            false,
            MIR::CallableContract.no_ownership(3),
          ))
        end
        cleanup_plan = needs_cleanup ? CaptureCleanupPlan.new(
          kind: CaptureCleanupKind::CapturedValue,
          mirror_type: Type.new(:CapturedValue, location: :heap),
        ) : CaptureCleanupPlan.none
        CaptureSpec.new(
          name: name,
          field_type_zig: "CheatLib.CapturedValue(@TypeOf(#{source_ref}))",
          init_value_mir: MIR::Ident.new(dupe_var),
          setup_mir: setup_mir,
          cleanup_plan: cleanup_plan,
        )
      elsif strat.is_a?(CaptureStrategy::RcClone)
        retain_var = "__fc_#{fresh_heap_id}_#{name}_retain"
        source_ref = source_overrides[name] || name
        ti = _type_obj.is_a?(Type) ? _type_obj : Type.new(_type_obj)
        sym = analysis&.capture_symbols&.dig(name)
        shared_capture = ti.shared? || sym&.storage == :shared
        rc_kind = shared_capture ? CaptureRcKind::Arc : CaptureRcKind::Rc
        payload_type_zig = rc_payload_zig_type(ti)
        retain_setup_mir = T.let([MIR::Let.new(retain_var, MIR::Call.new(
          "CheatLib.#{rc_kind.retain_func}",
          [MIR::Ident.new(payload_type_zig), MIR::Ident.new(source_ref)],
          false,
          false,
          MIR::CallableContract.no_ownership(2),
        ), false, nil, nil)], T::Array[MIR::Emittable])
        CaptureSpec.new(
          name: name,
          field_type_zig: "@TypeOf(#{source_ref})",
          init_value_mir: MIR::Ident.new(retain_var),
          setup_mir: retain_setup_mir,
          cleanup_plan: CaptureCleanupPlan.new(
            kind: CaptureCleanupKind::RcRelease,
            mirror_type: Type.new(ti).tap { |t| t.apply_reference_ownership!(shared_capture ? :shared : :multiowned) },
            rc_kind: rc_kind,
            rc_payload_type_zig: payload_type_zig,
          ),
        )
      elsif strat.is_a?(CaptureStrategy::MoveInto)
        source_ref = source_overrides[name] || name
        cleanup_plan = if needs_move_capture_cleanup?(_type_obj, schema_lookup)
                         CaptureCleanupPlan.new(
                           kind: CaptureCleanupKind::UniformValue,
                           mirror_type: Type.new(_type_obj.is_a?(Type) ? _type_obj : Type.new(_type_obj)),
                         )
                       else
                         CaptureCleanupPlan.none
                       end
        CaptureSpec.new(
          name: name,
          field_type_zig: "@TypeOf(#{source_ref})",
          init_value_mir: MIR::Ident.new(source_ref),
          setup_mir: [],
          cleanup_plan: cleanup_plan,
        )
      elsif pointer_captures.include?(name)
        source_ref = source_overrides[name] || name
        # Shared mutable collection (HashMap, @pool, @sharded:locked, ...).
        # Capture by pointer so writes inside the fiber body land on the
        # outer instance, not on a copied struct.
        #
        # Two sub-cases for the binding's existing Zig representation:
        #   * Function parameter of a `needs_pointer_passing?` type --
        #     Zig already passes the parameter as a pointer (the
        #     compiler emits `nodes: anytype` / `pool: *Pool`). Capture
        #     it by VALUE so the BG context carries the same pointer
        #     directly; wrapping with `&` would produce a `**T` that
        #     the body's method calls (`pool.acquire()`) cannot consume.
        #   * Local declaration -- Zig holds the value inline (e.g.
        #     `var cNodes = ShardedStringMap{...}`). Capture `&cNodes`
        #     so writes inside the fiber land on the outer struct, not
        #     on a copied per-shard-locks instance.
        # `@TypeOf(&name)` for the field type carries any const-ness
        # through (parameters are Zig-const, so `&pool` is `*const T`).
        sym = analysis&.capture_symbols&.dig(name)
        if sym&.is_param
          CaptureSpec.new(
            name: name,
            field_type_zig: "@TypeOf(#{source_ref})",
            init_value_mir: MIR::Ident.new(source_ref),
            setup_mir: [],
            cleanup_plan: CaptureCleanupPlan.none,
          )
        else
          CaptureSpec.new(
            name: name,
            field_type_zig: "@TypeOf(&#{source_ref})",
            init_value_mir: MIR::AddressOf.new(MIR::Ident.new(source_ref)),
            setup_mir: [],
            cleanup_plan: CaptureCleanupPlan.none,
          )
        end
      else
        source_ref = source_overrides[name] || name
        CaptureSpec.new(
          name: name,
          field_type_zig: "@TypeOf(#{source_ref})",
          init_value_mir: MIR::Ident.new(source_ref),
          setup_mir: [],
          cleanup_plan: CaptureCleanupPlan.none,
        )
      end
    end
    map = captured.keys.to_h { |n| [n, "#{body_access_prefix}.#{n}"] }
    Result.new(specs: specs, capture_map: map, capture_symbols: analysis&.capture_symbols || {})
  end

  sig { params(type_obj: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.needs_move_capture_cleanup?(type_obj, schema_lookup = nil)
    ti = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    return false if ti.primitive? || ti.void? || ti.any? || ti.rodata? || ti.borrowed_reference?
    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(schema_lookup)
  rescue StandardError
    false
  end

  sig { params(type_obj: T.untyped, schema_lookup: T.nilable(Proc), capture_symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def self.needs_fresh_heap_capture_cleanup?(type_obj, schema_lookup = nil, capture_symbol = nil)
    ti = type_obj.is_a?(Type) ? Type.new(type_obj) : Type.new(type_obj)
    return true if ti.any_sync? || ti.any_rc? || symbol_capture_value_needs_cleanup?(capture_symbol)
    return false if ti.primitive? || ti.void? || ti.any?
    return true if ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(schema_lookup)
    !!(ti.ownership && ti.ownership != :affine)
  rescue StandardError
    false
  end

  sig { params(type_obj: T.untyped, schema_lookup: T.nilable(Proc), capture_symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def self.needs_capture_value_cleanup?(type_obj, schema_lookup = nil, capture_symbol = nil)
    ti = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    return false if ti.void? || ti.any? || ti.rodata? || ti.borrowed_reference?
    needs_move_capture_cleanup?(ti, schema_lookup) ||
      ti.any_sync? || ti.any_rc? || symbol_capture_value_needs_cleanup?(capture_symbol) ||
      !!(ti.ownership && ti.ownership != :affine)
  rescue StandardError
    false
  end

  sig { params(capture_symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def self.symbol_capture_value_needs_cleanup?(capture_symbol)
    return false unless capture_symbol

    capture_symbol.atomic?
  end

  sig { params(ti: Type).returns(String) }
  def self.rc_payload_zig_type(ti)
    payload = Type.new(ti)
    payload.apply_reference_ownership!(:affine)
    payload.mark_stack_value!
    payload.clear_zig_type_cache!
    if payload.any_sync? && !(payload.map? && payload.striped?)
      inner = payload.bare_data_type.zig_type
      inner = "CheatLib.Locked(#{inner})" if payload.locked?
      inner = "CheatLib.RwLocked(#{inner})" if payload.write_locked?
      inner = "CheatLib.RefCell(#{inner})" if payload.sync == :always_mutable
      inner = "CheatLib.Versioned(#{inner})" if payload.versioned?
      inner = payload.indirect? ? "CheatLib.AtomicPtr(#{inner})" : "CheatLib.Atomic(#{inner})" if payload.atomic?
      return inner
    end
    payload.zig_type
  end
end
