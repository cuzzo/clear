# typed: strict
require "sorbet-runtime"

require_relative "type"
require_relative "schemas"
require_relative "../annotator-helpers/intrinsic_registry"

# ==========================================
# AST
# ==========================================
module AST
    extend T::Sig

  # A node's value-type is, for these kinds, a pure function of its
  # structure — so it is DERIVED, never stamped. The full_type getter
  # below memoizes the derived Type into @type_object; the pre-MIR
  # invariant walk (which calls .full_type on every node) materializes
  # it, so type_info / resolved_type work downstream with no extra
  # code. An annotator-set value always wins (`||=`).
  LITERAL_VALUE_TYPE = {
    STRING: :String, NUMBER: :Number, FLOAT64: :Float64,
    INT64: :Int64, BOOLEAN: :Bool, SYMBOL: :Symbol, NIL: :Void
  }.freeze
  BOOL_BINOPS = %i[LT GT LTE GTE EQ NEQ AND OR].freeze
  # Statements / control-flow evaluate to Void unless the annotator
  # promoted them to an expression (IF/MATCH as a value), in which
  # case @type_object is already set and wins.
  module StatementVoidType
    def full_type
      @type_object ||= Type.new(:Void)
    end
  end

  # A function/lambda/method parameter descriptor. Replaces the loose
  # `{ name:, type:, ... }` Hash that flowed through FunctionDef#params
  # and FunctionSignature#params. `type` is ALWAYS a Type (coerced;
  # nil only when the param is unannotated/inferred — the inference
  # signal). Strongly typed; no Hash-style access.
  Param = Struct.new(:name, :type, :default, :mutable, :takes,
                     :comptime, :name_token, :required, :sync, :symbol,
                     keyword_init: true) do
    extend T::Sig

    def initialize(**kw)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil? || t.is_a?(Type)
    end

    sig { params(val: T.untyped).void }
    def type=(val)
      self[:type] = val.nil? || val.is_a?(Type) ? val : Type.new(val)
    end
  end

  # One arm of a MATCH statement (MatchStatement#cases element).
  # Replaces the untyped clause hash. MATCH-only (WITH MATCH uses a
  # separate parse_with_match_arms shape). Every slot is a single
  # strong type (none is a union): `value` is ALWAYS the pattern /
  # condition AST node (never a Symbol/nil), `body` is ALWAYS an Array
  # ([] = no body, never nil). `indirect_payload_as` is an
  # annotator-stamped flag (set when a union-variant destructure needs
  # the transpiler to emit `subject.Variant.*` via an indirect *T).
  MatchCase = Struct.new(:kind, :value, :body, :binding, :destructure, :extra_values,
                         :indirect_payload_as,
                         keyword_init: true) do
    extend T::Sig

    def initialize(**kw)
      super
      self[:body] = [] if self[:body].nil?
      self[:extra_values] = [] if self[:extra_values].nil?
      self[:indirect_payload_as] = false if self[:indirect_payload_as].nil?
    end

    sig { returns(Symbol) }
    def kind
      self[:kind]
    end

    sig { returns(AST::Locatable) }
    def value
      self[:value]
    end

    sig { returns(T::Array[AST::Locatable]) }
    def body
      self[:body]
    end

    sig { params(val: T::Array[AST::Locatable]).void }
    def body=(val)
      self[:body] = val
    end

    sig { returns(T.nilable(String)) }
    def binding
      self[:binding]
    end

    sig { returns(T.nilable(AST::StructPattern)) }
    def destructure
      self[:destructure]
    end

    sig { returns(T::Array[AST::Locatable]) }
    def extra_values
      self[:extra_values]
    end

    sig { returns(T::Boolean) }
    def indirect_payload_as
      self[:indirect_payload_as]
    end

    sig { params(val: T::Boolean).void }
    def indirect_payload_as=(val)
      self[:indirect_payload_as] = val
    end

  end

  # One paren-binding of an IF...AS (AST::IfBind#bindings element):
  # `IF (expr) AS name`. Parser builds {expr,name,name_token}; the
  # annotator stamps unwrapped_type (the bound name's type -- ALWAYS a
  # Type; a bound name always has a type) and symbol. `capture` is the
  # emitter's label alias. Replaces the anonymous hash.
  Binding = Struct.new(:expr, :name, :name_token, :unwrapped_type, :symbol, :capture,
                       keyword_init: true) do
    extend T::Sig

    def initialize(**kw)
      super
      self[:unwrapped_type] = Type.new(:Untyped) if self[:unwrapped_type].nil?
    end

    sig { returns(AST::Locatable) }
    def expr
      self[:expr]
    end

    sig { returns(String) }
    def name
      self[:name]
    end

    sig { returns(Lexer::Token) }
    def name_token
      self[:name_token]
    end

    # The bound name's unwrapped type. Always a Type, never nil --
    # defaults to the :Untyped sentinel until the annotator stamps it
    # (same contract as full_type).
    sig { returns(Type) }
    def unwrapped_type
      self[:unwrapped_type]
    end

    sig { params(val: Type).void }
    def unwrapped_type=(val)
      self[:unwrapped_type] = val
    end

  end

  # One capability of a WITH block (AST::WithBlock#capabilities
  # element): `WITH @locked c AS a`. Parser builds
  # {capability,var_node,alias,alias_mutable,guard_expr}; the annotator
  # stamps resolved_type (= var_node.full_type, ALWAYS a Type) and
  # old_scope. Distinct from the BG-capture record (also named `cap`
  # in capture analysis) -- that has name/type/storage keys and is NOT
  # this struct. Replaces the anonymous hash.
  Capability = Struct.new(:capability, :var_node, :alias, :alias_mutable, :guard_expr,
                          :snapshot_token, :view_token, :resolved_type, :old_scope,
                          keyword_init: true) do
    extend T::Sig

    def initialize(**kw)
      super
      self[:resolved_type] = Type.new(:Untyped) if self[:resolved_type].nil?
    end

    # The capability's source type. Always a Type, never nil: the
    # producer is eager (acquire_capability! stamps both the input cap
    # and every expanded field-cap from .full_type); defaults to the
    # :Untyped sentinel until then. Readers that previously fell back
    # to old_scope.resolve_type now do so on .untyped? instead of nil.
    sig { returns(Type) }
    def resolved_type
      self[:resolved_type]
    end

    sig { params(val: Type).void }
    def resolved_type=(val)
      self[:resolved_type] = val
    end

  end

  # The value of a struct-pattern field: the :wildcard sentinel
  # (`c: _`), the :bind sentinel (bare `a`), or the bound expression /
  # nested pattern AST node (`b: x`). A real 3-way typed sum -- NOT
  # T.untyped. Named once here and reused on every slot/param that
  # carries it.
  PatternFieldValue = T.type_alias { T.any(Symbol, AST::Locatable) }

  # One field of a struct-destructuring pattern (StructPattern#fields
  # element), e.g. `a` / `b: x` / `c: _` inside `MATCH v { a, b: x }`.
  # `value` is the PatternFieldValue sum, encapsulated behind
  # wildcard? / bind? / expr so no reader re-derives it via raw
  # `== :wildcard` / `== :bind` symbol comparisons.
  PatternField = Struct.new(:name, :value, :name_token, keyword_init: true) do
    extend T::Sig

    sig { returns(String) }
    def name
      self[:name]
    end

    sig { returns(Lexer::Token) }
    def name_token
      self[:name_token]
    end

    sig { returns(PatternFieldValue) }
    def value
      self[:value]
    end

    sig { params(val: PatternFieldValue).void }
    def value=(val)
      self[:value] = val
    end

    sig { returns(T::Boolean) }
    def wildcard?
      self[:value] == :wildcard
    end

    sig { returns(T::Boolean) }
    def bind?
      self[:value] == :bind
    end

    # The bound expression / nested pattern, or nil for the :wildcard /
    # :bind sentinels. Readers that want "the AST node" use this.
    sig { returns(T.nilable(AST::Locatable)) }
    def expr
      v = self[:value]
      v.is_a?(AST::Locatable) ? v : nil
    end

  end

  # Walk all statements in a body, recursing into control flow branches.
  # Yields each statement node. Handles IfStatement, MatchStatement,
  # WhileLoop, ForRange, ForEach, and generic nodes with .body.
  # Adding a new control flow node type requires updating only this method.
  sig { params(body: T::Array[T.untyped], visitor: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self.walk_body(body, &visitor)
    return unless body
    Array(body).each do |node|
      yield node
      next unless node.is_a?(HasBodies)
      node.child_bodies.each { |b| walk_body(b, &visitor) }
    end
  end

  # The immediately-nested *value* children of a transparent wrapper
  # expression: struct/union-literal field values, list-literal items,
  # and the inner value of a MOVE/COPY/CLONE/SHARE/FREEZE/CapabilityWrap
  # pass-through. For anything else: [].
  #
  # This is the single source of truth for "what values does a stored /
  # moved expression actually carry through". Before this existed, every
  # site that needed to descend a stored expression (escape detection,
  # frame-concat promotion, ...) hand-maintained its own `case node`
  # recursion, and those drifted apart — e.g. one handled UnionVariantLit
  # and another didn't (docs/agents/bug9-forensic.md). Add a new wrapper
  # shape here once and every consumer descends it consistently.
  sig { params(expr: T.untyped).returns(T::Array[T.untyped]) }
  def self.wrapped_children(expr)
    case expr
    when StructLit, UnionVariantLit
      (expr.fields&.values || []).compact
    when ListLit
      (expr.items || []).compact
    when MoveNode, CopyNode, CloneNode, ShareNode, FreezeNode, CapabilityWrap
      expr.value ? [expr.value] : []
    else
      []
    end
  end

  # Yield every BgBlock / BgStreamBlock reachable from `body`, including
  # nested ones inside control flow (WHILE/MATCH/IF/FOR/WITH/DO),
  # expression positions (VarDecl.value, FuncCall.args), and inside
  # other BG bodies. Use this when classifying every BG in a function.
  # The single source of truth replacing the parallel walkers in
  # escape_analysis (e2_each_bg) and elsewhere.
  sig { params(body: T.untyped, block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self.each_bg_block(body, &block)
    return unless body
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each { |n| _bg_visit_recursive(n, &block) }
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self._bg_visit_recursive(node, &block)
    if node.is_a?(BgBlock) || node.is_a?(BgStreamBlock)
      yield node
    end
    case node
    when HasBodies
      node.child_bodies.each { |b| each_bg_block(b, &block) }
    when VarDecl, BindExpr, Assignment, ReturnNode
      _expr_each_bg_block_recursive(node.value, &block)
    when FuncCall
      node.args.each { |a| _expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      _expr_each_bg_block_recursive(node.object, &block)
      node.args.each { |a| _expr_each_bg_block_recursive(a, &block) }
    end
  end

  sig { params(expr: T.untyped, block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self._expr_each_bg_block_recursive(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      each_bg_block(expr.body, &block)
    when FuncCall
      expr.args.each { |a| _expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      _expr_each_bg_block_recursive(expr.object, &block)
      expr.args.each { |a| _expr_each_bg_block_recursive(a, &block) }
    end
  end

  # Yield ONLY the BgBlocks directly embedded in `stmt`'s expression
  # positions -- does NOT descend into nested control-flow branches OR
  # into the bodies of BGs found here. Use when emitting per-stmt MIR
  # markers (MIR::SuppressCleanup, MIR::Promote): nested control flow
  # gets its own transform_body call which handles its BGs separately;
  # nested BGs capture from their parent BG body's scope, not this
  # stmt's scope.
  sig { params(stmt: T.untyped, block: T.untyped).returns(T.untyped) }
  def self.each_bg_block_in_stmt(stmt, &block)
    case stmt
    when BgBlock, BgStreamBlock
      yield stmt
    when VarDecl, BindExpr, Assignment
      _expr_each_bg_block_shallow(stmt.value, &block) if stmt.respond_to?(:value)
    when FuncCall
      stmt.args.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      _expr_each_bg_block_shallow(stmt.object, &block)
      stmt.args.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when ReturnNode
      _expr_each_bg_block_shallow(stmt.value, &block) if stmt.respond_to?(:value)
    end
  end

  sig { params(expr: T.untyped, block: T.untyped).returns(T.untyped) }
  def self._expr_each_bg_block_shallow(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      # Stop here -- do not descend into BG body.
    when FuncCall
      expr.args.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      _expr_each_bg_block_shallow(expr.object, &block)
      expr.args.each { |a| _expr_each_bg_block_shallow(a, &block) }
    end
  end

  # Yield every CaptureAnalysis instance reachable from `body`. A
  # CaptureAnalysis is attached to any "fiber-like context" -- BG block,
  # BgStream block, DO block branch, or ConcurrentOp (CONCURRENT
  # SELECT/WHERE/EACH/etc.). All four use the same `analyze_fiber_captures`
  # machinery; this single walker lets BgCaptureClassifier process every
  # one with one pass per function. Replaces the per-source-type
  # iteration that used to live in lower_bg_block, lower_do_block, and
  # the pipeline_host concurrent lowerings.
  sig { params(body: T::Array[T.untyped], block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self.each_capture_analysis(body, &block)
    each_bg_block(body) do |bg|
      yield bg.capture_analysis if bg.capture_analysis
    end
    walk_body(body) do |node|
      if node.is_a?(DoBlock)
        node.branches.each do |b|
          yield b[:capture_analysis] if b[:capture_analysis]
        end
      end
      _expr_each_concurrent_capture(node, &block)
    end
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
  def self._expr_each_concurrent_capture(node, &block)
    case node
    when ConcurrentOp
      yield node.capture_analysis if node.capture_analysis
    when BinaryOp
      # `x |> CONCURRENT EACH { ... }` parses as BinaryOp(op=:SMOOTH);
      # the ConcurrentOp lives on .right. (Other binary ops can also
      # contain ConcurrentOps in either side via nested expressions.)
      _expr_each_concurrent_capture(node.left, &block) if node.respond_to?(:left)
      _expr_each_concurrent_capture(node.right, &block) if node.respond_to?(:right)
    when VarDecl, BindExpr, Assignment
      _expr_each_concurrent_capture(node.value, &block) if node.respond_to?(:value)
    when ReturnNode
      _expr_each_concurrent_capture(node.value, &block) if node.respond_to?(:value)
    when FuncCall
      node.args.each { |a| _expr_each_concurrent_capture(a, &block) }
    when MethodCall
      _expr_each_concurrent_capture(node.object, &block)
      node.args.each { |a| _expr_each_concurrent_capture(a, &block) }
    end
  end

  # Declarative metadata for AST nodes that own one or more statement
  # lists (control flow, blocks, function bodies). Generic walkers like
  # `walk_body` iterate via `child_bodies` instead of hand-coded
  # case chains. Adding a new such node type means including this and
  # defining child_bodies — no walker edit required.
  module HasBodies
    extend T::Sig
    # Override in including classes. Returns Array of stmt lists (each
    # itself an Array of statements). Nil/empty entries are filtered by
    # the walker via `Array(...)`/`.compact`.
    sig { returns(T::Array[T.untyped]) }
    def child_bodies
      []
    end
  end

  module Locatable
      extend T::Sig

    sig { returns(Integer) }
    def line; token.line; end
    sig { returns(Integer) }
    def column; token.column; end
    sig { void }
    def token_value; token.value; end

    sig { returns(T.nilable(Type)) }
    def coerced_type_object; @coerced_type_object = T.let(@coerced_type_object, T.nilable(Type)); end
    sig { returns(T.nilable(Type)) }
    def type_object; @type_object = T.let(@type_object, T.nilable(Type)); end

    sig { returns(T.untyped) }
    def zig_pattern; @zig_pattern = T.let(@zig_pattern, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def zig_pattern=(val); @zig_pattern = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def matched_stdlib_def; @matched_stdlib_def = T.let(@matched_stdlib_def, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def matched_stdlib_def=(val)
      @matched_stdlib_def = T.let(IntrinsicRegistry.fs(val), T.untyped)
    end

    sig { void }
    def stdlib_allocates; @stdlib_allocates = T.let(@stdlib_allocates, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def stdlib_allocates=(val); @stdlib_allocates = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def mutates_receiver; @mutates_receiver = T.let(@mutates_receiver, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def mutates_receiver=(val); @mutates_receiver = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def was_moved; @was_moved = T.let(@was_moved, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def was_moved=(val); @was_moved = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def container_borrow; @container_borrow = T.let(@container_borrow, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def container_borrow=(val); @container_borrow = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def needs_mut_ref; @needs_mut_ref = T.let(@needs_mut_ref, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def needs_mut_ref=(val); @needs_mut_ref = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def target_is_list_field; @target_is_list_field = T.let(@target_is_list_field, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def target_is_list_field=(val); @target_is_list_field = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def needs_heap_create; @needs_heap_create = T.let(@needs_heap_create, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def needs_heap_create=(val); @needs_heap_create = T.let(val, T.untyped); end

    sig { void }
    def collection_return; @collection_return = T.let(@collection_return, T.untyped); end
    sig { params(val: T.untyped).void }
    def collection_return=(val); @collection_return = T.let(val, T.untyped); end

    sig { returns(T.nilable(Integer)) }
    def slot_size; @slot_size = T.let(@slot_size, T.nilable(Integer)); end
    sig { params(val: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def slot_size=(val); @slot_size = T.let(val, T.nilable(Integer)); end

    sig { returns(T.untyped) }
    def resource_close_zig; @resource_close_zig = T.let(@resource_close_zig, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def resource_close_zig=(val); @resource_close_zig = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def can_fail; @can_fail = T.let(@can_fail, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def can_fail=(val); @can_fail = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def error_kind; @error_kind = T.let(@error_kind, T.untyped); end
    sig { params(val: T.untyped).void }
    def error_kind=(val); @error_kind = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def error_type; @error_type = T.let(@error_type, T.untyped); end
    sig { params(val: T.untyped).void }
    def error_type=(val); @error_type = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def var_used; @var_used = T.let(@var_used, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def var_used=(val); @var_used = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def var_mutated; @var_mutated = T.let(@var_mutated, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def var_mutated=(val); @var_mutated = T.let(val, T.untyped); end

    sig { returns(T.untyped) }
    def symbol; @symbol = T.let(@symbol, T.untyped); end
    sig { params(val: T.untyped).returns(T.untyped) }
    def symbol=(val); @symbol = T.let(val, T.untyped); end

    # Set full_type. Accepts a Type object (stored directly) or any other
    # value (wrapped in Type.new for backward compatibility).
    sig { params(val: T.untyped).returns(Type) }
    def full_type=(val)
      @type_object = T.let(val.is_a?(Type) ? val : Type.new(val), T.nilable(Type))
      T.must(@type_object)
    end

    # Non-nil contract: a generic evaluatable node defaults to the
    # :Untyped sentinel (mirrors StatementVoidType's :Void default)
    # rather than nil, so callers never branch on nil. A node the
    # annotator failed to stamp surfaces as :Untyped and is caught by
    # PreMirTypeCheck at the AST->MIR boundary, not as scattered nil.
    sig { returns(Type) }
    def full_type
      @type_object ||= Type.new(:Untyped)
    end

    # full_type, or `default` when it is the :Untyped sentinel (the
    # node was never stamped). Single home for the "type, else
    # fallback" decision -- pass a value or a block for a lazy default.
    sig do
      params(default: T.nilable(T.any(Type, Symbol, String)),
             blk: T.nilable(T.proc.returns(T.any(Type, Symbol, String))))
        .returns(T.any(Type, Symbol, String))
    end
    def full_type_or(default = nil, &blk)
      ft = full_type
      return ft unless ft.untyped?
      return blk.call if blk
      default.nil? ? ft : default
    end

    # True when the node carries a real (stamped) type, i.e. full_type
    # is not the :Untyped sentinel.
    sig { returns(T::Boolean) }
    def typed?
      !full_type.untyped?
    end

    sig { params(val: T.untyped).returns(T.nilable(Type)) }
    def coerced_type=(val)
      return @coerced_type_object = T.let(nil, T.nilable(Type)) if val.nil?

      # Same logic: Wrap raw values, accept Type objects
      @coerced_type_object = T.let(val.is_a?(Type) ? val : Type.new(val), T.nilable(Type))
    end

    sig { returns(T.untyped) }
    def coerced_type
      @coerced_type_object&.raw
    end

    # Use this to access the rich object for coerced types
    sig { returns(T.nilable(Type)) }
    def coerced_type_info
      @coerced_type_object
    end

    # Resolves the final type, handling coercion if needed.
    # Returns [final_type, error]. Error is nil if ok.
    #
    # @param declared_type [Symbol, nil] The explicitly declared type (or nil/:Any for inference)
    # @return [Array(Symbol, String|nil)] [final_type, error_message]
    #
    sig { params(declared_type: T.untyped).returns(T::Array[T.untyped]) }
    def coerce!(declared_type)
      # fn_type must not be flattened to its return type — preserve the full Type object.
      return [@type_object, nil] if @type_object&.fn_type? && (declared_type.nil? || declared_type == :Any)

      inferred = @type_object&.resolved

      # No explicit type or :Any -> use inferred, no coercion needed
      return [inferred, nil] if declared_type.nil? || declared_type == :Any

      # Explicit type matches inferred -> no coercion needed
      return [declared_type, nil] if declared_type == inferred

      # Check if coercion is valid
      error = Type.coerce_error(T.must(@type_object), declared_type)
      return [nil, error] if error

      # Valid coercion - set coerced_type and return declared
      self.coerced_type = declared_type
      [declared_type, nil]
    end

    # Finalizes storage for a declaration node (VarDecl, etc.).
    # Calculates slot_size, determines storage, and sets full_type.
    # Returns the storage location (:stack, :frame, :heap).
    #
    # @param final_type [Symbol] The resolved type after coercion
    # @yield [name] Block to look up struct schema by name
    # @return [Symbol] The storage location
    #
    sig { params(final_type: T.any(Symbol, Type), schema_lookup: T.untyped).returns(Symbol) }
    def finalize_storage!(final_type, &schema_lookup)
      T.bind(self, T.untyped) rescue nil
      # Normalize the Symbol|Type input to a Type once at the seam, so
      # the body never re-derives via final_type.is_a?(Type). A Symbol
      # tag yields a bare Type (no shard/sync/soa/observable) -- exactly
      # what the old `is_a?(Type) && ...` false-branch produced.
      final_type = Type.new(final_type) unless final_type.is_a?(Type)
      # Calculate slot size
      type_obj = Type.new(final_type)
      @slot_size = T.let(type_obj.slot_size(&schema_lookup), T.nilable(Integer))

      # Determine storage from value's type if this node has a value
      if respond_to?(:value) && value.type_object
        value_type = value.type_object
        storage = value_type.finalize_storage(@slot_size, value.storage)
        # Declared type overrides: pointer types (%Type annotation) or sync types
        storage = :heap if type_obj.heap? || type_obj.any_sync?
        # Declared @list annotation requires frame (unless already upgraded to heap)
        storage = :frame if type_obj.list_collection? && storage != :heap
        value.storage = storage if value.respond_to?(:storage=)
      else
        storage = type_obj.finalize_storage(T.must(@slot_size), nil)
      end

      # Determine if value has a sync capability
      value_sync = nil
      if respond_to?(:value) && value.type_object
        vt = value.type_object
        value_sync = vt.sync
      end

      # Build a Type that carries the resolved base type plus storage-derived capabilities.
      # For fn_type, preserve the full type object — do not reduce to the return-type symbol.
      t = if final_type.fn_type?
        final_type
      else
        new_t = Type.new(final_type.resolved)
        # Carry shard_count + sync + soa through finalize — not encoded in the base symbol.
        # Check both final_type and the value's type_info (for constructor sugar: List[], Pool[]).
        val_ti = respond_to?(:value) && value.respond_to?(:full_type) ? value.full_type : nil
        new_t.shard_count = final_type.shard_count if final_type.shard_count
        new_t.shard_count ||= val_ti.shard_count if val_ti&.shard_count
        new_t.sync = final_type.sync if final_type.sync
        new_t.soa = final_type.soa if final_type.soa
        new_t.soa ||= val_ti.soa if val_ti&.respond_to?(:soa) && val_ti.soa
        new_t.collection = val_ti.collection if val_ti&.collection && !new_t.collection
        # Carry @observable through finalize_storage! — without this the
        # binding's full_type loses the @is_observable bit and downstream
        # cleanup classification can't recognise `~T@observable`. The
        # terminal kind (`:sum`/`:count`/.../`:distinct`) must come along
        # too so OBSERVABLE_WRAPPERS can pick the right wrapper Zig type;
        # without it the lookup falls back to a default and silently
        # emits the wrong wrapper.
        new_t.is_observable = true if final_type.observable? ||
                                       (val_ti.respond_to?(:observable?) && val_ti.observable?)
        if final_type.observable_terminal
          new_t.observable_terminal = final_type.observable_terminal
        elsif val_ti.respond_to?(:observable_terminal) && val_ti.observable_terminal
          new_t.observable_terminal = val_ti.observable_terminal
        end
        new_t.elem_ownership = final_type.elem_ownership if final_type.elem_ownership
        new_t.elem_ownership ||= val_ti.elem_ownership if val_ti&.respond_to?(:elem_ownership) && val_ti&.elem_ownership
        new_t.elem_sync = final_type.elem_sync if final_type.elem_sync
        new_t.elem_sync ||= val_ti.elem_sync if val_ti&.respond_to?(:elem_sync) && val_ti&.elem_sync
        # Propagate @link_source from value's type
        if val_ti&.link?
          link_src = val_ti.link_source
          new_t.link_source = link_src if link_src
        end
        new_t
      end
      # Propagate @link ownership from the value's LinkNode
      val_ti = respond_to?(:value) && value.respond_to?(:full_type) ? value.full_type : nil
      if val_ti&.link?
        storage = :link
      end

      case storage
      when :frozen
        t.ownership = :frozen
      when :multiowned
        t.ownership = :multiowned
      when :shared
        t.ownership = :shared
      when :link
        t.ownership = :link
      when :rodata
        t.provenance = :rodata
      when :frame
        t.provenance = :frame
      when :heap
        if value_sync == :locked
          t.sync = :locked          # sync= setter sets provenance = :heap
        elsif value_sync == :write_locked
          t.sync = :write_locked    # sync= setter sets provenance = :heap
        else
          t.provenance = :heap
        end
        t.provenance = :heap
      # :stack — leave provenance nil; set_cleanup_alloc! may upgrade via ||= alloc
      end

      # Propagate additional capability fields from the value's type_object
      if respond_to?(:value) && value.type_object
        vt = value.type_object
        t.ownership = vt.ownership if vt.ownership && vt.ownership != :affine
        t.sync      = vt.sync      if vt.sync
        # Preserve value layout so VarDecl can propagate @indirect:atomic
        # bindings into the symbol table.
        t.layout    = vt.layout    if vt.layout
      end

      self.full_type = t

      # Override storage in case Type's default differs from finalized storage
      self.storage = storage

      storage
    end

    # -- REFACTORED HELPERS --
    # Delegate to the new class
    sig { returns(T.nilable(Symbol)) }
    def resolved_type
      @type_object&.resolved
    end

    sig { returns(T.nilable(Symbol)) }
    def base_type
      @type_object&.base_type
    end

    sig { returns(T.nilable(Symbol)) }
    def storage
      @storage_override || (@type_object && (@type_object.provenance || :stack))
    end

    sig { params(val: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
    def storage=(val)
      # Use a node-local override rather than mutating @type_object.provenance.
      # @type_object may be a shared Type (e.g. STRING_TYPE from std_lib, or the
      # function return type from FunctionSignature). Mutating it would corrupt every
      # other AST node that shares the same Type object. The override is node-local
      # so promote_expr_to_heap! can mark individual call-site nodes as heap without
      # touching the shared type.
      @storage_override = T.let(val, T.nilable(Symbol))
    end


    sig { returns(T.nilable(Symbol)) }
    def metatype
      return :lambda if self.is_a?(LambdaLit)
      return :named_function if self.is_a?(FunctionDef)

      t = @type_object
      return nil unless t

      return :void if t.resolved == :Void
      return :die if t.resolved == :NoReturn
      return :array if t.array?
      return :hashmap if t.map?
      return :struct if !t.primitive?
      return :primitive
    end
  end

  Program      = Struct.new(:token, :statements) do
    include Locatable
    # Resolved program-level SYNC POLICY, either user-written or the baked-in
    # default. Lowering reads this when filling unhandled WITH error slots.
    attr_accessor :sync_policy
  end
  # kind: :local (REQUIRE "file.cht") or :package (REQUIRE "pkg:name")
  RequireNode  = Struct.new(:token, :path, :namespace, :kind) { include Locatable }
  FunctionDef  = Struct.new(:token, :name, :params, :captures, :return_type, :return_lifetime, :body, :catch_clauses, :default_catch, :visibility, :deferred_drops, :uses_frame) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact

    # Seam: a function's declared/inferred return is always a Type
    # (or nil when undeclared — the implicit-return signal that
    # inference consumes). Coerced at BOTH construction (positional
    # Struct init from parser/synthetic builders) and post-parse
    # assignment (return inference, auto-infer) so no reader needs
    # an `is_a?(Type)` Symbol/Type discriminator.
    def initialize(*)
      super
      rt = self[:return_type]
      self[:return_type] = Type.new(rt) unless rt.nil? || rt.is_a?(Type)
      self[:params] = self[:params] || []
    end

    sig { params(val: T.untyped).void }
    def return_type=(val)
      self[:return_type] = val.nil? || val.is_a?(Type) ? val : Type.new(val)
    end

    sig { params(val: T::Array[T.untyped]).void }
    def params=(val)
      self[:params] = val
    end

    attr_accessor :type_params   # Array of type param name strings, e.g. ["T", "K"], or nil
    # True when the user wrote RETURNS explicitly; fallible-signature checks
    # only enforce on user-authored return types.
    attr_accessor :explicit_return_type
    attr_accessor :requires      # REQUIRES clause — { param_name => Set[Family] } or nil
                                 #     Family symbols: :LOCKED, :VERSIONED, :ACTOR, :LOCK_FREE
    attr_accessor :effect_set    # projected EffectSet (yield/alloc_heap/io/fail)
                                 #     view over fn.effects + fn.can_fail
    attr_accessor :inferred_effects  # alias of effect_set; used by formatter
    attr_accessor :reentrant     # :reentrant, :non_reentrant, or nil (default: non-reentrant, no guard)
    attr_accessor :tail_call     # true if @reentrant:tailCall — compiler emits @call(.always_tail, ...)
    attr_accessor :reentrant_token   # Token for the legacy @reentrant annotation (drives `clear fix` span)
    attr_accessor :arrow_token       # Token for the `->` after the function header (drives REQUIRES insertion span)
    attr_accessor :name_token        # Token for the function name itself (drives the `!`-suffix fix for STYLE_MUTABLE_PARAM_NEEDS_BANG)
    # Phase 4f.2: { start_tok:, end_tok: } pair covering the full
    # `EFFECTS REENTRANT[:VARIANT]` clause text. Used by `clear fix`
    # to swap variants (e.g., `:THUNK` -> plain or `:NOT_LOGICAL`).
    attr_accessor :effects_span
    # Phase 4f.3: positive Int from `EFFECTS REENTRANT:MAX_DEPTH(N)`.
    # Set on parse; the bridge validates `!T` return and the prologue
    # codegen path emits `safety.enterDepth(@src(), N)` /
    # `defer safety.exitDepth(@src())`.
    attr_accessor :max_depth_n
    # When true, the function declared `:TIGHT` (or `:TIGHT:VARIANT`)
    # — skip the entry `rt.checkYield()` co-op-yield injection.
    # Mirrors `TIGHT WHILE`; same opt-out, same risks (long
    # workloads stall the scheduler). For `:MAX_DEPTH(N)` TIGHT is
    # IMPLIED and not user-settable; the bridge force-flips it on
    # iff `N <= YIELD_BUDGET`.
    attr_accessor :tight_reentrance
    # Token at the start of the return type annotation (after RETURNS,
    # past any lifetime-prefix). Used for fixable spans that prepend
    # `!` to the declared return type.
    attr_accessor :return_type_token
    # Thunk Phase 1: declared via `EFFECTS REENTRANT[:VARIANT]` after RETURNS.
    # Values:
    #   nil                       no declaration
    #   :reentrant                EFFECTS REENTRANT (plain — must run on @service or @size:canSmash)
    #   :reentrant_thunk          EFFECTS REENTRANT:THUNK (CPS state machine + trampoline; non-contagious)
    #   :reentrant_tail_call      EFFECTS REENTRANT:TAIL_CALL (self-loop; verified by stack pass)
    #   :reentrant_not_logical    EFFECTS REENTRANT:NOT_LOGICAL (runtime StackGuard;
    #                                                            requires `!T` return type)
    #   :reentrant_max_depth      EFFECTS REENTRANT:MAX_DEPTH(N) (runtime depth counter;
    #                                                             requires `!T` return type;
    #                                                             max_depth_n stamped on FunctionDef)
    # The annotator bridges this with the legacy `@reentrant`/`tail_call` attrs into a
    # canonical reentrance_kind via src/annotator-helpers/reentrance.rb (Phase 1.3).
    attr_accessor :effects_decl
    # Thunk Phase 1.3: canonical, post-bridge reentrance kind. Read THIS, not
    # `effects_decl` or `reentrant` directly. Same value space as effects_decl;
    # the bridge unifies legacy and new declarations into one field.
    attr_accessor :reentrance_kind
    # Thunk Phase 4c: when the splitter recognizes a simple-recurrence
    # shape on a `:reentrant_thunk` function, the annotator stamps the
    # Plan here and lifts the Phase 4b "non-tail" error. Phase 4d's
    # MIR lowering then synthesizes the trampoline body from this.
    attr_accessor :thunk_plan
    # Thunk Phase 4f.1: when every member of a `:reentrant_thunk` cycle
    # matches the tail-position-mutual shape, the annotator stamps a
    # MutualThunkPlan on each member naming the cycle and the per-
    # member tail target. MIR lowering synthesizes a tagged-union
    # trampoline body from it (one trampoline per entry fn; same union
    # shape across cycle members).
    attr_accessor :mutual_thunk_plan
    # Thunk Phase 1.2: `REQUIRES <name>: NON_REENTRANT` clauses constrain function-typed
    # parameters. Hash mapping param name (String) to constraint symbol (e.g. :non_reentrant).
    attr_accessor :requires_clauses
    attr_accessor :needs_rt      # computed by compute_needs_rt! post-pass; nil = not yet computed
    attr_accessor :can_fail      # computed by compute_can_fail! post-pass; nil = not yet computed
    attr_accessor :uses_heap     # true when body allocates from heap (rt.heapAlloc)
    attr_accessor :uses_alloc    # true when body calls stdlib fns that use rt.frameAlloc (e.g. append)
    attr_accessor :uses_rt       # true when body references rt without allocating (e.g. Versioned.read for EBR pin)
    attr_accessor :return_provenance # :rodata, :frame, :heap — provenance of the return value
    attr_accessor :effects       # Set of effect symbols, computed by EffectTracker post-pass
    attr_accessor :snapshot_types # Set of pipeline input types that could be snapshots (for CATCH)
    attr_accessor :stack_tier        # recommended fiber tier (:micro, :standard, :large, :xl)
    attr_accessor :stack_vars_bytes  # lower-bound estimate of stack-local variable bytes
    attr_accessor :has_promotion      # set by MIRPass when function has escape promotions
    attr_accessor :moved_guard_info   # stamped by MIRPass: { var_name => bool } for has_moved_guard lookups
    attr_accessor :cleanup_bindings   # stamped by MIRPass: { var_name => entry_hash } for MIRLowering
    attr_accessor :heap_carry_return      # true when a heap carry var is the return value (caller must free)
    attr_accessor :heap_carry_return_vars # Set of var names that are heap carry return vars (their cleanup is skipped inside __pr_body)
    # FSM Phase A: set by FsmClassifier. fsm_eligible=true means this function can be
    # compiled as an FsmTask (state-machine resume fn) rather than a stackful fiber.
    # fsm_suspend_points is an Array of { id:, kind:, node: } enumerating the
    # yield-relevant call sites inside the body.
    attr_accessor :fsm_eligible
    attr_accessor :fsm_ineligible_reason  # Symbol: :reentrant, :extern, :self_recursive, :no_suspends
    attr_accessor :fsm_suspend_points
    # PRE clauses: Array of expression AST nodes parsed from
    # `PRE: <expr>` between RETURNS and `->`. Each predicate is checked
    # at function entry, fail-fast, raising PreconditionFail.
    # See docs / spec/with_pre_spec.rb for semantics.
    attr_accessor :pre_clauses
    # DEBUG_POST clauses: same shape as pre_clauses (Array of
    # {expr:, source:}). Checked in a debug-only wrapper after the
    # function body returns; panics on violation. See spec/with_post_spec.rb.
    attr_accessor :post_clauses
    # True when declared via `METHOD name(...)` instead of `FN name(...)`.
    # Purely a fmt directive: METHOD-flagged FNs have their prefix call
    # sites (`foo(v, ...)`) rewritten to UFCS form (`v.foo(...)`) by
    # `clear fmt`. Semantically identical to FN — same lookup, same
    # call resolution, same UFCS at call sites at the language level.
    attr_accessor :is_method
  end
  StructDef    = Struct.new(:token, :name, :fields, :visibility, :type_params) { include Locatable }
  VarDecl      = Struct.new(:token, :name, :type, :value, :mutable) do
    include Locatable
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)

    # Seam: a declaration's annotated/inferred type is always a Type
    # (or nil when unannotated — the inference signal). Coerced at
    # construction (positional Struct init) and post-parse assignment
    # (auto-infer, propagation) so no reader needs an `is_a?(Type)`
    # Symbol/Type discriminator.
    def initialize(*)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil? || t.is_a?(Type)
    end

    def type=(val)
      self[:type] = val.nil? || val.is_a?(Type) ? val : Type.new(val)
    end
  end
  Assignment   = Struct.new(:token, :name, :value) do
    include Locatable
    include StatementVoidType
    attr_accessor :auto_lock  # set by annotator when target is @locked/@writeLocked (inline guard)
    attr_accessor :field_pre_cleanup  # stamped by MIRPass: { zig_type:, alloc: } for field overwrite cleanup
    attr_accessor :container_promote_zig_type  # stamped by MIRPass: Zig type string when indexed store needs frame-to-heap promote
    # Preserves the source compound operator so atomic targets can lower to
    # fetch_<op> instead of load/modify/store.
    attr_accessor :compound_op
    # Stamped by the annotator for @shared:atomic targets so MIR lowering emits
    # MethodCall(cell, op, args) instead of plain Set.
    attr_accessor :auto_atomic_op
  end
  # Keywordless bind: `x = val` or `x: Type = val`. Annotator sets mode to :decl or :assign.
  BindExpr     = Struct.new(:token, :name, :type, :value) do
    include Locatable
    attr_accessor :mode
    attr_accessor :reassign_cleanup  # stamped by MIRPass: { kind:, alloc: } for reassignment pre-cleanup
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)
    attr_accessor :compound_op
    attr_accessor :auto_atomic_op

    # Seam: same contract as VarDecl#type — annotated/inferred type is
    # always a Type (or nil when unannotated). Coerced at construction
    # and post-parse assignment so no reader needs an `is_a?(Type)`
    # Symbol/Type discriminator.
    def initialize(*)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil? || t.is_a?(Type)
    end

    def type=(val)
      self[:type] = val.nil? || val.is_a?(Type) ? val : Type.new(val)
    end
  end
  BinaryOp     = Struct.new(:token, :left, :op, :right) do
    extend T::Sig
    include Locatable
    # Derived: comparison/logical -> Bool; otherwise an operand's type.
    def full_type
      @type_object ||=
        if BOOL_BINOPS.include?(op)
          Type.new(:Bool)
        else
          Type.new(left&.full_type.resolved || right&.full_type.resolved || :Any)
        end
    end
    attr_accessor :string_concat  # true when this is string + (stamped by annotator)
    attr_accessor :storage        # :heap when carry-var concat is promoted to heap
    attr_accessor :or_fallback_dupe  # true when OR_RESCUE fallback struct needs string-field heap dupe
    attr_accessor :paren_bind     # true when this :BIND_VAR was wrapped in parens: (expr AS name)
    # Lazy positions: fields whose lowering must NOT leak @pending_stmts to
    # outer scope. The lowering's `descend` helper consults this and wraps
    # the field's emission in MIR::BlockExpr when the field actually emitted
    # any pending allocs. OR_RESCUE's right side is the fallback expression;
    # its allocations must only run when the orelse short-circuits to it.
    sig { returns(T::Array[T.untyped]) }
    def lazy_fields = (op == :OR_RESCUE ? [:right] : [])
    # True on a `|> SUM/MAX/MIN/COUNT/AVERAGE/ANY/ALL/FIND/DISTINCT/REDUCE`
    # whose source is a still-running tense stream — fold terminal is backed by
    # an Observable<T> / atomic accumulator and may be observed via WITH VIEW.
    attr_accessor :observable_terminal
    # Set when the pipe's destination is a `~T@observable` binding so
    # pipeline lowering switches to fiber-spawn-with-accumulator codegen.
    attr_accessor :observable_dest
  end
  UnaryOp      = Struct.new(:token, :op, :right) do
    include Locatable
    # Derived: NOT -> Bool; otherwise the operand's type.
    def full_type
      @type_object ||= op == :NOT ? Type.new(:Bool) : Type.new(right&.full_type.resolved || :Any)
    end
  end
  # Parser-only placeholder for call-site override syntax; the annotator
  # rejects it until runtime semantics are implemented.
  CallSiteOverride = Struct.new(:token, :kind, :n, :inner) { include Locatable }
  Identifier   = Struct.new(:token, :name) do
    extend T::Sig
    include Locatable
    attr_accessor :fn_ref           # true when the identifier refers to a named function used as a value
    attr_accessor :heap_dupe_result # true when this identifier's value must be heap-duped at use site
    attr_accessor :atomic_borrow    # true when sync=:atomic ident is in fn-arg position (skip load wrap)
    sig { returns(FalseClass) }
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  Literal      = Struct.new(:token, :type, :value, :storage) do
    include Locatable
    # Derived: a literal's value-type is a pure function of its token
    # kind. Never nil, never stamped.
    def full_type
      @type_object ||= Type.new(LITERAL_VALUE_TYPE.fetch(self[:type], :Any))
    end
  end
  ListLit      = Struct.new(:token, :items, :storage) { 
    extend T::Sig
    include Locatable 

    sig { params(declared_type: T.untyped).returns(T::Array[T.untyped]) }
    def coerce!(declared_type)
      res, error = super(declared_type)
      return [nil, error] if error

      # Recursively coerce items if the container is being coerced
      if res && items.any?
        element_type = Type.new(res).element_type
        if element_type
          items.each { |item| item.coerce!(element_type.resolved) }
        end
      end
      [res, nil]
    end
  }
  HashLit      = Struct.new(:token, :pairs, :storage) { include Locatable }
  DefaultLit   = Struct.new(:token) { include Locatable }
  StructLit    = Struct.new(:token, :name, :fields, :storage, :type_args) do
    include Locatable
    # Parallel map of field_name (String) -> the lexer Token that parsed
    # the name. Populated by the parser so `clear fix` can locate a
    # misspelled field-name for a fixable edit span.
    attr_accessor :field_tokens
  end
  LambdaLit    = Struct.new(:token, :params, :captures, :body, :storage, :deferred_drops) do
    include Locatable
    # Same params seam as FunctionDef: always Array<AST::Param>.
    def initialize(*)
      super
      self[:params] = self[:params] || []
    end

    def params=(val)
      self[:params] = val || []
    end
  end
  IfStatement  = Struct.new(:token, :condition, :then_branch, :else_branch, :then_drops, :else_drops) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[T.untyped]) }
    def child_bodies = [then_branch, else_branch].compact
    attr_accessor :expr_mode           # true when used as an expression (x = IF ...)
    attr_accessor :then_result_type    # Type of last value expression in then_branch
    attr_accessor :else_result_type    # Type of last value expression in else_branch
  end
  # IF x AS y [&& z AS a] THEN ... [ELSE ...] END
  # bindings: Array of { expr:, name:, name_token: }
  # single binding emits: if (expr) |y| { ... }
  # multi binding emits labeled block: blk: { const y = expr1 orelse break :blk; const a = expr2 orelse break :blk; ... }
  IfBind       = Struct.new(:token, :bindings, :then_branch, :else_branch) do
    extend T::Sig
    include Locatable

    def initialize(*args)
      super
      self[:bindings] = [] if self[:bindings].nil?
    end

    sig { params(val: T::Array[AST::Binding]).void }
    def bindings=(val)
      self[:bindings] = val
    end
  end
  WhileLoop    = Struct.new(:token, :condition, :do_branch, :deferred_drops) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[T.untyped]) }
    def child_bodies = [do_branch].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight        # true when declared with TIGHT WHILE — no yield injection, no loop marks
  end
  WhileBindLoop = Struct.new(:token, :condition, :binding_name, :binding_token, :do_branch, :deferred_drops) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[T.untyped]) }
    def child_bodies = [do_branch].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight
  end
  BreakNode    = Struct.new(:token) do
    include Locatable
    include StatementVoidType
  end
  ContinueNode = Struct.new(:token) do
    include Locatable
    include StatementVoidType
  end
  FuncCall     = Struct.new(:token, :name, :args) do
    extend T::Sig
    include Locatable
    attr_accessor :module_alias
    attr_accessor :extern_call       # true when calling a native EXTERN FN (no rt, no try)
    attr_accessor :extern_effects    # Set of effect symbols (:Alloc, etc.) from EXTERN FN EFFECTS declaration
    attr_accessor :generic_type_args # Array of inferred type symbols for generic fns, e.g. [:Number]
    attr_accessor :fn_var_call       # true when calling a fn-type variable (not a named function)
    attr_accessor :pipe_lhs           # original LHS AST node when rewritten from pipeline (for CATCH snapshot)
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    attr_accessor :arg_families      # per-arg Set<Family> for ?-form effect resolution
    attr_accessor :collapsed_errors  # Set<Symbol> of errors this
                                     # specific call site can surface, projected per actual-family of
                                     # each REQUIRES'd arg. Strictly a subset of the callee fn's full
                                     # !T error union -- for `tick(myVersioned)` where tick has
                                     # REQUIRES x: SNAPSHOTTED, this is {:MvccConflict} (not the full
                                     # {:MvccConflict, :AtomicConflict}). nil for calls that don't
                                     # touch any REQUIRES'd param's family axis.
    attr_accessor :error_union_type  # when the callee
                                     # returns `!T`, `full_type` is stripped to the success
                                     # type `T` (so `x = call()` makes x of type T). The
                                     # original `!T` is stashed here for OR-RESCUE consumers
                                     # that need to know whether to emit `catch fallback`
                                     # (error union) or `orelse fallback` (optional).
    sig { returns(FalseClass) }
    def wildcard?; false end
    def name; self[:name].to_s end
  end

  MethodCall   = Struct.new(:token, :object, :name, :args) do
    extend T::Sig
    include Locatable
    attr_accessor :pool_method    # :insert, :get, :remove — set by annotator for Pool dispatch
    attr_accessor :set_method     # :insert, :contains, :remove, :count — set by annotator for Set dispatch
    attr_accessor :map_method     # :delete, :contains, :count, :keys, :values — set by annotator for HashMap dispatch
    attr_accessor :extern_call       # true when calling a native EXTERN method
    attr_accessor :extern_effects    # Hash of effect symbols from EXTERN FN EFFECTS declaration
    attr_accessor :generic_type_args # Array of inferred type symbols for generic methods
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    sig { returns(FalseClass) }
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  GetField     = Struct.new(:token, :target, :field) do
    extend T::Sig
    include Locatable
    # Set by visit_assignment_field before visiting this node so
    # downstream checks (e.g. CAP_FIELD_NEEDS_WITH_EXCLUSIVE for
    # `@locked` reads) can skip when this GetField is the LHS of an
    # assignment — writes go through visit_assignment_field's
    # auto-lock path instead.
    attr_accessor :is_assignment_lhs
    sig { returns(T::Boolean) }
    def wildcard?; field == '*' end
    sig { returns(String) }
    def name; target.name end
  end
  GetIndex     = Struct.new(:token, :target, :index) do
    extend T::Sig
    include Locatable
    sig { returns(String) }
    def name; target.name end
  end
  Cast         = Struct.new(:token, :value, :target) { include Locatable }
  ReturnNode   = Struct.new(:token, :value) do
    include Locatable
    attr_accessor :promote_ret_wrap       # :const or :var — set by MIRPass for return wrapping
    attr_accessor :catch_string_dupe_ret  # true: frame string in catch fn needs heap dupe on return
    attr_accessor :ret_field_promote_data # Hash { zig_type:, fields: } for struct field promotion on return
  end
  Assert       = Struct.new(:token, :condition, :message) { include Locatable }
  # RAISE Kind, ErrorName, "message"
  # kind: symbol (:Transient, :Input, :System, :NotFound, :Permission, :Canceled)
  # error_name: optional string (user-defined error enum name)
  # message_expr: optional string expression
  Raise        = Struct.new(:token, :kind, :error_name, :message_expr) { include Locatable }
  ThrowNode    = Struct.new(:token, :value) { include Locatable }
  DieNode      = Struct.new(:token, :status) { include Locatable }
  Slice        = Struct.new(:token, :target, :start, :end) { include Locatable }
  Require      = Struct.new(:token, :path) { include Locatable }
  # lock_error_clause: optional Hash describing ON TIMEOUT / RETRY handling for
  # EXCLUSIVE / write_locked_read captures. Shape:
  #   { action: :raise | :pass | :exit | :block, message: <string|nil>, body: <Array|nil>, retries: <Integer|nil> }
  # retries > 0 means RETRY(N) THEN <action>; retries nil/0 means plain ON TIMEOUT <action>.
  WithBlock    = Struct.new(:token, :capabilities, :body, :deferred_drops) do
    extend T::Sig
    include Locatable
    include HasBodies

    def initialize(*args)
      super
      self[:capabilities] = [] if self[:capabilities].nil?
    end

    sig { params(val: T::Array[AST::Capability]).void }
    def capabilities=(val)
      self[:capabilities] = val
    end

    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact
    attr_accessor :lock_error_clause
    # Per-WITH opt-out from a static nested-lock check. Hash shape:
    #   { kind: :deadlock | :lock_cycle, token: Token }
    # nil = no opt-out; annotator rejects violating nesting.
    attr_accessor :deadlock_escape
    # Arms for the WITH MATCH form. nil for plain WITH (single-family).
    # Array of { family: Symbol, body: [stmts], lock_error_clauses: [clause, ...], token: Token }.
    # Single-family WITH is a one-arm WithMatch internally; the parser
    # leaves arms nil when no MATCH keyword was used.
    attr_accessor :arms
    # :view is a cheap immutable borrow on ~T@observable; :materialized_view is
    # an owned snapshot on any ~T aggregate. nil for traditional capability blocks.
    attr_accessor :view_kind
    # Rolled-up snapshot classification used by downstream passes. Each
    # capability entry still carries the per-cell `:alias_mutable` flag.
    attr_accessor :snapshot_mode
    # Opts into polymorphic comptime-dispatch lowering. The annotator enforces
    # that POLYMORPHIC matches the binding's REQUIRES family set.
    attr_accessor :polymorphic
    # Stamped when WITH POLYMORPHIC admits every sync family; lowering routes
    # the block to MIR::PolymorphicMutate for caller-family dispatch.
    attr_accessor :universal_poly
  end

  # Top-level SYNC POLICY handlers use the same clause shape as
  # WithBlock#lock_error_clause. Policy validation lives in the annotator.
  SyncPolicyDecl = Struct.new(:token, :handlers) { include Locatable }

  SelectOp     = Struct.new(:token, :expression) { include Locatable }
  WhereOp      = Struct.new(:token, :expression) { include Locatable }
  IndexOp      = Struct.new(:token, :expression) { include Locatable }
  ReduceOp     = Struct.new(:token, :initial_value, :expression) { include Locatable }
  OrderByOp    = Struct.new(:token, :expression) { include Locatable }
  LimitOp      = Struct.new(:token, :count) { include Locatable }
  UnnestOp     = Struct.new(:token, :expression) { include Locatable }
  DistinctOp   = Struct.new(:token, :expression) { include Locatable }
  # EachOp: side-effect iteration over a collection.
  # Uses `_` as the implicit item binding. Body is a list of statements.
  # Syntax: collection |> EACH { _.field = value; };
  # On sharded pools, auto-dispatches N parallel fibers (one per shard).
  EachOp       = Struct.new(:token, :body) { include Locatable }
  # TAP: side-effect observer — runs body for each item, returns original list unchanged.
  # Unlike EACH, TAP passes through the collection (not void).
  TapOp        = Struct.new(:token, :body) { include Locatable }
  # SKIP: skip first N elements, return rest (inverse of LIMIT).
  SkipOp       = Struct.new(:token, :count) { include Locatable }
  # COLLECT: pipe-terminal that consumes a `~T@observable` (typically
  # produced by a fold over a tense stream) by blocking until the
  # producer's `finish()`, then returning the underlying T. Lowers
  # to `lhs.next()` (same shape as NEXT for ~T promises).
  CollectOp    = Struct.new(:token) { include Locatable }
  # TAKE_WHILE: take elements from the front while predicate is true.
  TakeWhileOp = Struct.new(:token, :expression) { include Locatable }
  # WINDOW(size): sliding window of `size` elements. _ is the sub-slice.
  WindowOp = Struct.new(:token, :size, :expression) { include Locatable }
  # WINDOW(size: N, time: 'Xms'): batch/tumbling window. _ is a T[] batch.
  # options = { "size" => size_node, "time" => time_node } (at least one required)
  BatchWindowOp = Struct.new(:token, :options, :expression) { include Locatable }
  # JOIN(right_source) key_expr_or_lambda
  # Equi-join: shared key applied to both sides, or lambda(a, b) -> Bool.
  # Result: anonymous struct { left: L, right: ?R } for each left element.
  JoinOp = Struct.new(:token, :right_source, :key_expr) { include Locatable }
  # Phase 3 predicate query operators — return scalar values (not new lists).
  # All use `_` as the implicit item binding (like SELECT/WHERE).
  FindOp   = Struct.new(:token, :expression) { include Locatable } # ?ElemType
  AnyOp    = Struct.new(:token, :expression) { include Locatable } # Bool
  AllOp    = Struct.new(:token, :expression) { include Locatable } # Bool
  CountOp  = Struct.new(:token, :expression) { include Locatable } # Int64
  # Phase 4 numeric aggregation operators — expression must be numeric.
  # SUM/AVERAGE return 0 for empty list; MIN/MAX panic on empty list.
  SumOp     = Struct.new(:token, :expression) { include Locatable } # Number
  AverageOp = Struct.new(:token, :expression) { include Locatable } # Number
  MinOp     = Struct.new(:token, :expression) { include Locatable } # Number (panics on empty)
  MaxOp     = Struct.new(:token, :expression) { include Locatable } # Number (panics on empty)
  # ShardOp: route items to owning schedulers by key hash.
  # Syntax: collection |> SHARD(key_expr, target_map) |> CONCURRENT EACH { body }
  # key_expr uses `_` as the implicit item binding (consistent with SELECT/WHERE).
  # target_map is the @sharded HashMap whose shardIndex determines routing.
  ShardOp = Struct.new(:token, :key_expr, :target_map) { include Locatable }
  # ConcurrentOp: CONCURRENT modifier wrapping a pipeline op for parallel execution.
  # op: SelectOp | WhereOp | EachOp
  # options: Hash of String => ASTNode  (e.g. {"pool_size" => Literal(8)})
  ConcurrentOp = Struct.new(:token, :op, :options) do
    include Locatable
    attr_accessor :shard_context  # set by annotator: { map_var:, shard_count:, key_expr: }
    attr_accessor :capture_analysis
  end
  Placeholder  = Struct.new(:token) { include Locatable }
  Copy         = Struct.new(:token, :value) { include Locatable }
  OptionalUnwrap = Struct.new(:token, :target) do
    extend T::Sig
    include Locatable
    sig { returns(T.nilable(String)) }
    def name; target.respond_to?(:name) ? target.name : nil end
  end
  OrRaise        = Struct.new(:token) { include Locatable }  # OR RAISE - bubble up error (Zig's try)
  # OR EXIT forms under the unified error system. Unspecified fields
  # inherit from the pre-existing rt.__error set by the failing call:
  #   OR EXIT "msg"                — message-only override (kind/type inherited)
  #   OR EXIT Kind                 — set kind, clear type
  #   OR EXIT Kind, "msg"          — kind + msg, clear type
  #   OR EXIT Kind, Type           — kind + type
  #   OR EXIT Kind, Type, "msg"    — full override
  #   OR EXIT Type                 — set type (kind auto-resolved)
  #   OR EXIT Type, "msg"          — type + msg
  OrExit         = Struct.new(:token, :kind, :error_name, :message) { include Locatable }
  OrPass         = Struct.new(:token) { include Locatable }  # OR PASS - ignore error, use undefined
  OrPrune        = Struct.new(:token) { include Locatable }  # OR PRUNE - discard error, skip item (concurrent only)
  OrBreak        = Struct.new(:token) { include Locatable }  # OR BREAK - error-to-break coercion in loops
  # CATCH block: error handler at function bottom. Multiple CATCH clauses + optional DEFAULT.
  # catch_clauses: [{ error_name: String|nil, with_msg: String|nil, body: [ASTNode] }]
  # default_body: [ASTNode] or nil
  CatchBlock     = Struct.new(:token, :catch_clauses, :default_body) { include Locatable }
  # RECOVER(default): pipeline operator that replaces errors with a default value.
  RecoverOp      = Struct.new(:token, :default_expr) { include Locatable }

  # BlockExpr: sequence of statements that produces a value.
  # Used by pipeline rewriter to express loops-that-return-a-value.
  # Transpiles to Zig labeled block: blk: { stmts; break :blk result; }
  # body: Array of statement AST nodes
  # result: AST node whose value is the block's result
  BlockExpr      = Struct.new(:token, :body, :result) { include Locatable }

  # StringConcat: flattened string concatenation.
  # parts: Array of AST nodes (strings, identifiers, expressions)
  # Rewritten from chained BinaryOp(:ADD) on string types.
  # Any backend emits a single allocation covering all parts.
  StringConcat   = Struct.new(:token, :parts) do
    include Locatable
    attr_accessor :storage  # :heap when carry-var concat promoted to heap (stamped by Phase 1.5c)
  end

  # CapabilityWrap: single AST node for all capability wrapping.
  # ownership: nil | :multiowned | :shared
  # sync:      nil | :locked | :write_locked | :local
  # layout:    nil | :indirect
  CapabilityWrap    = Struct.new(:token, :value, :ownership, :sync, :layout) do
    include Locatable
    # Optional integer rank on @locked(rank: N) / @writeLocked(rank: N).
    # Used by Phase 3 to prove LockCycle freedom: when all participating
    # locks are ranked, acquiring any lock requires the new rank to be
    # strictly greater than every held rank, which makes cycles
    # structurally unrepresentable.
    attr_accessor :lock_rank
  end
  MoveNode          = Struct.new(:token, :value) { include Locatable }  # MOVE expr               -> transfer Rc/Arc handle without retain
  CopyNode          = Struct.new(:token, :value) { include Locatable; attr_accessor :deep_copy }  # COPY expr -> explicit deep-copy; deep_copy: true for unions with heap variants
  CloneNode         = Struct.new(:token, :value) { include Locatable }  # CLONE expr              -> explicit handle retain for non-affine replay/shared futures
  ShareNode         = Struct.new(:token, :value) { include Locatable }  # SHARE expr              -> promote/retain as T@shared (semantic lowering follows)
  LinkNode          = Struct.new(:token, :value) { include Locatable }  # LINK expr               -> downgrade Rc/Arc to WeakRc/WeakArc
  ResolveNode       = Struct.new(:token, :value) { include Locatable }  # RESOLVE expr            -> upgrade WeakRc/WeakArc to ?Rc/?Arc
  FreezeNode        = Struct.new(:token, :value) { include Locatable }  # FREEZE expr             -> compact @multiowned tree into contiguous buffer
  # PassStmt: no-op statement (like Python's `pass`).
  PassStmt          = Struct.new(:token) { include Locatable }
  # StructPattern: destructuring pattern for MATCH.
  # fields: Array of { name: String, value: ASTNode | :wildcard }
  # partial: Boolean — true when `...` is present (remaining fields ignored)
  StructPattern     = Struct.new(:token, :fields, :partial) do
    extend T::Sig
    include Locatable

    def initialize(*args)
      super
      self[:fields] = [] if self[:fields].nil?
    end

    sig { params(val: T::Array[AST::PatternField]).void }
    def fields=(val)
      self[:fields] = val
    end
  end
  # RangeLit: a range expression (start..<end) or (start..<=end).
  # inclusive: false = exclusive end (..<), true = inclusive end (..<=)
  RangeLit          = Struct.new(:token, :start, :finish, :inclusive) { include Locatable }
  # ExternFnDecl: EXTERN FN name<T>(params) RETURNS type [EFFECTS :alloc] FROM "module"
  # Or method:    EXTERN FN TypeName<T>.method(params) RETURNS type FROM "module"
  # Declares a native Zig/C function importable via @import("module").
  ExternFnDecl     = Struct.new(:token, :name, :params, :return_type, :from_module, :effects) do
    include Locatable
    attr_accessor :owner_type        # "TypeName" for method declarations (nil for free functions)
    attr_accessor :owner_type_params # [:T, :U] for TypeName<T, U>.method
    attr_accessor :fn_type_params    # [:T] for fnName<T>(...)

    # Same params seam as FunctionDef/LambdaLit: always Array<AST::Param>.
    def initialize(*)
      super
      self[:params] = self[:params] || []
    end

    def params=(val)
      self[:params] = val || []
    end
  end
  # ExternStructDecl: EXTERN STRUCT Name { fields } [CLOSE "method"] FROM "module"
  # Declares a native Zig/C struct type for CLEAR type-checking purposes.
  # CLOSE registers the type as a resource with auto-defer cleanup (RAII).
  ExternStructDecl = Struct.new(:token, :name, :fields, :from_module) {
    include Locatable
    attr_accessor :type_params   # [:T, :U] for EXTERN STRUCT Name<T, U>
    attr_accessor :close_method  # "deinit" for CLOSE "deinit" — auto-defer on scope exit
    attr_accessor :as_type       # "Parsed(JsonRecord)" for AS "ZigTypeExpr" — parameterized alias
  }
  # EnumDef: ENUM Name { Variant1, Variant2, ... }
  # Declares a Zig enum type. variants is an Array of variant name strings.
  EnumDef          = Struct.new(:token, :name, :variants, :visibility) { include Locatable }
  # UnionDef: UNION Name { Variant1: Type, Variant2: Type, UnitVariant }
  # Declares a Zig tagged union (union(enum)). variants is a Hash of
  # { "VariantName" => value } where value is:
  #   nil                                          — unit variant (void payload)
  #   Type object                                  — single-type payload (existing)
  #   { kind: :inline_struct, fields: { "f" => Type } } — inline struct payload (new)
  # methods (optional): Array of { token:, name:, params: [{name:, type:},...], return_type: }
  #   — compile-time constraints verified after function registration.
  UnionDef         = Struct.new(:token, :name, :variants, :visibility) do
    include Locatable
    attr_accessor :type_params   # Array of type param name strings, e.g. ["T"], or nil
    attr_accessor :methods       # Array of method requirement hashes, or nil
  end

  # UnionVariantLit: TypeName.VariantName{ field: val, ... }
  # Constructs an inline-struct variant of a union type.
  # union_name: String (e.g., "Shape"), variant_name: String (e.g., "Circle")
  # fields: Hash<String, ASTNode>
  UnionVariantLit  = Struct.new(:token, :union_name, :variant_name, :fields, :storage) { include Locatable }

  # StaticCall: TypeName::method(args) — type-level static method call.
  # type_name: AST::Identifier (the type), method_name: String, args: Array of ASTNode
  StaticCall        = Struct.new(:token, :type_name, :method_name, :args) { include Locatable }

  # DoBlock: fork-join parallel execution.
  # branches: Array of { body: Array<ASTNode>, pinned: Boolean, stack_size: :standard | :micro | :large | :xl | nil }
  # pinned=true      → dispatch to least-loaded scheduler (spawnBest) instead of current (submitSpawn)
  # stack_size nil   → defaults to :standard (16 KB total: 12 KB stack + 4 KB arena)
  DoBlock           = Struct.new(:token, :branches) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T.untyped]) }
    def child_bodies = branches.filter_map { |b| b[:body] }
  end

  # BgBlock: background execution — spawns a fiber and returns a linear Promise (~T).
  # body: Array of expression nodes. The last expression's type determines T.
  # Captured affine variables are MOVED into the fiber (not borrowed by pointer).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgBlock           = Struct.new(:token, :body, :deferred_drops, :stack_size, :pinned, :parallel, :arena_mode, :can_smash) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact
    attr_accessor :return_provenance # :heap when BG body calls a returns_promoted function
    attr_accessor :computed_stack_tier  # auto-computed tier from call-graph analysis (:micro, :standard, :large, :xl)
    attr_accessor :captures_resource  # true when BG captures a TCP/resource fd — spawn on accepting scheduler
    attr_accessor :capture_analysis  # CaptureAnalysis: captures, strategies, derived sets, safety flags
    attr_accessor :exit_promote  # Hash { strategy: :string_dupe } when exit value needs scope-exit promotion
    attr_accessor :capture_string_dupes  # Set of capture names that need heap-dupe inside the BG run fn
    # FSM Phase A: spawn_form = :fsm or :stackful. Chosen by FsmClassifier based
    # on the BG body's transitive call set. Phase A only records this; Phase B
    # will use it to emit spawnFsmBest / spawnFsmOn instead of spawnBest.
    attr_accessor :spawn_form
    attr_accessor :fsm_ineligible_reason
    attr_accessor :fsm_suspend_points
    # Phase 4g: tokens that drive `clear fix` for stack-tier sigil
    # rewrites. open_brace_token = `{` (insert @service -> after);
    # prefix_token = the user's existing tier sigil (replace).
    # can_smash_token = the `@canSmash` sigil token specifically
    # (drives the @canSmash -> @service auto-fix).
    attr_accessor :open_brace_token, :prefix_token, :can_smash_token
  end

  # ThenChain: sequential chaining of steps inside a BG block fiber.
  # steps: Array of { expr: ASTNode, binding: String | nil }
  # Each step may bind its result to a name for use in subsequent steps.
  # The last step's type determines the ThenChain's full_type.
  ThenChain         = Struct.new(:token, :steps) { include Locatable }

  # BgStreamBlock: background generator — spawns a fiber that YIELDs values into a Stream.
  # body: Array of statements; YIELD expressions push values. Returns ~T[?] (open stream).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgStreamBlock     = Struct.new(:token, :body, :deferred_drops, :stack_size) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact
    attr_accessor :computed_stack_tier
    attr_accessor :capture_analysis  # CaptureAnalysis with captures hash
    attr_accessor :capture_string_dupes  # Set of capture names that need heap-dupe inside the stream run fn
    attr_accessor :yields_frame_strings  # true when any YIELD expr is a frame string (NEXT caller owns the duped copy)
    # FSM Phase A: set by FsmClassifier (see effects.rb).
    attr_accessor :spawn_form
    attr_accessor :fsm_ineligible_reason
    attr_accessor :fsm_suspend_points
  end

  # YieldExpr: push a value into the enclosing BG STREAM's buffer.
  # Only valid inside a BgStreamBlock body. expr: the value to yield.
  YieldExpr         = Struct.new(:token, :expr) do
    include Locatable
    attr_accessor :yield_dupe  # true when the yielded value must be heap-duped before push (frame string)
  end

  # NextExpr: consume a Promise (~T), blocking the current fiber until the result is ready.
  # expr: the ~T expression to wait on (must be a tense type). Marks the promise as moved.
  NextExpr          = Struct.new(:token, :expr) do
    include Locatable
  end

  # MatchStatement: pattern-matching on a value.
  # cases: Array of { value: ASTNode, body: [ASTNode] }
  # default_case: [ASTNode] or nil
  # case_drops: Array of drop-arrays (parallel to cases), filled by annotator
  # default_drops: drop-array for default branch (or nil), filled by annotator
  MatchStatement    = Struct.new(:token, :expr, :cases, :default_case, :case_drops, :default_drops, :exhaustive, :takes) do
    extend T::Sig
    include Locatable
    include HasBodies

    def initialize(*args)
      super
      self[:cases] = [] if self[:cases].nil?
    end

    sig { params(val: T::Array[AST::MatchCase]).void }
    def cases=(val)
      self[:cases] = val
    end

    sig { returns(T::Array[T.untyped]) }
    def child_bodies
      bodies = cases.map(&:body)
      bodies << default_case if default_case
      bodies
    end
    attr_accessor :string_match       # set by annotator: true when expr is string type (use strEql)
    attr_accessor :expr_mode          # true when used as an expression (x = MATCH ...)
    attr_accessor :case_result_types  # Array of Types (parallel to cases), for expression-MATCH
    attr_accessor :default_result_type # Type of last value expression in default_case
  end

  # ForRange: FOR var IN (start ..= end) DO body END
  # inclusive: true = ..= (start to end), false = ..< (start to end-1)
  ForRange          = Struct.new(:token, :var_name, :start_expr, :end_expr, :inclusive, :body, :deferred_drops, :mark_per_iter) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact
    attr_accessor :tight
  end

  # ForEach: FOR var IN collection DO body END
  ForEach           = Struct.new(:token, :var_name, :collection, :body, :deferred_drops, :is_mutable) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[T::Array[T.untyped]]) }
    def child_bodies = [body].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight
  end

  # ── Test Framework ───────────────────────────────────────────────

  # TEST name DO setup... WHEN... END
  TestBlock = Struct.new(:token, :name, :setup, :whens) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T.untyped]) }
    def child_bodies
      bodies = []
      bodies << setup if setup
      (before_each || []).each { |b| bodies << b }
      (after_each  || []).each { |b| bodies << b }
      (before_all  || []).each { |b| bodies << b }
      (after_all   || []).each { |b| bodies << b }
      (whens || []).each do |w|
        bodies << w.setup if w.setup
        (w.tests || []).each { |t| bodies << t.body if t.body }
      end
      bodies
    end
    # Hook bodies. Each is an Array of statement Arrays (multiple
    # `BEFORE EACH DO ... END` blocks at the same level run in
    # declaration order). TestLowering composes outer (TEST-level)
    # hooks around the inner (WHEN-level) ones around each TEST THAT.
    #
    # `before_all` / `after_all` lower to dedicated Zig `test` blocks
    # that run before / after the rest of the suite (Zig executes tests
    # in declaration order). Each ALL block has its own runtime; state
    # propagation to TEST THATs requires file-scope vars and is not
    # yet supported in v1.
    attr_accessor :before_each, :after_each, :before_all, :after_all
    # LET fixtures (Array of AST::LetBinding) declared at the TEST
    # level. Lowered as auto-injected declarations at the top of every
    # TEST THAT body. Inheritable: WHEN-level LETs override by name.
    attr_accessor :lets
  end

  # WHEN "description" DO setup... TEST THAT... BENCHMARK... END
  WhenBlock = Struct.new(:token, :description, :setup, :tests, :benchmarks) do
    include Locatable
    attr_accessor :before_each, :after_each, :before_all, :after_all
    attr_accessor :lets
    # Tags declared on the WHEN via `WHEN "..." TAGS [tag1, tag2] DO ...`.
    # Array of bare-identifier strings; every TEST THAT inside this WHEN
    # inherits these tags. Lowered as `#tag` suffixes on the emitted Zig
    # test name so `clear test --tag slow` can use Zig's --test-filter.
    attr_accessor :tags
  end

  # LET <name> = <expr>;  — fixture declaration valid inside TEST or
  # WHEN bodies. Lowering injects a fresh evaluation of <expr> at the
  # top of every TEST THAT in the enclosing block, so each test sees
  # an independent value. WHEN-level LETs override TEST-level LETs of
  # the same name (the inner declaration wins).
  LetBinding = Struct.new(:token, :name, :expr) { include Locatable }

  # TEST THAT "description" DO body... END
  TestThat = Struct.new(:token, :description, :body) do
    include Locatable
    attr_accessor :synthetic_fn # AST::FunctionDef wrapper synthesized by
                                # CompilerFrontend.synthesize_test_body_wrappers!
                                # so MIRPass treats the test body the same as
                                # a regular FN body. mir_lowering reads
                                # synthetic_fn.cleanup_bindings to scope its
                                # @current_bindings while walking the body.
    attr_accessor :pending      # true when declared `PENDING TEST THAT ...`.
                                # The MIR lowering prepends
                                # `return error.SkipZigTest;` to the body so
                                # Zig's runner reports the test as skipped
                                # rather than passing or failing.
  end

  # ASSERT_RAISES Kind, expr  OR  ASSERT_RAISES Kind, ErrorName, expr
  AssertRaises = Struct.new(:token, :kind, :error_name, :expression) { include Locatable }

  # BENCHMARK expr x<N>
  BenchmarkStmt = Struct.new(:token, :expression, :iterations) { include Locatable }

  # SMASH expr
  SmashStmt = Struct.new(:token, :expression) { include Locatable }

  # PROFILE expr
  ProfileStmt = Struct.new(:token, :expression) { include Locatable }

  # STUB fn RETURNS value | STUB fn CAPTURES var | STUB fn SEQUENCE [...] | STUB fn WITH lambda
  StubDecl = Struct.new(:token, :function_name, :kind, :value) { include Locatable }
  # kind: :returns, :captures, :sequence, :with

  UNARY_OPS = ['-', '!', '~']

  PRIMITIVE_TYPES = [:Number, :Bool, :Byte, :Int64, :Float64,
                     :Int8, :Int16, :Int32,
                     :UInt8, :UInt16, :UInt32, :UInt64,
                     :Float32]

  PRECEDENCE_MAP = T.let({
    8 => { ops: ['**'], assoc: :right },
    7 => { ops: ['*', '/', 'MOD'], assoc: :left },
    6 => { ops: ['+', '-'], assoc: :left },
    5 => { ops: ['==', '!=', '<', '>', '<=', '>='], assoc: :left },
    4 => { ops: ['&&'], assoc: :left },
    3 => { ops: ['||'], assoc: :left },
    # LEVEL 1: Both Pipe and Rescue live here.
    # They bind loosely and strictly left-to-right.
    1 => { ops: ['OR', '|>', 'AS'], assoc: :left }
  }, T::Hash[T.untyped, T.untyped])
  MAX_PRECEDENCE = T.let(PRECEDENCE_MAP.keys.max, Integer)

  OP_CODE_SENDABLE_SYMS = T.let({
    :SUB => :-,
    :MUL => :*,
    :DIV => :/,
    :POW => :**,
    :MOD => :%,
    :EQ => :==,
    :NEQ => :!=,
    :LT => :<,
    :GT => :>,
    :LTE => :<=,
    :GTE => :>=,
    :BITWISE_NOT => :~,
  }, T::Hash[T.untyped, T.untyped])

  # Canonical definitions are in Type class. These aliases maintain backward compat.
  NUMBER_RESULT_OPS = Type::NUMBER_RESULT_OPS
  BOOL_RESULT_OPS = Type::BOOL_RESULT_OPS

  OP_TO_OP_CODE = T.let({
    '+' => :ADD,
    '-' => :SUB,
    '*' => :MUL,
    '/' => :DIV,
    '**' => :POW,
    '==' => :EQ,
    '!=' => :NEQ,
    '<'  => :LT,
    '<=' => :LTE,
    '>'  => :GT,
    '>=' => :GTE,
    '!' => :NOT,
    '&&' => :AND,
    '||' => :OR,
    'MOD' => :MOD,
    'OR' => :OR_RESCUE,
    '~' => :BITWISE_NOT,
    'AS' => :BIND_VAR,
    '%+' => :WRAP_ADD,
    '%-' => :WRAP_SUB,
    '%*' => :WRAP_MUL,
    '!+' => :CHECK_ADD,
    '!-' => :CHECK_SUB,
    '!*' => :CHECK_MUL,
  }, T::Hash[T.untyped, T.untyped])

  CAPABILITIES = [:RESTRICT, :EXCLUSIVE, :BORROWED, :VIEW, :MATERIALIZED_VIEW, :SNAPSHOT]
end

# ==========================================
# MIR — Mid-level IR nodes
# ==========================================
# Inserted into AST statement lists by the MIR pass (future Phase 3).
# The transpiler handles these alongside AST nodes via `when MIR::Drop`, etc.
# Each node carries pre-computed decisions so the transpiler is purely mechanical.
module MIR
  # Drop: cleanup instruction inserted after variable declarations or before
  # field overwrites. Emits Zig `defer` cleanup code (or inline cleanup for
  # field pre-cleanup). Replaces CleanupClassifier lookups in transpiler.
  #
  # kind:              cleanup template symbol (matches emit_cleanup_from_entry cases):
  #                    :resource, :list, :list_with_elem_cleanup, :string_map, :numeric_map,
  #                    :pool, :set, :rc, :locked, :write_locked, :heap_string, :heap_slice,
  #                    :heap_union, :heap_struct, :heap_struct_plain, :struct_with_cleanup_fields,
  #                    :struct_rc, :array_with_struct_strings, :non_copy_union, :takes_union,
  #                    :takes_string, :takes_slice
  # alloc:             :heap or :frame — which allocator owns this value
  # has_moved_guard:   boolean — emit `var x_moved = false; defer if (!x_moved) ...`
  # resource_close_zig: string template for :resource kind (e.g. "{0}.deinit()")
  Drop = Struct.new(:token, :name, :kind, :alloc, :has_moved_guard, :type_info,
                     :resource_close_zig, :source_node) do
    extend T::Sig
    include AST::Locatable
    attr_accessor :cleanup_entry  # full classifier hash with pre-computed RC fields
    sig { returns(TrueClass) }
    def needs_cleanup; true; end
    # Carrier struct: the type lives in the :type_info member, NOT
    # Locatable's @type_object. Override Locatable so the canonical
    # full_type accessor reads/writes the member (member name kept).
    def full_type; type_info; end
    def full_type=(val); self.type_info = val; end
  end

  # Promote: escape promotion inserted before return statements.
  # Emits frame->heap copy/promotion code. Replaces PromotionClassifier lookups in transpiler.
  #
  # strategy:  :list     — promoteList (dupe backing buffer to heap; elem_type required)
  #            :string_map — swap allocator to heapAlloc
  #            :fields   — promoteFields (recursive field promotion)
  #            :generic  — promote (single value deep copy)
  Promote = Struct.new(:token, :name, :zig_type, :strategy, :fields, :elem_type) do
    include AST::Locatable
    # fields: Set of field names for :fields strategy (nil = all fields)
    # elem_type: Zig element type for :list promotion.
  end

  # SuppressCleanup: move suppression marker inserted at consumption points
  # (TAKES calls, GIVE, return escapes). Emits `x_moved = true;` to prevent
  # double-free via the defer guard emitted by Drop.
  SuppressCleanup = Struct.new(:token, :name) do
    include AST::Locatable
  end

  # Alloc: marks an allocation point - a variable binding that owns a resource
  # and will need cleanup. Inserted alongside MIR::Drop for each VarDecl/BindExpr
  # with cleanup. The StaticLeakChecker verifies every Alloc has exactly one
  # Drop or Move/Escape on every path through the function.
  #
  # kind:  cleanup template symbol (same as Drop - :list, :string_map, etc.)
  # alloc: :heap or :frame - which allocator owns this value
  Alloc = Struct.new(:token, :name, :kind, :alloc) do
    include AST::Locatable
  end

  # Return: marks function exit where local variable ownership transfers to
  # the caller. Inserted before ReturnNode. The checker uses this to know
  # that escaped variables don't need local cleanup (caller takes ownership).
  #
  # escaped_vars: [String] variable names whose ownership escapes via return
  Return = Struct.new(:token, :escaped_vars) do
    include AST::Locatable
  end

  # ReassignCleanup: verification marker for mutable variable reassignment.
  # Inserted after BindExpr :assign nodes where the old value needs cleanup
  # before overwrite. The checker verifies these exist for all reassignment
  # sites on cleanup-needing bindings.
  ReassignCleanup = Struct.new(:token, :name, :alloc) do
    include AST::Locatable
  end

  # FieldCleanup: verification marker for field overwrite pre-cleanup.
  # Inserted after Assignment nodes where a GetField target holds a
  # cleanup-needing value that must be freed before overwrite.
  FieldCleanup = Struct.new(:token, :target_name, :field, :alloc) do
    include AST::Locatable
  end
end
