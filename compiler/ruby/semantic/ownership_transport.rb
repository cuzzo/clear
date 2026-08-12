# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

# Final contract consumed by annotation, MIR ownership dataflow, and lowering.
class OwnershipTransportPlan < T::Struct
  const :action, Symbol
  const :source, String
  const :destination, String
  const :alias_root, String
  const :last_alias_use, T.nilable(AST::Identifier), default: nil
  const :conflicting_mutation, T.nilable(AST::Node), default: nil
  const :hidden_cost, T.nilable(Symbol), default: nil
end

# Facts are emitted by the normal semantic visitor after binding resolution.
# There is intentionally no AST walker here: identifiers are keyed by their
# SymbolEntry binding id, and mutable calls arrive only after exact signature
# resolution has identified MUTABLE parameters.
class OwnershipTransportFacts
  extend T::Sig

  class Event < T::Struct
    const :node, AST::Node
    const :binding_id, Integer
    const :ordinal, Integer
    const :ancestors, T::Array[AST::Node]
    const :escape, T::Boolean, default: false
  end

  class Alias < T::Struct
    const :declaration, T.any(AST::VarDecl, AST::BindExpr)
    const :source, AST::Node
    const :source_id, Integer
    const :destination_id, Integer
    const :source_name, String
    const :destination_name, String
    const :root_id, Integer
    const :root_name, String
    const :ordinal, Integer
    const :ancestors, T::Array[AST::Node]
    const :whole_binding, T::Boolean
  end

  class Decision < T::Struct
    const :alias_fact, Alias
    const :plan, OwnershipTransportPlan
  end

  class Transfer < T::Struct
    const :container, AST::Node
    const :slot, T.any(Integer, String)
    const :source, AST::Identifier
    const :source_id, Integer
    const :ordinal, Integer
  end

  class TransferDecision < T::Struct
    const :transfer, Transfer
    const :materialize, T::Boolean
  end

  sig { params(parameter_ids: T::Set[Integer]).void }
  def initialize(parameter_ids: Set.new)
    @parameter_ids = T.let(parameter_ids, T::Set[Integer])
    @reads = T.let([], T::Array[Event])
    @mutations = T.let([], T::Array[Event])
    @aliases = T.let([], T::Array[Alias])
    @transfers = T.let([], T::Array[Transfer])
    @alias_roots = T.let({}, T::Hash[Integer, [Integer, String]])
    @ordinal = T.let(0, Integer)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def self.source?(node)
    node.is_a?(AST::Identifier) || node.is_a?(AST::GetField) || node.is_a?(AST::GetIndex)
  end

  sig { params(node: AST::Node).returns(String) }
  def self.source_display(node)
    case node
    when AST::Identifier
      node.name
    when AST::GetField
      "#{source_display(node.target)}.#{node.field}"
    when AST::GetIndex
      "#{source_display(node.target)}[...]"
    else
      "value"
    end
  end

  sig { returns(Integer) }
  def next_ordinal
    value = @ordinal
    @ordinal += 1
    value
  end

  sig { params(node: AST::Identifier, ancestors: T::Array[AST::Node]).void }
  def record_read(node, ancestors)
    id = binding_id(node)
    return unless id
    @reads << Event.new(
      node: node,
      binding_id: id,
      ordinal: next_ordinal,
      ancestors: ancestors.dup.freeze,
      escape: ancestors.any? { |ancestor| escape_ancestor?(ancestor) },
    )
  end

  sig { params(node: AST::Node, identifier: AST::Identifier, ancestors: T::Array[AST::Node]).void }
  def record_mutation(node, identifier, ancestors)
    id = binding_id(identifier)
    return unless id
    record_mutation_id(node, id, ancestors)
  end

  sig { params(node: AST::Node, binding_id: Integer, ancestors: T::Array[AST::Node]).void }
  def record_mutation_id(node, binding_id, ancestors)
    @mutations << Event.new(
      node: node,
      binding_id: binding_id,
      ordinal: next_ordinal,
      ancestors: ancestors.dup.freeze,
    )
  end

  sig { params(node: T.any(AST::VarDecl, AST::BindExpr), ancestors: T::Array[AST::Node]).void }
  def record_alias(node, ancestors)
    source = T.let(node, AST::Node)
    symbol = T.let(nil, T.nilable(SymbolEntry))
    if node.is_a?(AST::VarDecl)
      source = T.cast(node.value, AST::Node)
      symbol = node.symbol
    elsif node.is_a?(AST::BindExpr)
      source = T.cast(node.value, AST::Node)
      symbol = node.symbol
    end
    return unless self.class.source?(source)
    return unless symbol.is_a?(SymbolEntry)
    root = source_root_identifier(source)
    return unless root
    source_id = binding_id(root)
    return unless source_id
    source_name = self.class.source_display(source)
    fallback_root = T.let([source_id, source_name], [Integer, String])
    root_id, root_name = @alias_roots.fetch(source_id, fallback_root)
    destination_name = T.let("", String)
    if node.is_a?(AST::VarDecl)
      destination_name = node.name.to_s
    elsif node.is_a?(AST::BindExpr)
      destination_name = node.name.to_s
    end
    fact = Alias.new(
      declaration: node,
      source: source,
      source_id: source_id,
      destination_id: T.must(symbol).binding_id,
      source_name: source_name,
      destination_name: destination_name,
      root_id: root_id,
      root_name: root_name,
      ordinal: next_ordinal,
      ancestors: ancestors.dup.freeze,
      whole_binding: source.is_a?(AST::Identifier),
    )
    @aliases << fact
    @alias_roots[T.must(symbol).binding_id] = [root_id, root_name]
  end

  sig { params(container: AST::Node, slot: T.any(Integer, String), source: AST::Identifier).void }
  def record_transfer(container, slot, source)
    id = binding_id(source)
    return unless id
    @transfers << Transfer.new(
      container: container,
      slot: slot,
      source: source,
      source_id: id,
      ordinal: next_ordinal,
    )
  end

  sig { returns(T::Array[Decision]) }
  def decisions
    @aliases.map do |fact|
      source_reads = source_reads_after(fact)
      destination_reads = destination_reads_after(fact)
      mutations = mutations_after(fact)
      conflict = conflict_for(fact, source_reads, destination_reads, mutations)
      last_alias = destination_reads.last&.node
      escapes = destination_reads.any?(&:escape)
      action = if fact.whole_binding && source_reads.empty? && !@parameter_ids.include?(fact.source_id) && !@alias_roots.key?(fact.source_id)
        :move
      elsif escapes
        :materialize
      else
        :borrow
      end
      Decision.new(
        alias_fact: fact,
        plan: OwnershipTransportPlan.new(
          action: action,
          source: fact.source_name,
          destination: fact.destination_name,
          alias_root: fact.root_name,
          last_alias_use: last_alias.is_a?(AST::Identifier) ? last_alias : nil,
          conflicting_mutation: conflict&.node,
          hidden_cost: action == :materialize ? :copy_or_retain : nil,
        ),
      )
    end
  end

  sig { params(fact: Alias).returns(T::Array[Event]) }
  def source_reads_after(fact)
    @reads.select do |event|
      event.ordinal > fact.ordinal && (event.binding_id == fact.source_id || event.binding_id == fact.root_id)
    end
  end
  private :source_reads_after

  sig { params(fact: Alias).returns(T::Array[Event]) }
  def destination_reads_after(fact)
    @reads.select do |event|
      event.ordinal > fact.ordinal && event.binding_id == fact.destination_id
    end
  end
  private :destination_reads_after

  sig { params(fact: Alias).returns(T::Array[Event]) }
  def mutations_after(fact)
    @mutations.select do |event|
      event.ordinal > fact.ordinal && [fact.source_id, fact.root_id, fact.destination_id].include?(event.binding_id)
    end
  end
  private :mutations_after

  sig do
    params(
      fact: Alias,
      source_reads: T::Array[Event],
      destination_reads: T::Array[Event],
      mutations: T::Array[Event],
    ).returns(T.nilable(Event))
  end
  def conflict_for(fact, source_reads, destination_reads, mutations)
    mutations.find do |mutation|
      mutation_conflicts?(fact, source_reads, destination_reads, mutation)
    end
  end
  private :conflict_for

  sig do
    params(
      fact: Alias,
      source_reads: T::Array[Event],
      destination_reads: T::Array[Event],
      mutation: Event,
    ).returns(T::Boolean)
  end
  def mutation_conflicts?(fact, source_reads, destination_reads, mutation)
    counterpart_reads = if mutation.binding_id == fact.destination_id
      source_reads
    else
      destination_reads
    end
    counterpart_reads.any? do |use|
      conflicting_use?(fact, mutation, use)
    end
  end
  private :mutation_conflicts?

  sig { params(fact: Alias, mutation: Event, use: Event).returns(T::Boolean) }
  def conflicting_use?(fact, mutation, use)
    ((use.ordinal > mutation.ordinal) || loop_backedge_reaches?(fact, mutation, use)) &&
      !mutually_exclusive?(mutation, use)
  end
  private :conflicting_use?


  sig { returns(T::Array[TransferDecision]) }
  def transfer_decisions
    @transfers.map do |transfer|
      later_read = later_read_after_transfer?(transfer)
      # Function parameters are borrows unless declared TAKES. They can never
      # be transferred into an owned field/container, even when this is their
      # final read. Generic parameters make this especially important: the
      # concrete specialization may require cleanup even though annotation
      # cannot see that representation yet.
      borrowed_parameter = borrowed_parameter_transfer?(transfer)
      TransferDecision.new(transfer: transfer, materialize: later_read || borrowed_parameter)
    end
  end

  sig { params(transfer: Transfer).returns(T::Boolean) }
  def later_read_after_transfer?(transfer)
    @reads.any? do |event|
      event.ordinal > transfer.ordinal && event.binding_id == transfer.source_id
    end
  end
  private :later_read_after_transfer?

  sig { params(transfer: Transfer).returns(T::Boolean) }
  def borrowed_parameter_transfer?(transfer)
    @parameter_ids.include?(transfer.source_id) && transfer.source.symbol&.takes != true
  end
  private :borrowed_parameter_transfer?

  private

  sig { params(node: AST::Identifier).returns(T.nilable(Integer)) }
  def binding_id(node)
    node.symbol&.ownership_binding_id
  end

  sig { params(node: AST::Node).returns(T.nilable(AST::Identifier)) }
  def source_root_identifier(node)
    root = AST.root_identifier(node)
    root.is_a?(AST::Identifier) ? root : nil
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def escape_ancestor?(node)
    node.is_a?(AST::ReturnNode) || node.is_a?(AST::BgBlock) ||
      node.is_a?(AST::BgStreamBlock) || node.is_a?(AST::LambdaLit)
  end

  sig { params(left: Event, right: Event).returns(T::Boolean) }
  def mutually_exclusive?(left, right)
    left.ancestors.each do |node|
      next unless node.is_a?(AST::IfStatement)

      conditional = T.cast(node, AST::IfStatement)
      left_side = conditional_side(left, conditional)
      right_side = conditional_side(right, conditional)
      return true if left_side && right_side && left_side != right_side
    end
    false
  end

  sig { params(event: Event, conditional: AST::IfStatement).returns(T.nilable(Symbol)) }
  def conditional_side(event, conditional)
    index = conditional_index(event, conditional)
    return nil unless index
    child = T.let(event.node, AST::Node)
    child_index = index + 1
    child = event.ancestors.fetch(child_index) if child_index < event.ancestors.length
    return :then if conditional.then_branch.include?(child)
    else_branch = conditional.else_branch
    if else_branch
      return :else if else_branch.include?(child)
    end
    nil
  end

  sig { params(event: Event, conditional: AST::IfStatement).returns(T.nilable(Integer)) }
  def conditional_index(event, conditional)
    index = T.let(0, Integer)
    while index < event.ancestors.length
      candidate = event.ancestors.fetch(index)
      if candidate.is_a?(AST::IfStatement)
        narrowed = T.cast(candidate, AST::IfStatement)
        return index if narrowed == conditional
      end
      index += 1
    end
    nil
  end

  sig { params(declaration: Alias, mutation: Event, use: Event).returns(T::Boolean) }
  def loop_backedge_reaches?(declaration, mutation, use)
    mutation.ancestors.any? do |ancestor|
      loop_node = ancestor.is_a?(AST::WhileLoop) || ancestor.is_a?(AST::WhileBindLoop) ||
        ancestor.is_a?(AST::ForRange) || ancestor.is_a?(AST::ForEach)
      loop_node && use.ancestors.include?(ancestor) &&
        !declaration.ancestors.include?(ancestor)
    end
  end
end
