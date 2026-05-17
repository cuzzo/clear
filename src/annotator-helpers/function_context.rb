# typed: strict
require "sorbet-runtime"
# Per-function state scoped to the function context stack.
# Replaces loose instance variables (@frame_usage_count, @heap_usage_count, etc.)
# that were manually reset in visit_FunctionDef and could leak across functions.
class FunctionContext
    extend T::Sig

  attr_accessor :name, :return_type, :lifetime, :type_params,
                :frame_count, :heap_count, :alloc_count,
                :needs_rt,  # explicit "fn body references rt" flag (independent of allocation counters)
                :loop_depth, :conditional_depth, :returns,
                :stack_vars_bytes  # accumulated bytes for stack-local variables

  sig { params(name: String, return_type: T.untyped, lifetime: T.nilable(T::Array[String]), type_params: T::Array[Symbol]).void }
  def initialize(name:, return_type:, lifetime: nil, type_params: [])
    @name = name
    @return_type = return_type
    @lifetime = lifetime
    @type_params = type_params
    @frame_count = T.let(0, Integer)
    @heap_count = T.let(0, Integer)
    @alloc_count = T.let(0, Integer)
    @needs_rt = T.let(false, T::Boolean)
    @loop_depth = T.let(0, Integer)
    @conditional_depth = T.let(0, Integer)
    @returns = T.let([], T::Array[T.untyped])
    @stack_vars_bytes = T.let(0, Integer)
  end
end
