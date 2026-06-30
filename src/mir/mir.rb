# typed: strict
# src/mir.rb - Comprehensive MIR (Mid-level IR) for CLEAR -> Zig compilation
#
# Every program construct is represented as an MIR node. The emitter
# (MIREmitter) maps each node to a Zig code template. The emitter makes
# ZERO type decisions, ZERO allocator decisions, ZERO schema lookups.
#
# Design principles:
# 1. Zig-targeted: each node maps 1:1 to a Zig code pattern
# 2. All memory explicit: every alloc/dealloc/copy/move is a node
# 3. Structured control flow: preserves if/while/for/block (Zig requires it)
# 4. Type-bearing verification data carries Type objects; Zig-only templates
#    carry target strings.
# 5. Recursive expressions: expression nodes contain sub-expression nodes
#
# Old MIR nodes (Drop, Promote, SuppressCleanup, Return,
# ReassignCleanup, FieldCleanup) in ast.rb remain for the existing pipeline.
# New nodes here use distinct names to coexist during migration.

require "sorbet-runtime"
require_relative "../annotator/helpers/intrinsic_registry"
require_relative "../ast/type"
require_relative "../ast/ast"
require_relative "../semantic/pass_state"
require_relative "cleanup_entry"

module MIR
  extend T::Sig

  sig { params(node: T.nilable(MIR::Node)).returns(T::Boolean) }
  def self.const_u8_literal_cast?(node)
    return false unless node.is_a?(MIR::Cast)

    !!(node.method == :as && node.target_type == "[]const u8" && node.expr.is_a?(MIR::Lit))
  end

  sig { params(node: T.nilable(MIR::Node)).returns(T::Boolean) }
  def self.expr_wrapper?(node)
    node.respond_to?(:expr) &&
      (node.is_a?(MIR::Cast) || node.is_a?(MIR::TryExpr) || node.is_a?(MIR::TryCatch))
  end

  class OwnershipOperandFact < T::Struct
    extend T::Sig

    const :kind, Symbol
    const :name, T.nilable(String)
    const :borrowed, T::Boolean
    const :type_info, Type
    const :source, String
    const :target_alloc, T.nilable(Symbol), default: nil

    sig { params(name: String, type_info: Type, source: String, target_alloc: T.nilable(Symbol)).returns(OwnershipOperandFact) }
    def self.owned_binding(name, type_info, source, target_alloc = nil)
      new(kind: :owned_binding, name: name, borrowed: false, type_info: type_info, source: source, target_alloc: target_alloc)
    end

    sig { params(name: T.nilable(String), type_info: Type, source: String, target_alloc: T.nilable(Symbol)).returns(OwnershipOperandFact) }
    def self.borrowed_access(name, type_info, source, target_alloc = nil)
      new(kind: :borrowed_access, name: name, borrowed: true, type_info: type_info, source: source, target_alloc: target_alloc)
    end

    sig { params(type_info: Type, source: String).returns(OwnershipOperandFact) }
    def self.non_owning(type_info, source)
      new(kind: :non_owning, name: nil, borrowed: false, type_info: type_info, source: source, target_alloc: nil)
    end
  end

  class OwnershipContract
    extend T::Sig

    sig { returns(T::Array[String]) }
    attr_reader :produces
    sig { returns(T::Array[String]) }
    attr_reader :borrows
    sig { returns(T::Boolean) }
    attr_reader :covers_consuming_params
    sig { returns(T::Array[MIR::OwnershipOperandFact]) }
    attr_reader :operands

    sig do
      params(
        operands: T::Array[MIR::OwnershipOperandFact],
        produces: T::Array[String],
        borrows: T::Array[String],
        covers_consuming_params: T::Boolean,
      ).void
    end
    def initialize(operands: [], produces: [], borrows: [], covers_consuming_params: false)
      @operands = T.let(operands.dup.freeze, T::Array[MIR::OwnershipOperandFact])
      @produces = T.let(normalize_names(produces).freeze, T::Array[String])
      @borrows = T.let(normalize_names(borrows).freeze, T::Array[String])
      @covers_consuming_params = T.let(covers_consuming_params, T::Boolean)
    end

    sig { returns(OwnershipContract) }
    def self.empty
      new
    end

    sig { params(operands: T::Array[MIR::OwnershipOperandFact]).returns(OwnershipContract) }
    def self.consume_operands(operands)
      new(operands: operands, covers_consuming_params: true)
    end

    sig { returns(T::Array[String]) }
    def owned_operand_names
      @operands.reject(&:borrowed).filter_map(&:name).map(&:to_s).reject(&:empty?).uniq.freeze
    end

    sig { returns(T::Boolean) }
    def empty?
      @operands.empty? && @produces.empty? && @borrows.empty? && !@covers_consuming_params
    end

    private

    sig { params(names: T::Array[String]).returns(T::Array[String]) }
    def normalize_names(names)
      names.map(&:to_s).reject(&:empty?).uniq
    end
  end

  class CallableContract
    extend T::Sig

    sig { returns(FunctionSignature) }
    attr_reader :signature
    sig { returns(OwnershipContract) }
    attr_reader :ownership_contract
    sig { returns(Integer) }
    attr_reader :checked_arg_count

    sig { params(signature: FunctionSignature, ownership_contract: OwnershipContract, checked_arg_count: Integer).void }
    def initialize(signature, ownership_contract, checked_arg_count)
      @signature = signature
      @ownership_contract = ownership_contract
      @checked_arg_count = checked_arg_count
    end

    sig { params(checked_arg_count: Integer).returns(CallableContract) }
    def self.no_ownership(checked_arg_count)
      params = T.let([], T::Array[::AST::Param])
      checked_arg_count.times do |idx|
        params << ::AST::Param.new(name: "__arg#{idx}", type: Type.new(:Any))
      end
      new(
        FunctionSignature.new(params: params, return_type: Type.new(:Void)),
        OwnershipContract.new(covers_consuming_params: true),
        checked_arg_count,
      )
    end
  end

  class OwnershipEffect < T::Struct
    extend T::Sig

    const :produces_owned, T::Boolean
    const :alloc, T.nilable(Symbol)
    const :cleanup_kind, T.nilable(Symbol)
    const :requires_hoist, T::Boolean
    const :target_var, T.nilable(String)

    NONE = T.let(new(
      produces_owned: false,
      alloc: nil,
      cleanup_kind: nil,
      requires_hoist: false,
      target_var: nil,
    ).freeze, OwnershipEffect)

    sig { returns(OwnershipEffect) }
    def self.none
      NONE
    end

    sig { params(alloc: T.nilable(Symbol), cleanup_kind: Symbol, requires_hoist: T::Boolean, target_var: T.nilable(String)).returns(OwnershipEffect) }
    def self.owned(alloc:, cleanup_kind: :uniform, requires_hoist: true, target_var: nil)
      new(
        produces_owned: true,
        alloc: alloc,
        cleanup_kind: cleanup_kind,
        requires_hoist: requires_hoist,
        target_var: target_var,
      )
    end

    sig do
      params(
        emits_allocating: T::Boolean,
        heap_return_alloc: T::Boolean,
        fixed_void_without_alloc_metadata: T::Boolean,
        mutates_receiver_without_heap_return: T::Boolean,
        result_owns: T.nilable(T::Boolean),
        result_type: T.nilable(Type),
        alloc: T.nilable(Symbol),
        target_var: T.nilable(String)
      ).returns(OwnershipEffect)
    end
    def self.from_callable_facts(emits_allocating:, heap_return_alloc:,
                                 fixed_void_without_alloc_metadata:,
                                 mutates_receiver_without_heap_return:,
                                 result_owns:, result_type:, alloc:, target_var:)
      active = emits_allocating || heap_return_alloc
      explicitly_not_owned = heap_return_alloc && result_owns == false
      unknown_owned_result = heap_return_alloc && result_owns.nil? &&
                             result_type && !owned_result_type?(result_type)
      missing_allocator = alloc.nil? && !heap_return_alloc
      blocked = fixed_void_without_alloc_metadata ||
                mutates_receiver_without_heap_return ||
                explicitly_not_owned ||
                unknown_owned_result ||
                missing_allocator

      return none unless active
      return none if blocked

      owned(alloc: alloc, target_var: target_var)
    end

    sig { params(type_info: Type).returns(T::Boolean) }
    def self.owned_result_type?(type_info)
      ti = type_info.success_type || type_info
      ti = ti.wrapped_type || ti if ti.optional?
      ti.ownership_bearing?
    end

    sig { params(name: String).returns(OwnershipEffect) }
    def with_target(name)
      OwnershipEffect.new(
        produces_owned: produces_owned,
        alloc: alloc,
        cleanup_kind: cleanup_kind,
        requires_hoist: requires_hoist,
        target_var: name,
      )
    end
  end

  class BoundaryCaptureFact < T::Struct
    extend T::Sig

    const :name, String
    const :storage, T.nilable(Symbol)
    const :sync, T.nilable(Symbol)
    const :ownership, T.nilable(Symbol)
    const :parallel_safe, T::Boolean
    const :scheduler_affine, T::Boolean
    const :requires_pinned, T::Boolean
    const :forbidden_reason, T.nilable(Symbol)
  end

  class ExecutionBoundaryFact < T::Struct
    extend T::Sig

    const :kind, Symbol
    const :dispatch, Symbol
    const :captures, T::Array[BoundaryCaptureFact]
  end

  class FsmOwnershipFact < T::Struct
    extend T::Sig

    const :name, String
    const :target, Symbol
    const :target_alloc, T.nilable(Symbol)
    const :move_guarded, T::Boolean
  end

  class FsmResultTransferFact < T::Struct
    extend T::Sig

    const :name, String
    const :target_alloc, Symbol
    const :move_guarded, T::Boolean

    sig { returns(T::Array[MIR::Stmt]) }
    def marks
      MIR::OwnershipTransferPlan.new(
        name: name,
        target: :owned_sink,
        target_alloc: target_alloc,
        move_guarded: move_guarded,
      ).marks
    end
  end

  class OwnershipConsumptionFact < T::Struct
    extend T::Sig

    const :operands, T::Array[OwnershipOperandFact]
    const :target, Symbol
    const :target_alloc, T.nilable(Symbol), default: nil
    const :source, String
    const :covers_consuming_params, T::Boolean, default: false

    sig { returns(T::Array[String]) }
    def names
      operands.filter_map(&:name).map(&:to_s).reject(&:empty?).uniq
    end
  end

  class BodySlot
    extend T::Sig
    Body = T.type_alias { T::Array[MIR::Emittable] }
    Writer = T.type_alias { T.proc.params(body: MIR::BodySlot::Body).void }

    sig { returns(Symbol) }
    attr_reader :name
    sig { returns(MIR::BodySlot::Body) }
    attr_reader :body

    sig { params(name: Symbol, body: MIR::BodySlot::Body, writer: MIR::BodySlot::Writer).void }
    def initialize(name, body, writer)
      @name = T.let(name, Symbol)
      @body = T.let(body, MIR::BodySlot::Body)
      @writer = T.let(writer, MIR::BodySlot::Writer)
    end

    sig { params(body: MIR::BodySlot::Body).void }
    def replace(body)
      @body = body
      @writer.call(body)
    end
  end

  class LoweredNodeId < T::Struct
    extend T::Sig

    const :value, Integer

    sig { params(other: MIR::LoweredNodeId).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(LoweredNodeId)

      other.value == value
    end

    sig { params(other: MIR::LoweredNodeId).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      value.hash
    end

  end

  class LoweredBodyId < T::Struct
    extend T::Sig

    const :node_ids, T::Array[LoweredNodeId]

    sig { params(other: MIR::LoweredBodyId).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(LoweredBodyId)

      other.node_ids == node_ids
    end

    sig { params(other: MIR::LoweredBodyId).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash
      node_ids.hash
    end

  end

  # Common interface for all MIR nodes.
  module Emittable
      extend T::Sig

    include Kernel
    ChildExprValue = T.type_alias { T.nilable(T.any(MIR::Emittable, T::Array[MIR::Emittable])) }
    EMPTY_CHILD_EXPRS = T.let([].freeze, T::Array[MIR::Emittable])
    EMPTY_BODY_SLOTS = T.let([].freeze, T::Array[MIR::BodySlot])

    sig { returns(TrueClass) }
    def mir?; true; end
    sig { returns(T::Boolean) }
    def stmt?; false; end
    sig { returns(T::Boolean) }
    def expr?; false; end
    sig { returns(OwnershipEffect) }
    def ownership_effect; OwnershipEffect.none; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs; EMPTY_CHILD_EXPRS; end
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs; EMPTY_CHILD_EXPRS; end
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs; EMPTY_CHILD_EXPRS; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots; EMPTY_BODY_SLOTS; end
    sig { returns(Emittable) }
    def without_try; self; end
    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract; nil; end
    sig { returns(T.nilable(OwnershipConsumptionFact)) }
    attr_accessor :ownership_consumption
    sig { returns(T.nilable(LoweredNodeId)) }
    attr_accessor :lowered_node_id

    private

    sig { params(values: T::Array[ChildExprValue]).returns(T::Array[Emittable]) }
    def compact_child_exprs(values)
      children = T.let([], T::Array[Emittable])
      values.each { |value| append_child_expr(children, value) }
      children
    end

    sig { params(children: T::Array[Emittable], value: ChildExprValue).void }
    def append_child_expr(children, value)
      if value.is_a?(Array)
        value.each { |child| append_child_expr(children, child) }
      elsif value.is_a?(Emittable)
        children << value
      end
      nil
    end

    sig { params(name: Symbol, body: T::Array[Emittable], writer: BodySlot::Writer).returns(BodySlot) }
    def body_slot(name, body, writer)
      BodySlot.new(name, body, writer)
    end

    sig { params(alloc: T.nilable(Symbol), cleanup_kind: Symbol).returns(OwnershipEffect) }
    def owned_effect_for_alloc(alloc, cleanup_kind: :uniform)
      OwnershipEffect.owned(alloc: alloc, cleanup_kind: cleanup_kind)
    end
  end

  module NamedEmittable
      extend T::Sig
      extend T::Helpers

    interface!

    sig { abstract.returns(T.any(String, Symbol)) }
    def name; end
  end

  module Stmt
      extend T::Sig

    include Emittable
    sig { returns(T::Boolean) }
    def stmt?; true; end

    # Source-line stamp used by the register VM emitter to attribute
    # opcodes to their originating CLEAR statement. Set by `lower_body`
    # in mir_lowering.rb from the AST node's `token.line`. nil when the
    # statement was synthesized by lowering (e.g. cleanup defers, hoist
    # temps) and has no user-visible source line.
    sig { returns(T.nilable(Integer)) }
    attr_accessor :source_line
    # Companion to `source_line`. Captures the AST node's `token.column`
    # so visualization layers can pinpoint the in-line position (LSP
    # ranges, debugger source-list carets, time-travel scrub UIs).
    # Same nil semantics as `source_line` for synthesized fragments.
    sig { returns(T.nilable(Integer)) }
    attr_accessor :source_column
  end

  module Expr
      extend T::Sig

    include Emittable
    sig { returns(T::Boolean) }
    def expr?; true; end
  end

  Node = T.type_alias { Emittable }
  NodeRoot = T.type_alias { T.any(Node, T::Array[Node]) }
  Body = T.type_alias { BodySlot::Body }
  DeferBody = T.type_alias { T.any(Emittable, T::Array[Emittable]) }
  DeferBodyInput = T.type_alias { T.any(DeferBody, String) }
  FsmBody = T.type_alias { T.any(MIR::FsmIoBody, MIR::FsmB1Body, MIR::FsmGenericBody) }
  BgBlockPlan = T.type_alias { T.any(MIR::BgStackfulPlan, MIR::BgStreamPlan, FsmBody) }
  NamedMirField = T.type_alias { T::Hash[Symbol, T.any(String, Symbol, Emittable)] }

  class OwnershipEffect
    OwnershipEffectInput = T.type_alias { T.nilable(Emittable) }

    sig { params(node: OwnershipEffectInput).returns(OwnershipEffect) }
    def self.of(node)
      mir_node = [node].grep(MIR::Emittable).first
      mir_node&.ownership_effect || none
    end

    sig { params(node: OwnershipEffectInput).returns(T::Boolean) }
    def self.hoistable_owned_result?(node)
      effect = of(node)
      effect.produces_owned && effect.requires_hoist
    end

    sig { params(node: OwnershipEffectInput).returns(T.nilable(Symbol)) }
    def self.alloc_of(node)
      of(node).alloc
    end

    sig { params(effects: T::Array[OwnershipEffect]).returns(OwnershipEffect) }
    def self.from_effects(effects)
      owned = effects.select(&:produces_owned)
      effect_when(!owned.empty?, owned(alloc: converged_effect_alloc(owned), cleanup_kind: :uniform))
    end

    sig { params(children: T::Array[Emittable]).returns(OwnershipEffect) }
    def self.from_children(children)
      from_effects(children.map(&:ownership_effect))
    end

    sig do
      params(
        left: OwnershipEffect,
        right: OwnershipEffect,
        result_type: T.nilable(Type),
        fallback_is_literal: T::Boolean,
        left_never_success: T::Boolean
      ).returns(OwnershipEffect)
    end
    def self.from_try_fallback(left, right, result_type:, fallback_is_literal:, left_never_success:)
      first_active_effect([
        [same_owned_alloc?(left, right), left],
        [owned_cleanup_result?(left, result_type), left],
        [left.produces_owned && fallback_is_literal, left],
        [right.produces_owned && left_never_success, right],
      ])
    end

    sig { params(left: OwnershipEffect, right: OwnershipEffect, result_type: T.nilable(Type)).returns(OwnershipEffect) }
    def self.from_optional_fallback(left, right, result_type:)
      first_active_effect([
        [same_owned_alloc?(left, right), left],
        [owned_cleanup_result?(left, result_type), left],
      ])
    end

    sig { params(left: OwnershipEffect, right: OwnershipEffect).returns(OwnershipEffect) }
    def self.from_required_branch_pair(left, right)
      effect_when(same_owned_alloc?(left, right), left)
    end

    sig { params(sink_alloc: T.nilable(Symbol), inner: OwnershipEffectInput).returns(OwnershipEffect) }
    def self.from_pipeline(sink_alloc:, inner:)
      first_active_effect([
        [!sink_alloc.nil?, owned(alloc: sink_alloc)],
        [true, of(inner)],
      ])
    end

    sig { params(body: T::Array[Emittable], result_type: T.nilable(Type)).returns(OwnershipEffect) }
    def self.from_block_body(body, result_type:)
      stmts = body
      break_stmt = stmts.reverse.grep(MIR::BreakStmt).first
      value = break_stmt&.value
      first_active_effect([
        [true, transferred_break_ident_effect(stmts, value)],
        [true, of(value)],
        [true, block_result_transfer_effect(stmts)],
        [cleanup_result_type?(result_type), owned(alloc: nil, cleanup_kind: :uniform)],
      ])
    end

    ActiveEffectCandidate = T.type_alias { [T::Boolean, OwnershipEffect] }

    sig { params(active: T::Boolean, effect: OwnershipEffect).returns(OwnershipEffect) }
    private_class_method def self.effect_when(active, effect)
      first_active_effect([[active, effect]])
    end

    sig { params(candidates: T::Array[ActiveEffectCandidate]).returns(OwnershipEffect) }
    private_class_method def self.first_active_effect(candidates)
      candidates.find { |active, effect| active && effect.produces_owned }&.last || none
    end

    sig { params(effects: T::Array[OwnershipEffect]).returns(T.nilable(Symbol)) }
    private_class_method def self.converged_effect_alloc(effects)
      allocs = effects.map(&:alloc).compact.uniq
      unique_symbol_or_nil(allocs)
    end

    sig { params(symbols: T::Array[Symbol]).returns(T.nilable(Symbol)) }
    private_class_method def self.unique_symbol_or_nil(symbols)
      { 1 => symbols.first }[symbols.uniq.length]
    end

    sig { params(left: OwnershipEffect, right: OwnershipEffect).returns(T::Boolean) }
    private_class_method def self.same_owned_alloc?(left, right)
      left.produces_owned && right.produces_owned && left.alloc == right.alloc
    end

    sig { params(effect: OwnershipEffect, result_type: T.nilable(Type)).returns(T::Boolean) }
    private_class_method def self.owned_cleanup_result?(effect, result_type)
      effect.produces_owned && cleanup_result_type?(result_type)
    end

    sig { params(result_type: T.nilable(Type)).returns(T::Boolean) }
    private_class_method def self.cleanup_result_type?(result_type)
      result_type&.needs_cleanup?(nil) == true
    end

    sig { params(stmts: T::Array[Emittable], value: OwnershipEffectInput).returns(OwnershipEffect) }
    private_class_method def self.transferred_break_ident_effect(stmts, value)
      ident = [value].grep(MIR::Ident).first
      name = (ident&.name || "").to_s
      mark = stmts.grep(MIR::AllocMark).find { |stmt| stmt.name.to_s == name }
      transfer = stmts.grep(MIR::TransferMark).find { |stmt| stmt.name.to_s == name }
      let = stmts.grep(MIR::Let).find { |stmt| stmt.name.to_s == name }
      init_effect = of(let&.init)
      cleanup_kind = { true => init_effect.cleanup_kind || :uniform, false => :uniform }[init_effect.produces_owned] || :uniform
      active = T.must(!name.empty? && !mark.nil? && !transfer.nil?)
      effect_when(active,
        owned(alloc: mark&.alloc, cleanup_kind: cleanup_kind, target_var: name))
    end

    sig { params(stmts: T::Array[Emittable]).returns(OwnershipEffect) }
    private_class_method def self.block_result_transfer_effect(stmts)
      transferred_allocs = stmts.grep(MIR::TransferMark)
        .select { |stmt| [:owned_sink, :block_result].include?(stmt.target) }
        .filter_map(&:target_alloc)
      effect_when(!transferred_allocs.empty?,
        owned(alloc: unique_symbol_or_nil(transferred_allocs), cleanup_kind: :uniform))
    end
  end

  StructInitFieldValue = T.type_alias { T.any(String, Symbol, Emittable) }

  class StructInitField < T::Struct
    extend T::Sig

    const :name, T.any(String, Symbol)
    const :value, Emittable
    const :alloc, T.nilable(Symbol), default: nil

    sig { params(key: Symbol).returns(T.nilable(StructInitFieldValue)) }
    def [](key)
      case key
      when :name then name
      when :value then value
      when :alloc then alloc
      end
    end
  end

  StructInitFieldInput = T.type_alias { T.any(StructInitField, NamedMirField) }

  sig { params(name: T.any(String, Symbol), value: Emittable).returns(StructInitField) }
  def self.named_field(name, value)
    StructInitField.new(name: name, value: value)
  end

  sig { params(expr: Emittable, capture: T.any(String, Symbol)).returns(NamedMirField) }
  def self.if_binding(expr, capture)
    binding = T.let({}, NamedMirField)
    binding[:expr] = expr
    binding[:capture] = capture
    binding
  end

  sig { params(field: StructInitFieldInput).returns(T.nilable(T.any(String, Symbol))) }
  def self.struct_init_field_name(field)
    return field.name if field.is_a?(StructInitField)
    return T.cast(field[:name], T.nilable(T.any(String, Symbol))) if field.is_a?(Hash)

    nil
  end

  sig { params(field: StructInitFieldInput).returns(T.nilable(Emittable)) }
  def self.struct_init_field_value(field)
    return field.value if field.is_a?(StructInitField)
    return T.cast(field[:value], T.nilable(Emittable)) if field.is_a?(Hash)

    nil
  end

  sig { params(field: StructInitFieldInput).returns(T.nilable(Symbol)) }
  def self.struct_init_field_alloc(field)
    return field.alloc if field.is_a?(StructInitField)
    return T.cast(field[:alloc], T.nilable(Symbol)) if field.is_a?(Hash)

    nil
  end

  sig { params(root: T.nilable(NodeRoot), blk: T.proc.params(arg0: Node).void).void }
  def self.each_node(root, &blk)
    each_node_inner(root, stop_at_block_expr: false, &blk)
  end

  sig { params(root: T.nilable(NodeRoot), stop: T.proc.params(arg0: Node).returns(T::Boolean), blk: T.proc.params(arg0: Node).void).void }
  def self.each_node_until(root, stop, &blk)
    each_node_inner(root, stop_at_block_expr: false, stop: stop, &blk)
  end

  sig { params(root: T.nilable(NodeRoot)).returns(T::Array[Node]) }
  def self.nodes(root)
    out = T.let([], T::Array[Node])
    each_node(root) { |node| out << node }
    out
  end

  sig { params(root: T.nilable(NodeRoot), blk: T.proc.params(arg0: Node).void).void }
  def self.each_surface_node(root, &blk)
    each_surface_node_inner(root, &blk)
  end

  sig { params(root: T.nilable(NodeRoot)).returns(T::Array[Node]) }
  def self.surface_nodes(root)
    out = T.let([], T::Array[Node])
    each_surface_node(root) { |node| out << node }
    out
  end

  sig { params(root: T.nilable(NodeRoot), stop_at_block_expr: T::Boolean, stop: T.nilable(T.proc.params(arg0: Node).returns(T::Boolean)), blk: T.proc.params(arg0: Node).void).void }
  def self.each_node_inner(root, stop_at_block_expr:, stop: nil, &blk)
    return unless root

    if root.is_a?(Array)
      root.each { |node| each_node_inner(node, stop_at_block_expr: stop_at_block_expr, stop: stop, &blk) }
      return
    end

    yield root
    return if stop_at_block_expr && root.is_a?(BlockExpr)
    return if stop&.call(root)

    root.child_exprs.each { |child| each_node_inner(child, stop_at_block_expr: stop_at_block_expr, stop: stop, &blk) }
    root.body_slots.each { |slot| each_node_inner(slot.body, stop_at_block_expr: stop_at_block_expr, stop: stop, &blk) }
    nil
  end

  sig { params(root: T.nilable(NodeRoot), blk: T.proc.params(arg0: Node).void).void }
  def self.each_surface_node_inner(root, &blk)
    return unless root

    if root.is_a?(Array)
      root.each { |node| each_surface_node_inner(node, &blk) }
      return
    end

    yield root
    return if root.is_a?(BlockExpr)

    root.child_exprs.each { |child| each_surface_node_inner(child, &blk) }
    nil
  end

  class InlineAllocMetadata
    extend T::Sig

    sig do
      params(
        alloc: T.nilable(Symbol),
        key_alloc: T.nilable(Symbol),
        val_alloc: T.nilable(Symbol),
        shard_alloc: T.nilable(Symbol),
      ).void
    end
    def initialize(alloc: nil, key_alloc: nil, val_alloc: nil, shard_alloc: nil)
      slots = T.let({}, T::Hash[Symbol, Symbol])
      slots[:alloc] = alloc if alloc
      slots[:key_alloc] = key_alloc if key_alloc
      slots[:val_alloc] = val_alloc if val_alloc
      slots[:shard_alloc] = shard_alloc if shard_alloc
      @slots = T.let(slots.freeze, T::Hash[Symbol, Symbol])
    end

    sig { returns(T::Boolean) }
    def empty?
      @slots.empty?
    end

    sig { params(blk: T.proc.params(key: Symbol, alloc: Symbol).void).void }
    def each(&blk)
      @slots.each { |key, alloc| blk.call(key, alloc) }
      nil
    end

    private

    sig { returns(T::Array[Symbol]) }
    def values
      @slots.values
    end

    sig { params(key: Symbol).returns(T.nilable(Symbol)) }
    def slot(key)
      @slots[key]
    end

    public

    sig { returns(T.nilable(Symbol)) }
    def primary
      slot(:alloc)
    end

    sig { returns(T.nilable(Symbol)) }
    def key_alloc
      slot(:key_alloc)
    end

    sig { returns(T.nilable(Symbol)) }
    def value_alloc
      slot(:val_alloc)
    end

    sig { returns(T.nilable(Symbol)) }
    def shard_alloc
      slot(:shard_alloc)
    end

    sig { returns(T.nilable(Symbol)) }
    def sink_alloc
      value_alloc || primary
    end

    sig { returns(T::Boolean) }
    def requires_target_alloc?
      !primary.nil? || !key_alloc.nil?
    end

    sig { returns(T.nilable(Symbol)) }
    def single_alloc
      uniq = values.uniq
      uniq.one? ? uniq.first : nil
    end

    sig { returns(T::Boolean) }
    def any_heap?
      values.include?(:heap)
    end

    sig { returns(T::Boolean) }
    def any_frame?
      values.include?(:frame)
    end

    sig { params(alloc: Symbol).returns(InlineAllocMetadata) }
    def with_all(alloc)
      updated = T.let({}, T::Hash[Symbol, Symbol])
      @slots.each { |key, _slot_alloc| updated[key] = alloc }
      InlineAllocMetadata.new(
        alloc: updated[:alloc],
        key_alloc: updated[:key_alloc],
        val_alloc: updated[:val_alloc],
        shard_alloc: updated[:shard_alloc],
      )
    end

    sig { returns(String) }
    def inspect
      @slots.inspect
    end
  end

  # ================================================================
  # Top-Level Definitions
  # ================================================================

  # Program: root container. items is a flat array of top-level nodes.
  # Zig: sequence of const/fn/test declarations separated by blank lines.
  class Program
    extend T::Sig
    include Emittable

    sig { returns(T::Array[Emittable]) }
    attr_reader :items

    sig { params(items: T::Array[Emittable], pass_state: T.nilable(MIRPassState)).void }
    def initialize(items, pass_state = nil)
      @items = items
      @pass_state = T.let(pass_state, T.nilable(MIRPassState))
    end

    sig { returns(T.nilable(MIRPassState)) }
    def mir_pass_state
      @pass_state
    end

    sig { params(state: T.nilable(MIRPassState)).void }
    def mir_pass_state=(state)
      @pass_state = state
    end
  end

  # Function definition.
  # Zig: [pub] fn name(params) [!]ret_type { body }
  #
  # body includes prologue statements (frame save, param shadows, etc.)
  # as leading MIR nodes -- emitter just processes them in order.
  # For catch-wrapping functions, the lowering produces the inner/outer
  # pair as two FnDefs.
  FnDef = Struct.new(:name, :params, :ret_type, :body,
                     :visibility,     # :pub or :private
                     :can_fail,       # bool: emit !RetType vs RetType
                     :comptime_params # ["comptime T: type", ...]
                    ) do
    extend T::Sig
    include Stmt

    sig { returns(T::Array[MIR::Param]) }
    def params
      self[:params]
    end

    sig { returns(TrueClass) }
    def has_own_frame? = true
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # Function parameter.
  # Zig: name: zig_type
  #
  # `pointer_passed` is true when this parameter receives a pointer-to-T
  # at the Zig level (MUTABLE collections that lower to `*ArrayList(...)`,
  # or any param whose receiver gets `&` at the call site). Note that
  # collection params lower to `anytype` for polymorphism, so we can't
  # infer this from `zig_type` alone — the lowering pass tags it
  # explicitly. Used by `MIRChecker#verify_cross_frame_param_alloc!`
  # to reject `:frame` allocators on receivers that outlive this fn.
  Param = Struct.new(:name, :zig_type, :pointer_passed) do
    include Emittable
  end

  # Struct type definition.
  # Zig: const Name = struct { fields; methods };
  StructDef = Struct.new(:name, :fields, :methods, :visibility) do
    include NamedEmittable
    include Stmt
  end

  # Struct field definition.
  # Zig: name: zig_type [= default]
  FieldDef = Struct.new(:name, :zig_type, :default) do
    include Emittable
    # Cross-backend capture hint: when this field stores a captured
    # @shared:locked / @local / @writeLocked binding, the BC backend
    # needs to know so it can mark the worker's pre-decoded slot as
    # boxed (so writes through a WITH alias route through BOX_STORE
    # back to the captured envId). Set by pipeline_host's CONCURRENT
    # callback builder; consumed by bc_emitter's
    # `compile_synthesized_helper_fn_mir`.
    attr_accessor :boxed_capture
  end

  # Enum type definition.
  # Zig: const Name = enum { A, B, C };
  EnumDef = Struct.new(:name, :variants, :visibility) do
    include NamedEmittable
    include Stmt
  end

  # Tagged union type definition.
  # Zig: const Name = union(enum) { A: type, B: void };
  class UnionTypeVariant < T::Struct
    extend T::Sig

    const :name, T.any(String, Symbol)
    const :zig_type, String

    sig { params(key: Symbol).returns(T.nilable(T.any(String, Symbol))) }
    def [](key)
      case key
      when :name then name
      when :zig_type then zig_type
      end
    end
  end

  UnionTypeDef = Struct.new(:name, :variants, :visibility) do
    include NamedEmittable
    include Stmt
    # variants: [UnionTypeVariant] (legacy hash variants are still readable)
    # unit variants have zig_type "void"
  end

  # Import statement.
  # Zig: const alias = @import("module")[.member];
  Import = Struct.new(:alias_name, :module_path, :member) do
    include Stmt
  end

  # Type alias.
  # Zig: const Name = target;
  TypeAlias = Struct.new(:name, :target) do
    include NamedEmittable
    include Stmt
  end

  # Inline module namespace for local/stdlib REQUIRE.
  # Zig: const Name = struct { ... };
  # The body is structural MIR, not pre-rendered Zig text, so imported function
  # bodies remain visible to traversal/checker/emitter code.
  ModuleNamespace = Struct.new(:name, :items) do
    extend T::Sig
    include Stmt

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs(items || [])
  end

  # Test block.
  # Zig: test "name" { body }
  TestDef = Struct.new(:name, :body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # ================================================================
  # Statements
  # ================================================================

  # Variable declaration.
  # Zig: const/var name[: type] = init;
  #
  # mutable: false -> const, true -> var
  # annotation: optional explicit Type (nil -> Zig infers)
  # suppression: optional "_ = &name;" or "_ = name;" for Zig warnings
  Let = Struct.new(:name, :init, :mutable, :annotation, :suppression, :alias_safe) do
    extend T::Sig
    include Stmt
    sig do
      params(
        name: T.any(String, Symbol),
        init: Emittable,
        mutable: T::Boolean,
        annotation: T.nilable(Type),
        suppression: T.nilable(String),
        alias_safe: T.nilable(T::Boolean),
      ).void
    end
    def initialize(name, init, mutable, annotation = nil, suppression = nil, alias_safe = nil)
      super(name, init, mutable, annotation, suppression, alias_safe)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([init])
    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      init.is_a?(Emittable) ? init.explicit_ownership_contract : nil
    end
  end

  # Assignment.
  # Zig: target = value;
  # target is an MIR expression (Ident, FieldGet, IndexGet, Deref)
  # needs_field_cleanup: true if this is a field assignment where the old
  #   value needs cleanup but no pre-cleanup was emitted (FIELD_LEAK).
  Set = Struct.new(:target, :value, :needs_field_cleanup) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([target, value])
  end

  # One target inside a destructuring assignment/declaration.
  # declaration_kind nil means assignment to an existing lvalue.
  # :const/:var mean declaration in the destructuring target list.
  DestructureTarget = Struct.new(:name, :declaration_kind, :annotation) do
    extend T::Sig
    include Expr
  end

  # Destructuring assignment/declaration.
  # Zig:
  #   a, b = value;
  #   const a: i64, var b: i64 = value;
  DestructureSet = Struct.new(:targets, :value) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # Reassignment with old-value cleanup.
  # Zig: { const __new = value; CheatLib.cleanup(T, alloc, &old); old = __new; }
  # alloc: symbol (:heap, :frame, :cleanup) -- resolved to Zig by emitter.
  ReassignWithCleanup = Struct.new(:name, :value, :zig_type, :alloc) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # If statement (not expression).
  # Zig: if (cond) { then_body } [else { else_body }]
  IfStmt = Struct.new(:cond, :then_body, :else_body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cond])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:then_body, then_body, ->(new_body) { self.then_body = new_body })], T::Array[BodySlot])
      slots << body_slot(:else_body, else_body, ->(new_body) { self.else_body = new_body }) if else_body
      slots
    end
  end

  # IF x AS y [&& z AS a] THEN ... [ELSE ...] END
  # Single binding: if (expr) |y| { then_body } else { else_body }
  # Multi binding:  blk: { const y = expr1 orelse break :blk; ... then_body } if (!ok) { else_body }
  # bindings: Array of { expr: MIR node, capture: String }
  IfBindStmt = Struct.new(:bindings, :then_body, :else_body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      exprs = bindings&.map { |binding| binding.is_a?(Hash) ? binding[:expr] : nil } || []
      compact_child_exprs(exprs)
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:then_body, then_body, ->(new_body) { self.then_body = new_body })], T::Array[BodySlot])
      slots << body_slot(:else_body, else_body, ->(new_body) { self.else_body = new_body }) if else_body
      slots
    end
  end

  # While loop.
  # Zig: while (cond) [: (update)] [|capture|] { body }
  WhileStmt = Struct.new(:cond, :body, :capture, :update, :mark_per_iter, :tight) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cond, update])
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # For loop over slice/range.
  # Zig: for (iter) |item[, idx]| { body }
  ForStmt = Struct.new(:iter, :capture, :body, :index_capture, :mark_per_iter, :tight) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([iter])
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # Scoped block.
  # Zig: { stmts }
  ScopeBlock = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  class EnumSwitchPattern < T::Struct
    const :variant, String
  end

  SwitchPattern = T.type_alias { T.any(Emittable, EnumSwitchPattern) }

  class SwitchArm < T::Struct
    extend T::Sig

    const :patterns, T::Array[SwitchPattern]
    prop :body, T::Array[Emittable]
  end

  # Switch statement (for int/enum MATCH).
  # Zig: switch (subject) { arms }
  SwitchStmt = Struct.new(:subject, :arms, :default_body) do
    extend T::Sig
    include Stmt
    # arms: [SwitchArm]
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      pattern_exprs = T.let([], T::Array[Emittable])
      (arms || []).each do |arm|
        arm.patterns.each do |pattern|
          pattern_exprs << pattern if pattern.is_a?(Emittable)
        end
      end
      compact_child_exprs([subject, pattern_exprs])
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm.body, ->(new_body) { arm.body = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
      slots
    end
  end

  class UnionMatchArm < T::Struct
    extend T::Sig

    const :variant, String
    const :payload, T.nilable(String)
    prop :body, T::Array[Emittable]
  end

  # Union match statement.
  # Zig: switch (subject) { .Variant => |payload| { body }, else => { ... } }
  # Payload capture is structurally tied to the active switch arm; lowering
  # must not synthesize subject.Variant reads for MATCH AS bindings.
  UnionMatchStmt = Struct.new(:subject, :arms, :default_body) do
    extend T::Sig
    include Stmt
    # arms: [UnionMatchArm]
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([subject])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm.body, ->(new_body) { arm.body = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
      slots
    end
  end

  class IfChainBranch < T::Struct
    extend T::Sig

    prop :cond, Emittable
    prop :body, T::Array[Emittable]
  end

  # If-chain statement (for union/string MATCH).
  # Zig: if (cond1) { ... } else if (cond2) { ... } else { ... }
  IfChain = Struct.new(:branches, :default_body) do
    extend T::Sig
    include Stmt
    # branches: [MIR::IfChainBranch]
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs(branches&.map(&:cond) || [])
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      branches&.each_with_index do |branch, index|
        slots << body_slot(:"branches_#{index}", branch.body, ->(new_body) { branch.body = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
      slots
    end
  end

  # Return statement.
  # Zig: return [value];
  ReturnStmt = Struct.new(:value) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # Break statement.
  # Zig: break [:label] [value];
  BreakStmt = Struct.new(:label, :value) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # Break expression.
  # Zig: break [:label] [value]
  # Used inside expression-only constructs such as `catch break :blk value`,
  # where the surrounding expression supplies statement termination.
  BreakExpr = Struct.new(:label, :value) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs
  end

  # Continue statement.
  # Zig: continue;
  ContinueStmt = Struct.new(:unused) do
    include Stmt
  end

  # Panic with a literal message. Never returns (control-flow terminator).
  # Used for compiler-emitted preconditions where the only sensible
  # response is to crash (e.g. MIN/MAX on empty list, INDEX allocation
  # failure). Both backends terminate execution.
  # Zig: @panic("message");
  Panic = Struct.new(:message) do
    include Stmt
  end

  AssertStmt = Struct.new(:cond, :message) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cond])
  end

  AssertRaisesCheck = Struct.new(:expr, :rt_name, :kind, :error_name) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  TestPreamble = Struct.new(:unused) do
    include Stmt
  end

  DebugOnly = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # In-place sort.
  # Borrows `items_expr`; mutates the underlying slice. The comparator is
  # encoded as two key extraction expressions (key_a, key_b) — both are MIR
  # expression trees referring to placeholder identifiers `a` and `b`. The
  # emitter wraps them in the appropriate Zig closure / VM comparator.
  # No allocation; ownership of items unchanged.
  # Zig: std.mem.sort(T, items, {}, struct { fn lessThan(_, a, b) {...} });
  Sort = Struct.new(:elem_type, :items_expr, :key_a, :key_b) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([items_expr, key_a, key_b])
  end

  # Typed-slice extraction from a Struct-of-Arrays container.
  # Borrows the SoA container; returns a slice view of one field.
  # Zig: container.data.items(.fieldname)
  SoaFieldAccess = Struct.new(:soa_expr, :field_name) do
    include Expr
  end

  # Fallible expression with literal-message panic on error. Replaces
  # `try X catch @panic("message")` patterns where the catch is purely
  # for "this can't legitimately fail at runtime, but the API is fallible".
  # Used by INDEX op (HashMap getOrPut, value_ptr.append) and similar.
  # Zig: <expr> catch @panic("message")
  TryOrPanic = Struct.new(:expr, :panic_msg) do
    include Expr

    extend T::Sig

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # INDEX-bucket insert: append `value` to the list bucket of `map` at `key`,
  # creating the bucket if missing. The Zig backend lowers this to the
  # getOrPut + value_ptr.append pattern with key dup/free; the VM lowers it
  # to MAP_GET + (Nil ? new_list : append) + MAP_PUT, which has matching
  # semantics for HashMap<K, []V> indexing.
  # `key_zig_type` is the comptime element type used by alloc.dupe in the
  # Zig backend (e.g. "u8"); ignored by the VM.
  # `elem_zig_type` is the comptime list-element type used by the empty-list
  # initializer in the Zig backend; ignored by the VM.
  IndexInsert = Struct.new(:map, :key_expr, :value_expr,
                           :key_zig_type, :elem_zig_type, :alloc) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([map, key_expr, value_expr])
  end

  # Batch-window runtime emission. These model the two ownership-sensitive
  # steps around CheatLib.BatchWindow(T): push-driven flushes and final flush.
  # The returned runtime slice is freed inside the emitted if-body after the
  # user expression has consumed the temporary ArrayListUnmanaged view.
  BatchWindowPush = Struct.new(:window, :item_expr, :batch_var, :elem_zig,
                               :result_var, :value_expr, :alloc) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([item_expr, value_expr])
  end

  BatchWindowFlush = Struct.new(:window, :batch_var, :elem_zig,
                                :result_var, :value_expr, :alloc) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value_expr])
  end

  # Defer statement.
  # Zig: defer { body };  or  defer expr;
  DeferStmt = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { params(body: DeferBodyInput).void }
    def initialize(body)
      MIR.validate_defer_body!(body, "MIR::DeferStmt")
      super(body)
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      body.is_a?(Array) ? [body_slot(:body, T.cast(body, Body), ->(new_body) { self.body = new_body })] : []
    end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])

    sig { returns(DeferBody) }
    def body
      self[:body]
    end
  end

  # Errdefer statement.
  # Zig: errdefer |_| { body };
  ErrDeferStmt = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { params(body: DeferBodyInput).void }
    def initialize(body)
      MIR.validate_defer_body!(body, "MIR::ErrDeferStmt")
      super(body)
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      body.is_a?(Array) ? [body_slot(:body, T.cast(body, Body), ->(new_body) { self.body = new_body })] : []
    end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])

    sig { returns(DeferBody) }
    def body
      self[:body]
    end
  end

  # Expression used as statement.
  # Zig: expr;  or  _ = expr;
  ExprStmt = Struct.new(:expr, :discard) do
    extend T::Sig
    include Stmt
    # discard: true -> emit `_ = expr;`
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      expr.is_a?(Emittable) ? expr.explicit_ownership_contract : nil
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Owning expression used as a statement.
  # Zig: evaluate into a scoped temp and clean it at the end of that scope.
  DiscardOwned = Struct.new(:expr, :cleanup_entry, :zig_type) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Non-mutual THUNK trampoline body. This is still emitted as a local
  # synchronous frame machine, but the MIR now exposes the frame layout,
  # base cases, recursive step, combine op, and yield policy instead of
  # hiding the entire function body in opaque Zig text.
  class ThunkBaseCase < T::Struct
    extend T::Sig

    const :cond, Emittable
    const :value, Emittable

    sig { params(key: Symbol).returns(Emittable) }
    def fetch(key)
      case key
      when :cond then cond
      when :value then value
      else
        Kernel.raise KeyError, "key not found: #{key.inspect}"
      end
    end
  end

  class ThunkFrameInit < T::Struct
    extend T::Sig

    const :field_name, String
    const :value, Emittable

    sig { params(key: Symbol).returns(T.any(String, Emittable)) }
    def fetch(key)
      case key
      when :field_name then field_name
      when :value then value
      else
        Kernel.raise KeyError, "key not found: #{key.inspect}"
      end
    end
  end

  class ThunkFrameField < T::Struct
    const :name, String
    const :type_info, Type
  end

  class ThunkVariant < T::Struct
    extend T::Sig

    const :name, String
    const :param_fields, T::Array[ThunkFrameField]

    sig { params(key: Symbol).returns(T.any(String, T::Array[ThunkFrameField])) }
    def fetch(key)
      case key
      when :name then name
      when :param_fields then param_fields
      else
        Kernel.raise KeyError, "key not found: #{key.inspect}"
      end
    end
  end

  class MutualThunkArm < T::Struct
    extend T::Sig

    const :variant_name, String
    const :base_cases, T::Array[ThunkBaseCase]
    const :target_variant, String
    const :target_arg_inits, T::Array[ThunkFrameInit]

    sig { params(key: Symbol).returns(T.any(String, T::Array[ThunkBaseCase], T::Array[ThunkFrameInit])) }
    def fetch(key)
      case key
      when :variant_name then variant_name
      when :base_cases then base_cases
      when :target_variant then target_variant
      when :target_arg_inits then target_arg_inits
      else
        Kernel.raise KeyError, "key not found: #{key.inspect}"
      end
    end
  end

  class ThunkTrampoline < T::Struct
    extend T::Sig
    include Stmt

    const :fn_name, String
    const :return_type, Type
    const :param_fields, T::Array[ThunkFrameField]
    const :param_init_fields, T::Array[ThunkFrameInit]
    const :base_cases, T::Array[ThunkBaseCase]
    const :recurse_arg_inits, T::Array[ThunkFrameInit]
    const :combine_lhs, Emittable
    const :combine_op, Symbol
    const :yield_policy, Symbol
  end

  # Mutual THUNK trampoline body. This is the tagged-union sibling of
  # ThunkTrampoline: each mutually-recursive function is a union variant,
  # and each arm either returns a base-case value or overwrites current
  # with the next variant's payload.
  class MutualThunkTrampoline < T::Struct
    extend T::Sig
    include Stmt

    const :fn_name, String
    const :return_type, Type
    const :variants, T::Array[ThunkVariant]
    const :initial_variant, String
    const :initial_fields, T::Array[ThunkFrameInit]
    const :arms, T::Array[MutualThunkArm]
    const :yield_policy, Symbol
  end

  sig { params(body: DeferBodyInput, label: String).void }
  def self.validate_defer_body!(body, label)
    valid = if body.is_a?(Array)
      body.all? { |stmt| stmt.is_a?(MIR::Emittable) }
    else
      body.is_a?(MIR::Emittable)
    end
    return if valid

    raise TypeError, "#{label} body must be structural MIR, got #{body.class}"
  end

  # Background block. Wraps a typed execution-boundary emission plan and exposes
  # capture_analysis for ownership verification (BG_ESCAPE check).
  # captures: { name => Type-like object } from capture_analysis.captures
  # run_body: [MIR::Stmt] — lowered MIR for the fiber run function body.
  #   Carries the MIR so the checker can see allocations inside the fiber.
  # fsm_structure: MIR::FsmStructure | nil. For BG bodies lowered to a
  #   stackless FSM, carries the structural metadata (captures, state
  #   fields, per-step bodies, cleanup placements) so the MIR checker
  #   can verify cross-step liveness invariants. nil for non-FSM BGs
  #   and for FSM Phase B1 (pure-compute, no suspend) where there's
  #   only one logical step.
  BgBlock = Struct.new(:code, :captures, :run_body, :fsm_structure) do
    extend T::Sig
    include Stmt
    sig do
      params(
        code: BgBlockPlan,
        captures: T::Hash[String, Type],
        run_body: T::Array[Emittable],
        fsm_structure: T.nilable(Emittable),
      ).void
    end
    def initialize(code, captures = {}, run_body = [], fsm_structure = nil)
      unless MIR.structural_bg_block_plan?(code)
        raise TypeError, "MIR::BgBlock code must be a structural emission plan, got #{code.class}"
      end
      super(code, captures, run_body, fsm_structure)
    end

    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end
    sig { params(value: T.nilable(Type)).returns(T.nilable(Type)) }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end
    sig { returns(T.nilable(MIR::ExecutionBoundaryFact)) }
    def boundary_fact
      @boundary_fact = T.let(nil, T.nilable(MIR::ExecutionBoundaryFact)) unless defined?(@boundary_fact)
      @boundary_fact
    end
    sig { params(value: T.nilable(MIR::ExecutionBoundaryFact)).returns(T.nilable(MIR::ExecutionBoundaryFact)) }
    def boundary_fact=(value); @boundary_fact = T.let(value, T.nilable(MIR::ExecutionBoundaryFact)); end
    sig { returns(T::Boolean) }
    def expr?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = run_body ? [body_slot(:run_body, run_body, ->(new_body) { self.run_body = new_body })] : []
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :heap, cleanup_kind: :uniform)
    end
  end

  # BC-only: producer-fiber + rendezvous channel for ~T[INF] BG STREAM.
  # Lowered when @target == :bc and the stream type is_inf?. The Zig
  # backend never produces this -- it has its own coroutine-based
  # StreamGen path. Captures: { name => Type } same shape as BgBlock so
  # the bc_emitter can reuse the BG-fiber prologue. body: lowered MIR
  # for the producer body (YieldExpr is already rewritten to MIR::StreamYield
  # by lower_yield).
  StreamSpawn = Struct.new(:captures, :body) do
    extend T::Sig
    include Stmt
    sig { returns(T.nilable(MIR::ExecutionBoundaryFact)) }
    def boundary_fact
      @boundary_fact = T.let(nil, T.nilable(MIR::ExecutionBoundaryFact)) unless defined?(@boundary_fact)
      @boundary_fact
    end
    sig { params(value: T.nilable(MIR::ExecutionBoundaryFact)).returns(T.nilable(MIR::ExecutionBoundaryFact)) }
    def boundary_fact=(value); @boundary_fact = T.let(value, T.nilable(MIR::ExecutionBoundaryFact)); end
    sig { returns(T::Boolean) }
    def expr?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # ================================================================
  # FSM Structure — visibility into stackless state machines
  # ================================================================
  #
  # The FSM lowering (src/mir/fsm_lowering.rb) renders a multi-step
  # stackless state machine as raw Zig text inside a BgBlock. That
  # text contains memory-safety decisions (which step a `defer`
  # fires in, which captures live across suspend, when ctx-owned
  # heap allocations are freed) that the MIR checker cannot see.
  #
  # FsmStructure makes those decisions visible: the lowering builds
  # an FsmStructure alongside the Zig text, and the checker (see
  # `MirChecker.check_fsm_structure!`) verifies the placement
  # invariants BEFORE the text is rendered into final output.
  #
  # Shape:
  #
  #   captures: [
  #     { name: String, type: Type-like, cleanup_at: :finalize | Integer }
  #   ]
  #     Captures are heap-dupe'd into the FSM ctx at spawn. They may
  #     be read by ANY step (the lowering does not statically
  #     restrict this), so cleanup_at MUST be :finalize. cleanup_at
  #     pointing at a specific step index means the lowering placed
  #     the cleanup inside that step's body — a UAF if any later
  #     step reads the capture.
  #
  #   state_fields: [FsmStateFieldFact]
  #     Per-call state struct fields (e.g. rf_buf, rf_fd). Cleanup
  #     placement is template-driven via :fsm_state_finalize. The
  #     `error_handled_in_setup` flag indicates step-0 errdefer
  #     coverage so the checker can require it on heap-alloc'd
  #     state fields.
  #
  #   steps: [FsmStepFact]
  #     One entry per step. `reads` is the set of binding names
  #     (captures + state_fields + ctx fields) referenced in this
  #     step's emitted body, derived by scanning the rendered Zig
  #     for `__ctx_<id>.<name>` patterns. `cleanups` is the set of
  #     names whose `defer free(...)` line was placed at the start
  #     of this step.
  #
  #   finalize_cleanups: [String]
  #     Names whose cleanup is placed at FSM finalize.
  #
  #   destroy_actions: [FsmDestroyAction]
  #     Closed structural operations run by destroyTask before the ctx
  #     is freed. The checker validates this list so finalization is
  #     not an opaque rendered-Zig side channel.
  #
  #   ctx_id: Integer
  #     The numeric id used in `__ctx_<id>.<name>` references. The
  #     checker uses this to scan step bodies for reads.
  #
  #   result_aliases_finalized: String | nil
  #     Set to the name of a finalized state field IF the BG body's
  #     terminal expression aliases that field via the bound var
  #     (e.g. `BG { content = readFile(p); content; }` aliases
  #     rf_buf — which is finalized — through `content`). The
  #     checker rejects on any non-nil value: the slice would
  #     escape the FSM but its backing storage dies at finalize.
  class FsmCaptureFact < T::Struct
    const :name, String
    const :cleanup_at, T.any(Symbol, Integer)
  end

  class FsmStateFieldFact < T::Struct
    const :name, String
    const :finalize_at, T.nilable(T.any(Symbol, Integer))
    const :error_handled_in_setup, T::Boolean, default: false
  end

  class FsmStepFact < T::Struct
    const :index, Integer
    const :reads, T::Array[String], default: []
    const :cleanups, T::Array[String], default: []
  end

  class FsmDestroyCleanup < T::Struct
    extend T::Sig

    SOURCE_DESTROY_ORDER = T.let({
      capture: 1,
      fresh_heap: 1,
      body: 2,
      owned_result: 2,
    }.freeze, T::Hash[Symbol, Integer])

    const :source_kind, Symbol
    const :name, String
    const :target, Emittable
    const :cleanup_entry, CleanupEntry
    const :guard, T.nilable(Emittable), default: nil
    const :allocator, T.nilable(Emittable), default: nil

    sig { returns(Integer) }
    def destroy_order_bucket = SOURCE_DESTROY_ORDER.fetch(source_kind, 2)

    sig { params(index: Integer).returns(Integer) }
    def destroy_order_index(index) = index

    sig { returns(T.nilable(String)) }
    def cleanup_name = name

    sig { returns(T.nilable(String)) }
    def ctx_cleanup_target_name
      target_expr = target
      return nil unless target_expr.is_a?(FieldGet)

      object = target_expr.object
      return nil unless object.is_a?(Ident)

      "#{object.name}.#{target_expr.field}"
    end
  end

  class FsmDestroyLockRelease < T::Struct
    extend T::Sig

    const :name, String
    const :ctx_id, Integer
    const :guard_index, Integer
    const :lock_ref, Emittable
    const :unlock_method, String

    sig { returns(String) }
    def guard_field = "__lock_held_#{guard_index}"

    sig { returns(Integer) }
    def destroy_order_bucket = 0

    sig { params(index: Integer).returns(Integer) }
    def destroy_order_index(index) = -index

    sig { returns(T.nilable(String)) }
    def cleanup_name = nil

    sig { returns(T.nilable(String)) }
    def ctx_cleanup_target_name = nil
  end

  class FsmDestroyStmt < T::Struct
    extend T::Sig

    const :source_kind, Symbol
    const :name, String
    const :stmt, Emittable

    sig { returns(Integer) }
    def destroy_order_bucket = FsmDestroyCleanup::SOURCE_DESTROY_ORDER.fetch(source_kind, 2)

    sig { params(index: Integer).returns(Integer) }
    def destroy_order_index(index) = index

    sig { returns(T.nilable(String)) }
    def cleanup_name = name

    sig { returns(T.nilable(String)) }
    def ctx_cleanup_target_name
      current_stmt = stmt
      return nil unless current_stmt.is_a?(MIR::RcRelease)

      source = current_stmt.source
      return nil unless source.is_a?(FieldGet)

      object = source.object
      return nil unless object.is_a?(Ident)

      "#{object.name}.#{source.field}"
    end
  end

  FsmDestroyAction = T.type_alias { T.any(FsmDestroyCleanup, FsmDestroyStmt, FsmDestroyLockRelease) }

  class FsmStructureFacts < T::Struct
    prop :required_move_guards, T::Array[String], factory: -> { [] }
    prop :move_guard_writes, T::Array[String], factory: -> { [] }
    prop :ownership_facts, T::Array[FsmOwnershipFact], factory: -> { [] }
    prop :destroy_actions, T::Array[FsmDestroyAction], factory: -> { [] }
  end

  FsmStructure = Struct.new(
    :captures, :state_fields, :steps, :finalize_cleanups, :ctx_id,
    :result_aliases_finalized
  ) do
    extend T::Sig
    include Emittable

    sig { params(args: T.untyped).void }
    def initialize(*args)
      super
      @facts = T.let(FsmStructureFacts.new, FsmStructureFacts)
    end

    sig { returns(T::Array[String]) }
    def required_move_guards
      @facts.required_move_guards
    end

    sig { params(value: T::Array[String]).returns(T::Array[String]) }
    def required_move_guards=(value)
      @facts.required_move_guards = value
    end

    sig { returns(T::Array[String]) }
    def move_guard_writes
      @facts.move_guard_writes
    end

    sig { params(value: T::Array[String]).returns(T::Array[String]) }
    def move_guard_writes=(value)
      @facts.move_guard_writes = value
    end

    sig { returns(T::Array[FsmOwnershipFact]) }
    def ownership_facts
      @facts.ownership_facts
    end

    sig { params(value: T::Array[FsmOwnershipFact]).returns(T::Array[FsmOwnershipFact]) }
    def ownership_facts=(value)
      @facts.ownership_facts = value
    end

    sig { returns(T::Boolean) }
    def owned_result_required
      @owned_result_required = T.let(@owned_result_required, T.nilable(T::Boolean))
      @owned_result_required == true
    end

    sig { params(value: T::Boolean).returns(T::Boolean) }
    def owned_result_required=(value)
      @owned_result_required = value
    end

    sig { returns(T::Array[FsmDestroyAction]) }
    def destroy_actions
      @facts.destroy_actions
    end

    sig { params(value: T::Array[FsmDestroyAction]).returns(T::Array[FsmDestroyAction]) }
    def destroy_actions=(value)
      @facts.destroy_actions = value
    end
  end

  class ContextFieldDecl < T::Struct
    const :name, String
    const :type_zig, String
    const :default_value, T.nilable(MIR::Emittable), default: nil
  end

  class CaptureCleanupAction < T::Struct
    const :target, Emittable
    const :cleanup_entry, CleanupEntry
    const :allocator, T.nilable(Emittable), default: nil
  end

  class TaskConfigPlan < T::Struct
    const :stack_variant, String
    const :profile_site_id, T.nilable(Integer), default: nil
    const :profile_dispatch_id, T.nilable(Integer), default: nil
  end

  class ProfileTaskSite < T::Struct
    const :site_id, Integer
    const :line, Integer
    const :column, Integer
    const :dispatch, Symbol
    const :form, Symbol
  end

  class FiberSpawnCall < T::Struct
    const :target, Symbol
    const :runtime_name, T.nilable(String), default: nil
    const :wait_group_name, T.nilable(String), default: nil
    const :ctx_type, String
    const :ctx_var, String
    const :task_config, TaskConfigPlan
    const :pass_ctx_by_address, T::Boolean, default: false
  end

  class BgStackfulPlan < T::Struct
    const :id, Integer
    const :ctx_type, String
    const :alloc_var, String
    const :promise_var, String
    const :ctx_var, String
    const :blk_label, String
    const :bg_rt, String
    const :rt_name, String
    const :promise_zig, String
    const :is_void, T::Boolean
    const :capture_fields, T::Array[ContextFieldDecl]
    const :capture_inits, T::Array[StructInitField]
    const :capture_frees, T::Array[CaptureCleanupAction]
    const :promoted_decls, T::Array[MIR::Emittable]
    const :profile_site, ProfileTaskSite
    const :arena_init, T.nilable(MIR::Node)
    const :spawn_call, FiberSpawnCall
    const :alloc_expr, MIR::Emittable
    const :run_body, T::Array[MIR::Node]
  end

  class BgStreamPlan < T::Struct
    const :id, Integer
    const :ctx_type, String
    const :alloc_var, String
    const :stream_var, String
    const :ctx_var, String
    const :blk_label, String
    const :stream_zig, String
    const :local_stream, String
    const :capture_fields, T::Array[ContextFieldDecl]
    const :capture_inits, T::Array[StructInitField]
    const :promoted_decls, T::Array[MIR::Emittable]
    const :capture_cleanups, T::Array[MIR::Emittable]
    const :body, T::Array[MIR::Node]
    const :spawn_call, FiberSpawnCall
    const :rt_name, String
  end

  class DoBranchPlan < T::Struct
    const :ctx_type, String
    const :ctx_var, String
    const :wg_var, String
    const :raw_rt_name, String
    const :raw_args_name, String
    const :capture_fields, T::Array[ContextFieldDecl]
    const :capture_inits, T::Array[StructInitField]
    const :capture_pre_decls, T::Array[MIR::Emittable]
    const :body, T::Array[MIR::Node]
    const :spawn_call, FiberSpawnCall
  end

  class DoBlockPlan < T::Struct
    const :wg_var, String
    const :branches, T::Array[DoBranchPlan]
  end

  # ================================================================
  # FSM-IO state-machine wrapper (structural)
  # ================================================================
  #
  # The previous lowering for FSM-IO bodies built the entire state
  # machine — outer label block, ctx struct decl, runStep0/runStep1,
  # resumeFn switch, alloc / init / spawn / break — as a single Zig
  # heredoc inside `emit_fsm_io_bg_code`. That meant the wrapper's
  # structure (where the resumeFn dispatch lives, where the step-0
  # error catch sits, what the spawn call looks like) was implicit
  # in string interpolation. The MIR checker had no view into it.
  #
  # The types below replace that heredoc with explicit MIR nodes.
  # The lowering builds an `MIR::FsmIoBody` tree; the renderer in
  # `src/backends/fsm_wrapper_emitter.rb` walks the tree and produces
  # the same Zig text — but now every structural piece is named,
  # typed, and inspectable. `FsmIoBody` lives inside an
  # `MIR::BgBlock.code` field for emitter compatibility, but the
  # tree itself is the source of truth and any future MIR pass
  # (checker, transformer, dumper) walks the structure rather than
  # the rendered string.
  #
  # Body content that comes from the surrounding fiber-body lowering
  # is now structural MIR. The wrapper structure is fully MIR; the
  # per-step body nodes are rendered only by the final emitter.

  # Top-level FSM-IO body. Renders to:
  #   <blk_label>: {
  #     <ctx_struct>
  #     <spawn_setup>
  #     break :<blk_label> <promise_var>;
  #   }
  FsmIoBody = Struct.new(
    :blk_label,           # String, e.g. "__bg0"
    :ctx_struct,          # MIR::FsmCtxStruct
    :spawn_setup,         # MIR::FsmSpawnSetup
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end
  end

  # BC-only: producer-side rendezvous push. Emitted by lower_yield when
  # the enclosing BG STREAM is is_inf? and @target == :bc. The single
  # `value` is pushed into the channel; producer fiber blocks until the
  # consumer's STREAM_NEXT empties the slot.
  StreamYield = Struct.new(:value) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # Top-level FSM Phase B1 (pure-compute) body. Same labeled-block
  # shape as FsmIoBody; the inner ctx struct has only ONE member
  # fn (runBody, no step counter, no suspend) and a simple
  # resumeFn that calls runBody once and returns Done.
  FsmB1Body = Struct.new(
    :blk_label,
    :ctx_struct,          # MIR::FsmB1CtxStruct
    :spawn_setup,         # MIR::FsmSpawnSetup (same as IO)
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end
  end

  # B1 ctx struct: like FsmCtxStruct but without `step` / two-step
  # member fns. Holds a single runBody whose body is a list of MIR
  # statements (or strings as transitional fallback).
  FsmB1CtxStruct = Struct.new(
    :type_name,
    :promise_zig,
    :capture_fields,
    :run_body,            # MIR::FsmStep (re-using the same shape;
                          # index=0, but the renderer for B1 emits
                          # the fn name as `runBody` not
                          # `runStep0`).
  )

  # Generic FSM body shape that hosts FSM emit forms beyond
  # FSM-IO and B1. Used for B2-LOOP, B2-WITH, B2-NEXT-CHAIN --
  # forms whose dispatch is form-specific but whose member-fn
  # bodies are typed MIR going through MIREmitter.
  #
  # The dispatch is a structured FSM state table. The wrapper
  # emitter renders that table into the final resume function.
  FsmGenericBody = Struct.new(
    :blk_label,
    :ctx_struct,          # MIR::FsmGenericCtxStruct
    :spawn_setup,         # MIR::FsmSpawnSetup (shared)
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end
  end

  # Ctx struct for the generic body. Holds:
  #   - the standard task / rt / inner / alloc fields (added by
  #     the renderer);
  #   - a list of typed extra field declarations (step counter, sp
  #     promise fields, retry counter, lock_waiter, etc.);
  #   - promoted-local field declarations;
  #   - a list of MIR::FsmStep entries with their fn name and
  #     signature (not just `runStepN`);
  #   - the structured dispatch table.
  FsmGenericCtxStruct = Struct.new(
    :type_name,
    :promise_zig,
    :capture_fields,
    :extra_field_decls,    # [MIR::ContextFieldDecl]
    :promoted_field_decls, # [MIR::ContextFieldDecl]
    :member_fns,           # [MIR::FsmMemberFn]
    :dispatch,             # MIR::FsmDispatch
    :destroy_actions,      # [MIR::FsmDestroyAction] -- structural
                           # finalizer ops run by destroyTask BEFORE
                           # alloc.destroy(ctx). Used for capture
                           # cleanup, promoted ctx cleanup, owned
                           # suspend results, and WITH+suspend lock
                           # release across runFn boundaries.
  )

  # A named member fn on the FSM ctx struct. fn_name is used as
  # the Zig fn name (`runPre`, `runLoopPre`, `runStep0`, ...).
  # signature is the Zig signature minus the fn name (e.g.
  # `(__ctx_0: *@This()) anyerror!void`). body_stmts are typed
  # MIR statements rendered via MIREmitter.
  FsmMemberFn = Struct.new(
    :fn_name,
    :ctx_id,
    :bg_rt,                # "__rt_bg0"
    :suppress_runtime_ref,
    :body_stmts,           # [MIR::Stmt]
    :extra_prologue_stmts, # optional pre-body MIR stmts -- appear
                           # before body_stmts in the rendered fn
  )

  # The `const __BgCtxN = struct { ... };` declaration that holds
  # task / rt / inner / alloc / captures / step / state_decls /
  # promoted fields, plus the runStep0 / runStep1 / resumeFn member
  # functions.
  FsmCtxStruct = Struct.new(
    :type_name,            # "__BgCtx0"
    :promise_zig,          # "CheatLib.Promise(i64)"
    :capture_fields,       # [MIR::ContextFieldDecl]
    :state_decls,          # [FsmOps::StateFieldDecl]
    :promoted_field_decls, # [String] — raw lines
    :step0,                # MIR::FsmStep
    :step1,                # MIR::FsmStep
    :resume_fn,            # MIR::FsmDispatch
  )

  # One `fn runStepN(__ctx_<id>: *@This()) anyerror!void` body.
  #
  # `body_stmts` is a list of MIR statement nodes. The wrapper
  # renderer uses the standard MIREmitter to walk each one, so
  # structural MIR statement types such as MIR::Let, MIR::Set,
  # MIR::DeferStmt, and MIR::ExprStmt are valid here.
  #
  # The renderer concatenates each emitted statement with newlines
  # and the function body indentation. It does NOT insert ';'s or
  # pick statement order; those are decisions of the lowering and
  # are encoded in the MIR node type.
  FsmStep = Struct.new(
    :index,                # 0 or 1
    :ctx_id,               # int matching __ctx_<id>
    :bg_rt,                # "__rt_bg0"
    :suppress_runtime_ref, # whether to emit `_ = &<bg_rt>;`
    :body_stmts,           # [MIR::Stmt]
  )

  # ================================================================
  # FSM SuspendDescriptor (kind-agnostic suspend contract)
  # ================================================================
  #
  # A suspend point yields a "future-like thing" with a uniform
  # protocol: setup before yield, dispatch transition, bind on
  # resume. SuspendDescriptor captures that protocol so the unified
  # FSM emit can handle ANY suspend kind (IO, NEXT, LOCK, future
  # TCP/channel/...) without per-kind branching.
  #
  # Resolvers in src/mir/fsm_transform/suspend_resolvers.rb turn a
  # Segments::IoSuspend / NextSuspend / LockSuspend into a
  # SuspendDescriptor. The unified emit consumes the descriptor
  # without caring which kind it is.
  #
  # Shape (for a suspend at the END of segment K, transitioning to
  # segment K+1):
  #
  #   setup_stmts: [MIR::Stmt]
  #     Appended to segment K's runStep body. Registers the wait
  #     source, submits any syscalls, etc. For IO this is the
  #     stdlib fsm_setup template. For NEXT it's the
  #     `ctx.sp_<K> = <promise_expr>` stash. May read captures /
  #     promoted locals (already in capture_map by the time the
  #     emit calls this).
  #
  #   bind_stmts: [MIR::Stmt]
  #     Prepended to segment K+1's runStep body. Extracts the
  #     resumed value into result_var, propagates errors. For IO
  #     this is the fsm_finish_block + finish_value. For NEXT it's
  #     the `if ctx.sp.inner.result |r| { result_var = r } else
  #     |e| { return err }` destructure.
  #
  #   tail: MIR::FsmTailYield | MIR::FsmTailRegisterYield
  #     The dispatch transition emitted in the resumeFn arm K.
  #     Always-yield (IO) -> FsmTailYield. Conditional register
  #     (NEXT) -> FsmTailRegisterYield. Compound shapes (LOCK
  #     retry-loop) fan out into multiple segments at split-time
  #     instead of needing a richer tail.
  #
  #   ctx_field_decls: [MIR::ContextFieldDecl]
  #     Extra typed field declarations this suspend needs in the ctx
  #     struct (e.g. "sp_1: Promise(T) = undefined," or
  #     "rf_fd: i32 = -1,"). Liveness output covers user-visible
  #     locals that cross the boundary; these are
  #     suspend-protocol fields beyond that.
  #
  #   result_var: String | nil
  #   result_zig_type: String | nil
  #   result_needs_cleanup: Bool
  #     Name + Zig type of the local the bind produces. Visible
  #     to subsequent segments as a Zig local (or, if Liveness
  #     flagged it as cross-segment, as a ctx field). nil for
  #     suspends without a bound result (Void IO, bare NEXT).
  #     result_needs_cleanup means the ctx field owns cleanup-bearing
  #     data after bind; the FSM emitter must track initialization
  #     and either clean it in destroyTask or clear the guard when
  #     the value is transferred into the promise result.
  SuspendDescriptor = Struct.new(
    :setup_stmts,
    :bind_stmts,
    :tail,
    :ctx_field_decls,
    :result_var,
    :result_zig_type,
    :result_needs_cleanup,
  )

  # ================================================================
  # FSM dispatch table.
  # ================================================================
  #
  # Per-state dispatch table. The renderer walks `arms` and emits a
  # `switch (step) { ... }` (optionally wrapped in `__sw: while(true)`
  # for shapes that use jump tails or back-edges).
  #
  # Shape coverage:
  #   - B2-IO          (2 arms: runStep0 + Yield -> runStep1 + Done)
  #   - B2-LOOP        (4 arms: pre / cond+loop_pre / bind+loop_post / post)
  #   - B2-NEXT-CHAIN  (N+1 arms: per-NEXT register-yield + final post)
  #
  # Not yet covered (still rendered as raw Zig templates):
  #   - B1            -- simple, no switch needed (single runBody call)
  #   - B2-WITH       -- multi-block lock-retry dispatch with
  #                       __cs_block + __try_loop + per-clause error
  #                       arms; structurally distinct from a flat
  #                       switch and remains template-driven for now.
  #
  # The renderer is in src/backends/fsm_wrapper_emitter.rb#render_dispatch.
  # Tail variants are the entirety of "what happens after the arm's
  # member fn returns ok"; adding a new suspend kind = new tail
  # variant + new arm in `render_tail`. NEVER a new dispatcher.
  FsmDispatch = Struct.new(
    :ctx_id,                  # Integer
    :arms,                    # [FsmStateArm]
    :uses_loop_label,         # Bool: wrap switch in `__sw: while (true) { ... }`?
                              #   true when any tail uses Jump / RegisterYield
                              #   (which can fall through to another arm
                              #   without re-entering resumeFn).
  )

  # One state-machine arm. Sequence of effects:
  #   1. If pre_body_skip is set and its cond holds, jump to skip_step
  #      (no body, no tail). Used by B2-LOOP arm 1 ("if !cond goto post").
  #   2. Run pre_body_stmts (structural MIR injected before the body fn).
  #      Used by B2-LOOP arm 2 to bind sp.result into a ctx field
  #      BEFORE runLoopPost reads it.
  #   3. Else call body_fn_name (skipped when nil); on error: emit
  #      err_cleanups (per-arm direct cleanups, e.g. capture frees in
  #      a B2-IO step-0 catch), store err on inner, wg.done, destroy
  #      ctx, return Done.
  #   4. Dispatch via tail.
  FsmStateArm = Struct.new(
    :index,                   # Integer state number
    :pre_body_skip,           # FsmTailCondSkip | nil
    :pre_body_stmts,          # [MIR::Stmt]
    :body_fn_name,            # String | nil
    :err_cleanups,            # [MIR::Stmt] | nil -- direct cleanups
                              #   in the err handler of this arm,
                              #   placed before the standard
                              #   inner.result = err / wg.done /
                              #   destroy / return Done sequence.
                              #   Used by B2-IO step-0 for capture
                              #   frees on setup error.
    :tail,                    # FsmTailDone | FsmTailYield |
                              #   FsmTailRegisterYield | FsmTailJump |
                              #   FsmTailCondJump
  )

  # Conditional pre-body skip: used inside an arm to short-circuit
  # past the body and tail to a different state.
  FsmTailCondSkip = Struct.new(:condition, :skip_step)

  # ================================================================
  # LOCK-fan-out tail variants (composable B2-WITH dispatch)
  # ================================================================
  #
  # WITH's dispatch decomposes into per-step segments tied together
  # by these narrower tail variants. Each variant is generic enough
  # to combine with other shapes (WhileLoop+WITH, IF+WITH, etc.)
  # because the dispatch is FLAT once fanned out.
  #
  # Three-way branch on tryLock outcome:
  #   const __lock_r = <lock_field_ref>.<try_method>(
  #       &__ctx.task, &__ctx.lock_waiter, __ctx.rt.getSched());
  #   switch (__lock_r) {
  #       .Acquired   => { step = ok_step;    continue :__sw; },
  #       .Registered => { step = wait_step;  return .WaitForLock; },
  #       .Error      => { step = error_step; continue :__sw; },
  #   }
  FsmTailLockTry = Struct.new(
    :try_method,        # "tryLockForFsm" / "tryWriteLockForFsm" / ...
    :lock_field_ref,    # Zig string for the lock receiver
    :ok_step,           # state to enter on .Acquired
    :wait_step,         # state to enter when re-entered after wake
    :error_step,        # state to enter on .Error
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :lock_try; end
  end

  # Post-resume check after a .Registered yield. Reads
  # task.lock_error: if .None we got the lock (jump to ok_step);
  # else jump to error_step (which checks retry / runs error_arm).
  #   const __lerr = __ctx.task.lock_error;
  #   __ctx.task.lock_error = .None;
  #   if (__lerr == .None) { step = ok_step;    continue :__sw; }
  #   step = error_step; continue :__sw;
  FsmTailWokenCheck = Struct.new(
    :ok_step,
    :error_step,
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :woken_check; end
  end

  # Retry-or-fail: if retries remaining, increment retry_count and
  # jump back to the lock-try step; else jump to the error_arm step.
  #   if (<retries> > 0 and __ctx.retry_count < <retries>) {
  #       __ctx.retry_count += 1;
  #       step = retry_step; continue :__sw;
  #   }
  #   step = fail_step; continue :__sw;
  FsmTailRetryOrError = Struct.new(
    :retries,           # Integer (0 => never retry; always fail)
    :retry_step,        # state to retry from (the lock-try step)
    :fail_step,         # state to run the error_arm body in
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :retry_or_error; end
  end


  # Final state. Renders to:
  #   inner.result = err_or_pass_through;  // err_action handles
  #   inner.wg.done();
  #   alloc.destroy(ctx);
  #   return .{ .Done = {} };
  FsmTailDone = Struct.new(:_) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :done; end
  end

  # Pure transition (no yield).
  #   step = next_step;
  #   continue :__sw;
  FsmTailJump = Struct.new(:next_step) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :jump; end
  end

  # Set step + return YieldReason. Used by the IO-template shape and
  # any tail that ALWAYS yields without conditional registration.
  #   step = next_step;
  #   return .{ .<reason> = {} };
  FsmTailYield = Struct.new(:next_step, :yield_reason) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :yield; end
  end

  # Conditional-yield: register on a wake source; if the registration
  # took (we'll be woken later), yield; otherwise the source already
  # completed synchronously, so jump straight to next_step.
  #
  #   if (<register_expr>) { step = next_step; return .{ .<reason> = {} }; }
  #   step = next_step;
  #   continue :__sw;
  #
  # Used by NEXT (registerFsmWaiter on Promise.wg). LOCK uses a
  # different shape (try-loop with retry); kept as template for now.
  FsmTailRegisterYield = Struct.new(
    :next_step,
    :register_expr,
    :yield_reason,
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :register_yield; end
  end

  # Conditional jump (cond ? then_step : else_step).
  #   if (<condition>) { step = then_step; continue; }
  #   step = else_step; continue;
  FsmTailCondJump = Struct.new(:condition, :then_step, :else_step) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :cond_jump; end
  end

  # Post-struct setup: alloc the ctx, spawn the promise, allocate +
  # initialize the ctx struct, init the FsmTask, fire the spawn,
  # break with the promise. All decisions (alloc kind, spawn fn,
  # ctx init field map) are explicit fields on this node — the
  # renderer walks them.
  FsmSpawnSetup = Struct.new(
    :alloc_var,            # "__bg0_alloc"
    :alloc_expr,           # MIR expression for the allocator
    :promise_var,          # "__bg0_promise"
    :promise_zig,          # "CheatLib.Promise(i64)"
    :promoted_decls,       # [MIR::Emittable]
    :ctx_var,              # "__bg0_ctx"
    :ctx_type,             # "__BgCtx0"
    :ctx_init_fields,      # [MIR::StructInitField]
    :spawn_call,           # MIR::FsmSpawnCall
    :rt_name,              # "rt" (the surrounding fn's runtime)
    :profile_site_id,      # integer id used by runtime fiber profile
    :profile_dispatch_id,  # fiber-profile.DispatchKind enum value
    :profile_site,         # MIR::ProfileTaskSite metadata comment
  )

  class FsmSpawnCall < T::Struct
    const :target, Symbol
    const :runtime_name, T.nilable(String), default: nil
    const :ctx_var, String
  end

  class FsmLoweringResult < T::Struct
    FsmBody = T.type_alias { T.any(MIR::FsmIoBody, MIR::FsmB1Body, MIR::FsmGenericBody) }

    const :body, FsmBody
    const :structure, FsmStructure
  end

  class CatchReassign < T::Struct
    const :name, String
    const :alloc, Symbol
    const :line, Integer
  end

  class CatchClauseMeta < T::Struct
    const :kinds, T::Array[String]
    const :types, T::Array[String]
    const :filter_types, T::Array[String]
    const :filter_messages, T::Array[MIR::Node]
  end

  class CatchDefaultAction < T::Enum
    enums do
      Body = new("body")
      Propagate = new("propagate")
      Unreachable = new("unreachable")
    end
  end

  class FailureActionKind < T::Enum
    enums do
      Raise = new("raise")
      Exit = new("exit")
      Pass = new("pass")
      Return = new("return")
      Block = new("block")
    end
  end

  class FailureAction < T::Struct
    extend T::Sig
    include Emittable

    const :kind, FailureActionKind
    const :error_type, Symbol
    const :error_kind, Symbol
    const :default_message, String
    const :line, String
    const :rt_name, String
    const :with_label, T.nilable(String), default: nil
    const :message, T.nilable(Emittable), default: nil
    const :return_value, T.nilable(Emittable), default: nil
    prop :body, T::Array[Emittable], default: []

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([], T::Array[Emittable::ChildExprValue])
      values << message if message
      values << return_value if return_value
      compact_child_exprs(values)
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      return [] unless kind == FailureActionKind::Block

      [body_slot(:body, body, ->(new_body) { self.body = new_body })]
    end
  end

  CapabilityLockTarget = Struct.new(:source, :arc_wrapped, :comptime_arc_unwrap) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs([source])
    end
  end

  CapabilityLockAddress = Struct.new(:source, :arc_wrapped) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs([source])
    end
  end

  class SortedLockAcquireEntry < T::Struct
    const :index, Integer
    const :alias_name, String
    const :guard_var, String
    const :held_var, String
    const :lock_expr, Emittable
    const :address_expr, Emittable
    const :method_name, String
  end

  SortedLockAcquire = Struct.new(:entries, :action, :matched_types, :bubble_types, :retries, :source_line, :loop_label, :rt_name, :fallible) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      entry_exprs = (entries || []).flat_map { |entry| [entry.lock_expr, entry.address_expr] }
      compact_child_exprs([entry_exprs, action])
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      action ? T.must(action).body_slots : []
    end
  end

  FallibleLockBinding = Struct.new(:guard_var, :alias_name, :acquire_call, :action, :retries, :matched_types, :bubble_types, :source_line, :acquire_block, :rt_name) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([acquire_call, action], T::Array[Emittable::ChildExprValue])
      compact_child_exprs(values)
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      action.body_slots
    end
  end

  class CatchClause < T::Struct
    extend T::Sig

    const :meta, CatchClauseMeta
    prop :body, T::Array[Emittable]

    sig { returns(T::Array[Emittable]) }
    def filter_message_exprs
      meta.filter_messages
    end
  end

  # Function CATCH wrapper. It is structural MIR; MIREmitter owns the only
  # conversion to Zig's `catch { ... }` syntax.
  CatchWrapper = Struct.new(:inner_call, :error_reassigns, :clauses, :default_body, :default_action, :snapshot_type, :rt_name) do
    extend T::Sig
    include Stmt

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs([inner_call, *(clauses || []).flat_map(&:filter_message_exprs)])
    end

    sig { returns(T::Array[T::Array[Emittable]]) }
    def clause_bodies
      bodies = T.let((clauses || []).map(&:body), T::Array[T::Array[Emittable]])
      bodies << default_body if has_default
      bodies
    end

    sig { returns(T::Array[CatchClauseMeta]) }
    def clause_meta
      (clauses || []).map(&:meta)
    end

    sig { returns(T::Boolean) }
    def has_default
      default_action == CatchDefaultAction::Body
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      clauses&.each_with_index do |clause, index|
        slots << body_slot(:"clauses_#{index}", clause.body, ->(new_body) { clause.body = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if has_default
      slots
    end
  end

  sig { params(plan: T.untyped).returns(T::Boolean) }
  def self.structural_bg_block_plan?(plan)
    plan.is_a?(MIR::BgStackfulPlan) ||
      plan.is_a?(MIR::BgStreamPlan) ||
      plan.is_a?(MIR::FsmIoBody) ||
      plan.is_a?(MIR::FsmB1Body) ||
      plan.is_a?(MIR::FsmGenericBody)
  end

  # DO block. Wraps a typed fork-join emission plan.
  # branch_bodies: Array<Array<MIR::Stmt>> — one per branch, lowered MIR.
  #   Carries the MIR so the checker can see allocations inside DO branches.
  DoBlock = Struct.new(:code, :branch_bodies) do
    extend T::Sig
    include Stmt
    sig { params(code: DoBlockPlan, branch_bodies: T::Array[T::Array[Emittable]]).void }
    def initialize(code, branch_bodies)
      super(code, branch_bodies)
      @boundary_facts = T.let([], T::Array[MIR::ExecutionBoundaryFact])
    end

    sig { returns(T::Array[MIR::ExecutionBoundaryFact]) }
    def boundary_facts
      @boundary_facts
    end
    sig { params(value: T::Array[MIR::ExecutionBoundaryFact]).returns(T::Array[MIR::ExecutionBoundaryFact]) }
    def boundary_facts=(value)
      @boundary_facts = value
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      branch_bodies&.each_with_index do |body, index|
        slots << body_slot(:"branch_bodies_#{index}", body, ->(new_body) { branch_bodies[index] = new_body })
      end
      slots
    end
  end

  # No-op. Emits nothing. Used as placeholder for verification-only nodes.
  Noop = Struct.new(:reason) do
    include Stmt
  end

  # Source line comment.
  # Zig: // CLR:42
  Comment = Struct.new(:text) do
    include Stmt
  end

  # Variable/param suppression.
  # Zig: _ = &name;
  Suppress = Struct.new(:name) do
    include Stmt
  end

  # Public const declaration.
  # Zig: pub const NAME = VALUE;
  PubConst = Struct.new(:name, :value) do
    include Stmt
  end

  # ================================================================
  # Memory Operations (the point of the entire MIR system)
  # ================================================================

  # --- Allocation ---

  # Heap pointer allocation + initialization.
  # Zig: blk: {
  #     const __p = try alloc.create(zig_type);
  #     errdefer alloc.destroy(__p);
  #     __p.* = init;
  #     break :blk __p;
  # }
  # Used for: @indirect fields, heap struct literals, capability boxing.
  # alloc: Symbol (:heap, :frame) resolved via rt.
  HeapCreate = Struct.new(:zig_type, :init, :alloc, :label) do
    extend T::Sig
    include Expr
    sig { params(zig_type: String, init: T.untyped, alloc: Symbol, label: T.nilable(String)).void }
    def initialize(zig_type, init, alloc, label = nil)
      super(zig_type, init, alloc, label)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([init])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # Byte slice duplication.
  # Zig: try alloc.dupe(u8, source)
  # Used for: string copies, HPT return dupes, BG captures.
  # alloc: Symbol (:heap, :frame) resolved via rt.
  DupeSlice = Struct.new(:source, :alloc) do
    extend T::Sig
    include Expr
    sig { params(source: T.untyped, alloc: Symbol).void }
    def initialize(source, alloc)
      super(source, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc, cleanup_kind: :heap_string)
    end
  end

  # Typed slice allocation (uninitialized).
  # Zig: try alloc.alloc(elem_type, len)
  # Used for: COPY list deep-copy buffer.
  # alloc: Symbol (:heap, :frame) resolved via rt.
  AllocSlice = Struct.new(:elem_type, :len, :alloc) do
    extend T::Sig
    include Expr
    sig { params(elem_type: String, len: T.untyped, alloc: Symbol).void }
    def initialize(elem_type, len, alloc)
      super(elem_type, len, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([len])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # Free a slice.
  # Zig: alloc.free(slice)
  # Used for: errdefer cleanup of AllocSlice.
  # alloc: Symbol (:heap, :frame) resolved via rt, or a MIR allocator
  # expression in generated destructor helpers where the allocator is a param.
  FreeSlice = Struct.new(:slice, :alloc) do
    extend T::Sig
    include Expr
    sig { params(slice: T.untyped, alloc: T.any(Symbol, Emittable)).void }
    def initialize(slice, alloc)
      super(slice, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([slice])
  end

  # Destroy a heap pointer.
  # Zig: alloc.destroy(ptr)
  # Used for: errdefer cleanup of HeapCreate, intermediate cap wrap cleanup.
  # alloc: Symbol (:heap, :frame) resolved via rt, or a MIR allocator
  # expression in generated destructor helpers where the allocator is a param.
  DestroyPtr = Struct.new(:ptr, :alloc) do
    extend T::Sig
    include Expr
    sig { params(ptr: T.untyped, alloc: T.any(Symbol, Emittable)).void }
    def initialize(ptr, alloc)
      super(ptr, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([ptr])
  end

  # --- Cleanup / Lifecycle ---

  # Deferred cleanup for a binding. Always emits `defer` (with optional moved
  # guard). cleanup_entry carries all pre-computed data: kind, zig_type,
  # elem_zig_type, alloc, has_moved_guard, rc_* fields, etc.
  # The emitter applies templates mechanically from the entry.
  #
  # cleanup_entry keys: :kind, :zig_type, :elem_zig_type, :alloc,
  #   :has_moved_guard, :resource_close_plan, :is_fixed,
  #   :rc_variant, :rc_alloc, :rc_release_func, :base_zig,
  #   :needs_release_fields
  #
  # Use ErrCleanup instead when ownership transfers to a callee or container
  # and cleanup is only needed on the error path.
  Cleanup = Struct.new(:name, :cleanup_entry) do
    include Stmt
  end

  # Error-path-only cleanup for a binding. Always emits `errdefer`.
  # Used when ownership transfers out of this scope on the success path
  # (TAKES arg, struct/union field) -- the callee/container owns on success,
  # but the binding must be freed if an error occurs after allocation.
  # The emitter emits `errdefer cleanup(name)` unconditionally (no guard).
  ErrCleanup = Struct.new(:name, :cleanup_entry) do
    include Stmt
  end

  # Move mark: suppress cleanup for a transferred binding.
  # Zig: name_moved = true;
  # Subsumes old MIR::SuppressCleanup.
  MoveMark = Struct.new(:name) do
    include Stmt
  end

  # --- Deep Copy ---

  # Explicit deep copy (COPY keyword). Strategy determines the pattern:
  #   :string      -> try alloc.dupe(u8, source)
  #   :union       -> try CheatLib.dupeUnionValue(T, source, alloc)
  #   :list_shallow -> blk: { alloc + memcpy }
  #   :list_deep    -> blk: { alloc + per-element dupeUnionValue }
  #   :full_value  -> try CheatLib.dupeValue(@TypeOf(source), source, alloc)
  #                   (Used when the destination type matches source: ArrayList ->
  #                    ArrayList, struct -> struct. Comptime branches in
  #                    dupeValue dispatch to the right deep-copy.)
  #   :passthrough  -> source (no copy needed, value type)
  # alloc: Symbol (:heap, :frame) resolved via rt; nil only for :passthrough.
  DEEP_COPY_SHAPE_BY_PREFIX = T.let({
    "" => :inferred,
    "*" => :pointer,
    "[]" => :slice
  }.freeze, T::Hash[String, Symbol])

  DeepCopy = Struct.new(:source, :zig_type, :elem_type, :strategy,
                        :alloc, :copy_shape) do
    extend T::Sig
    include Expr
    sig do
      params(
        source: T.untyped,
        zig_type: T.nilable(String),
        elem_type: T.nilable(String),
        strategy: Symbol,
        alloc: T.nilable(Symbol),
        copy_shape: Symbol
      ).void
    end
    def initialize(source, zig_type, elem_type, strategy, alloc, copy_shape = self.class.copy_shape_for_zig_type(zig_type))
      super(source, zig_type, elem_type, strategy, alloc, copy_shape)
    end

    sig { params(zig_type: T.nilable(String)).returns(Symbol) }
    def self.copy_shape_for_zig_type(zig_type)
      text = zig_type.to_s
      DEEP_COPY_SHAPE_BY_PREFIX.fetch(T.must(text[0, 2])) do
        DEEP_COPY_SHAPE_BY_PREFIX.fetch(T.must(text[0, 1]), :value)
      end
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none if strategy == :passthrough
      owned_effect_for_alloc(alloc)
    end
  end

  # --- Collection Initialization ---

  # Collection init with explicit allocator.
  # Strategy determines the Zig pattern:
  #   :pool           -> try T.initCapacity(alloc, cap)
  #   :list_capacity  -> try T.initCapacity(alloc, cap)
  #   :array_list_empty -> @as(T, .empty)
  #   :list_empty     -> T{}
  #   :set_empty      -> T{}
  #   :map_bare       -> T{ .alloc = alloc }
  #   :map_empty      -> T{}
  # alloc: symbol (:heap, :frame, nil) -- resolved to Zig by emitter.
  ContainerInit = Struct.new(:zig_type, :strategy, :alloc,
                             :capacity) do
    extend T::Sig
    include Expr
    sig { params(zig_type: String, strategy: Symbol, alloc: T.nilable(Symbol), capacity: T.untyped).void }
    def initialize(zig_type, strategy, alloc, capacity)
      super(zig_type, strategy, alloc, capacity)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([capacity])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # --- Capability Wrapping ---

  # Capability wrap: applies sync and/or ownership layers.
  # Zig patterns:
  #   :local     -> try CheatLib.localCreate(T, alloc, inner)
  #   :sync_only -> try CheatLib.lockedCreate(T, alloc, inner)
  #   :own_only  -> try CheatLib.arcCreate(T, alloc, inner)
  #   :both      -> blk: { sync_create; deref; destroy_inner; own_create; }
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  CapWrap = Struct.new(:inner, :zig_base, :strategy,
                       :sync_fn,   # "lockedCreate", "rwLockedCreate", "refCellCreate", nil
                       :sync_type, # "CheatLib.Locked(T)", nil
                       :own_fn,    # "arcCreate", "rcCreate", nil
                       :alloc) do
    extend T::Sig
    include Expr
    sig { params(inner: T.untyped, zig_base: String, strategy: Symbol, sync_fn: T.nilable(String), sync_type: T.nilable(String), own_fn: T.nilable(String), alloc: Symbol).void }
    def initialize(inner, zig_base, strategy, sync_fn, sync_type, own_fn, alloc)
      super(inner, zig_base, strategy, sync_fn, sync_type, own_fn, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([inner])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      kind = own_fn ? :rc : :uniform
      owned_effect_for_alloc(alloc, cleanup_kind: kind)
    end
  end

  # Promote a consumed Rc(T) handle into a fresh Arc(T).
  # Zig: copy rc.ctrl.data.* into a new Arc, then release the consumed Rc.
  SharePromote = Struct.new(:source, :zig_base, :alloc) do
    extend T::Sig
    include Expr
    sig { params(source: Emittable, zig_base: String, alloc: Symbol).void }
    def initialize(source, zig_base, alloc)
      super(source, zig_base, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc, cleanup_kind: :rc)
    end
  end

  # Rc/Arc retain (reference count increment).
  # Zig: CheatLib.arcRetain(T, name)  or  CheatLib.rcRetain(T, name)
  RcRetain = Struct.new(:source, :zig_base, :func) do
    extend T::Sig
    include Expr
    # func: "arcRetain" or "rcRetain"
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :heap, cleanup_kind: :rc)
    end
  end

  # Rc/Arc release (reference count decrement).
  # Zig: CheatLib.arcRelease(T, alloc, name)  or  CheatLib.rcRelease(T, alloc, name)
  RcRelease = Struct.new(:source, :zig_base, :func, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source, alloc])
  end

  # Rc/Arc downgrade to weak ref.
  # Zig: CheatLib.arcDowngrade(T, source) or CheatLib.rcDowngrade(T, source)
  RcDowngrade = Struct.new(:source, :zig_base, :func) do
    extend T::Sig
    include Expr
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :heap, cleanup_kind: :rc)
    end
  end

  # Weak ref upgrade to strong ref.
  # Zig: CheatLib.weakArcUpgrade(T, source) or CheatLib.weakRcUpgrade(T, source)
  WeakUpgrade = Struct.new(:source, :zig_base, :func) do
    extend T::Sig
    include Expr
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :heap, cleanup_kind: :rc)
    end
  end

  # Allocator reference. Zig-side: rt.heapAlloc() / rt.frameAlloc() /
  # rt.cleanupAlloc(). VM-side: no-op (VM is GC'd); strip_alloc_args drops
  # these at call sites. kind: :heap | :frame | :cleanup.
  AllocatorRef = Struct.new(:kind) do
    include Expr
  end

  # Compact an @multiowned tree into a single contiguous buffer.
  # Zig: try CheatLib.freeze(T, alloc, inner_ptr)
  # inner: MIR expr for the Rc data pointer (*const T)
  # zig_base: Zig type name for T
  # alloc_ref: typed allocator operand -- resolved to Zig by emitter.
  FreezeExpr = Struct.new(:inner, :zig_base, :alloc_ref) do
    extend T::Sig
    include Expr
    sig { params(inner: Emittable, zig_base: String, alloc_ref: AllocatorRef).void }
    def initialize(inner, zig_base, alloc_ref = AllocatorRef.new(:heap))
      super(inner, zig_base, alloc_ref)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([inner])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(Symbol) }
    def alloc = alloc_ref.kind
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc, cleanup_kind: :frozen)
    end
  end

  # Make a list from items.
  # Zig: try CheatLib.makeList(elem_type, alloc, &.{ items })
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  MakeList = Struct.new(:elem_type, :items, :alloc) do
    extend T::Sig
    include Expr
    sig { params(elem_type: String, items: T::Array[Emittable], alloc: Symbol).void }
    def initialize(elem_type, items, alloc)
      super(elem_type, items, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([items])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # Frame mark save.
  # Zig: const frame_mark = rt.saveFrameMark();
  FrameSave = Struct.new(:rt_expr) do
    include Stmt
  end

  # Frame mark restore (as defer).
  # Zig: defer rt.restoreFrameMark(frame_mark);
  FrameRestore = Struct.new(:rt_expr) do
    include Stmt
  end

  # ================================================================
  # MVCC Snapshot Nodes (structured -- no raw Zig escape hatch)
  # ================================================================
  #
  # These replace what used to be hand-emitted opaque blobs in
  # mir_lowering.rb's :SNAPSHOT branch + emit_snapshot_mutable_call +
  # lower_with_match_block. The backend emitter maps each
  # structured node 1:1 to the same Zig text we used to generate, BUT
  # the construct is now visible to MIRChecker. Specifically:
  #
  # - SnapshotTransaction's heap allocation (Versioned.update's new
  #   version) is now under structured MIR -- the checker can pair the
  #   AllocMark with the EBR-retire Cleanup that runs inside
  #   Versioned.update. Pre-migration this allocation lived inside an
  #   opaque string and was invisible to the checker (INV-12 violation).
  #
  # - SnapshotRead's Guard pin/release becomes a structured pair the
  #   checker can verify (matching defer-release on every exit path).
  #
  # - WithMatchDispatch carries a list of MIR-lowered arm bodies, not
  #   pre-emitted Zig strings. The checker walks each arm body with
  #   the rest of the MIR.

  # SNAPSHOT-read: `WITH SNAPSHOT cell AS view { body }` for a
  # Versioned cell in read mode. Lowers to:
  #   var <guard_var> = <cell_unwrap>.read(<rt>);
  #   defer <guard_var>.release();
  #   const <alias> = <guard_var>.get();
  # followed by the body. The unwrap_expr handles the comptime
  # pointer + Arc shape dispatch (see L7.3 / L7.4).
  #
  CapabilityUnwrap = Struct.new(:source) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
  end

  # cell_unwrap : MIR expression resolving to *Versioned(T)
  # rt          : Zig expression for *Runtime
  # alias_name  : safe identifier for the user's alias (e.g. "view")
  # guard_var   : internal Zig name for the Guard local
  SnapshotRead = Struct.new(:cell_unwrap, :rt, :alias_name, :guard_var, :body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cell_unwrap])
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # SNAPSHOT-mutable single-cell: `WITH SNAPSHOT cell AS MUTABLE va
  # { body } [ON MvccConflict <action>]` for a @versioned (MVCC) or
  # @indirect:atomic (AtomicPtr M3.6) cell in transaction mode.
  # Versioned: lowers to `Versioned.update(rt, alloc, fn(va: *T) ...)`
  # wrapped in catch+switch for ON MvccConflict handling.
  # AtomicPtr (is_atomic_ptr=true): lowers to
  # `AtomicPtr.update(rt, alloc, fn(va: *T) ...)` with NO conflict
  # handler today -- rcu retries until success. Once #330 bounds the
  # AtomicPtr.update loop at 256 the right handler will be
  # `ON AtomicConflict`.
  #
  # cell_unwrap     : MIR expr resolving to *Versioned(T) or *AtomicPtr(T)
  # rt              : runtime binding name
  # alloc           : allocator symbol (:heap or :frame)
  # alias_name      : safe identifier for the user's MUTABLE alias
  # bare_type       : Type for the inner T
  # body            : Array of MIR statements -- the user's transaction body
  # conflict_action : structural ON MvccConflict handler body (nil for atomic-ptr)
  # retries         : nil or integer N for RETRY(N) THEN <action> (nil for atomic-ptr)
  # with_label      : nil or string for the labeled block exit (PASS/block actions)
  # is_atomic_ptr   : true when the cell's sync is :atomic + layout :indirect.
  #                   Routes the emitter to the no-conflict-handler shape.
  SnapshotTransaction = Struct.new(
    :cell_unwrap, :rt, :alloc, :alias_name, :bare_type,
    :body, :conflict_action, :retries, :with_label, :is_atomic_ptr
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([cell_unwrap], T::Array[Emittable::ChildExprValue])
      values << conflict_action if conflict_action
      compact_child_exprs(values)
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:body, body, ->(new_body) { self.body = new_body })], T::Array[BodySlot])
      slots.concat(T.must(conflict_action).body_slots) if conflict_action
      slots
    end

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # SNAPSHOT-mutable multi-cell: `WITH SNAPSHOT a AS MUTABLE va, b AS
  # MUTABLE vb, ... { body } ON MvccConflict <action>`. Lowers to
  # `CheatLib.versionedUpdateMulti(.{cells...}, rt, alloc, fn(views) ...)`
  # which sorts the cells by address (deadlock-free), tags the soft
  # locks, runs the body once, and publishes all new versions
  # atomically.
  #
  # cells        : MIR expressions for the cells in `.{ cell1, cell2, ... }`
  # rt, alloc    : runtime binding name and allocator symbol
  # aliases      : Alias identifiers declared from `views[i]`
  # body         : Array of MIR statements
  # conflict_action, retries, with_label : as above
  SnapshotMultiTxn = Struct.new(
    :cells, :rt, :alloc, :aliases,
    :body, :conflict_action, :retries, :with_label
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([cells || []], T::Array[Emittable::ChildExprValue])
      values << conflict_action if conflict_action
      compact_child_exprs(values)
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:body, body, ->(new_body) { self.body = new_body })], T::Array[BodySlot])
      slots.concat(T.must(conflict_action).body_slots) if conflict_action
      slots
    end

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # True-Sync-Polymorphism Gate 3: `WITH POLYMORPHIC c AS x { body }`
  # on a parameter with no narrow REQUIRES (universal polymorphism).
  # Lowers to a single `CheatLib.polymorphicMutate(cell, rt, fn, .{})`
  # call. The runtime helper comptime-dispatches by the post-Arc
  # inner type:
  #   - has `.update`  -> Versioned / AtomicPtr (CAS retry write)
  #   - has `.write`   -> RwLocked
  #   - has `.acquire` -> Locked
  #   - else           -> plain `*T` (direct call)
  # The body is emitted as a no-capture `struct { fn run(x: *T) void
  # { ... } }.run` so it can ride the closure-style write paths.
  #
  # cell        : MIR expression for the bound binding (no Arc-unwrap;
  #               the helper does that comptime-internally).
  # rt          : runtime variable name in scope.
  # alias_name  : the user's safe alias inside the body (e.g. "x").
  # bare_type   : the type of the success branch.
  # body        : Array of MIR statements forming the WITH body.
  PolymorphicMutate = Struct.new(
    :cell, :rt, :alias_name, :bare_type, :body
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cell])
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  PolymorphicMutateFlow = Struct.new(
    :cell, :rt, :alias_name, :bare_type, :return_type, :body, :guard_cond, :guard_fail_body
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cell, guard_cond])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:body, body, ->(new_body) { self.body = new_body })], T::Array[BodySlot])
      slots << body_slot(:guard_fail_body, guard_fail_body, ->(new_body) { self.guard_fail_body = new_body }) if guard_fail_body
      slots
    end

    sig { returns(Body) }
    def body
      self[:body]
    end
  end

  # Statement scoped to PolymorphicMutateFlow callback emission.
  # It writes the private __flow result and returns from the callback.
  PolymorphicFlowSignal = Struct.new(:kind, :ret) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([ret])
  end

  class WithMatchArm < T::Struct
    extend T::Sig

    const :family, Symbol
    const :guard_var, String
    prop :body, T::Array[Emittable]
  end

  # WITH MATCH dispatch: `WITH cell AS va MATCH WHEN F1 -> {...} WHEN
  # F2 -> {...} END`. Lowers to a comptime `if (@hasField/@hasDecl)`
  # chain, one branch per family, each branch containing the matching
  # arm's lowered body.
  #
  # cell : MIR expression for the bound variable (param shape preserved)
  # arms : Array of WithMatchArm
  WithMatchDispatch = Struct.new(:cell, :alias_name, :snapshot_mode, :rt_name, :arms) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cell])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm.body, ->(new_body) { arm.body = new_body })
      end
      slots
    end
  end

  # ================================================================
  # Verification-Only Nodes (no codegen, for MIRChecker)
  # ================================================================

  # Marks an allocation point.
  AllocMark = Struct.new(:name, :alloc, :type_info, :scope) do
    extend T::Sig
    include Stmt
    sig { params(name: String, alloc: Symbol, type_info: Type, scope: T.nilable(Symbol)).void }
    def initialize(name, alloc, type_info, scope = nil)
      raise "MIR::AllocMark requires concrete Type info" if type_info.untyped?

      super(name, alloc, type_info, scope)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
    # Carrier struct: member stays :type_info; expose the project-wide
    # canonical accessor name so readers use one name everywhere.
    sig { returns(Type) }
    def full_type; type_info; end
    sig { params(val: Type).returns(Type) }
    def full_type=(val); self.type_info = val; end
  end

  # Finalized ownership facts. These are verification-only nodes: lowering may
  # still build them from existing marker nodes during the transition, but MIR
  # checking must ultimately read ownership from this closed fact surface.
  OwnedCreate = Struct.new(:name, :alloc, :type_info, :source) do
    extend T::Sig
    include Stmt
    sig { params(name: String, alloc: Symbol, type_info: Type, source: String).void }
    def initialize(name, alloc, type_info, source)
      super(name, alloc, type_info, source)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedDestroy = Struct.new(:name, :alloc, :source) do
    extend T::Sig
    include Stmt
    sig { params(name: String, alloc: Symbol, source: String).void }
    def initialize(name, alloc, source)
      super(name, alloc, source)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedTransfer = Struct.new(:name, :target, :source) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedBorrow = Struct.new(:name, :source) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedStore = Struct.new(:name, :target, :alloc, :source) do
    extend T::Sig
    include Stmt
    sig { params(name: String, target: String, alloc: T.nilable(Symbol), source: String).void }
    def initialize(name, target, alloc, source)
      super(name, target, alloc, source)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedReturn = Struct.new(:name, :source) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  # Marks function exit with escaped vars. Subsumes old MIR::Return.
  ReturnMark = Struct.new(:escaped_vars) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  # Marks an owned binding whose local cleanup is intentionally absent because
  # ownership transfers out of the current scope (TAKES arg, return, container).
  # For local owned sinks, target_alloc records the destination allocator so the
  # checker can distinguish frame-local aggregate ownership from heap escape.
  TransferMark = Struct.new(:name, :target, :target_alloc) do
    extend T::Sig
    include Stmt
    sig { params(name: String, target: Symbol, target_alloc: T.nilable(Symbol)).void }
    def initialize(name, target, target_alloc = nil)
      super(name, target, target_alloc)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  class OwnershipTransferPlan < T::Struct
    extend T::Sig

    const :name, String
    const :target, Symbol
    const :target_alloc, T.nilable(Symbol)
    const :move_guarded, T::Boolean

    sig { returns(T::Array[Stmt]) }
    def marks
      out = T.let([TransferMark.new(name, target, target_alloc)], T::Array[Stmt])
      out << MoveMark.new(name) if move_guarded
      out
    end
  end

  sig do
    params(
      name: String,
      target: Symbol,
      target_alloc: T.nilable(Symbol),
      move_guarded: T::Boolean,
    ).returns(T::Array[Stmt])
  end
  def self.ownership_transfer_marks(name, target, target_alloc: nil, move_guarded: false)
    OwnershipTransferPlan.new(
      name: name,
      target: target,
      target_alloc: target_alloc,
      move_guarded: move_guarded,
    ).marks
  end

  # Marks reassignment needing pre-cleanup. Subsumes old MIR::ReassignCleanup.
  ReassignMark = Struct.new(:name, :alloc) do
    extend T::Sig
    include Stmt
    sig { params(name: String, alloc: Symbol).void }
    def initialize(name, alloc)
      super(name, alloc)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  # Marks field overwrite needing pre-cleanup. Subsumes old MIR::FieldCleanup.
  FieldCleanupMark = Struct.new(:target_name, :field, :alloc) do
    extend T::Sig
    include Stmt
    sig { params(target_name: String, field: String, alloc: Symbol).void }
    def initialize(target_name, field, alloc)
      super(target_name, field, alloc)
    end

    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  # ================================================================
  # Expressions
  # ================================================================

  # Function call.
  # Zig: [try] callee(args)
  #
  # `owned_return` is a checker-visible structural fact from lowering:
  # this call returns an owning value that must be bound/cleaned or
  # transferred. The emitter ignores it.
  Call = Struct.new(:callee, :args, :try_wrap, :owned_return, :callable_contract) do
    extend T::Sig
    include Expr

    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end
    sig { params(value: T.nilable(Type)).returns(T.nilable(Type)) }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { params(callee: String, args: T::Array[Emittable], try_wrap: T::Boolean, owned_return: T::Boolean, callable_contract: T.nilable(CallableContract)).void }
    def initialize(callee, args, try_wrap, owned_return = false, callable_contract = nil)
      super(callee, args, try_wrap, owned_return, callable_contract)
      @never_success = T.let(false, T::Boolean)
    end

    sig { returns(T::Boolean) }
    def owned_return? = owned_return == true

    sig { returns(T::Boolean) }
    def never_success
      @never_success
    end

    sig { params(value: T::Boolean).void }
    def never_success=(value)
      @never_success = value
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([args])

    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      callable_contract&.ownership_contract
    end

    sig { returns(Call) }
    def without_try
      out = Call.new(callee, args, false, owned_return, callable_contract)
      out.never_success = never_success
      out.result_type = Type.new(result_type) if result_type
      out
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless owned_return?
      alloc_arg = args.find { |arg| arg.is_a?(AllocatorRef) }
      OwnershipEffect.owned(alloc: alloc_arg&.kind || :heap)
    end
  end

  class RuntimeCallSpec < T::Struct
    extend T::Sig

    const :callee, String
    const :try_wrap, T::Boolean, default: false
    const :owned_return, T::Boolean, default: false
    const :callable_contract, CallableContract

    sig { params(args: T::Array[Emittable]).returns(Call) }
    def call(args)
      Call.new(callee, args, try_wrap, owned_return, callable_contract)
    end
  end

  RuntimeCall = Struct.new(:spec, :args) do
    extend T::Sig
    include Expr

    sig { params(spec: RuntimeCallSpec, args: T::Array[Emittable]).void }
    def initialize(spec, args)
      super(spec, args)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([args])

    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      spec.callable_contract.ownership_contract
    end

    sig { returns(T::Boolean) }
    def owned_return? = spec.owned_return

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless owned_return?
      alloc_arg = args.find { |arg| arg.is_a?(AllocatorRef) }
      OwnershipEffect.owned(alloc: alloc_arg&.kind || :heap)
    end
  end

  module RuntimeCalls
    extend T::Sig

    EQL = T.let(
      RuntimeCallSpec.new(
        callee: "CheatLib.eql",
        callable_contract: CallableContract.no_ownership(2),
      ).freeze,
      RuntimeCallSpec,
    )

    THREAD_COUNT = T.let(
      RuntimeCallSpec.new(
        callee: "CheatLib.threadCount",
        callable_contract: CallableContract.no_ownership(0),
      ).freeze,
      RuntimeCallSpec,
    )

    sig { returns(RuntimeCallSpec) }
    def self.eql_spec
      EQL
    end

    sig { returns(RuntimeCallSpec) }
    def self.thread_count_spec
      THREAD_COUNT
    end

    sig { params(element_zig: String).returns(RuntimeCallSpec) }
    def self.batch_window_init_spec(element_zig)
      RuntimeCallSpec.new(
        callee: "CheatLib.BatchWindow(#{element_zig}).init",
        callable_contract: CallableContract.no_ownership(3),
      )
    end

    sig { params(inner_zig: String).returns(RuntimeCallSpec) }
    def self.atomic_reduce_init_spec(inner_zig)
      RuntimeCallSpec.new(
        callee: "CheatLib.obs.AtomicReduce(#{inner_zig}).init",
        callable_contract: CallableContract.no_ownership(1),
      )
    end
  end

  # Tail call (emits @call(.always_tail, callee, .{args})).
  TailCall = Struct.new(:callee, :args, :callable_contract) do
    extend T::Sig
    include Expr

    sig { params(callee: String, args: T::Array[T.untyped], callable_contract: T.nilable(CallableContract)).void }
    def initialize(callee, args, callable_contract = nil)
      super(callee, args, callable_contract)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([args])

    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      callable_contract&.ownership_contract
    end
  end

  # Method call.
  # Zig: receiver.method(args)
  MethodCall = Struct.new(:receiver, :method, :args, :try_wrap, :callable_contract, :owned_result_alloc) do
    extend T::Sig
    include Expr

    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end
    sig { params(value: T.nilable(Type)).returns(T.nilable(Type)) }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig do
      params(
        receiver: T.untyped,
        method: String,
        args: T::Array[T.untyped],
        try_wrap: T::Boolean,
        callable_contract: T.nilable(CallableContract),
        owned_result_alloc: T.nilable(Symbol),
      ).void
    end
    def initialize(receiver, method, args, try_wrap, callable_contract = nil, owned_result_alloc = nil)
      super(receiver, method, args, try_wrap, callable_contract, owned_result_alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([receiver, args])

    sig { returns(T.nilable(OwnershipContract)) }
    def explicit_ownership_contract
      callable_contract&.ownership_contract
    end

    sig { returns(MethodCall) }
    def without_try
      out = MethodCall.new(receiver, method, args, false, callable_contract, owned_result_alloc)
      out.result_type = Type.new(result_type) if result_type
      out
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      alloc = owned_result_alloc
      return OwnershipEffect.none unless alloc

      OwnershipEffect.owned(alloc: alloc)
    end
  end

  # Field access.
  # Zig: object.field
  FieldGet = Struct.new(:object, :field) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([object])
  end

  # Safe tagged-union payload extraction. This exists only for non-switchable
  # union MATCH shapes; pure union MATCH lowers to UnionMatchStmt payload
  # capture so the payload is structurally tied to its active arm.
  UnionPayloadGet = Struct.new(:subject, :variant) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([subject])
  end

  # Index access.
  # Zig: object[index]  or  specialized patterns (charAt, numericMapGet, etc.)
  IndexGet = Struct.new(:object, :index) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([object, index])
  end

  # Binary operation.
  # Zig: left op right
  # op is the Zig operator string: "+", "-", "==", "and", "or", etc.
  BinOp = Struct.new(:op, :left, :right) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([left, right])
  end

  # Unary operation.
  # Zig: op operand
  UnaryOp = Struct.new(:op, :operand) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([operand])
  end

  # Literal value. Carries pre-formatted Zig literal string.
  # Zig: 42, 3.14, "hello", true, null, etc.
  Lit = Struct.new(:value) do
    include Expr
  end

  # Void value.
  # Zig: {}
  VoidLiteral = Struct.new(nil) do
    include Expr
  end

  class DefaultValue < T::Struct
    include Expr

    const :kind, Symbol
    const :zig_type, T.nilable(String), default: nil
  end

  class EnumTag < T::Struct
    include Expr

    const :variant, String
  end

  EnumOrdinal = Struct.new(:value) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([value])
  end

  # Variable / name reference.
  # Zig: name
  Ident = Struct.new(:name) do
    include Expr
  end

  # Anonymous tuple literal.
  # Zig: .{ item1, item2, ... }
  TupleLiteral = Struct.new(:items) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([], T::Array[Emittable::ChildExprValue])
      items.each { |item| values << item if item.is_a?(Emittable) }
      compact_child_exprs(values)
    end
  end

  # Function pointer reference.
  # Zig: &name
  FnRef = Struct.new(:name) do
    include Expr
  end

  LockAcquire = Struct.new(:lock_expr, :lock_sync, :fallible) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs([lock_expr])
    end
  end

  TypeOf = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs([expr])
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Struct initialization.
  # Zig: TypeName{ .a = x, .b = y }  or  .{ .a = x }
  StructInit = Struct.new(:zig_type, :fields) do
    extend T::Sig
    include Expr
    # zig_type: String or nil (nil -> anonymous .{})
    # fields: [MIR::StructInitField] (legacy hash fields are still readable)
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([], T::Array[Emittable::ChildExprValue])
      fields&.each do |field|
        value = MIR.struct_init_field_value(field)
        values << value if value
      end
      compact_child_exprs(values)
    end
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_children(child_exprs)
    end

  end

  # Fixed-size array initialization.
  # Zig: [N]T{ item1, item2, ... }
  ArrayInit = Struct.new(:elem_type, :count, :items) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([items])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
  end

  # Fixed-size array default initialization.
  # Zig: [_]T{ default } ** N
  ArrayDefaultInit = Struct.new(:elem_type, :count, :default_value, :alloc) do
    extend T::Sig
    include Expr

    sig { params(elem_type: String, count: String, default_value: Emittable, alloc: T.nilable(Symbol), result_type: Type).void }
    def initialize(elem_type, count, default_value, alloc, result_type)
      super(elem_type, count, default_value, alloc)
      @result_type = T.let(result_type, Type)
    end

    sig { returns(Type) }
    def result_type
      @result_type
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([default_value])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = []
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # Slice expression.
  # Zig: @as([]const T, target[start..end])
  SliceExpr = Struct.new(:target, :start, :end_expr, :elem_type) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([target, start, end_expr])
  end

  # Labeled block expression.
  # Zig: label: { body; break :label result; }
  BlockExpr = Struct.new(:label, :body) do
    extend T::Sig
    include Expr
    sig { returns(T::Boolean) }
    def lazy_boundary
      @lazy_boundary = T.let(nil, T.nilable(T::Boolean)) unless defined?(@lazy_boundary)
      @lazy_boundary == true
    end

    sig { params(value: T::Boolean).void }
    def lazy_boundary=(value)
      @lazy_boundary = T.let(value, T.nilable(T::Boolean))
    end
    # body: [MIR stmt] -- last stmt should be BreakStmt with matching label
    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end

    sig { params(value: T.nilable(Type)).void }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]

    sig { returns(Body) }
    def body
      self[:body]
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_block_body(body, result_type: result_type)
    end
  end

  # String concatenation.
  # Zig: try std.mem.concat(alloc, u8, &.{ parts })
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  # rt_expr: Zig expression for runtime (e.g. "rt") -- used for rt-dependent calls.
  ConcatStr = Struct.new(:parts, :alloc, :rt_expr) do
    extend T::Sig
    include Expr
    sig { params(parts: T::Array[T.untyped], alloc: Symbol, rt_expr: T.nilable(String)).void }
    def initialize(parts, alloc, rt_expr)
      super(parts, alloc, rt_expr)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([parts])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc, cleanup_kind: :heap_string)
    end
  end

  # Type cast.
  # Zig: @as(target_type, expr)  or  @intCast(expr)  etc.
  Cast = Struct.new(:expr, :target_type, :method) do
    extend T::Sig
    include Expr
    # method: :as, :intCast, :floatCast, :ptrCast, :intFromFloat,
    #         :floatFromInt, :truncate, :enumFromInt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.of(expr)
    end

    sig { returns(Emittable) }
    def without_try
      expr
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Try expression (wraps a failable expression).
  # Zig: try expr
  TryExpr = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.of(expr)
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Try-catch expression.
  # Zig: expr catch |err| fallback
  # or   (expr catch fallback)
  TryCatch = Struct.new(:expr, :catch_body, :capture) do
    extend T::Sig
    include Expr
    # capture: error variable name or nil
    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end

    sig { params(value: T.nilable(Type)).void }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr, catch_body])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_try_fallback(
        OwnershipEffect.of(expr),
        OwnershipEffect.of(catch_body),
        result_type: result_type,
        fallback_is_literal: catch_body.is_a?(Lit),
        left_never_success: call_never_success?(expr),
      )
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end

    private

    sig { params(value: Emittable).returns(T::Boolean) }
    def call_never_success?(value)
      value.is_a?(Call) && value.never_success
    end
  end

  # Optional orelse expression.
  # Zig: (expr orelse fallback)
  Orelse = Struct.new(:expr, :fallback) do
    extend T::Sig
    include Expr
    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end

    sig { params(value: T.nilable(Type)).void }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr, fallback])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_optional_fallback(
        OwnershipEffect.of(expr),
        OwnershipEffect.of(fallback),
        result_type: result_type,
      )
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Conditional expression (Zig if-expression).
  # Zig: if (cond) then_val else else_val
  Conditional = Struct.new(:cond, :then_val, :else_val) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cond, then_val, else_val])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = compact_child_exprs([then_val, else_val])
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = ownership_source_exprs
  end

  # Optional-unwrap conditional expression.
  # Zig: (if (optional) |capture| then_expr else else_expr)
  # capture is the name bound to the unwrapped value inside then_expr.
  IfOptional = Struct.new(:optional, :capture, :then_expr, :else_expr) do
    extend T::Sig
    include Expr
    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end

    sig { params(value: T.nilable(Type)).void }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([optional, then_expr, else_expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = compact_child_exprs([then_expr, else_expr])
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = ownership_source_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_required_branch_pair(
        OwnershipEffect.of(then_expr),
        OwnershipEffect.of(else_expr),
      )
    end
  end

  # Comptime-qualified expression.
  # Zig: comptime expr
  # Forces expr to be evaluated at compile time.
  Comptime = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Semantic union-variant payload access.
  # Zig: union_value.Variant
  # zig_type: the union's Zig type name (for checker cross-reference and
  # for bc_emitter dispatch). Distinguishes variant access from struct-field
  # access so bc_emitter can route to native `cdr` (or equivalent) without
  # scanning variant name tables.
  UnionVariantGet = Struct.new(:object, :variant, :zig_type) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([object])
  end

  # Semantic list-backing-slice access.
  # Zig: list.items
  # Used by lowering to mark list-specific accesses (vs arbitrary struct
  # fields). The checker and bc_emitter can dispatch on node class rather
  # than name-matching "items".
  ListItems = Struct.new(:list) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([list])
  end

  # Semantic list length access.
  # Zig: expr.len
  # Wrap in ListItems first for ArrayList-shaped containers whose length
  # lives at list.items.len (compose as ListLength(ListItems(list))).
  ListLength = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Address-of.
  # Zig: &expr
  AddressOf = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Dereference.
  # Zig: expr.*
  Deref = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Pointer cast with Zig's required alignment assertion.
  # Zig: @as(target_type, @ptrCast(@alignCast(expr)))
  PointerCast = Struct.new(:expr, :target_type) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Const-removing cast for APIs that legitimately mutate through a slice.
  # Zig: @constCast(expr)
  ConstCast = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Default bounded-channel capacity for streaming CONCURRENT.
  # Rounds worker_count * 4 up to a power of two in 4..64.
  DefaultStreamCapacity = Struct.new(:worker_count) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([worker_count])
  end

  # NEXT on a promise list (~T[]@list): await each promise into a new
  # ArrayListUnmanaged(T) owned by `alloc`.
  NextPromiseList = Struct.new(:list_expr, :elem_zig, :label, :results_var, :alloc) do
    extend T::Sig
    include Expr

    sig { params(list_expr: Emittable, elem_zig: String, label: String, results_var: String, alloc: Symbol, result_type: Type).void }
    def initialize(list_expr, elem_zig, label, results_var, alloc, result_type)
      super(list_expr, elem_zig, label, results_var, alloc)
      @result_type = T.let(result_type, Type)
    end

    sig { returns(Type) }
    def result_type
      @result_type
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([list_expr])

    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end
  end

  # Uninitialized-memory sentinel. Zig: `undefined`. VM: nil (the slot is
  # about to be written before use).
  Undef = Struct.new(:zig_type) do
    include Expr
    # zig_type is optional — used by the Zig emitter when it needs a typed
    # undefined like `@as(T, undefined)`.
  end

  # Type sentinel — floatMax/floatMin/intMax/intMin style bootstrap value.
  # Zig: std.math.floatMax(T), -std.math.floatMax(T), std.math.maxInt(T), etc.
  # VM: a large concrete literal sufficient for accumulator-seed purposes.
  # kind: :max | :min      extreme: which end of the type range.
  # zig_type: the Zig type string (e.g. "f64", "i64").
  TypeSentinel = Struct.new(:extreme, :zig_type) do
    include Expr
  end

  # Bare integer range for Zig `for (0..N) |i| { ... }` loops. Distinct from
  # RangeLit which wraps as CheatLib.IntRange{...}. IterRange emits literal
  # `start..end` and is legal only inside ForStmt iterables.
  # capture_type is :usize for runtime index loops and :i64 for Clear integer
  # range iteration; nil preserves Zig's native range capture type.
  IterRange = Struct.new(:start, :end_val, :capture_type) do
    include Expr
  end

  # Optional unwrap.
  # Zig: expr.?
  OptionalUnwrap = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Range literal.
  # Zig: CheatLib.IntRange{ .start = s, .end = e } or CheatLib.Range{ .start = s, .end = e }
  RangeLit = Struct.new(:start, :end_val, :elem_type) do
    extend T::Sig
    include Expr
    sig { returns(T.nilable(Type)) }
    def result_type
      @result_type = T.let(nil, T.nilable(Type)) unless defined?(@result_type)
      @result_type
    end

    sig { params(value: T.nilable(Type)).void }
    def result_type=(value); @result_type = T.let(value, T.nilable(Type)); end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([start, end_val])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :frame, cleanup_kind: :uniform, requires_hoist: false)
    end
  end

  # Comptime has-field check.
  # Zig: @hasField(@TypeOf(expr), "field")
  HasField = Struct.new(:expr, :field) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Items accessor (ArrayList -> slice).
  # Zig: expr.items  or  (if (@hasField(...)) expr.items else expr)
  ItemsAccess = Struct.new(:expr, :safe) do
    extend T::Sig
    include Expr
    # safe: true -> emit @hasField guard, false -> direct .items
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])

    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Transfer an ArrayList-backed value into an owned slice.
  # Zig: try expr.toOwnedSlice(alloc)
  OwnedSlice = Struct.new(:expr, :alloc) do
    extend T::Sig
    include Expr
    sig { params(expr: Emittable, alloc: Symbol).void }
    def initialize(expr, alloc)
      super(expr, alloc)
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(OwnershipEffect) }
    def ownership_effect
      owned_effect_for_alloc(alloc)
    end

    sig { returns(Emittable) }
    def expr
      self[:expr]
    end
  end

  # Lambda expression (anonymous function pointer via struct trick).
  # Zig: &(struct { fn name(params) ret { body } }).name
  LambdaExpr = Struct.new(:fn_def, :captures) do
    include Expr
    # fn_def: MIR::FnDef with the lambda's implementation
    # captures: optional Array<String> — USE-captured variable names
    # from the AST. The Zig backend ignores these (the synthesized
    # struct's `fn` accesses outer scope); the BC backend uses them
    # to emit STORE_NAME at lambda creation and LOAD_NAME inside the
    # body so the values survive across the BC_CALL boundary.
  end

  # Pipeline IR node. Wraps the pre-computed MIR output of a |> chain.
  # Phase 1: inner carries old-path MIR; all other fields nil.
  # Future phases: source_type, stages, sink, sink_alloc encode streaming structure.
  #
  # ast_node:    original |> BinaryOp AST node
  # inner:       pre-computed MIR from existing paths (Phase 1), nil in Phase 2+
  # source_type: :range/:slice/:list/:pool/:sharded/:inf_stream (Phase 2+)
  # stages:      Array of stage descriptors (Phase 3+)
  # sink:        sink descriptor (Phase 4+)
  # sink_alloc:  :frame/:heap for sink output (Phase 4+)
  Pipeline = Struct.new(:ast_node, :inner, :source_type, :stages, :sink, :sink_alloc) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end  # can appear in both expression and statement position

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([inner])
    sig { returns(T::Array[Emittable]) }
    def ownership_source_exprs = child_exprs
    sig { returns(T::Array[Emittable]) }
    def owned_position_source_exprs = child_exprs

    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.from_pipeline(sink_alloc: sink_alloc, inner: inner)
    end
  end

  class RegistryCallArg < T::Struct
    const :expr, Emittable
    const :coerce_type, T.nilable(Symbol), default: nil
  end

  class RegistryCall < T::Struct
    extend T::Sig

    include Expr

    const :entry, FunctionSignature
    const :args, T::Array[RegistryCallArg]
    const :reason, String
    const :ownership_contract, OwnershipContract, default: OwnershipContract.empty
    prop :allocs, T.nilable(InlineAllocMetadata), default: nil
    const :owned_result_alloc, T.nilable(Symbol), default: nil
    prop :target_var, T.nilable(String), default: nil
    const :result_type, T.nilable(Type), default: nil
    const :result_ownership_bearing, T.nilable(T::Boolean), default: nil
    const :key_type, T.nilable(Type), default: nil
    const :value_type, T.nilable(Type), default: nil
    const :suppress_try, T::Boolean, default: false

    sig { returns(FunctionSignature) }
    def stdlib_def
      entry
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      children = T.let([], T::Array[Emittable::ChildExprValue])
      args.each { |arg| children << arg.expr }
      compact_child_exprs(children)
    end

    sig { returns(T::Boolean) }
    def has_alloc_metadata?
      metadata = allocs
      metadata.is_a?(InlineAllocMetadata) && !metadata.empty?
    end

    sig { returns(T::Boolean) }
    def mutating_receiver_allocator_op?
      has_alloc_metadata? && entry.mutates_receiver?
    end

    sig { returns(T::Boolean) }
    def assignable_allocating_result?
      entry.emits_allocating? && !entry.mutates_receiver?
    end

    sig { returns(OwnershipContract) }
    def explicit_ownership_contract
      ownership_contract
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      result_alloc = owned_result_alloc || (entry.heap_return_alloc? ? :heap : nil)
      metadata = allocs
      alloc = if result_alloc
        result_alloc
      elsif metadata.is_a?(InlineAllocMetadata)
        metadata.single_alloc
      else
        nil
      end
      fixed_void = !!(entry.fixed_return? == true &&
                      entry.return_type.void? &&
                      !has_alloc_metadata?)
      OwnershipEffect.from_callable_facts(
        emits_allocating: entry.emits_allocating? == true,
        heap_return_alloc: !result_alloc.nil?,
        fixed_void_without_alloc_metadata: fixed_void,
        mutates_receiver_without_heap_return: entry.mutates_receiver? && result_alloc.nil?,
        result_owns: result_ownership_bearing,
        result_type: result_type,
        alloc: alloc,
        target_var: target_var
      )
    end

    sig { returns(RegistryCall) }
    def without_try
      RegistryCall.new(
        entry: entry,
        args: args,
        reason: reason,
        ownership_contract: ownership_contract,
        allocs: allocs,
        owned_result_alloc: owned_result_alloc,
        target_var: target_var,
        result_type: result_type,
        result_ownership_bearing: result_ownership_bearing,
        key_type: key_type,
        value_type: value_type,
        suppress_try: true,
      )
    end
  end

  class IndexedStore < T::Struct
    extend T::Sig

    include Expr

    const :target, Emittable
    const :index, Emittable
    const :value, Emittable
    const :entry, FunctionSignature
    const :template_kind, IntrinsicTemplateKind
    const :map_kind, Symbol
    const :ownership_contract, OwnershipContract, default: OwnershipContract.empty
    const :allocs, InlineAllocMetadata, default: InlineAllocMetadata.new
    const :target_var, T.nilable(String), default: nil
    const :key_type, T.nilable(Type), default: nil
    const :value_type, T.nilable(Type), default: nil

    sig { returns(FunctionSignature) }
    def stdlib_def
      entry
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      children = T.let([], T::Array[Emittable::ChildExprValue])
      children << target
      children << index
      children << value
      compact_child_exprs(children)
    end

    sig { returns(T::Boolean) }
    def has_alloc_metadata?
      !allocs.empty?
    end

    sig { returns(T::Boolean) }
    def mutating_receiver_allocator_op?
      has_alloc_metadata? && entry.mutates_receiver?
    end

    sig { returns(OwnershipContract) }
    def explicit_ownership_contract
      ownership_contract
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      heap_return = entry.heap_return_alloc? == true
      fixed_void = !!(entry.fixed_return? == true &&
                      entry.return_type.void? &&
                      !has_alloc_metadata?)
      OwnershipEffect.from_callable_facts(
        emits_allocating: entry.emits_allocating? == true,
        heap_return_alloc: heap_return,
        fixed_void_without_alloc_metadata: fixed_void,
        mutates_receiver_without_heap_return: entry.mutates_receiver? && !heap_return,
        result_owns: nil,
        result_type: entry.return_type,
        alloc: heap_return ? :heap : allocs.single_alloc,
        target_var: target_var
      )
    end
  end

  class ExternTrampolineArg < T::Struct
    const :expr, Emittable
    const :field_type, T.nilable(Type), default: nil
  end

  class ExternTrampoline < T::Struct
    extend T::Sig

    include Expr

    const :id, Integer
    const :callee_name, String
    const :module_alias, T.nilable(String), default: nil
    const :method_name, T.nilable(String), default: nil
    const :receiver, T.nilable(Emittable), default: nil
    const :comptime_args, T::Array[Emittable], factory: -> { [] }
    const :runtime_args, T::Array[ExternTrampolineArg], factory: -> { [] }
    const :alloc_kind, T.nilable(Symbol), default: nil
    const :return_type, Type
    const :stdlib_def, FunctionSignature

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      children = T.let([], T::Array[Emittable::ChildExprValue])
      current_receiver = receiver
      children << current_receiver if current_receiver
      comptime_args.each { |arg| children << arg }
      runtime_args.each { |arg| children << arg.expr }
      compact_child_exprs(children)
    end

	    sig { returns(OwnershipEffect) }
	    def ownership_effect
	      heap_return = stdlib_def.heap_return_alloc? == true
	      actual_return = return_type.success_type || return_type
	      OwnershipEffect.from_callable_facts(
	        emits_allocating: stdlib_def.emits_allocating? == true,
	        heap_return_alloc: heap_return,
	        fixed_void_without_alloc_metadata: stdlib_def.fixed_return? && actual_return.void?,
	        mutates_receiver_without_heap_return: stdlib_def.mutates_receiver? && !heap_return,
	        result_owns: nil,
	        result_type: return_type,
        alloc: alloc_kind,
        target_var: nil
      )
    end
  end

  class ObservableConsumerSpawn < T::Struct
    extend T::Sig

    include Expr

    const :id, Integer
    const :acc_name, String
    const :source_name, String
    const :acc_type, Type
    const :runtime_name, String
    const :task_config_variant, String
    const :stdlib_def, FunctionSignature
    const :ownership_contract, OwnershipContract
    prop :body, T::Array[Emittable]

    sig { returns(OwnershipContract) }
    def explicit_ownership_contract
      ownership_contract
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      [body_slot(:body, body, ->(new_body) { self.body = new_body })]
    end
  end

  class ShardConcurrentEach < T::Struct
    extend T::Sig

    include Stmt

    const :id, Integer
    const :map_expr, Emittable
    const :map_var_name, String
    const :map_type, Type
    const :key_type, Type
    const :shard_count, Integer
    const :start_expr, Emittable
    const :finish_expr, Emittable
    const :inclusive, T::Boolean
    const :capacity_expr, Emittable
    const :batch_size_expr, Emittable
    const :task_config_variant, String
    prop :producer_key_body, T::Array[Emittable]
    const :capture_fields, T::Array[ContextFieldDecl], factory: -> { [] }
    const :capture_inits, T::Array[StructInitField], factory: -> { [] }
    prop :capture_setup, T::Array[Emittable], factory: -> { [] }
    prop :body, T::Array[Emittable]
    const :key_allocates_frame, T::Boolean
    const :body_allocates_frame, T::Boolean

    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs(T.unsafe([
        map_expr,
        start_expr,
        finish_expr,
        capacity_expr,
        batch_size_expr,
      ]))
    end

    sig { returns(T::Array[BodySlot]) }
    def body_slots
      [
        body_slot(:producer_key_body, producer_key_body, ->(new_body) { self.producer_key_body = new_body }),
        body_slot(:capture_setup, capture_setup, ->(new_body) { self.capture_setup = new_body }),
        body_slot(:body, body, ->(new_body) { self.body = new_body }),
      ]
    end
  end

  # Inline bytecode. Consumed only by bc_emitter (the
  # VM backend). Emitted by MIR lowering when target == :bc AND the stdlib
  # registry entry opts into bc (entry[:bc] == true). Carries the op symbol
  # (same key used in BUILTIN_OPS) + arg expressions.
  #
  # op:    Symbol — the registry key (e.g. :intAdd, :assert, :eql).
  # args:  Array<MIR::Expr> — the argument expressions (unlowered).
  # stdlib_def: the registry hash (ownership semantics).
  #
  # bc_emitter has a case-per-op dispatch. It evaluates args (via compile_expr)
  # in declared order, then emits the corresponding opcode sequence. The Zig
  # backend must never see this node.
  InlineBc = Struct.new(:op, :args, :stdlib_def) do
    include Expr
    extend T::Sig

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs(args)

    sig { returns(OwnershipEffect) }
    def ownership_effect
      sig = FunctionSignature.unwrap(stdlib_def)
      return OwnershipEffect.none unless sig

      heap_return = sig.heap_return_alloc? == true
      OwnershipEffect.from_callable_facts(
        emits_allocating: sig.emits_allocating? == true,
        heap_return_alloc: heap_return,
        fixed_void_without_alloc_metadata: sig.fixed_return? && sig.return_type.void?,
        mutates_receiver_without_heap_return: sig.mutates_receiver? && !heap_return,
        result_owns: nil,
        result_type: sig.return_type,
        alloc: heap_return ? :heap : nil,
        target_var: nil
      )
    end
  end

  # Register/bytecode OR-EXIT error rewrite. This used to ride through
  # InlineBc as an ad hoc metadata hash, but InlineBc now has one role:
  # stdlib/function-signature-backed bytecode intrinsic dispatch.
  OrExitBcRewrite = Struct.new(:kind, :name_id, :clear_type, :has_message, :line, :message) do
    include Expr
    extend T::Sig

    sig do
      params(
        kind: T.nilable(String),
        name_id: T.nilable(Integer),
        clear_type: T::Boolean,
        has_message: T::Boolean,
        line: Integer,
        message: T.nilable(Emittable)
      ).void
    end
    def initialize(kind, name_id, clear_type, has_message, line, message = nil)
      super
    end

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([message])
  end

  # Sharded HashMap put / get -- structural representation of a write/read
  # against a (possibly sharded, possibly Arc-wrapped) HashMap.
  #
  # Fields:
  #   target:      MIR node for the container being read/written.
  #   key:         MIR node for the lookup key (string or numeric).
  #   value:       MIR node for the value being written (Put only).
  #   shard_idx:   MIR node (typically Ident) for the shard index var
  #                when emitted inside a SHARD pipeline body. nil ->
  #                routed dispatch (target.put / target.get computes
  #                the shard internally).
  #   shard_key:   MIR node for the shard-keyed lookup string (only set
  #                when shard_idx is non-nil and the shard_direct
  #                template uses it).
  #   map_kind:    :string_map | :numeric_map -- chooses key encoding.
  #   stdlib_def:  the INDEX_OPS entry (with :zig, :shard_direct_zig,
  #                :sharded_zig, allocator keys,
  #                bc_op). The Zig emitter reads this to pick the
  #                template; the checker reads it to validate
  #                ownership effects.
  #   key_type:    Optional numeric-map key Type. The emitter renders it into
  #                CheatLib.numericMap* templates.
  #   value_type:  Same, for value type.
  # resolved_allocs: InlineAllocMetadata of allocator placeholder name
  #   (:alloc, :key_alloc, :val_alloc, :shard_alloc) to a resolved allocator
  #   symbol (:heap | :frame). The lowering pre-resolves :receiver_storage /
  #   :node_storage to a concrete kind based on the receiver/target context,
  #   so the emitter only needs to map symbol -> Zig string.
  # template_kind: IntrinsicTemplateKind -- which
  #   INDEX_OPS template the lowering chose. The emitter uses this to
  #   pick the same template without re-running the lowering's
  #   shard-context inspection.
  ShardedMapPut = Struct.new(:target, :key, :value, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_type, :value_type,
                              :resolved_allocs, :template_kind, :target_var) do
    extend T::Sig
    include Stmt
	    sig { params(target: Emittable, key: Emittable, value: Emittable, shard_idx: T.nilable(Emittable), shard_key: T.nilable(Emittable), map_kind: Symbol, stdlib_def: FunctionSignature, key_type: T.nilable(Type), value_type: T.nilable(Type), resolved_allocs: InlineAllocMetadata, template_kind: IntrinsicTemplateKind, target_var: T.nilable(String)).void }
    def initialize(target, key, value, shard_idx, shard_key, map_kind, stdlib_def, key_type, value_type, resolved_allocs, template_kind, target_var = nil)
      super(target, key, value, shard_idx, shard_key, map_kind, stdlib_def, key_type, value_type,
        resolved_allocs, template_kind, target_var)
    end
    sig { returns(T::Boolean) }
    def expr?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([target, key, value])
    sig { returns(T::Boolean) }
    def has_alloc_metadata?
      !resolved_allocs.empty?
    end
    sig { returns(T::Boolean) }
    def mutating_receiver_allocator_op?
      has_alloc_metadata?
    end
    sig { returns(OwnershipContract) }
    def explicit_ownership_contract
      OwnershipContract.empty
    end
    sig { returns(OwnershipEffect) }
    def ownership_effect
      heap_return = stdlib_def.heap_return_alloc? == true
      OwnershipEffect.from_callable_facts(
        emits_allocating: stdlib_def.emits_allocating? == true,
        heap_return_alloc: heap_return,
        fixed_void_without_alloc_metadata: !!(stdlib_def.fixed_return? && stdlib_def.return_type.void? && !has_alloc_metadata?),
        mutates_receiver_without_heap_return: mutating_receiver_allocator_op? && !heap_return,
        result_owns: nil,
        result_type: stdlib_def.return_type,
        alloc: heap_return ? :heap : resolved_allocs.single_alloc,
        target_var: nil,
      )
    end
  end

  ShardedMapGet = Struct.new(:target, :key, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_type, :value_type,
                              :resolved_allocs, :template_kind) do
    extend T::Sig
    include Expr
    sig { params(target: Emittable, key: Emittable, shard_idx: T.nilable(Emittable), shard_key: T.nilable(Emittable), map_kind: Symbol, stdlib_def: FunctionSignature, key_type: T.nilable(Type), value_type: T.nilable(Type), resolved_allocs: InlineAllocMetadata, template_kind: IntrinsicTemplateKind).void }
    def initialize(target, key, shard_idx, shard_key, map_kind, stdlib_def, key_type, value_type, resolved_allocs, template_kind)
      super(target, key, shard_idx, shard_key, map_kind, stdlib_def, key_type, value_type,
        resolved_allocs, template_kind)
    end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([target, key])
  end

  # Hard flip (EPIC #65): every stdlib_def carrier coerces its payload
  # to a FunctionSignature on write. No Hash backdoor -- readers still
  # doing entry[:zig]/.dig(:...) will fail loudly, which is the
  # intended map of remaining reader-migration work.
  module StdlibDefFsCoercion
    extend T::Sig
    sig { params(v: T.untyped).returns(T.nilable(FunctionSignature)) }
    def stdlib_def=(v)
      super(IntrinsicRegistry.fs(v))
    end

    # Struct positional construction (`InlineBc.new(op, args, hash)`)
    # assigns the member directly, bypassing the setter -- re-run it
    # through the coercing setter so the carrier is always FS.
    sig { params(args: T.untyped).void }
    def initialize(*args)
      super
      T.unsafe(self).stdlib_def = T.unsafe(self).stdlib_def
    end
  end
  [InlineBc, ShardedMapPut, ShardedMapGet].each do |k|
    k.prepend(StdlibDefFsCoercion)
  end

  LEGACY_OWNERSHIP_NODE_TYPES = T.let(
    [:ReassignCleanup, :FieldCleanup, :ReassignPlan].filter_map do |name|
      value = const_defined?(name, false) ? const_get(name, false) : nil
      value if value.is_a?(Class)
    end.freeze,
    T::Array[T::Class[T.anything]],
  )
  LEGACY_OWNERSHIP_NODE_NAMES = T.let(
    ["MIR::ReassignCleanup", "MIR::FieldCleanup", "MIR::ReassignPlan"].freeze,
    T::Array[String],
  )

  OWNERSHIP_SIGNIFICANT_NODE_TYPES = T.let([
    OwnedCreate, OwnedDestroy, OwnedTransfer, OwnedBorrow, OwnedStore, OwnedReturn,
    AllocMark, Cleanup, ErrCleanup, TransferMark, MoveMark,
    ReassignMark, FieldCleanupMark, ReassignWithCleanup,
    *LEGACY_OWNERSHIP_NODE_TYPES,
    ReturnMark, DiscardOwned, RegistryCall, IndexedStore, ExternTrampoline, ObservableConsumerSpawn,
    Call, TailCall, MethodCall,
    HeapCreate, DupeSlice, AllocSlice, FreeSlice, DestroyPtr,
    DeepCopy, ContainerInit, CapWrap, SharePromote, RcRetain, RcRelease,
    RcDowngrade, WeakUpgrade, MakeList, ArrayDefaultInit, ConcatStr, OwnedSlice,
    NextPromiseList,
    IndexInsert, BatchWindowPush, BatchWindowFlush,
    SnapshotTransaction, SnapshotMultiTxn,
    ShardedMapPut, ShardedMapGet,
  ].freeze, T::Array[T::Class[T.anything]])

  OWNERSHIP_SIGNIFICANT_NODE_NAMES = T.let(
    (OWNERSHIP_SIGNIFICANT_NODE_TYPES.map { |klass| T.must(klass.name) } + LEGACY_OWNERSHIP_NODE_NAMES).uniq.freeze,
    T::Array[String],
  )
end
