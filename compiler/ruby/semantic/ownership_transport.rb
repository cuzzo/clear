# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

# Immutable semantic decision for one implicit ownership operation. DEFAULT
# and EASY consume the plan. STRICT may retain it for explanations and fixes,
# but preserves explicit affine lowering instead of applying inference.
class OwnershipTransportPlan < T::Struct
  const :action, Symbol
  const :source, String
  const :destination, String
  const :alias_root, String
  const :last_alias_use, T.nilable(AST::Identifier), default: nil
  const :conflicting_mutation, T.nilable(AST::Node), default: nil
  const :hidden_cost, T.nilable(Symbol), default: nil
end

class OwnershipTransportPlanner
  extend T::Sig

  Event = Struct.new(:node, :ancestors, :ordinal)
  sig { params(body: T.any(AST::Node, T::Array[AST::Node]), parameter_names: T::Set[String], language_mode: Symbol).void }
  def self.plan!(body, parameter_names: Set.new, language_mode: :default)
    roots = body.is_a?(Array) ? body : [body]
    events = T.let([], T::Array[Event])
    roots.each { |root| collect(root, [], events) }
    stamp_future_uses!(events)
    stamp_alias_plans!(events, parameter_names)
    nil
  end

  sig { params(node: AST::Node, ancestors: T::Array[AST::Node], events: T::Array[Event]).void }
  def self.collect(node, ancestors, events)
    events << Event.new(node, ancestors.freeze, events.length)
    return if node.is_a?(AST::FunctionDef)

    next_ancestors = ancestors + [node]
    AST.each_child_node(node) { |child| collect(child, next_ancestors, events) }
  end
  private_class_method :collect

  sig { params(events: T::Array[Event]).void }
  def self.stamp_future_uses!(events)
    last = T.let({}, T::Hash[String, Integer])
    events.each do |event|
      node = event.node
      last[node.name] = event.ordinal if node.is_a?(AST::Identifier)
    end
    events.each do |event|
      node = event.node
      next unless node.is_a?(AST::Identifier)
      T.unsafe(node).ownership_future_use = T.must(last[node.name]) > event.ordinal
    end
  end
  private_class_method :stamp_future_uses!

  sig { params(events: T::Array[Event], parameter_names: T::Set[String]).void }
  def self.stamp_alias_plans!(events, parameter_names)
    declared = parameter_names.dup
    alias_roots = T.let({}, T::Hash[String, String])
    events.each do |event|
      node = event.node
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
      # BindExpr also represents language-defined borrows such as
      # `IF values[i] AS item`. Those already have precise, construct-specific
      # ownership rules and must never be reinterpreted as a plain alias.
      next if node.is_a?(AST::BindExpr) && event.ancestors.any? { |ancestor| ancestor.is_a?(AST::IfBind) }
      # BG/lambda bodies have their own capture and escape contracts. A local
      # declaration inside one is not an escape merely because the enclosing
      # execution boundary itself escapes.
      next if event.ancestors.any? do |ancestor|
        ancestor.is_a?(AST::BgBlock) || ancestor.is_a?(AST::BgStreamBlock) || ancestor.is_a?(AST::LambdaLit)
      end
      destination = node.name.to_s
      declared.add(destination)
      source_node = node.value
      next unless source_node.is_a?(AST::Identifier)

      source = source_node.name
      alias_root = alias_roots.fetch(source, source)
      # The declaration event precedes its RHS children in the preorder list;
      # those identifiers are the current transfer, not future uses.
      later = events.drop(event.ordinal + 1).reject { |candidate| candidate.ancestors.include?(node) }
      source_uses = later.select do |candidate|
        identifier_named?(candidate.node, source) || identifier_named?(candidate.node, alias_root)
      end
      destination_uses = later.select { |candidate| identifier_named?(candidate.node, destination) }
      if source_uses.empty? && !parameter_names.include?(source) && !alias_roots.key?(source)
        T.unsafe(node).ownership_transport_plan = OwnershipTransportPlan.new(
          action: :move, source: source, destination: destination, alias_root: alias_root,
        )
        next
      end

      last_alias_event = destination_uses.last
      last_alias = last_alias_event&.node
      if last_alias.is_a?(AST::Identifier)
        releases = T.unsafe(last_alias).ownership_alias_releases || []
        T.unsafe(last_alias).ownership_alias_releases = releases + [destination]
      end
      # Direct assignments are syntactically unambiguous here. Calls are
      # deliberately checked later, after normal overload resolution has
      # selected the exact stdlib or user FunctionSignature.
      mutations = later.select { |candidate| mutation_of?(candidate.node, alias_root, destination) }
      conflict = mutations.find do |mutation|
        destination_uses.any? do |use|
          ((use.ordinal > mutation.ordinal) || loop_backedge_reaches?(event, mutation, use)) &&
            !mutually_exclusive?(mutation, use)
        end
      end
      # NLL across branches: if a mutation can only execute on paths where the
      # alias has no later use, release that branch's borrow before the write.
      mutations.each do |mutation|
        next if destination_uses.any? do |use|
          ((use.ordinal > mutation.ordinal) || loop_backedge_reaches?(event, mutation, use)) &&
            !mutually_exclusive?(mutation, use)
        end
        next unless mutation.node.is_a?(AST::Assignment)
        releases = T.unsafe(mutation.node).ownership_alias_releases_before || []
        T.unsafe(mutation.node).ownership_alias_releases_before = releases + [destination]
      end
      escapes = destination_uses.any? { |candidate| escape_use?(candidate) }
      T.unsafe(node).ownership_transport_plan = OwnershipTransportPlan.new(
        action: escapes ? :materialize : :borrow,
        source: source,
        destination: destination,
        alias_root: alias_root,
        last_alias_use: last_alias.is_a?(AST::Identifier) ? last_alias : nil,
        conflicting_mutation: conflict&.node,
        hidden_cost: escapes ? :copy_or_retain : nil,
      )
      alias_roots[destination] = alias_root unless escapes
    end
  end
  private_class_method :stamp_alias_plans!

  sig { params(node: AST::Node, name: String).returns(T::Boolean) }
  def self.identifier_named?(node, name)
    node.is_a?(AST::Identifier) && node.name == name
  end
  private_class_method :identifier_named?

  sig { params(node: AST::Node, source: String, destination: String).returns(T::Boolean) }
  def self.mutation_of?(node, source, destination)
    names = Set[source, destination]
    if node.is_a?(AST::Assignment) || node.is_a?(AST::BindExpr)
      root = AST.root_identifier(node.name) rescue nil
      assigned = root&.name || (node.name.is_a?(String) ? node.name : nil)
      return true if assigned && names.include?(assigned.to_s)
    end
    false
  end
  private_class_method :mutation_of?

  sig { params(event: Event).returns(T::Boolean) }
  def self.escape_use?(event)
    event.ancestors.any? do |ancestor|
      ancestor.is_a?(AST::ReturnNode) || ancestor.is_a?(AST::BgBlock) ||
        ancestor.is_a?(AST::BgStreamBlock) || ancestor.is_a?(AST::LambdaLit)
    end
  end
  private_class_method :escape_use?

  sig { params(left: Event, right: Event).returns(T::Boolean) }
  def self.mutually_exclusive?(left, right)
    shared = left.ancestors.select { |ancestor| ancestor.is_a?(AST::IfStatement) }
    shared.any? do |conditional|
      left_side = conditional_side(left, conditional)
      right_side = conditional_side(right, conditional)
      left_side && right_side && left_side != right_side
    end
  end
  private_class_method :mutually_exclusive?

  sig { params(event: Event, conditional: AST::IfStatement).returns(T.nilable(Symbol)) }
  def self.conditional_side(event, conditional)
    index = event.ancestors.index(conditional)
    return nil unless index
    child = event.ancestors[index + 1] || event.node
    return :then if conditional.then_branch.include?(child)
    return :else if conditional.else_branch.include?(child)

    nil
  end
  private_class_method :conditional_side

  sig { params(declaration: Event, mutation: Event, use: Event).returns(T::Boolean) }
  def self.loop_backedge_reaches?(declaration, mutation, use)
    mutation.ancestors.any? do |ancestor|
      loop_node = ancestor.is_a?(AST::WhileLoop) || ancestor.is_a?(AST::WhileBindLoop) ||
        ancestor.is_a?(AST::ForRange) || ancestor.is_a?(AST::ForEach)
      loop_node && use.ancestors.include?(ancestor) && !declaration.ancestors.include?(ancestor)
    end
  end
  private_class_method :loop_backedge_reaches?
end
