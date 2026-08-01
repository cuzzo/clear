# typed: strict
# frozen_string_literal: true

# Acyclic foundation: capability data records and their surface-name tables.
# Pure syntax facts - no dependency on semantic Type.

require "sorbet-runtime"
require_relative "lexer"

class TypeCapabilitySuffix < T::Struct
  const :base, String
  const :ownership, T.nilable(Symbol)
  const :sync, T.nilable(Symbol)
end

class TypeCapabilityUnset < T::Struct
end

# ruby-to-clear: value
class TypeCapabilities
  extend T::Sig

  UNSET = T.let(TypeCapabilityUnset.new.freeze, TypeCapabilityUnset)
  MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
  MaybeInteger = T.type_alias { T.any(TypeCapabilityUnset, Integer, NilClass) }
  MaybeBoolean = T.type_alias { T.any(TypeCapabilityUnset, T::Boolean) }
  MaybeToken = T.type_alias { T.any(TypeCapabilityUnset, Lexer::Token, NilClass) }

  sig { returns(T.nilable(Symbol)) }
  attr_reader :ownership, :sync, :layout, :collection, :elem_ownership, :elem_sync,
    :elem_layout, :link_source, :observable_terminal
  sig { returns(T.nilable(Integer)) }
  attr_reader :lock_rank, :shard_count
  sig { returns(T::Boolean) }
  attr_reader :ownership_set, :soa, :observable, :polymorphic_shared
  sig { returns(T.nilable(Lexer::Token)) }
  attr_reader :observable_token

  sig do
    params(
      ownership: T.nilable(Symbol),
      ownership_set: T::Boolean,
      sync: T.nilable(Symbol),
      layout: T.nilable(Symbol),
      lock_rank: T.nilable(Integer),
      collection: T.nilable(Symbol),
      shard_count: T.nilable(Integer),
      soa: T::Boolean,
      elem_ownership: T.nilable(Symbol),
      elem_sync: T.nilable(Symbol),
      elem_layout: T.nilable(Symbol),
      link_source: T.nilable(Symbol),
      observable: T::Boolean,
      observable_terminal: T.nilable(Symbol),
      observable_token: T.nilable(Lexer::Token),
      polymorphic_shared: T::Boolean
    ).void
  end
  def initialize(
    ownership: nil,
    ownership_set: false,
    sync: nil,
    layout: nil,
    lock_rank: nil,
    collection: nil,
    shard_count: nil,
    soa: false,
    elem_ownership: nil,
    elem_sync: nil,
    elem_layout: nil,
    link_source: nil,
    observable: false,
    observable_terminal: nil,
    observable_token: nil,
    polymorphic_shared: false
  )
    @ownership = ownership
    @ownership_set = ownership_set
    @sync = sync
    @layout = layout
    @lock_rank = lock_rank
    @collection = collection
    @shard_count = shard_count
    @soa = soa
    @elem_ownership = elem_ownership
    @elem_sync = elem_sync
    @elem_layout = elem_layout
    @link_source = link_source
    @observable = observable
    @observable_terminal = observable_terminal
    @observable_token = observable_token
    @polymorphic_shared = polymorphic_shared
    freeze
  end

  sig { returns(TypeCapabilities) }
  def copy
    self
  end

  sig do
    params(
      ownership: MaybeSymbol,
      ownership_set: MaybeBoolean,
      sync: MaybeSymbol,
      layout: MaybeSymbol,
      lock_rank: MaybeInteger,
      collection: MaybeSymbol,
      shard_count: MaybeInteger,
      soa: MaybeBoolean,
      elem_ownership: MaybeSymbol,
      elem_sync: MaybeSymbol,
      elem_layout: MaybeSymbol,
      link_source: MaybeSymbol,
      observable: MaybeBoolean,
      observable_terminal: MaybeSymbol,
      observable_token: MaybeToken,
      polymorphic_shared: MaybeBoolean
    ).returns(TypeCapabilities)
  end
  def with(
    ownership: UNSET,
    ownership_set: UNSET,
    sync: UNSET,
    layout: UNSET,
    lock_rank: UNSET,
    collection: UNSET,
    shard_count: UNSET,
    soa: UNSET,
    elem_ownership: UNSET,
    elem_sync: UNSET,
    elem_layout: UNSET,
    link_source: UNSET,
    observable: UNSET,
    observable_terminal: UNSET,
    observable_token: UNSET,
    polymorphic_shared: UNSET
  )
    next_ownership = T.let(ownership.equal?(UNSET) ? self.ownership : T.cast(ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_ownership_set = T.let(
      ownership_set.equal?(UNSET) ? (!ownership.equal?(UNSET) || self.ownership_set) : T.cast(ownership_set, T::Boolean),
      T::Boolean
    )
    next_sync = T.let(sync.equal?(UNSET) ? self.sync : T.cast(sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_layout = T.let(layout.equal?(UNSET) ? self.layout : T.cast(layout, T.nilable(Symbol)), T.nilable(Symbol))
    next_lock_rank = T.let(lock_rank.equal?(UNSET) ? self.lock_rank : T.cast(lock_rank, T.nilable(Integer)), T.nilable(Integer))
    next_collection = T.let(collection.equal?(UNSET) ? self.collection : T.cast(collection, T.nilable(Symbol)), T.nilable(Symbol))
    next_shard_count = T.let(shard_count.equal?(UNSET) ? self.shard_count : T.cast(shard_count, T.nilable(Integer)), T.nilable(Integer))
    next_soa = T.let(soa.equal?(UNSET) ? self.soa : T.cast(soa, T::Boolean), T::Boolean)
    next_elem_ownership = T.let(elem_ownership.equal?(UNSET) ? self.elem_ownership : T.cast(elem_ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_elem_sync = T.let(elem_sync.equal?(UNSET) ? self.elem_sync : T.cast(elem_sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_elem_layout = T.let(elem_layout.equal?(UNSET) ? self.elem_layout : T.cast(elem_layout, T.nilable(Symbol)), T.nilable(Symbol))
    next_link_source = T.let(link_source.equal?(UNSET) ? self.link_source : T.cast(link_source, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable = T.let(observable.equal?(UNSET) ? self.observable : T.cast(observable, T::Boolean), T::Boolean)
    next_observable_terminal = T.let(observable_terminal.equal?(UNSET) ? self.observable_terminal : T.cast(observable_terminal, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable_token = T.let(observable_token.equal?(UNSET) ? self.observable_token : T.cast(observable_token, T.nilable(Lexer::Token)), T.nilable(Lexer::Token))
    next_polymorphic_shared = T.let(polymorphic_shared.equal?(UNSET) ? self.polymorphic_shared : T.cast(polymorphic_shared, T::Boolean), T::Boolean)

    return self if next_ownership == self.ownership && next_ownership_set == self.ownership_set &&
      next_sync == self.sync && next_layout == self.layout && next_lock_rank == self.lock_rank &&
      next_collection == self.collection && next_shard_count == self.shard_count && next_soa == self.soa &&
      next_elem_ownership == self.elem_ownership && next_elem_sync == self.elem_sync &&
      next_elem_layout == self.elem_layout && next_link_source == self.link_source &&
      next_observable == self.observable && next_observable_terminal == self.observable_terminal &&
      next_observable_token == self.observable_token && next_polymorphic_shared == self.polymorphic_shared

    TypeCapabilities.new(
      ownership: next_ownership,
      ownership_set: next_ownership_set,
      sync: next_sync,
      layout: next_layout,
      lock_rank: next_lock_rank,
      collection: next_collection,
      shard_count: next_shard_count,
      soa: next_soa,
      elem_ownership: next_elem_ownership,
      elem_sync: next_elem_sync,
      elem_layout: next_elem_layout,
      link_source: next_link_source,
      observable: next_observable,
      observable_terminal: next_observable_terminal,
      observable_token: next_observable_token,
      polymorphic_shared: next_polymorphic_shared
    )
  end

  sig { returns(TypeCapabilities) }
  def without_runtime_wrappers
    with(
      ownership: :affine,
      ownership_set: false,
      sync: nil,
      layout: nil,
      elem_ownership: nil,
      elem_sync: nil,
      elem_layout: nil
    )
  end

  sig { returns(T::Boolean) }
  def inline_migration_safe?
    return false unless lock_rank.nil? && elem_ownership.nil? && elem_sync.nil? &&
      elem_layout.nil? && link_source.nil? && observable_terminal.nil?
    return false if polymorphic_shared

    collection.nil? || collection == :list || collection == :set || collection == :pool
  end

  sig { returns(T::Boolean) }
  def explicit_layer_capability?
    (!ownership.nil? && ownership != :affine) || !sync.nil? || !layout.nil? || !lock_rank.nil? ||
      !shard_count.nil? || soa || !elem_ownership.nil? || !elem_sync.nil? ||
      !elem_layout.nil? || !link_source.nil? || observable ||
      !observable_terminal.nil? || polymorphic_shared
  end

  sig { params(ownership: MaybeSymbol, sync: MaybeSymbol, layout: MaybeSymbol).returns(T::Boolean) }
  def element_update_requested?(ownership:, sync:, layout:)
    !ownership.equal?(UNSET) || !sync.equal?(UNSET) || !layout.equal?(UNSET) ||
      !elem_ownership.nil? || !elem_sync.nil? || !elem_layout.nil?
  end

  # Shared default for T::Struct `factory:` props. `default:` deep-clones
  # non-primitive values per instantiation even when frozen; a factory
  # returning this frozen instance is the only T::Props path that shares.
  # The .freeze is redundant (initialize freezes) but marks immutability
  # where the constant is declared.
  AFFINE = T.let(TypeCapabilities.new(ownership: :affine).freeze, TypeCapabilities)

  # Surface-name tables are syntax facts: how a capability symbol is spelled
  # in CLEAR source. Semantic Type delegates here, never the reverse.
  sig { params(value: Symbol).returns(T.nilable(String)) }
  def self.ownership_surface_name_for(value)
    return "@multiowned" if value == :multiowned
    return "@shared" if value == :shared
    return "@node" if value == :node
    return "@shared:node" if value == :shared_node
    return "@split" if value == :split
    return "@link" if value == :link
    return "@frozen" if value == :frozen

    nil
  end

  sig { params(value: Symbol).returns(T.nilable(String)) }
  def self.sync_surface_name_for(value)
    return "@locked" if value == :locked
    return "@writeLocked" if value == :write_locked
    return "@versioned" if value == :versioned
    return "@atomic" if value == :atomic
    return "@alwaysMutable" if value == :always_mutable
    return "@local" if value == :local
    return "@raw" if value == :raw
    return "@symbol" if value == :symbol
    return "@c" if value == :c
    return "@size" if value == :size

    nil
  end
end
