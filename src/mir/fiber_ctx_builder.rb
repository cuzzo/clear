# typed: strict
require "sorbet-runtime"

require_relative "mir"
require_relative "capture_strategy"

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
# FreshHeapCopy captures may override the field/init shape; see below.
#
# This builder produces a normalized list of CaptureSpec entries that
# each callsite can render either as a Zig string (BG / BG STREAM /
# DO use Zig templates) or as MIR nodes (CONCURRENT pipeline_host
# uses MIR::StructDef / MIR::StructInit). The capture_map and
# capture_symbols outputs feed `with_fiber_capture_map` so body
# lowerings (especially WITH EXCLUSIVE's Arc-vs-bare dispatch in
# with_cap_sync_storage) read the live SymbolEntry.
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
#   * a `dupe_var` (a unique pre-spawn local) and a `dupe_decl_zig`
#     fragment that the callsite emits BEFORE the ctx init:
#       `const __fc_<id>_<name> = try CheatLib.dupeValue(@TypeOf(<name>), <name>, <alloc>);
#        errdefer CheatLib.cleanup(@TypeOf(__fc_<id>_<name>), <alloc>, &__fc_<id>_<name>);`
#   * `init_value_zig` switches to reference the dupe_var instead of
#     the raw capture name
#   * `body_cleanup_zig` carries a `defer CheatLib.cleanup(...)` that
#     the callsite injects INTO the run function so the duped value
#     is released on every exit (success or error).
#
# This works today for plain structs / strings (which `dupeValue`
# handles via its comptime walk over fields). Collections with
# `deinit` (ArrayList / HashMap / Pool) fall through `dupeValue`
# unchanged -- that is the language-level COPY @list bug (258), not
# this builder's concern.
module FiberCtxBuilder
    extend T::Sig

  # name           : String              -- captured outer-scope name
  # field_type_zig : String              -- Zig type expression for the ctx field
  # init_value_zig : String              -- Zig expression for the field init
  # init_value_mir : MIR::Ident-or-other -- MIR node form of the same init
  # dupe_decl_zig  : String?             -- pre-spawn dupe decl (FreshHeapCopy only)
  # body_cleanup_zig : String?           -- in-body cleanup defer (FreshHeapCopy only)
  CaptureSpec = Struct.new(:name, :field_type_zig, :init_value_zig, :init_value_mir,
                           :dupe_decl_zig, :body_cleanup_zig, :setup_mir,
                           :release_func, :payload_zig) do
    extend T::Sig

    sig { params(receiver: String).returns(T.nilable(MIR::DeferStmt)) }
    def cleanup_mir_for(receiver)
      return nil unless release_func && payload_zig

      MIR::DeferStmt.new(MIR::Call.new(
        "CheatLib.#{release_func}",
        [
          MIR::Ident.new(T.cast(payload_zig, String)),
          MIR::Ident.new("std.heap.page_allocator"),
          MIR::Ident.new("#{receiver}.#{name}"),
        ],
        false,
        false,
        MIR::CallableContract.no_ownership(3),
      ))
    end
  end

  # specs                : Array<CaptureSpec>
  # capture_map          : Hash<name => "<prefix>.name"> for body identifier rewrites
  # capture_symbols      : Hash<name => SymbolEntry> live entries for storage/sync queries
  # has_fresh_heap_copy? : true if any spec carries dupe_decl_zig (callsite must emit
  #                        the pre-spawn decls and inject the body cleanups)
  Result = Struct.new(:specs, :capture_map, :capture_symbols) do
    extend T::Sig
    sig { returns(T::Boolean) }
    def has_fresh_heap_copy?
      specs.any? { |s| s.dupe_decl_zig }
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
  sig { params(analysis: T.untyped, body_access_prefix: String, promoted_names: T::Hash[String, String], fresh_heap_alloc: T.nilable(String), fresh_heap_id: Integer, source_overrides: T::Hash[String, String], schema_lookup: T.nilable(Proc)).returns(FiberCtxBuilder::Result) }
  def self.build(analysis, body_access_prefix:, promoted_names: {},
                 fresh_heap_alloc: nil, fresh_heap_id: 0, source_overrides: {}, schema_lookup: nil)
    captured = analysis&.captures || {}
    strategies = analysis&.strategies || {}
    pointer_captures = analysis&.pointer_captures || Set.new
    specs = captured.map do |name, _type_obj|
      strat = strategies[name]
      if promoted_names[name]
        CaptureSpec.new(name, "[]const u8", promoted_names[name],
                        MIR::Ident.new(promoted_names[name]), nil, nil, nil, nil, nil)
      elsif strat.is_a?(CaptureStrategy::FreshHeapCopy) && fresh_heap_alloc
        dupe_var = "__fc_#{fresh_heap_id}_#{name}"
        source_ref = source_overrides[name] || name
        needs_cleanup = needs_capture_value_cleanup?(_type_obj, schema_lookup)
        # ctx field type and dupe return type must be the same
        # expression (CapturedValue) so they cannot diverge for a
        # `*const T` borrowed-param source.
        dupe_decl = "const #{dupe_var} = try CheatLib.dupeCaptured(@TypeOf(#{source_ref}), #{source_ref}, #{fresh_heap_alloc});"
        dupe_decl += "\n        errdefer CheatLib.cleanup(@TypeOf(#{dupe_var}), #{fresh_heap_alloc}, &#{dupe_var});" if needs_cleanup
        body_cleanup = if needs_cleanup
          "defer if (!#{body_access_prefix}.#{name}_moved) CheatLib.cleanup(@TypeOf(#{body_access_prefix}.#{name}), " \
          "#{body_access_prefix}.alloc, &#{body_access_prefix}.#{name});"
        end
        CaptureSpec.new(name, "CheatLib.CapturedValue(@TypeOf(#{source_ref}))", dupe_var,
                        MIR::Ident.new(dupe_var), dupe_decl, body_cleanup, nil, nil, nil)
      elsif strat.is_a?(CaptureStrategy::RcClone)
        retain_var = "__fc_#{fresh_heap_id}_#{name}_retain"
        source_ref = source_overrides[name] || name
        ti = _type_obj.is_a?(Type) ? _type_obj : Type.new(_type_obj)
        sym = analysis&.capture_symbols&.dig(name)
        shared_capture = ti.shared? || sym&.storage == :shared
        func = shared_capture ? "arcRetain" : "rcRetain"
        release = shared_capture ? "arcRelease" : "rcRelease"
        payload_zig = rc_payload_zig_type(ti)
        retain_decl = "const #{retain_var} = CheatLib.#{func}(#{payload_zig}, #{source_ref});"
        body_cleanup =
          "defer if (!#{body_access_prefix}.#{name}_moved) CheatLib.#{release}(#{payload_zig}, std.heap.page_allocator, " \
          "#{body_access_prefix}.#{name});"
        setup_mir = MIR::Let.new(retain_var, MIR::Call.new(
          "CheatLib.#{func}",
          [MIR::Ident.new(payload_zig), MIR::Ident.new(source_ref)],
          false,
          false,
          MIR::CallableContract.no_ownership(2),
        ), false, nil, nil)
        CaptureSpec.new(name, "@TypeOf(#{source_ref})", retain_var,
                        MIR::Ident.new(retain_var), retain_decl, body_cleanup,
                        setup_mir, release, payload_zig)
      elsif strat.is_a?(CaptureStrategy::MoveInto)
        source_ref = source_overrides[name] || name
        cleanup = if needs_move_capture_cleanup?(_type_obj, schema_lookup)
                    "defer if (!#{body_access_prefix}.#{name}_moved) CheatLib.cleanup(@TypeOf(#{body_access_prefix}.#{name}), " \
                    "#{body_access_prefix}.alloc, &#{body_access_prefix}.#{name});"
                  end
        CaptureSpec.new(name, "@TypeOf(#{source_ref})", source_ref,
                        MIR::Ident.new(source_ref), nil, cleanup, nil, nil, nil)
      elsif pointer_captures.include?(name)
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
          CaptureSpec.new(name, "@TypeOf(#{name})", name,
                          MIR::Ident.new(name), nil, nil, nil, nil, nil)
        else
          CaptureSpec.new(name, "@TypeOf(&#{name})", "&#{name}",
                          MIR::AddressOf.new(MIR::Ident.new(name)), nil, nil, nil, nil, nil)
        end
      else
        CaptureSpec.new(name, "@TypeOf(#{name})", name,
                        MIR::Ident.new(name), nil, nil, nil, nil, nil)
      end
    end
    map = captured.keys.to_h { |n| [n, "#{body_access_prefix}.#{n}"] }
    Result.new(specs, map, analysis&.capture_symbols || {})
  end

  sig { params(type_obj: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.needs_move_capture_cleanup?(type_obj, schema_lookup = nil)
    ti = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    return false if ti.primitive? || ti.void? || ti.any? || ti.rodata? || ti.borrowed_reference?
    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(schema_lookup)
  rescue StandardError
    false
  end

  sig { params(type_obj: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.needs_capture_value_cleanup?(type_obj, schema_lookup = nil)
    ti = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    return false if ti.void? || ti.any? || ti.rodata? || ti.borrowed_reference?
    needs_move_capture_cleanup?(ti, schema_lookup) ||
      ti.any_sync? || ti.any_rc? || !!(ti.ownership && ti.ownership != :affine)
  rescue StandardError
    false
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
