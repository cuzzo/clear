# typed: strict
require "sorbet-runtime"

require_relative "capture_strategy"
require_relative "../ast/scope"

# BgCaptureClassifier
# ===================
#
# Single authority for BG/BgStream capture-strategy facts. Runs after
# `EscapeAnalysis.propagate_caller_sync!` so SymbolEntry sync/storage
# stamps are final, and BEFORE downstream passes that need to know
# which captures are MoveInto vs FreshHeapCopy vs RcClone vs ByValue.
#
# Walks every BG block reachable from each function (via the unified
# `AST.each_bg_block` helper -- same set every consumer uses), reads
# the per-capture `site_info` (collected by `analyze_fiber_captures`
# during Pass 1's single AST walk), reads the LIVE SymbolEntry's
# current sync/storage (no snapshot), classifies each capture via
# `CaptureStrategy.classify`, and stamps the results back onto
# `BgBlock.capture_analysis`:
#
#   - strategies         : Hash<name => CaptureStrategy::*>
#   - move_mark_names    : Set<name> -- read by MIRPass.insert_bg_give_suppress!
#                          and OwnershipDataflow.collect_bg_body_gives instead
#                          of each re-walking the BG body looking for GIVE.
#   - alloc_mark_entries : Hash<name => alloc_sym> -- for FreshHeapCopy
#                          captures (currently unused; reserved for the
#                          marker_plan wiring in Phase 7).
#
# Every consumer reads from these fields. Nobody re-derives. That makes
# divergence between the dataflow's view of "this is moved" and
# MIRPass's view of "we should suppress cleanup for this" structurally
# impossible -- they read the same field.
module BgCaptureClassifier
    extend T::Sig

  sig { params(fn_nodes: T::Hash[String, T.untyped], schema_lookup: T.nilable(Proc)).returns(T::Hash[String, T.untyped]) }
  def self.classify_all!(fn_nodes, schema_lookup: nil)
    fn_nodes.each do |_name, fn|
      next unless fn&.body
      # `Scope.live_param_syms` returns the {name => live SymbolEntry}
      # map -- the entries that `propagate_caller_sync!` mutates in
      # place. `analyze_fiber_captures` recorded references off
      # nested scopes that `Scope.dup` deep-copied; refreshing
      # against the live entries before we read sync/storage closes
      # the dual-SymbolEntry divergence flagged in
      # docs/agents/sync-boundary-unification.md (Gap C) and fixes
      # transpile-tests/257_concurrent_capture_locked_param.cht.
      live_param_syms = Scope.live_param_syms(fn)
      AST.each_capture_analysis(fn.body) { |a| classify_one!(a, live_param_syms, schema_lookup: schema_lookup) }
    end
  end

  # `a` is a CaptureAnalysis instance. Source can be BgBlock,
  # BgStreamBlock, DoBlock branch (Hash with :capture_analysis key),
  # or ConcurrentOp -- all use the same analysis machinery and now
  # share strategy classification.
  sig { params(a: CapabilityHelper::CaptureAnalysis, live_param_syms: T::Hash[String, SymbolEntry], schema_lookup: T.nilable(Proc)).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def self.classify_one!(a, live_param_syms = {}, schema_lookup: nil)
    return unless a && a.captures
    # Refresh capture_symbols against the live function-param entries
    # (which propagate_caller_sync! mutates in place). Without this,
    # captures into a fiber-like body inside a function with REQUIRES
    # LOCKED see a deep-copied stale entry whose storage is still
    # :stack instead of the propagated :shared.
    if a.capture_symbols
      a.capture_symbols.each do |name, _entry|
        live = live_param_syms[name]
        a.capture_symbols[name] = live if live
      end
    end

    site_info = CaptureStrategy::CaptureSiteInfo.new(a.site_copied || Set.new,
                                                     a.site_moved  || Set.new)

    strategies = {}
    a.captures.each do |name, type_obj|
      sym = a.capture_symbols&.dig(name)
      t = resolve_capture_type(type_obj, sym)
      next unless t
      strategies[name] = CaptureStrategy.classify(
        name: name,
        type: t,
        site_info: site_info,
        is_resource: a.resource_captures&.include?(name) || false,
        schema_lookup: schema_lookup
      )
    end

    a.strategies = strategies

    # move_mark_names: explicit user-written GIVE intent (or its
    # type-adapted CopyNode-with-was_moved equivalent). Drives
    # MIR::SuppressCleanup emission and OwnershipDataflow's
    # "consumed by BG" marking. One source of truth for both.
    a.move_mark_names = strategies.each_with_object(Set.new) { |(n, s), set|
      set << n if s.is_a?(CaptureStrategy::MoveInto)
    }
    a.alloc_mark_entries = strategies.each_with_object({}) { |(n, s), h|
      h[n] = s.alloc_sym if s.is_a?(CaptureStrategy::FreshHeapCopy)
    }
  end

  # Build a Type with the SymbolEntry's CURRENT sync/storage overlaid on
  # top of the AST node's snapshot. Mirrors Scope#resolve_full_type's
  # overlay logic without depending on a Scope instance (Phase-2-end has
  # no live scope -- only @fn_nodes). The capture's nominal type comes
  # from the snapshot; sync/storage come from the live entry (post
  # propagate_caller_sync!).
  sig { params(type_obj: Type, sym: SymbolEntry).returns(Type) }
  def self.resolve_capture_type(type_obj, sym)
    return nil unless type_obj
    base = type_obj.is_a?(Type) ? Type.new(type_obj) : Type.new(type_obj)
    return base unless sym
    case sym.storage
    when :multiowned then base.ownership = :multiowned unless base.ownership && base.ownership != :affine
    when :shared     then base.ownership = :shared     unless base.ownership && base.ownership != :affine
    end
    base.sync = sym.sync if sym.sync && !base.sync
    base
  end

end
