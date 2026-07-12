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
    source = node.value
    symbol = node.respond_to?(:symbol) ? T.unsafe(node).symbol : nil
    return unless self.class.source?(source) && symbol.is_a?(SymbolEntry)
    root = source_root_identifier(source)
    return unless root
    source_id = binding_id(root)
    return unless source_id
    source_name = self.class.source_display(source)
    root_id, root_name = @alias_roots.fetch(source_id, [source_id, source_name])
    fact = Alias.new(
      declaration: node,
      source: source,
      source_id: source_id,
      destination_id: symbol.binding_id,
      source_name: source_name,
      destination_name: node.name.to_s,
      root_id: root_id,
      root_name: root_name,
      ordinal: next_ordinal,
      ancestors: ancestors.dup.freeze,
      whole_binding: source.is_a?(AST::Identifier),
    )
    @aliases << fact
    @alias_roots[symbol.binding_id] = [root_id, root_name]
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
      source_reads = @reads.select do |event|
        event.ordinal > fact.ordinal && (event.binding_id == fact.source_id || event.binding_id == fact.root_id)
      end
      destination_reads = @reads.select do |event|
        event.ordinal > fact.ordinal && event.binding_id == fact.destination_id
      end
      mutations = @mutations.select do |event|
        event.ordinal > fact.ordinal && [fact.source_id, fact.root_id, fact.destination_id].include?(event.binding_id)
      end
      conflict = mutations.find do |mutation|
        counterpart_reads = if mutation.binding_id == fact.destination_id
          source_reads
        else
          destination_reads
        end
        counterpart_reads.any? do |use|
          ((use.ordinal > mutation.ordinal) || loop_backedge_reaches?(fact, mutation, use)) &&
            !mutually_exclusive?(mutation, use)
        end
      end
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


  sig { returns(T::Array[TransferDecision]) }
  def transfer_decisions
    @transfers.map do |transfer|
      later_read = @reads.any? do |event|
        event.ordinal > transfer.ordinal && event.binding_id == transfer.source_id
      end
      TransferDecision.new(transfer: transfer, materialize: later_read)
    end
  end

  private

  sig { params(node: AST::Identifier).returns(T.nilable(Integer)) }
  def binding_id(node)
    symbol = node.symbol
    symbol.is_a?(SymbolEntry) ? symbol.ownership_binding_id : nil
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
    left.ancestors.filter_map do |node|
      node if node.is_a?(AST::IfStatement)
    end.any? do |conditional|
      left_side = conditional_side(left, conditional)
      right_side = conditional_side(right, conditional)
      left_side && right_side && left_side != right_side
    end
  end

  sig { params(event: Event, conditional: AST::IfStatement).returns(T.nilable(Symbol)) }
  def conditional_side(event, conditional)
    index = event.ancestors.index(conditional)
    return nil unless index
    child = event.ancestors[index + 1] || event.node
    return :then if conditional.then_branch.include?(child)
    return :else if conditional.else_branch.include?(child)
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
