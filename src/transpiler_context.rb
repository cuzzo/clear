# Per-function transpilation state, pushed/popped on a stack.
# Prevents leaks between nested functions/lambdas (same pattern as FunctionContext
# for the annotator).
class TranspilerContext
  attr_accessor :uses_frame, :has_rt, :collection_params,
                :pending_heap_temps,   # Array of temp hashes awaiting emission at statement boundary
                :heap_temp_counter,    # Monotonic counter for unique temp names
                :bind_value_node,      # AST node of current VarDecl/BindExpr value (skip hoisting for non-HPT uses)
                :fn_name               # current function name (for plan lookup)

  def initialize(uses_frame:, has_rt:, collection_params: Set.new, fn_name: nil)
    @uses_frame = uses_frame
    @has_rt = has_rt
    @collection_params = collection_params
    @fn_name = fn_name
    @pending_heap_temps = []
    @heap_temp_counter = 0
    @bind_value_node = nil
  end
end
