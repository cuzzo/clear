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
# 4. No Type objects: nodes carry Zig type strings, never Type instances
# 5. Recursive expressions: expression nodes contain sub-expression nodes
#
# Old MIR nodes (Drop, Promote, SuppressCleanup, Return,
# ReassignCleanup, FieldCleanup) in ast.rb remain for the existing pipeline.
# New nodes here use distinct names to coexist during migration.

require "sorbet-runtime"
require_relative "../annotator/helpers/intrinsic_registry"
require_relative "pass_state"

module MIR
  extend T::Sig

  class OwnershipContract
    extend T::Sig

    sig { returns(T::Array[String]) }
    attr_reader :consumes
    sig { returns(T::Array[String]) }
    attr_reader :produces
    sig { returns(T::Array[String]) }
    attr_reader :borrows
    sig { returns(T::Boolean) }
    attr_reader :covers_consuming_params

    sig do
      params(
        consumes: T::Array[String],
        produces: T::Array[String],
        borrows: T::Array[String],
        covers_consuming_params: T::Boolean,
      ).void
    end
    def initialize(consumes: [], produces: [], borrows: [], covers_consuming_params: false)
      @consumes = T.let(normalize_names(consumes).freeze, T::Array[String])
      @produces = T.let(normalize_names(produces).freeze, T::Array[String])
      @borrows = T.let(normalize_names(borrows).freeze, T::Array[String])
      @covers_consuming_params = T.let(covers_consuming_params, T::Boolean)
    end

    sig { returns(OwnershipContract) }
    def self.empty
      new
    end

    sig { params(consumes: T::Array[String]).returns(OwnershipContract) }
    def self.consumes(consumes)
      new(consumes: consumes, covers_consuming_params: true)
    end

    sig { returns(T::Boolean) }
    def empty?
      @consumes.empty? && @produces.empty? && @borrows.empty? && !@covers_consuming_params
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
      params = T.let([], T::Array[AST::Param])
      checked_arg_count.times do |idx|
        params << AST::Param.new(name: "__arg#{idx}", type: Type.new(:Any))
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

    sig { returns(OwnershipEffect) }
    def self.none
      new(
        produces_owned: false,
        alloc: nil,
        cleanup_kind: nil,
        requires_hoist: false,
        target_var: nil,
      )
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

  class OwnershipConsumptionFact < T::Struct
    extend T::Sig

    const :names, T::Array[String]
    const :target, Symbol
    const :target_alloc, T.nilable(Symbol)
    const :source, String
  end

  class BodySlot
    extend T::Sig

    sig { returns(Symbol) }
    attr_reader :name
    sig { returns(T::Array[T.untyped]) }
    attr_reader :body

    sig { params(name: Symbol, body: T::Array[T.untyped], writer: T.proc.params(body: T::Array[T.untyped]).void).void }
    def initialize(name, body, writer)
      @name = name
      @body = body
      @writer = T.let(writer, T.proc.params(body: T::Array[T.untyped]).void)
    end

    sig { params(body: T::Array[T.untyped]).void }
    def replace(body)
      @body = body
      @writer.call(body)
    end
  end

  # Common interface for all MIR nodes.
  module Emittable
      extend T::Sig

    include Kernel
    sig { returns(TrueClass) }
    def mir?; true; end
    sig { returns(T::Boolean) }
    def stmt?; false; end
    sig { returns(T::Boolean) }
    def expr?; false; end
    sig { returns(OwnershipEffect) }
    def ownership_effect; OwnershipEffect.none; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs; []; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots; []; end
    sig { returns(T.nilable(OwnershipConsumptionFact)) }
    attr_accessor :ownership_consumption

    private

    sig { params(values: T::Array[T.untyped]).returns(T::Array[Emittable]) }
    def compact_child_exprs(values)
      children = T.let([], T::Array[Emittable])
      values.flatten.compact.each do |value|
        children << value if value.is_a?(Emittable)
      end
      children
    end

    sig { params(name: Symbol, body: T.nilable(T::Array[T.untyped]), writer: T.proc.params(body: T::Array[T.untyped]).void).returns(BodySlot) }
    def body_slot(name, body, writer)
      BodySlot.new(name, body || [], writer)
    end
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
  NodeRoot = T.type_alias { T.any(Node, T::Array[T.untyped]) }

  sig { params(root: T.nilable(NodeRoot), blk: T.proc.params(arg0: Node).void).void }
  def self.each_node(root, &blk)
    each_node_inner(root, stop_at_block_expr: false, &blk)
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

  sig { params(root: T.nilable(NodeRoot), stop_at_block_expr: T::Boolean, blk: T.proc.params(arg0: Node).void).void }
  def self.each_node_inner(root, stop_at_block_expr:, &blk)
    return unless root

    if root.is_a?(Array)
      root.each { |node| each_node_inner(node, stop_at_block_expr: stop_at_block_expr, &blk) }
      return
    end

    yield root
    return if stop_at_block_expr && root.is_a?(BlockExpr)

    root.child_exprs.each { |child| each_node_inner(child, stop_at_block_expr: stop_at_block_expr, &blk) }
    root.body_slots.each { |slot| each_node_inner(slot.body, stop_at_block_expr: stop_at_block_expr, &blk) }
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

    sig { returns(T::Hash[T.any(Symbol, String), Symbol]) }
    attr_reader :placeholders

    sig { params(placeholders: T::Hash[T.any(Symbol, String), Symbol]).void }
    def initialize(placeholders = {})
      @placeholders = T.let(placeholders.dup.freeze, T::Hash[T.any(Symbol, String), Symbol])
    end

    sig { params(value: T.untyped).returns(T.nilable(InlineAllocMetadata)) }
    def self.from(value)
      return nil unless value
      return value if value.is_a?(InlineAllocMetadata)
      unless value.is_a?(Hash)
        raise TypeError, "InlineZig allocs must be MIR::InlineAllocMetadata or Hash"
      end

      normalized = T.let({}, T::Hash[T.any(Symbol, String), Symbol])
      value.each do |key, alloc|
        next unless alloc.is_a?(Symbol)
        normalized[T.cast(key, T.any(Symbol, String))] = alloc
      end
      new(normalized)
    end

    sig { returns(T::Boolean) }
    def empty?
      @placeholders.empty?
    end

    sig { params(blk: T.proc.params(key: T.any(Symbol, String), alloc: Symbol).void).void }
    def each(&blk)
      @placeholders.each { |key, alloc| blk.call(key, alloc) }
      nil
    end

    sig { returns(T::Array[Symbol]) }
    def values
      @placeholders.values
    end

    sig { params(key: T.any(Symbol, String)).returns(T::Boolean) }
    def key?(key)
      @placeholders.key?(key)
    end

    sig { params(key: T.any(Symbol, String)).returns(T.nilable(Symbol)) }
    def [](key)
      @placeholders[key]
    end

    sig { returns(T.nilable(Symbol)) }
    def primary
      self[:alloc]
    end

    sig { returns(T.nilable(Symbol)) }
    def key_alloc
      self[:key_alloc]
    end

    sig { returns(T.nilable(Symbol)) }
    def value_alloc
      self[:val_alloc]
    end

    sig { returns(T.nilable(Symbol)) }
    def shard_alloc
      self[:shard_alloc]
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
      updated = T.let({}, T::Hash[T.any(Symbol, String), Symbol])
      @placeholders.each_key { |key| updated[key] = alloc }
      InlineAllocMetadata.new(updated)
    end

    sig { returns(T::Hash[T.any(Symbol, String), Symbol]) }
    def to_h
      @placeholders.dup
    end

    sig { returns(String) }
    def inspect
      @placeholders.inspect
    end
  end

  sig do
    params(
      alloc: T.nilable(Symbol),
      key_alloc: T.nilable(Symbol),
      val_alloc: T.nilable(Symbol),
      shard_alloc: T.nilable(Symbol),
    ).returns(InlineAllocMetadata)
  end
  def self.inline_alloc_metadata(alloc: nil, key_alloc: nil, val_alloc: nil, shard_alloc: nil)
    placeholders = T.let({}, T::Hash[T.any(Symbol, String), Symbol])
    placeholders[:alloc] = alloc if alloc
    placeholders[:key_alloc] = key_alloc if key_alloc
    placeholders[:val_alloc] = val_alloc if val_alloc
    placeholders[:shard_alloc] = shard_alloc if shard_alloc
    InlineAllocMetadata.new(placeholders)
  end

  # ================================================================
  # Top-Level Definitions
  # ================================================================

  # Program: root container. items is a flat array of top-level nodes.
  # Zig: sequence of const/fn/test declarations separated by blank lines.
  class Program
    extend T::Sig
    include Emittable

    sig { returns(T::Array[Object]) }
    attr_reader :items

    sig { params(items: T::Array[Object], pass_state: T.nilable(MIRPassState)).void }
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
    include Stmt
  end

  # Tagged union type definition.
  # Zig: const Name = union(enum) { A: type, B: void };
  UnionTypeDef = Struct.new(:name, :variants, :visibility) do
    include Stmt
    # variants: [{ name: String, zig_type: String }]
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
    include Stmt
  end

  # Test block.
  # Zig: test "name" { body }
  TestDef = Struct.new(:name, :body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
  end

  # ================================================================
  # Statements
  # ================================================================

  # Variable declaration.
  # Zig: const/var name[: type] = init;
  #
  # mutable: false -> const, true -> var
  # annotation: optional explicit type string (nil -> Zig infers)
  # suppression: optional "_ = &name;" or "_ = name;" for Zig warnings
  Let = Struct.new(:name, :init, :mutable, :annotation, :suppression, :alias_safe) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([init])
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
  end

  # Scoped block.
  # Zig: { stmts }
  ScopeBlock = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
  end

  # Switch statement (for int/enum MATCH).
  # Zig: switch (subject) { arms }
  SwitchStmt = Struct.new(:subject, :arms, :default_body) do
    extend T::Sig
    include Stmt
    # arms: [{ pattern: String, body: [MIR stmt] }]
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([subject])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm[:body], ->(new_body) { arm[:body] = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
      slots
    end
  end

  # Union match statement.
  # Zig: switch (subject) { .Variant => |payload| { body }, else => { ... } }
  # Payload capture is structurally tied to the active switch arm; lowering
  # must not synthesize subject.Variant reads for MATCH AS bindings.
  UnionMatchStmt = Struct.new(:subject, :arms, :default_body) do
    extend T::Sig
    include Stmt
    # arms: [{ pattern: String, payload: String|nil, body: [MIR stmt] }]
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([subject])
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm[:body], ->(new_body) { arm[:body] = new_body })
      end
      slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
      slots
    end
  end

  # If-chain statement (for union/string MATCH).
  # Zig: if (cond1) { ... } else if (cond2) { ... } else { ... }
  IfChain = Struct.new(:branches, :default_body) do
    extend T::Sig
    include Stmt
    # branches: [{ cond: MIR expr, body: [MIR stmt] }]
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      compact_child_exprs(branches&.map { |branch| branch[:cond] } || [])
    end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      branches&.each_with_index do |branch, index|
        slots << body_slot(:"branches_#{index}", branch[:body], ->(new_body) { branch[:body] = new_body })
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

  # In-place sort.
  # Borrows `items_expr`; mutates the underlying slice. The comparator is
  # encoded as two key extraction expressions (key_a, key_b) — both are MIR
  # expression trees referring to placeholder identifiers `a` and `b`. The
  # emitter wraps them in the appropriate Zig closure / VM comparator.
  # No allocation; ownership of items unchanged.
  # Zig: std.mem.sort(T, items, {}, struct { fn lessThan(_, a, b) {...} });
  Sort = Struct.new(:elem_type, :items_expr, :key_a, :key_b) do
    include Stmt
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
    # body: single MIR stmt, or a RawZig for inline defer
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      body.is_a?(Array) ? [body_slot(:body, body, ->(new_body) { self.body = new_body })] : []
    end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])
  end

  # Errdefer statement.
  # Zig: errdefer |_| { body };
  ErrDeferStmt = Struct.new(:body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      body.is_a?(Array) ? [body_slot(:body, body, ->(new_body) { self.body = new_body })] : []
    end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])
  end

  # Expression used as statement.
  # Zig: expr;  or  _ = expr;
  ExprStmt = Struct.new(:expr, :discard) do
    extend T::Sig
    include Stmt
    # discard: true -> emit `_ = expr;`
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Owning expression used as a statement.
  # Zig: evaluate into a scoped temp and clean it at the end of that scope.
  DiscardOwned = Struct.new(:expr, :cleanup_entry, :zig_type) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Raw Zig code. Escape hatch for patterns not yet modeled in MIR.
  # Every use is tracked by `reason` for auditing. Goal: zero RawZig nodes.
  #
  # WARNING: RawZig BYPASSES ownership verification. The MIR checker cannot
  # see inside raw Zig code. Any allocation, deallocation, or ownership
  # transfer inside a RawZig block is INVISIBLE to the checker.
  #
  # SAFETY RULES:
  #   - NEVER allocate heap memory inside RawZig without a matching
  #     MIR::AllocMark + MIR::Cleanup outside it (leak).
  #   - NEVER free/deinit a binding inside RawZig that has a Cleanup
  #     outside it (double-free).
  #   - NEVER move ownership of a binding into RawZig without a
  #     MIR::MoveMark + guarded Cleanup outside it (double-free or leak).
  #   - NEVER return a frame-allocated value from RawZig without
  #     MIR::EscapePromote outside it (use-after-free).
  #   - ALWAYS declare ownership_contract so the checker can cross-reference.
  #
  # ownership_contract: MIR::OwnershipContract
  #   consumes: bindings whose ownership transfers into the raw block (must have SuppressCleanup)
  #   produces: bindings the raw block creates (must have MIR::AllocMark + MIR::Drop)
  #   borrows:  bindings read but not moved/freed (must not be moved during raw block)
  RawZig = Struct.new(:code, :reason, :ownership_contract, :stdlib_def) do
    extend T::Sig
    include Stmt

    sig { params(code: String, reason: T.nilable(String), ownership_contract: OwnershipContract, stdlib_def: T.untyped).void }
    def initialize(code, reason, ownership_contract = OwnershipContract.empty, stdlib_def = nil)
      super(code, reason, ownership_contract, stdlib_def)
    end

    sig { params(contract: OwnershipContract).returns(OwnershipContract) }
    def ownership_contract=(contract)
      self[:ownership_contract] = contract
    end

    sig { params(key: T.any(Symbol, Integer), value: T.untyped).returns(T.untyped) }
    def []=(key, value)
      validate_ownership_contract!(value) if key == :ownership_contract || key == 2
      super
    end

    sig { returns(T::Boolean) }
    def expr?; true; end  # can appear in expression position too

    private

    sig { params(value: T.untyped).void }
    def validate_ownership_contract!(value)
      return if value.is_a?(OwnershipContract)

      raise TypeError, "ownership_contract must be MIR::OwnershipContract"
    end
  end

  # Non-mutual THUNK trampoline body. This is still emitted as a local
  # synchronous frame machine, but the MIR now exposes the frame layout,
  # base cases, recursive step, combine op, and yield policy instead of
  # hiding the entire function body in RawZig.
  ThunkTrampoline = Struct.new(
    :fn_name,
    :ret_zig,
    :param_field_decls,
    :param_init_fields,
    :base_cases,
    :recurse_arg_inits,
    :combine_lhs_zig,
    :op_zig,
    :yield_line
  ) do
    include Stmt
  end

  # Mutual THUNK trampoline body. This is the tagged-union sibling of
  # ThunkTrampoline: each mutually-recursive function is a union variant,
  # and each arm either returns a base-case value or overwrites current
  # with the next variant's payload.
  MutualThunkTrampoline = Struct.new(
    :fn_name,
    :ret_zig,
    :variants,
    :initial_variant,
    :initial_fields,
    :arms,
    :yield_line
  ) do
    include Stmt
  end

  # Background block. Wraps raw Zig code for a fiber spawn but exposes
  # capture_analysis for ownership verification (BG_ESCAPE check).
  # captures: { name => Type-like object } from capture_analysis.captures
  # run_body: [MIR::Stmt] — lowered MIR for the fiber run function body.
  #   Carries the MIR so the checker can see allocations inside the fiber.
  #   Emission still uses code (raw Zig). nil for legacy callers; checker skips.
  # fsm_structure: MIR::FsmStructure | nil. For BG bodies lowered to a
  #   stackless FSM, carries the structural metadata (captures, state
  #   fields, per-step bodies, cleanup placements) so the MIR checker
  #   can verify cross-step liveness invariants. nil for non-FSM BGs
  #   and for FSM Phase B1 (pure-compute, no suspend) where there's
  #   only one logical step.
  BgBlock = Struct.new(:code, :captures, :run_body, :fsm_structure) do
    extend T::Sig
    include Stmt
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
  #   state_fields: [
  #     { name: String, finalize_at: :finalize | Integer | nil,
  #       error_handled_in_setup: Boolean }
  #   ]
  #     Per-call state struct fields (e.g. rf_buf, rf_fd). Cleanup
  #     placement is template-driven via :fsm_state_finalize. The
  #     `error_handled_in_setup` flag indicates step-0 errdefer
  #     coverage so the checker can require it on heap-alloc'd
  #     state fields.
  #
  #   steps: [
  #     { index: Integer, reads: [String], cleanups: [String] }
  #   ]
  #     One entry per step. `reads` is the set of binding names
  #     (captures + state_fields + ctx fields) referenced in this
  #     step's emitted body, derived by scanning the rendered Zig
  #     for `__ctx_<id>.<name>` patterns. `cleanups` is the set of
  #     names whose `defer free(...)` line was placed at the start
  #     of this step.
  #
  #   finalize_cleanups: [String]
  #     Names whose cleanup is placed at FSM finalize (start of the
  #     last step, fires after post-stmts).
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
  FsmStructure = Struct.new(
    :captures, :state_fields, :steps, :finalize_cleanups, :ctx_id,
    :result_aliases_finalized
  ) do
    include Emittable
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
  # `src/mir/fsm_wrapper_emitter.rb` walks the tree and produces
  # the same Zig text — but now every structural piece is named,
  # typed, and inspectable. `FsmIoBody` lives inside an
  # `MIR::BgBlock.code` field for emitter compatibility, but the
  # tree itself is the source of truth and any future MIR pass
  # (checker, transformer, dumper) walks the structure rather than
  # the rendered string.
  #
  # Body content that comes from the surrounding fiber-body lowering
  # (pre_stmts, post_stmts, post_result_line, etc.) is still Zig
  # text at this layer — that's a Phase 4 transpiler concern. The
  # wrapper structure is fully MIR; the per-step body fragments are
  # an array of pre-rendered lines the renderer joins with
  # newlines + indentation. Once the fiber-body lowering itself
  # emits MIR, those fragments become MIR nodes too.

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
    :captures_decl_zig,
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
  # The dispatch (`resume_fn_zig`) is the protocol contract for
  # each form: a labeled-while-switch for NEXT-CHAIN, a __cs_block
  # with retry loop for WITH, the `step` switch for LOOP. Those
  # are fixed Zig per form and do not vary based on user code, so
  # carrying them as raw Zig strings on the wrapper node is
  # acceptable -- the variability is in the per-step bodies,
  # which are MIR.
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
  #   - a list of extra field decl lines (step counter, sp
  #     promise fields, retry counter, lock_waiter, etc.);
  #   - promoted-local field decls;
  #   - a list of MIR::FsmStep entries with their fn name and
  #     signature (not just `runStepN`);
  #   - the resume_fn_zig contributed by the form's emitter.
  FsmGenericCtxStruct = Struct.new(
    :type_name,
    :promise_zig,
    :captures_decl_zig,
    :extra_field_decls,    # [String]
    :promoted_field_decls, # [String]
    :member_fns,           # [MIR::FsmMemberFn]
    :resume_fn_zig,        # String -- protocol-specific dispatch
    :destroy_extra_zig,    # optional String -- extra Zig run inside
                           # destroyTask BEFORE alloc.destroy(ctx).
                           # Used for WITH+suspend-in-CS to release
                           # locks held across runFn boundaries on
                           # err paths (Zig defer can't span runFn
                           # boundaries; the per-cap __lock_held_<i>
                           # flag tells destroyTask which to release).
  )

  # A named member fn on the FSM ctx struct. fn_name is used as
  # the Zig fn name (`runPre`, `runLoopPre`, `runStep0`, ...).
  # signature is the Zig signature minus the fn name (e.g.
  # `(__ctx_0: *@This()) anyerror!void`). body_stmts are typed
  # MIR statements (or transitional Strings) rendered via
  # MIREmitter.
  FsmMemberFn = Struct.new(
    :fn_name,
    :ctx_id,
    :bg_rt,                # "__rt_bg0"
    :rt_suppress_zig,
    :body_stmts,           # [MIR::Stmt | String]
    :extra_prologue_zig,   # optional pre-body Zig (e.g. defer
                           # unlock for runCsBody) -- appears
                           # before body_stmts in the rendered fn
  )

  # The `const __BgCtxN = struct { ... };` declaration that holds
  # task / rt / inner / alloc / captures / step / state_decls /
  # promoted fields, plus the runStep0 / runStep1 / resumeFn member
  # functions.
  FsmCtxStruct = Struct.new(
    :type_name,            # "__BgCtx0"
    :promise_zig,          # "CheatLib.Promise(i64)"
    :captures_decl_zig,    # raw Zig field decls from fiber lowering
    :state_decls,          # [FsmOps::StateFieldDecl]
    :promoted_field_decls, # [String] — raw lines
    :step0,                # MIR::FsmStep
    :step1,                # MIR::FsmStep
    :resume_fn,            # MIR::FsmDispatch
  )

  # One `fn runStepN(__ctx_<id>: *@This()) anyerror!void` body.
  #
  # `body_stmts` is a list of MIR statement nodes (or plain Strings
  # as a transitional escape hatch). The wrapper renderer uses the
  # standard MIREmitter to walk each one, so all MIR statement
  # types -- MIR::Let, MIR::Set, MIR::DeferStmt, MIR::RawZig,
  # MIR::ExprStmt, etc. -- are valid here. Plain strings are
  # accepted because MIREmitter.emit handles them as a base case;
  # they exist so the lowering can pass through Zig text from the
  # surrounding fiber-body lowering without a forced wrap.
  #
  # The renderer concatenates each emitted statement with newlines
  # and the function body indentation. It does NOT insert ';'s or
  # pick statement order; those are decisions of the lowering and
  # are encoded in the MIR node type.
  FsmStep = Struct.new(
    :index,                # 0 or 1
    :ctx_id,               # int matching __ctx_<id>
    :bg_rt,                # "__rt_bg0"
    :rt_suppress_zig,      # "_ = &__rt_bg0;" or ""
    :body_stmts,           # [MIR::Stmt | String]
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
  #   ctx_field_decls: [String]
  #     Extra Zig field decl lines this suspend needs in the ctx
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
  # FSM dispatch (structured replacement for `resume_fn_zig: String`)
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
  # The renderer is in src/mir/fsm_wrapper_emitter.rb#render_dispatch.
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
  #   2. Run pre_body_zig (free-form Zig injected before the body fn).
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
    :pre_body_zig,            # String | nil
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
  #   if (<cond_zig>) { step = <skip_step>; continue :__sw; }
  FsmTailCondSkip = Struct.new(:cond_zig, :skip_step)

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
  #   if (<register_zig>) { step = next_step; return .{ .<reason> = {} }; }
  #   step = next_step;
  #   continue :__sw;
  #
  # Used by NEXT (registerFsmWaiter on Promise.wg). LOCK uses a
  # different shape (try-loop with retry); kept as template for now.
  FsmTailRegisterYield = Struct.new(
    :next_step,
    :register_zig,
    :yield_reason,
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def kind; :register_yield; end
  end

  # Conditional jump (cond ? then_step : else_step).
  #   if (<cond_zig>) { step = then_step; continue; }
  #   step = else_step; continue;
  FsmTailCondJump = Struct.new(:cond_zig, :then_step, :else_step) do
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
    :alloc_expr_zig,       # "rt.heapAlloc()" or "rt.getSched().allocator"
    :promise_var,          # "__bg0_promise"
    :promise_zig,          # "CheatLib.Promise(i64)"
    :promoted_decls_zig,   # raw
    :ctx_var,              # "__bg0_ctx"
    :ctx_type,             # "__BgCtx0"
    :ctx_init_zig,         # raw Zig for the .{ ... } body of the
                           # ctx struct initializer (fixed prefix
                           # for task / rt / inner / alloc plus
                           # capture inits the lowering decided)
    :spawn_call_zig,       # "try ...spawn(&ctx.task);"
    :rt_name,              # "rt" (the surrounding fn's runtime)
    :profile_site_id,      # integer id used by runtime fiber profile
    :profile_dispatch_id,  # fiber-profile.DispatchKind enum value
    :profile_site_comment, # CLEAR_PROFILE_TASK_SITE metadata comment
  )

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

  # Catch wrapper. Wraps raw Zig code for try/catch but exposes
  # typed error-path reassignment metadata for allocator consistency (INV-9).
  # clause_bodies: Array<Array<MIR::Stmt>> — one per catch clause + default.
  #   Carries the lowered MIR so the checker can see allocations inside each
  #   catch body. Emission still uses code (raw Zig). nil for legacy callers.
  CatchWrapper = Struct.new(:code, :error_reassigns, :clause_bodies, :clause_meta, :has_default) do
    extend T::Sig
    include Stmt
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      clause_bodies&.each_with_index do |body, index|
        slots << body_slot(:"clause_bodies_#{index}", body, ->(new_body) { clause_bodies[index] = new_body })
      end
      slots
    end
  end

  # DO block. Wraps raw Zig code for fork-join parallel branches.
  # branch_bodies: Array<Array<MIR::Stmt>> — one per branch, lowered MIR.
  #   Carries the MIR so the checker can see allocations inside DO branches.
  #   Emission still uses code (raw Zig).
  DoBlock = Struct.new(:code, :branch_bodies) do
    extend T::Sig
    include Stmt
    sig { returns(T.nilable(T::Array[MIR::ExecutionBoundaryFact])) }
    def boundary_facts
      @boundary_facts = T.let(nil, T.nilable(T::Array[MIR::ExecutionBoundaryFact])) unless defined?(@boundary_facts)
      @boundary_facts
    end
    sig { params(value: T.nilable(T::Array[MIR::ExecutionBoundaryFact])).returns(T.nilable(T::Array[MIR::ExecutionBoundaryFact])) }
    def boundary_facts=(value); @boundary_facts = T.let(value, T.nilable(T::Array[MIR::ExecutionBoundaryFact])); end
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
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  HeapCreate = Struct.new(:zig_type, :init, :alloc, :label) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([init])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
    end
  end

  # Byte slice duplication.
  # Zig: try alloc.dupe(u8, source)
  # Used for: string copies, HPT return dupes, BG captures.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  DupeSlice = Struct.new(:source, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :heap_string)
    end
  end

  # Typed slice allocation (uninitialized).
  # Zig: try alloc.alloc(elem_type, len)
  # Used for: COPY list deep-copy buffer.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  AllocSlice = Struct.new(:elem_type, :len, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([len])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
    end
  end

  # Free a slice.
  # Zig: alloc.free(slice)
  # Used for: errdefer cleanup of AllocSlice.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  FreeSlice = Struct.new(:slice, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([slice])
  end

  # Destroy a heap pointer.
  # Zig: alloc.destroy(ptr)
  # Used for: errdefer cleanup of HeapCreate, intermediate cap wrap cleanup.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  DestroyPtr = Struct.new(:ptr, :alloc) do
    extend T::Sig
    include Expr
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
  #   :has_moved_guard, :resource_close_zig, :is_fixed,
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
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  DeepCopy = Struct.new(:source, :zig_type, :elem_type, :strategy,
                        :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none if strategy == :passthrough
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
    end
  end

  # --- Collection Initialization ---

  # Collection init with explicit allocator.
  # Strategy determines the Zig pattern:
  #   :pool           -> try T.initCapacity(alloc, cap)
  #   :list_capacity  -> try T.initCapacity(alloc, cap)
  #   :list_empty     -> T{}
  #   :set_empty      -> T{}
  #   :map_bare       -> T{ .alloc = alloc }
  #   :map_empty      -> T{}
  # alloc: symbol (:heap, :frame, nil) -- resolved to Zig by emitter.
  ContainerInit = Struct.new(:zig_type, :strategy, :alloc,
                             :capacity) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([capacity])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
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
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([inner])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      kind = own_fn ? :rc : :uniform
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: kind)
    end
  end

  # Promote a consumed Rc(T) handle into a fresh Arc(T).
  # Zig: copy rc.ctrl.data.* into a new Arc, then release the consumed Rc.
  SharePromote = Struct.new(:source, :zig_base, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([source])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :rc)
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
      OwnershipEffect.none
    end
  end

  # Rc/Arc downgrade to weak ref.
  # Zig: CheatLib.arcDowngrade(T, source) or CheatLib.rcDowngrade(T, source)
  RcDowngrade = Struct.new(:source, :zig_base, :func) do
    extend T::Sig
    include Expr
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.none
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

  # Compact an @multiowned tree into a single contiguous buffer.
  # Zig: try CheatLib.freeze(T, alloc, inner_ptr)
  # inner: MIR expr for the Rc data pointer (*const T)
  # zig_base: Zig type name for T
  FreezeExpr = Struct.new(:inner, :zig_base) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([inner])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: :heap, cleanup_kind: :frozen)
    end
  end

  # Make a list from items.
  # Zig: try CheatLib.makeList(elem_type, alloc, &.{ items })
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  MakeList = Struct.new(:elem_type, :items, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([items])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
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
  # MVCC Snapshot Nodes (structured -- no InlineZig escape hatch)
  # ================================================================
  #
  # These replace what used to be hand-emitted InlineZig blobs in
  # mir_lowering.rb's :SNAPSHOT branch + emit_snapshot_mutable_call +
  # lower_with_match_block. The emitter (mir_emitter.rb) maps each
  # structured node 1:1 to the same Zig text we used to generate, BUT
  # the construct is now visible to MIRChecker. Specifically:
  #
  # - SnapshotTransaction's heap allocation (Versioned.update's new
  #   version) is now under structured MIR -- the checker can pair the
  #   AllocMark with the EBR-retire Cleanup that runs inside
  #   Versioned.update. Pre-migration this allocation lived inside an
  #   InlineZig string and was invisible to the checker (INV-12 violation).
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
  # cell_unwrap : Zig expression resolving to *Versioned(T)
  # rt          : Zig expression for *Runtime
  # alias_zig   : Zig identifier for the user's alias (e.g. "view")
  # guard_var   : internal Zig name for the Guard local
  SnapshotRead = Struct.new(:cell_unwrap, :rt, :alias_zig, :guard_var, :body) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
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
  # cell_unwrap     : Zig expr resolving to *Versioned(T) or *AtomicPtr(T)
  # rt              : Zig expr for *Runtime
  # alloc           : Zig expr for the allocator (rt.heapAlloc())
  # alias_zig       : Zig identifier for the user's MUTABLE alias
  # bare_t_zig      : Zig type string for the inner T
  # body            : Array of MIR statements -- the user's transaction body
  # conflict_action : Zig text for the ON MvccConflict handler body (nil for atomic-ptr)
  # retries         : nil or integer N for RETRY(N) THEN <action> (nil for atomic-ptr)
  # with_label      : nil or string for the labeled block exit (PASS/block actions)
  # is_atomic_ptr   : true when the cell's sync is :atomic + layout :indirect.
  #                   Routes the emitter to the no-conflict-handler shape.
  SnapshotTransaction = Struct.new(
    :cell_unwrap, :rt, :alloc, :alias_zig, :bare_t_zig,
    :body, :conflict_action, :retries, :with_label, :is_atomic_ptr
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
  end

  # SNAPSHOT-mutable multi-cell: `WITH SNAPSHOT a AS MUTABLE va, b AS
  # MUTABLE vb, ... { body } ON MvccConflict <action>`. Lowers to
  # `CheatLib.versionedUpdateMulti(.{cells...}, rt, alloc, fn(views) ...)`
  # which sorts the cells by address (deadlock-free), tags the soft
  # locks, runs the body once, and publishes all new versions
  # atomically.
  #
  # cells_tuple  : Zig text for `.{ unwrap1, unwrap2, ... }`
  # rt, alloc    : as above
  # alias_decls  : Zig text declaring per-arg aliases from `views[i]`
  # body         : Array of MIR statements
  # conflict_action, retries, with_label : as above
  SnapshotMultiTxn = Struct.new(
    :cells_tuple, :rt, :alloc, :alias_decls,
    :body, :conflict_action, :retries, :with_label
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
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
  # cell_zig    : Zig expression for the bound binding (no Arc-unwrap;
  #               the helper does that comptime-internally).
  # rt          : runtime variable name in scope.
  # alias_zig   : the user's alias inside the body (e.g. "x").
  # bare_t_zig  : the Zig type of the success branch (e.g. "Counter").
  # body        : Array of MIR statements forming the WITH body.
  PolymorphicMutate = Struct.new(
    :cell_zig, :rt, :alias_zig, :bare_t_zig, :body
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots = [body_slot(:body, body, ->(new_body) { self.body = new_body })]
  end

  PolymorphicMutateFlow = Struct.new(
    :cell_zig, :rt, :alias_zig, :bare_t_zig, :ret_zig, :body, :guard_cond, :guard_fail_body
  ) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([body_slot(:body, body, ->(new_body) { self.body = new_body })], T::Array[BodySlot])
      slots << body_slot(:guard_fail_body, guard_fail_body, ->(new_body) { self.guard_fail_body = new_body }) if guard_fail_body
      slots
    end
  end

  # WITH MATCH dispatch: `WITH cell AS va MATCH WHEN F1 -> {...} WHEN
  # F2 -> {...} END`. Lowers to a comptime `if (@hasField/@hasDecl)`
  # chain, one branch per family, each branch containing the matching
  # arm's lowered body.
  #
  # cell_zig : Zig expression for the bound variable (param shape preserved)
  # arms     : Array of { family:, probe:, prelude_zig:, body: [MIR stmts] }
  WithMatchDispatch = Struct.new(:cell_zig, :arms) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def stmt?; true; end
    sig { returns(T::Array[BodySlot]) }
    def body_slots
      slots = T.let([], T::Array[BodySlot])
      arms&.each_with_index do |arm, index|
        slots << body_slot(:"arms_#{index}", arm[:body], ->(new_body) { arm[:body] = new_body })
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
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  OwnedDestroy = Struct.new(:name, :alloc, :source) do
    extend T::Sig
    include Stmt
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
    sig { returns(T::Boolean) }
    def stmt?; true; end
  end

  # Marks field overwrite needing pre-cleanup. Subsumes old MIR::FieldCleanup.
  FieldCleanupMark = Struct.new(:target_name, :field, :alloc) do
    extend T::Sig
    include Stmt
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

    sig { params(callee: String, args: T::Array[T.untyped], try_wrap: T::Boolean, owned_return: T::Boolean, callable_contract: T.nilable(CallableContract)).void }
    def initialize(callee, args, try_wrap, owned_return = false, callable_contract = nil)
      super(callee, args, try_wrap, owned_return, callable_contract)
    end

    sig { returns(T::Boolean) }
    def owned_return? = owned_return == true

    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([args])

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless owned_return?
      alloc_arg = args.find { |arg| arg.is_a?(AllocatorRef) }
      OwnershipEffect.owned(alloc: alloc_arg&.kind || :heap)
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

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless owned_result_alloc.is_a?(Symbol)
      OwnershipEffect.owned(alloc: owned_result_alloc)
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

  # Variable / name reference.
  # Zig: name
  Ident = Struct.new(:name) do
    include Expr
  end

  # Function pointer reference.
  # Zig: &name
  FnRef = Struct.new(:name) do
    include Expr
  end

  # Struct initialization.
  # Zig: TypeName{ .a = x, .b = y }  or  .{ .a = x }
  StructInit = Struct.new(:zig_type, :fields) do
    extend T::Sig
    include Expr
    # zig_type: String or nil (nil -> anonymous .{})
    # fields: [{ name: String, value: MIR expr }]
    sig { returns(T::Array[Emittable]) }
    def child_exprs
      values = T.let([], T::Array[T.untyped])
      fields&.each do |field|
        values << field[:value] if field.respond_to?(:[])
      end
      compact_child_exprs(values)
    end
    sig { returns(OwnershipEffect) }
    def ownership_effect
      effects = child_exprs.map { |child| child.respond_to?(:ownership_effect) ? child.ownership_effect : OwnershipEffect.none }
      owned = effects.select(&:produces_owned)
      return OwnershipEffect.none if owned.empty?

      allocs = owned.map(&:alloc).compact.uniq
      OwnershipEffect.owned(alloc: allocs.one? ? allocs.first : nil, cleanup_kind: :uniform)
    end

  end

  # Fixed-size array initialization.
  # Zig: [N]T{ item1, item2, ... }
  ArrayInit = Struct.new(:elem_type, :count, :items) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([items])
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
    sig { returns(OwnershipEffect) }
    def ownership_effect
      break_stmt = body&.reverse&.find { |stmt| stmt.is_a?(BreakStmt) }
      return OwnershipEffect.none unless break_stmt.is_a?(BreakStmt)
      if break_stmt.value.is_a?(Ident)
        name = break_stmt.value.name.to_s
        mark = body&.find { |stmt| stmt.is_a?(AllocMark) && stmt.name.to_s == name }
        transfer = body&.find { |stmt| stmt.is_a?(TransferMark) && stmt.name.to_s == name }
        if mark && transfer
          let = body&.find { |stmt| stmt.is_a?(Let) && stmt.name.to_s == name }
          init_effect = let&.init&.respond_to?(:ownership_effect) ? let.init.ownership_effect : OwnershipEffect.none
          cleanup_kind = init_effect.produces_owned ? (init_effect.cleanup_kind || :uniform) : :uniform
          return OwnershipEffect.owned(alloc: mark.alloc, cleanup_kind: cleanup_kind, target_var: name)
        end
      end
      value_effect = break_stmt.value.ownership_effect
      return value_effect if value_effect.produces_owned
      transferred_allocs = T.let([], T::Array[Symbol])
      body&.each do |stmt|
        next unless stmt.is_a?(TransferMark)
        next unless stmt.target == :owned_sink || stmt.target == :block_result
        transferred_allocs << stmt.target_alloc if stmt.target_alloc.is_a?(Symbol)
      end
      unless transferred_allocs.empty?
        uniq = transferred_allocs.uniq
        return OwnershipEffect.owned(alloc: uniq.one? ? uniq.first : nil, cleanup_kind: :uniform)
      end
      return OwnershipEffect.owned(alloc: nil, cleanup_kind: :uniform) if result_type&.needs_cleanup?(nil)

      OwnershipEffect.none
    end
  end

  # String concatenation.
  # Zig: try std.mem.concat(alloc, u8, &.{ parts })
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  # rt_expr: Zig expression for runtime (e.g. "rt") -- used for rt-dependent calls.
  ConcatStr = Struct.new(:parts, :alloc, :rt_expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([parts])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :heap_string)
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
    sig { returns(OwnershipEffect) }
    def ownership_effect
      expr.ownership_effect
    end
  end

  # Try expression (wraps a failable expression).
  # Zig: try expr
  TryExpr = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      expr.ownership_effect
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
    sig { returns(OwnershipEffect) }
    def ownership_effect
      left = expr.ownership_effect
      right = catch_body.ownership_effect
      if left.produces_owned && right.produces_owned && left.alloc == right.alloc
        return left
      end

      return left if left.produces_owned && result_type&.needs_cleanup?(nil)
      return left if left.produces_owned && catch_body.is_a?(Lit)

      OwnershipEffect.none
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
    sig { returns(OwnershipEffect) }
    def ownership_effect
      left = expr.ownership_effect
      right = fallback.ownership_effect
      if left.produces_owned && right.produces_owned && left.alloc == right.alloc
        return left
      end

      return left if left.produces_owned && result_type&.needs_cleanup?(nil)

      OwnershipEffect.none
    end
  end

  # Conditional expression (Zig if-expression).
  # Zig: if (cond) then_val else else_val
  Conditional = Struct.new(:cond, :then_val, :else_val) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([cond, then_val, else_val])
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
    sig { returns(OwnershipEffect) }
    def ownership_effect
      left = then_expr.ownership_effect
      right = else_expr.ownership_effect
      return OwnershipEffect.none unless left.produces_owned && right.produces_owned
      return OwnershipEffect.none unless left.alloc == right.alloc
      left
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
  end

  # Address-of.
  # Zig: &expr
  AddressOf = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Dereference.
  # Zig: expr.*
  Deref = Struct.new(:expr) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Allocator reference. Zig-side: rt.heapAlloc() / rt.frameAlloc() /
  # rt.cleanupAlloc(). VM-side: no-op (VM is GC'd); strip_alloc_args drops
  # these at call sites. kind: :heap | :frame | :cleanup.
  AllocatorRef = Struct.new(:kind) do
    include Expr
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
  end

  # Range literal.
  # Zig: CheatLib.IntRange{ .start = s, .end = e } or CheatLib.Range{ .start = s, .end = e }
  RangeLit = Struct.new(:start, :end_val, :elem_type) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([start, end_val])
  end

  # Comptime has-field check.
  # Zig: @hasField(@TypeOf(expr), "field")
  HasField = Struct.new(:expr, :field) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Items accessor (ArrayList -> slice).
  # Zig: expr.items  or  (if (@hasField(...)) expr.items else expr)
  ItemsAccess = Struct.new(:expr, :safe) do
    extend T::Sig
    include Expr
    # safe: true -> emit @hasField guard, false -> direct .items
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
  end

  # Transfer an ArrayList-backed value into an owned slice.
  # Zig: try expr.toOwnedSlice(alloc)
  OwnedSlice = Struct.new(:expr, :alloc) do
    extend T::Sig
    include Expr
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([expr])
    sig { returns(OwnershipEffect) }
    def ownership_effect
      OwnershipEffect.owned(alloc: alloc.is_a?(Symbol) ? alloc : nil, cleanup_kind: :uniform)
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
  # Phase 1: inner carries old-path MIR (RawZig or MIR tree); all other fields nil.
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

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless inner.respond_to?(:ownership_effect)

      inner.ownership_effect
    end
  end

  # Inline Zig expression. Tracked escape hatch for expression-level Zig code.
  #
  # WARNING: InlineZig BYPASSES ownership verification unless stdlib_def is set.
  # The MIR checker cannot see inside inline Zig expressions. Any function call
  # that allocates, deallocates, or transfers ownership is INVISIBLE to the
  # checker unless the stdlib_def field declares it.
  #
  # SAFETY RULES:
  #   - NEVER call a function that allocates (append, getOrPut, dupe, concat)
  #     without setting stdlib_def = { allocates: true }.
  #   - NEVER call a function that frees memory without a corresponding
  #     MIR::Cleanup marker outside the InlineZig.
  #   - NEVER embed multi-statement code -- InlineZig is for expressions only.
  #     Use RawZig (with ownership_contract) for statement-level escape hatches.
  #   - All CheatLib.* calls MUST go through BUILTIN_OPS or STD_LIB registries,
  #     not be emitted as raw InlineZig strings.
  #   - Pure expressions (casts, ranges, field access, Zig builtins) are safe
  #     without stdlib_def.
  #
  # stdlib_def: hash from BUILTIN_OPS/STD_LIB with ownership metadata
  #   { allocates: true }  -- call allocates; checker uses for HPT_LEAK
  #   { borrows: :all }    -- call borrows all args; no ownership transfer
  #   nil = unaudited or pure expression (safe if no allocation/deallocation)
  # ownership_contract: MIR::OwnershipContract. Empty means this node has no
  # ownership effects; consuming stdlib calls must use a non-empty contract.
  #
  # allocs: resolved allocator symbols for placeholders left in code.
  #   { key_alloc: :heap, val_alloc: :frame, alloc: :heap }
  #   Emitter substitutes {key_alloc} -> "rt.heapAlloc()" etc.
  #   Checker inspects symbols directly (same as DupeSlice.alloc, etc.)
  #   nil = no allocator placeholders (pure expression).
  #
  # target_var: CLEAR variable name of the container being operated on.
  #   Used by the checker to cross-reference with AllocMark for consistency.
  #   nil = no target (intrinsic call, not a container operation).
  InlineZig = Struct.new(:code, :reason, :ownership_contract, :stdlib_def, :allocs, :target_var) do
    extend T::Sig
    include Expr

    sig { params(code: String, reason: T.nilable(String), ownership_contract: OwnershipContract, stdlib_def: T.untyped, allocs: T.untyped, target_var: T.nilable(String)).void }
    def initialize(code, reason, ownership_contract = OwnershipContract.empty, stdlib_def = nil, allocs = nil, target_var = nil)
      super(code, reason, ownership_contract, stdlib_def, InlineAllocMetadata.from(allocs), target_var)
    end

    sig { params(contract: OwnershipContract).returns(OwnershipContract) }
    def ownership_contract=(contract)
      self[:ownership_contract] = contract
    end

    sig { params(allocs: T.untyped).returns(T.nilable(InlineAllocMetadata)) }
    def allocs=(allocs)
      normalized = InlineAllocMetadata.from(allocs)
      self[:allocs] = normalized
      normalized
    end

    sig { params(key: T.any(Symbol, Integer), value: T.untyped).returns(T.untyped) }
    def []=(key, value)
      validate_ownership_contract!(value) if key == :ownership_contract || key == 2
      value = InlineAllocMetadata.from(value) if key == :allocs || key == 4
      super
    end

    sig { returns(OwnershipEffect) }
    def ownership_effect
      return OwnershipEffect.none unless stdlib_def&.emits_allocating?
      return OwnershipEffect.none if stdlib_def&.mutates_receiver?
      return OwnershipEffect.none if stdlib_def&.fixed_return? && stdlib_def.return_type.void?
      alloc = if stdlib_def&.heap_return_alloc?
        :heap
      elsif allocs.is_a?(InlineAllocMetadata)
        allocs.single_alloc
      else
        nil
      end
      return OwnershipEffect.none unless alloc || stdlib_def&.heap_return_alloc?
      OwnershipEffect.owned(alloc: alloc, target_var: target_var)
    end

    sig { returns(T::Boolean) }
    def has_alloc_metadata?
      allocs.is_a?(InlineAllocMetadata) && !allocs.empty?
    end

    sig { returns(T::Boolean) }
    def mutating_receiver_allocator_op?
      has_alloc_metadata? && stdlib_def&.mutates_receiver?
    end

    sig { returns(T::Boolean) }
    def assignable_allocating_result?
      stdlib_def&.emits_allocating? && !stdlib_def&.mutates_receiver?
    end

    private

    sig { params(value: T.untyped).void }
    def validate_ownership_contract!(value)
      return if value.is_a?(OwnershipContract)

      raise TypeError, "ownership_contract must be MIR::OwnershipContract"
    end
  end

  # Inline bytecode. Sibling to InlineZig, consumed only by bc_emitter (the
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
  end

  # Raw bytecode. Sibling to RawZig for the :bc target. Nothing in
  # mir_lowering emits this yet — Phase 0 scaffolding only (see
  # examples/minivm/MIR_MIGRATION.md). Phase 3 will start emitting it
  # by target-aware rewriting of RawZig sites that have a :bc_raw
  # registry mapping.
  #
  # template: Array of Symbol | String | Array. bc_emitter walks the
  #   template: a Symbol is an opcode name (emit_op(OPCODE)), a String
  #   is a placeholder like "{0}" that substitutes with the compiled
  #   value of args[0], an Array is [opcode_symbol, *inline_args] for
  #   opcodes that take immediate args (e.g. [:NATIVE_CALL, :list_push, 2]).
  # args:     Array<MIR::Expr> — the argument expressions (unlowered).
  # stdlib_def: the registry hash the template came from (ownership
  #   semantics so the checker can reason about it).
  #
  # Same invisibility rule as RawZig applies: the checker cannot see
  # inside the template. When Phase 3 lands, every bc_raw template should
  # come from a registry entry whose ownership effects are declared in
  # stdlib_def, making INV-5 enforceable uniformly.
  RawBc = Struct.new(:template, :args, :stdlib_def) do
    extend T::Sig
    include Stmt
    sig { returns(T::Boolean) }
    def expr?; true; end  # can appear in expression position too
  end

  # Sharded HashMap put / get -- structural representation of a write/read
  # against a (possibly sharded, possibly Arc-wrapped) HashMap. Replaces
  # the InlineZig template substitution path so the checker has visibility
  # into key allocation, value transfer, and shard-direct vs routed
  # dispatch.
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
  #   key_zig:     Optional Zig type string for numeric_map key (for
  #                CheatLib.numericMapGet template). Set when relevant.
  #   val_zig:     Same, for value type.
  # resolved_allocs: InlineAllocMetadata of allocator placeholder name
  #   (:alloc, :key_alloc, :val_alloc, :shard_alloc) to a resolved allocator
  #   symbol (:heap | :frame). The lowering pre-resolves :receiver_storage /
  #   :node_storage to a concrete kind based on the receiver/target context,
  #   so the emitter only needs to map symbol -> Zig string.
  # template_kind: :zig | :sharded_zig | :shard_direct_zig -- which
  #   INDEX_OPS template the lowering chose. The emitter uses this to
  #   pick the same template without re-running the lowering's
  #   shard-context inspection.
  ShardedMapPut = Struct.new(:target, :key, :value, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_zig, :val_zig,
                              :resolved_allocs, :template_kind) do
    extend T::Sig
    include Stmt
    sig { params(target: T.untyped, key: T.untyped, value: T.untyped, shard_idx: T.untyped, shard_key: T.untyped, map_kind: T.untyped, stdlib_def: T.untyped, key_zig: T.untyped, val_zig: T.untyped, resolved_allocs: T.untyped, template_kind: T.untyped).void }
    def initialize(target, key, value, shard_idx, shard_key, map_kind, stdlib_def, key_zig, val_zig, resolved_allocs, template_kind)
      super(target, key, value, shard_idx, shard_key, map_kind, stdlib_def, key_zig, val_zig,
        InlineAllocMetadata.from(resolved_allocs), template_kind)
    end
    sig { returns(T::Boolean) }
    def expr?; true; end
    sig { returns(T::Array[Emittable]) }
    def child_exprs = compact_child_exprs([target, key, value])
  end

  ShardedMapGet = Struct.new(:target, :key, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_zig, :val_zig,
                              :resolved_allocs, :template_kind) do
    extend T::Sig
    include Expr
    sig { params(target: T.untyped, key: T.untyped, shard_idx: T.untyped, shard_key: T.untyped, map_kind: T.untyped, stdlib_def: T.untyped, key_zig: T.untyped, val_zig: T.untyped, resolved_allocs: T.untyped, template_kind: T.untyped).void }
    def initialize(target, key, shard_idx, shard_key, map_kind, stdlib_def, key_zig, val_zig, resolved_allocs, template_kind)
      super(target, key, shard_idx, shard_key, map_kind, stdlib_def, key_zig, val_zig,
        InlineAllocMetadata.from(resolved_allocs), template_kind)
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
    sig { params(v: T.untyped).returns(T.untyped) }
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
  [RawZig, InlineZig, InlineBc, RawBc, ShardedMapPut, ShardedMapGet].each do |k|
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
    ReturnMark, DiscardOwned, RawZig, InlineZig,
    Call, TailCall, MethodCall,
    HeapCreate, DupeSlice, AllocSlice, FreeSlice, DestroyPtr,
    DeepCopy, ContainerInit, CapWrap, SharePromote, RcRetain,
    RcDowngrade, WeakUpgrade, MakeList, ConcatStr, OwnedSlice,
    IndexInsert, BatchWindowPush, BatchWindowFlush,
    SnapshotTransaction, SnapshotMultiTxn,
    ShardedMapPut, ShardedMapGet,
  ].freeze, T::Array[T::Class[T.anything]])

  OWNERSHIP_SIGNIFICANT_NODE_NAMES = T.let(
    (OWNERSHIP_SIGNIFICANT_NODE_TYPES.map { |klass| T.must(klass.name) } + LEGACY_OWNERSHIP_NODE_NAMES).uniq.freeze,
    T::Array[String],
  )
end
