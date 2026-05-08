# typed: true
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
# (with a per-name override to `[]const u8` + a promoted-local init for
# BG string captures that get heap-duped via fiber_string_promotes,
# AND a FreshHeapCopy override -- see below.)
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
  # name           : String              -- captured outer-scope name
  # field_type_zig : String              -- Zig type expression for the ctx field
  # init_value_zig : String              -- Zig expression for the field init
  # init_value_mir : MIR::Ident-or-other -- MIR node form of the same init
  # dupe_decl_zig  : String?             -- pre-spawn dupe decl (FreshHeapCopy only)
  # body_cleanup_zig : String?           -- in-body cleanup defer (FreshHeapCopy only)
  CaptureSpec = Struct.new(:name, :field_type_zig, :init_value_zig, :init_value_mir,
                           :dupe_decl_zig, :body_cleanup_zig)

  # specs                : Array<CaptureSpec>
  # capture_map          : Hash<name => "<prefix>.name"> for body identifier rewrites
  # capture_symbols      : Hash<name => SymbolEntry> live entries for storage/sync queries
  # has_fresh_heap_copy? : true if any spec carries dupe_decl_zig (callsite must emit
  #                        the pre-spawn decls and inject the body cleanups)
  Result = Struct.new(:specs, :capture_map, :capture_symbols) do
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
  # `promoted_names`      -- BG-only override map. For names in this hash,
  #                          the field type is []const u8 and the init
  #                          uses the promoted local (heap-duped string).
  #                          Pass {} when no string-promotes apply.
  # `fresh_heap_alloc`    -- Zig variable name for the allocator that
  #                          owns FreshHeapCopy dupes. Required for
  #                          FreshHeapCopy emission; when nil, FreshHeapCopy
  #                          captures fall back to the byte-copy path
  #                          (callsite has no allocator to use).
  # `fresh_heap_id`       -- numeric id used to make dupe_var names unique
  #                          across multiple fiber blocks in the same
  #                          function. Default: 0.
  def self.build(analysis, body_access_prefix:, promoted_names: {},
                 fresh_heap_alloc: nil, fresh_heap_id: 0)
    captured = analysis&.captures || {}
    strategies = analysis&.strategies || {}
    pointer_captures = analysis&.pointer_captures || Set.new
    specs = captured.map do |name, _type_obj|
      strat = strategies[name]
      if promoted_names[name]
        CaptureSpec.new(name, "[]const u8", promoted_names[name],
                        MIR::Ident.new(promoted_names[name]), nil, nil)
      elsif strat.is_a?(CaptureStrategy::FreshHeapCopy) && fresh_heap_alloc
        dupe_var = "__fc_#{fresh_heap_id}_#{name}"
        dupe_decl =
          "const #{dupe_var} = try CheatLib.dupeValue(@TypeOf(#{name}), #{name}, #{fresh_heap_alloc});\n" \
          "        errdefer CheatLib.cleanup(@TypeOf(#{dupe_var}), #{fresh_heap_alloc}, &#{dupe_var});"
        body_cleanup =
          "defer CheatLib.cleanup(@TypeOf(#{body_access_prefix}.#{name}), " \
          "#{body_access_prefix}.alloc, &#{body_access_prefix}.#{name});"
        CaptureSpec.new(name, "@TypeOf(#{name})", dupe_var,
                        MIR::Ident.new(dupe_var), dupe_decl, body_cleanup)
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
                          MIR::Ident.new(name), nil, nil)
        else
          CaptureSpec.new(name, "@TypeOf(&#{name})", "&#{name}",
                          MIR::AddressOf.new(MIR::Ident.new(name)), nil, nil)
        end
      else
        CaptureSpec.new(name, "@TypeOf(#{name})", name,
                        MIR::Ident.new(name), nil, nil)
      end
    end
    map = captured.keys.to_h { |n| [n, "#{body_access_prefix}.#{n}"] }
    Result.new(specs, map, analysis&.capture_symbols || {})
  end
end
