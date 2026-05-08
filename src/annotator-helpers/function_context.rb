require "sorbet-runtime"
# Per-function state scoped to the function context stack.
# Replaces loose instance variables (@frame_usage_count, @heap_usage_count, etc.)
# that were manually reset in visit_FunctionDef and could leak across functions.
class FunctionContext
  attr_accessor :name, :return_type, :lifetime, :type_params,
                :frame_count, :heap_count, :alloc_count,
                :needs_rt,  # explicit "fn body references rt" flag (independent of allocation counters)
                :loop_depth, :conditional_depth, :returns,
                :stack_vars_bytes  # accumulated bytes for stack-local variables

  def initialize(name:, return_type:, lifetime: nil, type_params: [])
    @name = name
    @return_type = return_type
    @lifetime = lifetime
    @type_params = type_params
    @frame_count = 0
    @heap_count = 0
    @alloc_count = 0
    @needs_rt = false
    @loop_depth = 0
    @conditional_depth = 0
    @returns = []
    @stack_vars_bytes = 0
  end
end
