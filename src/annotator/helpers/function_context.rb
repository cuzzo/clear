# typed: strict
require "sorbet-runtime"
# Per-function state scoped to the function context stack.
# Replaces loose instance variables (@frame_usage_count, @heap_usage_count, etc.)
# that were manually reset in visit_FunctionDef and could leak across functions.
class FunctionContext
    extend T::Sig
  LifetimeSource = T.type_alias { T.any(String, Symbol) }

  sig { returns(String) }
  attr_reader :name

  sig { returns(T.untyped) }
  attr_accessor :type_params,
                :frame_count, :heap_count, :alloc_count,
                :loop_depth, :conditional_depth,
                :stack_vars_bytes  # accumulated bytes for stack-local variables

  sig { returns(T::Array[AST::ReturnFact]) }
  attr_accessor :returns

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

  sig { params(val: T.nilable(Type::TypeInput)).void }
  def return_type=(val)
    @return_type = val.nil? ? Type.new(:Void) : Type.new(val)
  end

  sig { void }
  def record_frame_use!
    self.frame_count += 1
  end

  sig { void }
  def record_heap_use!
    self.heap_count += 1
  end

  sig { void }
  def record_alloc_use!
    self.alloc_count += 1
  end

  sig { params(bytes: Integer).void }
  def record_stack_bytes!(bytes)
    self.stack_vars_bytes += bytes
  end

  sig { void }
  def mark_runtime_used!
    self.uses_rt = true
  end

  sig { void }
  def enter_loop!
    self.loop_depth += 1
  end

  sig { void }
  def exit_loop!
    self.loop_depth -= 1
  end

  sig { void }
  def enter_conditional!
    self.conditional_depth += 1
  end

  sig { void }
  def exit_conditional!
    self.conditional_depth -= 1
  end

  sig { params(name: String, return_type: T.nilable(Type::TypeInput), lifetime: T::Array[LifetimeSource], type_params: T::Array[Symbol]).void }
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
    @returns = T.let([], T::Array[AST::ReturnFact])
    @stack_vars_bytes = T.let(0, Integer)
  end
end
