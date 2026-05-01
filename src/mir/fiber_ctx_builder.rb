require_relative "mir"

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
# BG string captures that get heap-duped via fiber_string_promotes).
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
# What this ENABLES:
#
#   - A new fiber-like construct (CHANNEL, ASYNC, future @parallel
#     primitive) becomes one new caller of this builder, not a 5th
#     parallel emitter.
#   - FreshHeapCopy.marker_plan emission (Phase 2 of
#     docs/agents/sync-boundary-unification.md) becomes one wiring
#     into this builder, not 4 separate wirings.
module FiberCtxBuilder
  # name           : String              -- captured outer-scope name
  # field_type_zig : String              -- Zig type expression for the ctx field
  # init_value_zig : String              -- Zig expression for the field init
  # init_value_mir : MIR::Ident-or-other -- MIR node form of the same init
  CaptureSpec = Struct.new(:name, :field_type_zig, :init_value_zig, :init_value_mir)

  # specs           : Array<CaptureSpec>
  # capture_map     : Hash<name => "<prefix>.name"> for body identifier rewrites
  # capture_symbols : Hash<name => SymbolEntry> live entries for storage/sync queries
  Result = Struct.new(:specs, :capture_map, :capture_symbols)

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
  def self.build(analysis, body_access_prefix:, promoted_names: {})
    captured = analysis&.captures || {}
    specs = captured.map do |name, _type_obj|
      if promoted_names[name]
        CaptureSpec.new(name, "[]const u8", promoted_names[name],
                        MIR::Ident.new(promoted_names[name]))
      else
        CaptureSpec.new(name, "@TypeOf(#{name})", name,
                        MIR::Ident.new(name))
      end
    end
    map = captured.keys.to_h { |n| [n, "#{body_access_prefix}.#{n}"] }
    Result.new(specs, map, analysis&.capture_symbols || {})
  end
end
