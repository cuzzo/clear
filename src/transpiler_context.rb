# Per-function transpilation state, pushed/popped on a stack.
# Prevents leaks between nested functions/lambdas (same pattern as FunctionContext
# for the annotator).
class TranspilerContext
  attr_accessor :uses_frame, :has_rt, :collection_params

  def initialize(uses_frame:, has_rt:, collection_params: Set.new)
    @uses_frame = uses_frame
    @has_rt = has_rt
    @collection_params = collection_params
  end
end
