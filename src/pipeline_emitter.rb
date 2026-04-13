# src/pipeline_emitter.rb -- Pipeline-specific code generation.
#
# Phase 1: pure delegation to the pre-computed MIR inner node.
#          MIR::Pipeline.inner carries the old-path output (RawZig or MIR tree).
#          This class exists so that future phases can replace delegation with
#          structured lazy-stream emission without touching MIREmitter.
#
# Future phases will replace emit() with source/stage/sink composition:
#   Phase 2: LazyRange source -- no intermediate slice materialization
#   Phase 3: Lazy stage chain -- single pull loop, zero intermediate lists
#   Phase 4: BoundedChannel -- CONCURRENT with backpressure
#   Phase 5: Sharded pipelines -- N channels, work-stealing
#   Phase 6: InfStream/OpenStream as pipeline sources

require_relative "mir"

class PipelineEmitter
  def initialize(main_emitter)
    @emitter = main_emitter
  end

  # Emit Zig for a MIR::Pipeline node.
  # Phase 1: delegate entirely to node.inner (pre-computed by old paths).
  def emit(pipeline_node)
    @emitter.emit(pipeline_node.inner)
  end
end
