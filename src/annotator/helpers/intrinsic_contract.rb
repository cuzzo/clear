# typed: strict
require "sorbet-runtime"
require_relative "intrinsic_emit"

class IntrinsicTemplateContract < T::Struct
  extend T::Sig

  TemplateValue = T.type_alias { T.any(String, Symbol) }

  const :zig, T.nilable(TemplateValue), default: nil
  const :numeric_zig, T.nilable(TemplateValue), default: nil
  const :sharded_zig, T.nilable(TemplateValue), default: nil
  const :shard_direct_zig, T.nilable(TemplateValue), default: nil
  const :bc, T::Boolean, default: false
  const :bc_op, T.nilable(Symbol), default: nil

  sig { params(kind: Symbol).returns(T.nilable(TemplateValue)) }
  def pattern_for(kind)
    case kind
    when :zig then zig
    when :numeric_zig then numeric_zig
    when :sharded_zig then sharded_zig
    when :shard_direct_zig then shard_direct_zig
    else nil
    end
  end

  sig { params(default_name: Symbol).returns(Symbol) }
  def bc_op_or(default_name)
    bc_op || default_name
  end
end

class IntrinsicAllocationContract < T::Struct
  extend T::Sig

  const :allocates, T::Boolean, default: false
  const :alloc, T.nilable(Symbol), default: nil
  const :return_alloc, T.nilable(Symbol), default: nil
  const :val_alloc, T.nilable(Symbol), default: nil
  const :key_alloc, T.nilable(Symbol), default: nil
  const :shard_alloc, T.nilable(Symbol), default: nil
  const :sharded_alloc, T.nilable(Symbol), default: nil

  sig { params(kind: Symbol).returns(T.nilable(Symbol)) }
  def placeholder(kind)
    case kind
    when :alloc then alloc
    when :return_alloc then return_alloc
    when :val_alloc then val_alloc
    when :key_alloc then key_alloc
    when :shard_alloc then shard_alloc
    when :sharded_alloc then sharded_alloc
    else nil
    end
  end
end

class IntrinsicOwnershipContract < T::Struct
  extend T::Sig

  const :mutates_receiver, T::Boolean, default: false
  const :takes_value, T::Boolean, default: false
  const :takes_indices, T::Set[Integer], factory: -> { Set.new }
  const :argument_takes_indices, T::Set[Integer], factory: -> { Set.new }
  const :container_borrow, T::Boolean, default: false

  sig { returns(T::Boolean) }
  def takes_any?
    takes_value || !takes_indices.empty?
  end

end

class IntrinsicBehaviorContract < T::Struct
  extend T::Sig

  const :is_method, T::Boolean, default: false
  const :suspends, T::Boolean, default: false
  const :fsm_setup_present, T::Boolean, default: false
  const :narrows_collection, T::Boolean, default: false
  const :narrows_receiver_collection, T::Boolean, default: false
  const :reject_when, T.nilable(Symbol), default: nil
  const :reject_error, T.nilable(String), default: nil
  const :error_kind, T.nilable(Symbol), default: nil
  const :error_type, T.nilable(Symbol), default: nil
  const :lifetime, T::Array[String], factory: -> { [] }

  sig { returns(T::Boolean) }
  def narrows_collection_type?
    narrows_collection || narrows_receiver_collection
  end
end

class IntrinsicContract < T::Struct
  extend T::Sig

  const :template, IntrinsicTemplateContract
  const :allocation, IntrinsicAllocationContract
  const :ownership, IntrinsicOwnershipContract
  const :behavior, IntrinsicBehaviorContract

  sig { returns(IntrinsicContract) }
  def self.empty
    new(
      template: IntrinsicTemplateContract.new,
      allocation: IntrinsicAllocationContract.new,
      ownership: IntrinsicOwnershipContract.new,
      behavior: IntrinsicBehaviorContract.new,
    )
  end

  sig { params(emit: IntrinsicEmit, params: T::Array[AST::Param]).returns(IntrinsicContract) }
  def self.from_emit(emit, params)
    new(
      template: IntrinsicTemplateContract.new(
        zig: emit.zig,
        numeric_zig: emit.numeric_zig,
        sharded_zig: emit.sharded_zig,
        shard_direct_zig: emit.shard_direct_zig,
        bc: emit.bc,
        bc_op: emit.bc_op,
      ),
      allocation: IntrinsicAllocationContract.new(
        allocates: emit.allocates,
        alloc: emit.alloc,
        return_alloc: emit.return_alloc,
        val_alloc: emit.val_alloc,
        key_alloc: emit.key_alloc,
        shard_alloc: emit.shard_alloc,
        sharded_alloc: emit.sharded_alloc,
      ),
      ownership: IntrinsicOwnershipContract.new(
        mutates_receiver: emit.mutates_receiver,
        takes_value: emit.takes_value,
        takes_indices: normalized_takes_indices(emit, params),
        argument_takes_indices: normalized_argument_takes_indices(emit),
        container_borrow: emit.container_borrow,
      ),
      behavior: IntrinsicBehaviorContract.new(
        is_method: emit.is_method,
        suspends: emit.suspends,
        fsm_setup_present: emit.fsm_setup_present,
        narrows_collection: emit.narrows_collection,
        narrows_receiver_collection: emit.narrows_receiver_collection,
        reject_when: emit.reject_when,
        reject_error: emit.reject_error,
        error_kind: emit.error_kind,
        error_type: emit.error_type,
        lifetime: emit.lifetime,
      ),
    )
  end

  sig { params(emit: IntrinsicEmit, params: T::Array[AST::Param]).returns(T::Set[Integer]) }
  def self.normalized_takes_indices(emit, params)
    indices = T.let(Set.new, T::Set[Integer])
    emit.takes_args.each { |index| indices << index }
    params.each_with_index { |param, index| indices << index if param.takes }
    indices
  end

  sig { params(emit: IntrinsicEmit).returns(T::Set[Integer]) }
  def self.normalized_argument_takes_indices(emit)
    indices = T.let(Set.new, T::Set[Integer])
    emit.takes_args.each { |index| indices << index }
    indices
  end
end
