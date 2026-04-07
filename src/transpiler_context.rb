# Per-function transpilation state, pushed/popped on a stack.
# Prevents leaks between nested functions/lambdas (same pattern as FunctionContext
# for the annotator).
class TranspilerContext
  attr_accessor :uses_frame, :has_rt, :collection_params,
                :fn_name               # current function name (for plan lookup)

  def initialize(uses_frame:, has_rt:, collection_params: Set.new, fn_name: nil)
    @uses_frame = uses_frame
    @has_rt = has_rt
    @collection_params = collection_params
    @fn_name = fn_name
  end
end
