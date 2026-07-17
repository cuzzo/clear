# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

require_relative "../ast/ast"
require_relative "../ast/scope"

module CapabilityPlan
  extend T::Sig

  CapabilityVarNode = T.type_alias { AST::Locatable }

  LOCK_CAPABILITIES = T.let(Set[:EXCLUSIVE, :write_locked_read].freeze, T::Set[Symbol])
  VIEW_CAPABILITIES = T.let(Set[:VIEW, :MATERIALIZED_VIEW, :UNSAFE_VIEW].freeze, T::Set[Symbol])

  class CapabilityRequest < T::Struct
    extend T::Sig

    const :source, AST::Capability
    const :capability, Symbol
    const :var_node, CapabilityVarNode
    const :alias_name, T.nilable(String)
    const :alias_explicit, T::Boolean
    const :alias_mutable, T::Boolean
    const :guard_expr, T.nilable(AST::Locatable)
    const :view_length, T.nilable(AST::Locatable)

    sig { params(source: AST::Capability).returns(CapabilityRequest) }
    def self.from_ast(source)
      alias_name = T.cast(source[:alias], T.nilable(String))
      CapabilityRequest.new(
        source: source,
        capability: T.cast(source[:capability] || :infer, Symbol),
        var_node: T.cast(source[:var_node], AST::Locatable),
        alias_name: alias_name,
        alias_explicit: !alias_name.nil?,
        alias_mutable: source[:alias_mutable] == true,
        guard_expr: T.cast(source[:guard_expr], T.nilable(AST::Locatable)),
        view_length: T.cast(source[:view_length], T.nilable(AST::Locatable)),
      )
    end

    sig { returns(T::Boolean) }
    def inferred?
      capability == :infer
    end

    sig { returns(String) }
    def effective_alias_name
      alias_name || CapabilityPlan.var_name_for(var_node)
    end
  end

  class CapabilityTargetFact < T::Struct
    extend T::Sig

    const :var_node, CapabilityVarNode
    const :var_name, String
    const :target_label, String
    const :field_target, T::Boolean
    const :index_target, T::Boolean
    const :resolved_type, Type
    const :old_scope, T.nilable(Scope)
    const :source_entry, T.nilable(SymbolEntry)
    const :source_type, Type
    const :sync, T.nilable(Symbol)
    const :storage, T.nilable(Symbol)
    const :layout, T.nilable(Symbol)
    const :live_symbol_refreshed, T::Boolean

    sig { returns(T.nilable(Symbol)) }
    def lock_identity
      resolved_type.base_type
    end

    sig { params(source_entry: T.nilable(SymbolEntry)).returns(CapabilityTargetFact) }
    def with_source_entry(source_entry)
      return self unless source_entry

      CapabilityTargetFact.new(
        var_node: var_node,
        var_name: var_name,
        target_label: target_label,
        field_target: field_target,
        index_target: index_target,
        resolved_type: resolved_type,
        old_scope: old_scope,
        source_entry: source_entry,
        source_type: Type.new(source_entry.type),
        sync: source_entry.sync || resolved_type.sync,
        storage: source_entry.storage,
        layout: source_entry.layout || resolved_type.layout,
        live_symbol_refreshed: true,
      )
    end
  end

  class CapabilityTransition < T::Struct
    extend T::Sig

    const :request, CapabilityRequest
    const :target, CapabilityTargetFact
    const :source, AST::Capability
    const :capability, Symbol
    const :var_node, CapabilityVarNode
    const :var_name, String
    const :target_label, String
    const :alias_name, String
    const :alias_explicit, T::Boolean
    const :alias_mutable, T::Boolean
    const :guard_expr, T.nilable(AST::Locatable)
    const :view_length, T.nilable(AST::Locatable)
    const :resolved_type, Type
    const :old_scope, T.nilable(Scope)
    const :source_entry, T.nilable(SymbolEntry)
    const :field_target, T::Boolean
    const :sync, T.nilable(Symbol)
    const :storage, T.nilable(Symbol)
    const :layout, T.nilable(Symbol)
    const :source_type, Type
    const :lock_identity_value, T.nilable(Symbol)
    const :borrowed_qualifier, T.nilable(String)

    sig { returns(T::Boolean) }
    def lock_capability?
      LOCK_CAPABILITIES.include?(capability)
    end

    sig { returns(T::Boolean) }
    def restrict?
      capability == :RESTRICT
    end

    sig { returns(T::Boolean) }
    def borrowed?
      capability == :BORROWED
    end

    sig { returns(T::Boolean) }
    def snapshot?
      capability == :SNAPSHOT
    end

    sig { returns(T::Boolean) }
    def view?
      VIEW_CAPABILITIES.include?(capability)
    end

    sig { returns(T::Boolean) }
    def deferred_lock_param?
      (deferred_sync_param? && lock_capability?) == true
    end

    sig { returns(T::Boolean) }
    def deferred_sync_param?
      (parameter_target? && sync.nil? && !declared_sync_contract?) == true
    end

    sig { returns(T::Boolean) }
    def parameter_target?
      source_entry&.is_param == true
    end

    sig { returns(T::Boolean) }
    def declared_sync_contract?
      entry = source_entry
      return false unless entry

      entry.declared_sync_contract?
    end

    sig { returns(T::Boolean) }
    def exclusive_sync?
      SymbolEntry.locked_family_sync?(sync)
    end

    sig { returns(T::Boolean) }
    def write_locked_sync?
      SymbolEntry.write_locked_sync?(sync)
    end

    sig { returns(Symbol) }
    def exclusive_validation_action
      return :valid if exclusive_sync?
      return :declared_contract if parameter_target? && declared_sync_contract?
      return :defer if deferred_sync_param?

      :mismatch
    end

    sig { returns(T::Boolean) }
    def unwraps_sync_alias?
      return !sync.nil? if field_target

      !sync.nil? || deferred_lock_param?
    end

    sig { returns(T::Boolean) }
    def declares_plain_restrict_alias?
      restrict? && alias_explicit && sync.nil?
    end

    sig { returns(Type) }
    def declared_source_type
      source_type
    end

    sig { returns(T.nilable(String)) }
    def borrowed_rejection_qualifier
      borrowed_qualifier
    end

    sig { returns(T.nilable(Symbol)) }
    def lock_identity
      lock_identity_value
    end

    sig { returns(T::Boolean) }
    def sync_constrained?
      case capability
      when :EXCLUSIVE, :write_locked_read, :SNAPSHOT, :ATOMIC
        true
      when :infer
        entry = source_entry
        if entry
          families = entry.sync_families
          !entry.sync.nil? || (families ? !families.empty? : false)
        else
          false
        end
      else
        false
      end
    end

    sig { returns(T::Boolean) }
    def admits_atomic?
      sym = source_entry
      return false unless sym
      return true if sym.atomic?

      fams = sym.sync_families
      return false unless fams.is_a?(Set)

      expanded = fams.flat_map { |fam| fam == :SNAPSHOTTED ? [:VERSIONED, :ATOMIC] : [fam] }.to_set
      expanded.include?(:ATOMIC)
    end

    sig { params(source_entry: T.nilable(SymbolEntry)).returns(CapabilityTransition) }
    def with_source_entry(source_entry)
      refreshed_target = target.with_source_entry(source_entry)
      CapabilityPlan.transition_from(request, refreshed_target, borrowed_qualifier)
    end

    private :deferred_lock_param?, :exclusive_sync?, :lock_capability?, :parameter_target?
  end

  WithCapabilityFacts = T.type_alias { T::Array[CapabilityTransition] }

  class WithCapabilityPlan < T::Struct
    extend T::Sig

    prop :all, WithCapabilityFacts, factory: -> { [] }

    sig { params(fact: CapabilityTransition).void }
    def add(fact)
      all << fact
    end

    sig { returns(WithCapabilityFacts) }
    def locks
      all.select { |fact| LOCK_CAPABILITIES.include?(fact.capability) }
    end

    sig { returns(WithCapabilityFacts) }
    def guarded
      all.select { |fact| !fact.guard_expr.nil? }
    end

    sig { returns(WithCapabilityFacts) }
    def sync_constrained
      all.select { |fact| fact.sync_constrained? }
    end

    sig { returns(WithCapabilityFacts) }
    def snapshot_transitions
      all.select { |fact| fact.snapshot? }
    end

    sig { returns(T::Boolean) }
    def mutable_snapshot?
      snapshot_transitions.any? { |fact| fact.alias_mutable }
    end

    sig { returns(CapabilityTransition) }
    def first_transition
      T.must(all.first)
    end

    sig { params(live_symbols: T::Hash[String, SymbolEntry]).returns(WithCapabilityPlan) }
    def refresh_live_symbols(live_symbols)
      refreshed = WithCapabilityPlan.new
      all.each do |fact|
        refreshed.add(fact.with_source_entry(live_symbols[fact.var_name]))
      end
      refreshed
    end
  end

  sig { params(var_node: AST::Locatable).returns(String) }
  def self.var_name_for(var_node)
    root = AST.root_identifier(var_node)
    return root.name if root
    return var_node.field.to_s if var_node.is_a?(AST::GetField)

    "__unknown"
  end

  sig do
    params(
      request: CapabilityRequest,
      target: CapabilityTargetFact,
      borrowed_qualifier: T.nilable(String),
    ).returns(CapabilityTransition)
  end
  def self.transition_from(request, target, borrowed_qualifier)
    capability = request.source[:capability] || request.capability
    capability = T.cast(capability, Symbol)
    CapabilityTransition.new(
      request: request,
      target: target,
      source: request.source,
      capability: capability,
      var_node: request.var_node,
      var_name: target.var_name,
      target_label: target.target_label,
      alias_name: request.alias_name || target.var_name,
      alias_explicit: request.alias_explicit,
      alias_mutable: request.alias_mutable,
      guard_expr: request.guard_expr,
      view_length: request.view_length,
      resolved_type: Type.new(target.resolved_type),
      old_scope: target.old_scope,
      source_entry: target.source_entry,
      field_target: target.field_target,
      sync: target.sync,
      storage: target.storage,
      layout: target.layout,
      source_type: target.source_type,
      lock_identity_value: target.lock_identity,
      borrowed_qualifier: borrowed_qualifier,
    )
  end

  sig { params(fn: AST::FunctionDef, with_blocks: T::Array[AST::WithBlock]).void }
  def self.refresh_function_plans!(fn, with_blocks)
    live_symbols = Scope.live_param_syms(fn)
    return if live_symbols.empty?

    with_blocks.each do |node|
      plan = node.capability_plan
      next unless plan

      node.capability_plan = plan.refresh_live_symbols(live_symbols)
    end
  end

  sig { params(node: AST::WithBlock).returns(WithCapabilityPlan) }
  def self.require_for(node)
    plan = node.capability_plan
    raise "Internal: WITH block reached consumer without a CapabilityPlan" unless plan

    plan
  end
end

module AST
  class WithBlock
    extend T::Sig

    sig { params(plan: CapabilityPlan::WithCapabilityPlan).void }
    def capability_plan=(plan)
      self[:capability_plan] = plan
    end

    sig { returns(T.nilable(CapabilityPlan::WithCapabilityPlan)) }
    def capability_plan
      T.cast(self[:capability_plan], T.nilable(CapabilityPlan::WithCapabilityPlan))
    end

  end
end
