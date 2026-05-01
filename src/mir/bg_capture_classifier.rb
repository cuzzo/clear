require_relative "capture_strategy"

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
#   - heap_promote_names : Set<name> -- read by EscapeAnalysis instead
#                          of re-walking BG bodies via e2_bg_capture_names.
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
  def self.classify_all!(fn_nodes)
    fn_nodes.each do |_name, fn|
      next unless fn&.body
      AST.each_bg_block(fn.body) { |bg| classify_one!(bg) }
    end
  end

  def self.classify_one!(bg)
    a = bg.capture_analysis
    return unless a && a.captures

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
        is_resource: a.resource_captures&.include?(name) || false
      )
    end

    a.strategies = strategies
    a.heap_promote_names = strategies.each_with_object(Set.new) { |(n, s), set|
      set << n if heap_promote_for?(s)
    }
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

  # The set of strategies that imply the capture's source binding must be
  # heap-allocated at the declaration site (so the iteration's per-iter
  # frame rewind doesn't free the backing while the spawned fiber holds
  # a pointer into it). Mirrors the existing
  # EscapeAnalysis.e2_bg_capture_names predicate; the classifier reads
  # from strategies instead of re-walking BG bodies.
  def self.heap_promote_for?(strategy)
    case strategy
    when CaptureStrategy::MoveInto, CaptureStrategy::FreshHeapCopy
      true
    else
      false
    end
  end
end
