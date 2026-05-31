# typed: strict
require "sorbet-runtime"
# Per-function state scoped to the function context stack.
# Replaces loose instance variables (@frame_usage_count, @heap_usage_count, etc.)
# that were manually reset in visit_FunctionDef and could leak across functions.
class FunctionContext
    extend T::Sig
  LifetimeSource = T.type_alias { T.any(String, Symbol) }

  sig { returns(T.untyped) }
  attr_accessor :name, :type_params,
                :frame_count, :heap_count, :alloc_count,
                :loop_depth, :conditional_depth, :returns,
                :stack_vars_bytes  # accumulated bytes for stack-local variables

  sig { returns(T::Boolean) }
  attr_accessor :uses_rt

  # Seam: the enclosing function's expected return is ALWAYS a Type
  # (Void for "no value"). Coerced here so the producer may pass
  # nil/Symbol without any return-check reader needing a Symbol/Type
  # discriminator.
  sig { returns(Type) }
  attr_reader :return_type

  sig { returns(T::Array[LifetimeSource]) }
  attr_reader :lifetime

  sig { params(val: T.any(Symbol, String, Type, FunctionSignature, NilClass)).void }
  def return_type=(val)
    @return_type = val.nil? ? Type.new(:Void) : (val.is_a?(Type) ? val : Type.new(val))
  end

  sig { params(name: String, return_type: T.any(Symbol, String, Type, FunctionSignature, NilClass), lifetime: T::Array[LifetimeSource], type_params: T::Array[Symbol]).void }
  def initialize(name:, return_type: nil, lifetime: [], type_params: [])
    @name = name
    @return_type = T.let(Type.new(:Void), Type)
    self.return_type = return_type
    @lifetime = T.let(lifetime, T::Array[LifetimeSource])
    @type_params = type_params
    @frame_count = T.let(0, Integer)
    @heap_count = T.let(0, Integer)
    @alloc_count = T.let(0, Integer)
    @uses_rt = T.let(false, T::Boolean)
    @loop_depth = T.let(0, Integer)
    @conditional_depth = T.let(0, Integer)
    @returns = T.let([], T::Array[T.untyped])
    @stack_vars_bytes = T.let(0, Integer)
  end
end
