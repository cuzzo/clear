# typed: strict
# ruby-to-clear: data-only
require "sorbet-runtime"

require_relative "param"
require_relative "struct_field"
require_relative "type"
require_relative "schemas"
require_relative "lexer"
require_relative "function_signature_forward"

# ==========================================
# AST
# ==========================================
module AST
  extend T::Sig

  # Load-order-safe protocol for capture analyses attached to fiber-like AST
  # nodes. CapabilityHelper defines the concrete record after the AST loads.
  module CaptureAnalysisValue
  end

  # Load-order-safe protocol for immutable tense plans attached by annotation
  # and consumed by MIR. The concrete planner lives outside the syntax layer.
  module TensePlanValue
  end

  RawBody = T.type_alias { T::Array[AST::Node] }
  HashLitPairs = T.type_alias { T::Hash[AST::Node, AST::Node] }
  BgNode = T.type_alias { T.any(AST::BgBlock, AST::BgStreamBlock) }
  BindingNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr, AST::DestructureTarget) }
  ScalarLiteralCandidate = T.type_alias do
    T.nilable(T.any(AST::Node, RawBody, Struct, Type, String, Symbol, Numeric, TrueClass, FalseClass))
  end

  class BodySlot
    extend T::Sig

    sig { returns(AST::RawBody) }
    attr_reader :body

    sig { params(body: AST::RawBody, writer: T.proc.params(body: AST::RawBody).void).void }
    def initialize(body, writer)
      @body = T.let(body, AST::RawBody)
      @writer = T.let(writer, T.proc.params(body: AST::RawBody).void)
    end

    sig { params(body: AST::RawBody).void }
    def replace(body)
      @body = body
      writer = @writer
      writer.call(body)
    end
  end

  SyntheticTypeInput = T.type_alias { T.any(Type, Symbol, String, FunctionSignature) }
  CoerceTypeInput = T.type_alias { T.nilable(T.any(Type::TypeInput, FunctionSignature)) }
  CoerceResult = T.type_alias { [CoerceTypeInput, T.nilable(String)] }
  InitArgs = T.type_alias { T.untyped }
  SchemaLookup = T.type_alias { T.proc.params(type_name: T.any(String, Symbol)).returns(T.untyped) }
  PrecedenceInfo = T.type_alias { T::Hash[Symbol, T.any(Symbol, T::Array[String])] }
  LambdaBody = T.type_alias { T.any(AST::Node, RawBody) }
  class CollectionConstructorFact < T::Struct
    const :collection, Symbol
    const :soa, T::Boolean, default: false
    const :shard_count, T.nilable(Integer), default: nil
  end

  # Source span for an EFFECTS clause. This remains attached to the function
  # so diagnostics can replace the original clause precisely.
  class EffectSpan < T::Struct
    const :start_token, Lexer::Token
    const :end_token, Lexer::Token
  end


  # Immutable half-open source range retained by syntax nodes. Offsets are
  # absolute bytes within +file+; line/column coordinates are one-based.
  class SourceRange < T::Struct
    const :file, T.nilable(String), default: nil
    const :start_offset, Integer
    const :end_offset, Integer
    const :start_line, Integer
    const :start_column, Integer
    const :end_line, Integer
    const :end_column, Integer
  end

  sig { params(node: AST::Locatable, value: SyntheticTypeInput, context: String).returns(Type) }
  def self.stamp_synthetic_type!(node, value, context:)
    node.full_type = value
    stamped = node.full_type!(context: context)
    raise "#{context}: synthetic type stamp produced :Untyped for #{node.class}" if stamped.untyped?

    stamped
  end

  sig do
    params(
      src: AST::Locatable,
      dst: AST::Locatable,
      include_call_metadata: T::Boolean,
    ).returns(AST::Locatable)
  end
  def self.copy_pipeline_rewrite_metadata!(src, dst, include_call_metadata: false)
    src.full_type!(context: "pipeline rewrite type copy")
    copy_pipeline_base_metadata!(src, dst)
    copy_pipeline_call_metadata!(src, dst) if include_call_metadata
    dst
  end

  sig { params(src: AST::Locatable, dst: AST::Locatable).void }
  def self.copy_pipeline_base_metadata!(src, dst)
    dst.full_type = src.full_type
    dst.coerced_type = src.coerced_type_object if src.coerced_type_object
    dst.storage = src.storage_override if src.storage_override
    dst.var_used = src.var_used unless src.var_used.nil?
    dst.slot_size = src.slot_size unless src.slot_size.nil?
    dst.container_borrow = src.container_borrow unless src.container_borrow.nil?
    dst.tense_plan = T.must(src.tense_plan) if src.tense_plan
    if src.respond_to?(:retain_error_channel) && dst.respond_to?(:retain_error_channel=)
      retained = T.unsafe(src).retain_error_channel
      T.unsafe(dst).retain_error_channel = retained unless retained.nil?
    end
  end
  private_class_method :copy_pipeline_base_metadata!

  sig { params(src: AST::Locatable, dst: AST::Locatable).void }
  def self.copy_pipeline_call_metadata!(src, dst)
    dst.zig_pattern = src.zig_pattern if src.zig_pattern
    dst.matched_stdlib_def = src.matched_stdlib_def if src.matched_stdlib_def
    dst.matched_signature = src.matched_signature if src.matched_signature
    dst.stdlib_allocates = src.stdlib_allocates unless src.stdlib_allocates.nil?
    dst.mutates_receiver = src.mutates_receiver unless src.mutates_receiver.nil?
    dst.implicit_layout_cost = src.implicit_layout_cost unless src.implicit_layout_cost.nil?
    dst.layout_transport = src.layout_transport unless src.layout_transport.nil?
    dst.can_fail = src.can_fail unless src.can_fail.nil?
    dst.error_kind = src.error_kind if src.error_kind
    dst.error_type = src.error_type if src.error_type
  end
  private_class_method :copy_pipeline_call_metadata!

  # A node's value-type is, for these kinds, a pure function of its
  # structure — so it is DERIVED, never stamped. The full_type getter
  # below memoizes the derived Type into @type_object; the pre-MIR
  # invariant walk (which calls .full_type on every node) materializes
  # it, so type_info / resolved_type work downstream with no extra
  # code. An annotator-set value always wins (`||=`).
  LITERAL_VALUE_TYPE = T.let({
    STRING: :String, NUMBER: :Number, FLOAT64: :Float64,
    INT64: :Int64, BOOLEAN: :Bool, SYMBOL: :Symbol, NIL: :NIL
  }.freeze, T::Hash[Symbol, Symbol])
  BOOL_BINOPS = %i[LT GT LTE GTE EQ NEQ AND OR].freeze
  # Statements / control-flow evaluate to Void unless the annotator
  # promoted them to an expression (IF/MATCH as a value), in which
  # case @type_object is already set and wins.
  module StatementVoidType
    extend T::Sig
    sig { returns(Type) }
    def full_type
      @type_object = T.let(@type_object, T.nilable(Type))
      @type_object ||= Type.new(:Void)
    end
  end

  Capture = Struct.new(:name, :type, :default, :mutable, :takes,
                       :comptime, :name_token, :storage,
                       keyword_init: true) do
    extend T::Sig

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      # mutable/takes/comptime arrive from match! (a Token when the
      # keyword is present, nil/false otherwise) -- normalize to Bool.
      self[:mutable]  = !!self[:mutable]
      self[:takes]    = !!self[:takes]
      self[:comptime] = !!self[:comptime]
      t = self[:type]
      self[:type] = Type.new(t || :Any)
    end

    sig { returns(String) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def name; self[:name]; end

    sig { returns(Type) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def type; self[:type]; end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def type=(val)
      self[:type] = Type.new(val || :Any)
    end

    sig { returns(T.nilable(AST::Locatable)) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def default; self[:default]; end

    sig { returns(T::Boolean) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def mutable; self[:mutable]; end

    sig { returns(T::Boolean) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def takes; self[:takes]; end

    sig { returns(T::Boolean) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def comptime; self[:comptime]; end

    sig { returns(T.nilable(Lexer::Token)) }
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    def name_token; self[:name_token]; end

    sig { returns(T.nilable(Symbol)) }
    def storage; self[:storage]; end

    sig { params(val: T.nilable(Symbol)).void }
    def storage=(val); self[:storage] = val; end
  end

  MatchCase = Struct.new(:kind, :value, :body, :binding, :destructure, :extra_values,
                         :indirect_payload_as,
                         keyword_init: true) do
    extend T::Sig
    # ruby-to-clear: field-type value=Node
    # ruby-to-clear: field-type body=Node[]
    # ruby-to-clear: field-type extra_values=Node[]

    sig { params(kw: StructKwargs).void }
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

  Binding = Struct.new(:expr, :name, :name_token, :unwrapped_type, :symbol, :capture, :predicate,
                       keyword_init: true) do
    extend T::Sig
    attr_accessor :mir_binding_entry
    # ruby-to-clear: field-type expr=Node

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      self[:unwrapped_type] = Type.new(:Untyped) if self[:unwrapped_type].nil?
      self[:predicate] = :exists if self[:predicate].nil?
    end

    sig { returns(AST::Locatable) }
    def expr
      self[:expr]
    end

    sig { returns(String) }
    def name
      self[:name]
    end

    sig { returns(T.nilable(Lexer::Token)) }
    def name_token
      self[:name_token]
    end

    sig { returns(Type) }
    def unwrapped_type
      self[:unwrapped_type]
    end

    sig { params(val: Type).void }
    def unwrapped_type=(val)
      self[:unwrapped_type] = val
    end

    sig { returns(T.nilable(SymbolEntry)) }
    def symbol
      self[:symbol]
    end

    sig { params(val: T.nilable(SymbolEntry)).void }
    def symbol=(val)
      self[:symbol] = val
    end

    sig { returns(T.nilable(String)) }
    def capture
      self[:capture]
    end

    sig { returns(Symbol) }
    def predicate
      self[:predicate]
    end

  end

  Capability = Struct.new(:capability, :var_node, :alias, :alias_mutable, :guard_expr,
                          :snapshot_token, :view_token, :view_length, :as_token,
                          :resolved_type, :old_scope,
                          keyword_init: true) do
    extend T::Sig

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      self[:resolved_type] = Type.new(:Untyped) if self[:resolved_type].nil?
    end

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
  PatternFieldValue = T.type_alias { T.any(Symbol, AST::Node) }

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

    sig { returns(T.nilable(Lexer::Token)) }
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
  sig { params(body: T.nilable(T.any(AST::Node, T::Array[AST::Node])), visitor: T.proc.params(node: AST::Node).void).void }
  def self.walk_body(body, &visitor)
    return unless body
    Array(body).each do |node|
      yield node
      next unless node.is_a?(HasBodies)
      node.child_bodies.each { |b| walk_body(b, &visitor) }
    end
  end

  # Walk every AST Locatable reachable from a root object. This is the
  # structural expression+statement walker; semantic walkers should layer
  # their own filtering on top instead of re-open-coding Struct member scans.
  sig { params(root: BasicObject, descend_functions: T::Boolean, visitor: T.proc.params(node: Locatable).void).void }
  def self.each_locatable(root, descend_functions: false, &visitor)
    raw_root = T.unsafe(root)
    stack = raw_root.is_a?(Array) ? raw_root.reverse : [raw_root]
    until stack.empty?
      node = T.unsafe(stack.pop)
      next unless node
      if node.is_a?(Array)
        node.reverse_each { |child| stack << child }
        next
      end
      if node.is_a?(Hash)
        node.to_a.reverse_each do |key, value|
          stack << value
          stack << key
        end
        next
      end
      yield node if node.is_a?(Locatable)
      next if node.is_a?(FunctionDef) && !descend_functions
      next unless node.is_a?(Struct)

      node.class.members.reverse_each do |member|
        value = node[member]
        case value
        when Array, Hash, Struct
          stack << value
        end
      end
    end
  end

  # Walk a GetField/GetIndex access chain down to the root Identifier it
  # is anchored at; nil if the chain does not bottom out at an Identifier.
  #
  # Single source of truth for "what variable does this lvalue/access
  # chain ultimately name". Before this, escape analysis, IF-AS source
  # resolution, capability source naming, and placeholder-root detection
  # each hand-rolled the same `case node; GetField/GetIndex -> .target`
  # recursion (decomplex Missing-Abstraction, scatter=7).
  sig { params(node: AST::Node).returns(T.nilable(AST::Identifier)) }
  def self.root_identifier(node)
    case node
    when AST::MutableBorrow             then root_identifier(node.target)
    when AST::GetField, AST::GetIndex then root_identifier(node.target)
    when AST::Identifier              then node
    end
  end

  # ruby-to-clear: skip
  sig { params(symbol: T.nilable(SymbolEntry)).returns(T.nilable(SymbolEntry)) }
  def self.declaration_symbol(symbol)
    return nil unless symbol
    decl = symbol.reg
    return nil unless decl.respond_to?(:symbol)

    decl.symbol
  end

  # Is this node a call expression (function or method)? The
  # `is_a?(AST::FuncCall) || is_a?(AST::MethodCall)` predicate-use was
  # recomputed inline across the MIR pipeline (decomplex
  # Missing-Abstraction). Syntactic `case ... when FuncCall, MethodCall`
  # dispatch arms are NOT this -- leave those.
  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Boolean) }
  def self.call?(node)
    node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.container_borrow?(node)
    return false unless node
    return true if node.respond_to?(:container_borrow) && T.unsafe(node).container_borrow == true
    operand = borrow_transparent_operand(node)
    return false unless operand

    container_borrow?(operand)
  end

  # Return the operand whose ownership is preserved by a syntax wrapper.
  # These nodes may change control flow or remove a tense, but they never
  # manufacture an owned value. Keeping the rule here prevents annotation,
  # cleanup classification, and lowering from independently guessing which
  # wrappers preserve borrow provenance.
  sig { params(node: AST::Node).returns(T.nilable(AST::Node)) }
  def self.borrow_transparent_operand(node)
    return node.target if node.is_a?(AST::OptionalUnwrap)
    return node.right if node.is_a?(AST::UnaryOp) && node.op == :TRY
    return node.left if node.is_a?(AST::BinaryOp) && (node.op == :OR || node.op == :OR_ELSE)

    nil
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.borrowed_ownership_view?(node)
    return false unless node
    return false if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)
    return true if node.is_a?(AST::Identifier) && node.symbol&.borrowed_alias
    return true if container_borrow?(node)
    return true if node.is_a?(AST::GetIndex)
    return false unless node.is_a?(AST::GetField)

    root = root_identifier(node)
    return false if root&.token&.type == :TYPE_ID

    sym = root&.symbol
    !!(sym && (sym.is_param || sym.reg))
  end

  # Whether a successful IF/WHILE optional capture receives a value that it
  # owns and must clean up. Keep this policy centralized: cleanup
  # classification and MIR lowering must agree or an RC capture is either
  # leaked (missing cleanup) or released out from under its source owner.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.capture_expr_owns_result?(node)
    return false unless node
    current = T.let(node, AST::Node)
    current = current.value while current.is_a?(AST::Cast)
    node = current
    return false if borrowed_ownership_view?(node)
    if call?(node) && node.respond_to?(:matched_signature)
      signature = T.unsafe(node).matched_signature
      return false if signature&.respond_to?(:return_lifetime) && !signature.return_lifetime.empty?
    end

    call?(node) || node.is_a?(AST::NextExpr) || node.is_a?(AST::ResolveNode) ||
      node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode) ||
      node.is_a?(AST::MoveNode) || node.is_a?(AST::ShareNode)
  end

  # IS_OK annotation exposes the successful payload as the expression's
  # regular type while retaining the fallible source type for capture logic.
  sig { params(node: AST::Node).returns(Type) }
  def self.capture_expr_source_type(node)
    fallible = node.respond_to?(:error_union_type) ? T.unsafe(node).error_union_type : nil
    fallible || Type.from_node!(node, context: "capture expression")
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.collection_method_call?(node)
    !!(node.is_a?(AST::MethodCall) &&
      (node.pool_method || node.set_method || node.map_method)
    )
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.empty_auto_collection_literal_decl?(node)
    return false unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return false unless node.type&.auto?
    value = node.value
    return false unless value.respond_to?(:type_object) && value.type_object

    !!((value.is_a?(AST::ListLit) && value.items.empty? &&
      !value.collection_constructor?) ||
      (value.is_a?(AST::HashLit) && value.pairs.empty?))
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.negative_integer_literal?(node)
    return false unless node.is_a?(AST::UnaryOp) && node.op == :SUB
    lit = node.right
    !!(lit.is_a?(AST::Literal) && (lit.type == :INT64 || lit.type == :PREFIXED_INT))
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.declaration_with_identifier_value?(node)
    return false unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return false if node.is_a?(AST::BindExpr) && node.mode != :decl

    node.value.is_a?(AST::Identifier)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.declaration_with_heap_symbol?(node)
    !!((node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) &&
      node.symbol&.storage == :heap)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.type_declaration?(node)
    node.is_a?(AST::StructDef) || node.is_a?(AST::ExternStructDecl) ||
      node.is_a?(AST::EnumDef) || node.is_a?(AST::UnionDef)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.top_level_declaration?(node)
    type_declaration?(node) || node.is_a?(AST::RequireNode) ||
      node.is_a?(AST::ExternFnDecl)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Boolean) }
  def self.statement_result_void?(node)
    node.is_a?(AST::ReturnNode) || node.is_a?(AST::VarDecl) ||
      node.is_a?(AST::BindExpr) || node.is_a?(AST::Assignment) ||
      node.is_a?(AST::DestructuringAssignment) ||
      node.is_a?(AST::WhileLoop) || node.is_a?(AST::ForRange) ||
      node.is_a?(AST::ForEach) || node.is_a?(AST::MatchStatement) ||
      node.is_a?(AST::Assert) || node.is_a?(AST::Raise) ||
      node.is_a?(AST::WithBlock) || node.is_a?(AST::BgBlock) ||
      node.is_a?(AST::DoBlock) || node.is_a?(AST::PassStmt) ||
      node.is_a?(AST::DieNode) || node.is_a?(AST::ThrowNode)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Boolean) }
  def self.ownership_transfer_stmt?(node)
    node.is_a?(AST::WhileLoop) || node.is_a?(AST::WhileBindLoop) ||
      node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach) ||
      node.is_a?(AST::IfStatement) || node.is_a?(AST::MatchStatement) ||
      node.is_a?(AST::WithBlock) || node.is_a?(AST::DoBlock)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.ownership_wrapper?(node)
    node.is_a?(AST::MoveNode) || node.is_a?(AST::CopyNode) ||
      node.is_a?(AST::CloneNode) || node.is_a?(AST::ShareNode) ||
      node.is_a?(AST::FreezeNode) || node.is_a?(AST::CapabilityWrap)
  end

  # TRY and UNWRAP change the control-flow/type channel around a value without
  # copying, moving, or relocating its successful payload. Analyses concerned
  # with allocator provenance or escape placement must therefore look through
  # these wrappers.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.recovery_wrapper?(node)
    (node.is_a?(AST::UnaryOp) && node.op == :TRY) ||
      node.is_a?(AST::OptionalUnwrap)
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def self.recovery_payload(node)
    return node.right if node.is_a?(AST::UnaryOp) && node.op == :TRY
    return node.target if node.is_a?(AST::OptionalUnwrap)

    node
  end

  sig { params(node: ScalarLiteralCandidate).returns(T::Boolean) }
  def self.scalar_literal_value?(node)
    node.is_a?(String) || node.is_a?(Symbol) || node.is_a?(Numeric) ||
      node.is_a?(TrueClass) || node.is_a?(FalseClass)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Boolean) }
  def self.call_like_boundary?(node)
    node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit) ||
      node.is_a?(AST::BgBlock) || node.is_a?(AST::BgStreamBlock) ||
      node.is_a?(AST::WithBlock) || node.is_a?(AST::DoBlock)
  end

  # ruby-to-clear: data-api
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.inline_union_constructor_target?(node)
    return false unless node.is_a?(AST::GetField)
    target = T.cast(node.target, AST::Node)
    return false unless target.is_a?(AST::Identifier)

    !!(target.name[0] =~ /[A-Z]/)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.soa_placeholder_field?(node)
    return false unless node.is_a?(AST::GetField)
    target = node.target
    !!(target.is_a?(AST::Identifier) && target.name == "_")
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.soa_placeholder_assignment?(node)
    return false unless node.is_a?(AST::BindExpr) || node.is_a?(AST::Assignment)

    soa_placeholder_field?(node.name)
  end

  # Explicit ownership transfer marker stamped by annotation. This is a
  # predicate over the AST contract, not an ad hoc respond_to? check.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.moved?(node)
    !!(node && node.respond_to?(:was_moved) && node.was_moved == true)
  end

  # Statement-position body traversal is an AST fact. MIR passes may attach
  # loop-specific meaning to a body, but they should not maintain parallel
  # lists of every node shape that can contain one.
  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Boolean) }
  def self.loop_node?(node)
    node.is_a?(AST::WhileLoop) || node.is_a?(AST::WhileBindLoop) ||
      node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Struct))).returns(T::Array[RawBody]) }
  def self.child_bodies(node)
    node.is_a?(AST::HasBodies) ? node.child_bodies : []
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Array[BodySlot]) }
  def self.body_slots(node)
    slots = T.let([], T::Array[BodySlot])
    case node
    when IfStatement, IfBind
      slots << BodySlot.new(node.then_branch, ->(body) { node.then_branch = body }) if node.then_branch
      slots << BodySlot.new(node.else_branch, ->(body) { node.else_branch = body }) if node.else_branch && !node.else_branch.empty?
    when WhileLoop, WhileBindLoop
      slots << BodySlot.new(node.do_branch, ->(body) { node.do_branch = body }) if node.do_branch
    when ForRange, ForEach, BgBlock, BgStreamBlock
      slots << BodySlot.new(node.body, ->(body) { node.body = body }) if node.body
    when WithBlock
      slots << BodySlot.new(node.body, ->(body) { node.body = body }) if node.body
      node.arms&.each do |arm|
        slots << BodySlot.new(arm.body, ->(body) { arm.body = body })
      end
    when MatchStatement
      node.cases.each { |match_case| slots << BodySlot.new(match_case.body, ->(body) { match_case.body = body }) if match_case.body }
      slots << BodySlot.new(node.default_case, ->(body) { node.default_case = body }) if node.default_case
    when DoBlock
      node.branches.each do |branch|
        slots << BodySlot.new(branch.body, ->(body) { branch.body = body })
      end
    end
    slots
  end

  # Canonical recursion-yield policy: non-tight recursive functions that can
  # run arbitrarily long must thread rt so MIR can inject checkYield().
  sig { params(fn_node: AST::FunctionDef).returns(T::Boolean) }
  def self.recursion_yield_needed?(fn_node)
    return false if fn_node.tight_reentrance

    fn_node.reentrance_kind == :reentrant ||
      fn_node.reentrance_kind == :reentrant_tail_call ||
      fn_node.reentrance_kind == :reentrant_max_depth
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
  sig { params(expr: T.nilable(AST::Node)).returns(T::Array[AST::Node]) }
  def self.wrapped_children(expr)
    case expr
    when StructLit, UnionVariantLit
      (expr.fields&.values || []).compact
    when ListLit
      (expr.items || []).compact
    when Cast, MoveNode, CopyNode, CloneNode, ShareNode, LinkNode, ResolveNode,
         MutableBorrow,
         FreezeNode, CapabilityWrap
      child = expr.is_a?(MutableBorrow) ? expr.target : expr.value
      child ? [child] : []
    else
      []
    end
  end

  # Immediate expression children for semantic expression walks. This excludes
  # statement bodies; callers that need bodies should use child_bodies/walk_body.
  sig { params(node: T.nilable(T.any(AST::Node, Struct)), skip_copy: T::Boolean).returns(T::Array[AST::Node]) }
  def self.expression_children(node, skip_copy: false)
    return [] unless node

    case node
    when CopyNode, CloneNode, FreezeNode
      skip_copy ? [] : [node.value].compact
    when MoveNode, ShareNode, CapabilityWrap, Cast, MutableBorrow, ReturnNode, Assignment, VarDecl, BindExpr,
         DestructuringAssignment
      child = node.is_a?(MutableBorrow) ? node.target : node.value
      [child].compact
    when BinaryOp
      [node.left, node.right].compact
    when UnaryOp
      [node.right].compact
    when FuncCall, StaticCall
      node.args.compact
    when MethodCall
      children = T.let([node.object], T::Array[T.nilable(AST::Node)])
      children.concat(node.args)
      children.compact
    when GetField
      [node.target].compact
    when GetIndex
      [node.target, node.index].compact
    when StructLit, UnionVariantLit
      (node.fields&.values || []).compact
    when ListLit
      node.items.compact
    when HashLit
      hash_lit_pair_nodes(node.pairs)
    when Assert
      [node.condition].compact
    else
      []
    end
  end

  sig { params(pairs: HashLitPairs).returns(T::Array[AST::Node]) }
  def self.hash_lit_pair_nodes(pairs)
    nodes = T.let([], T::Array[AST::Node])
    pairs.each do |key, value|
      nodes << key if key.is_a?(AST::Locatable)
      nodes << value if value.is_a?(AST::Locatable)
    end
    nodes
  end

  # Yield every BgBlock / BgStreamBlock reachable from `body`, including
  # nested ones inside control flow (WHILE/MATCH/IF/FOR/WITH/DO),
  # expression positions (VarDecl.value, FuncCall.args), and inside
  # other BG bodies. Use this when classifying every BG in a function.
  # The single source of truth replacing the parallel walkers in
  # escape_analysis (e2_each_bg) and elsewhere.
  sig { params(body: T.nilable(T.any(AST::Node, T::Array[AST::Node])), block: T.proc.params(node: BgNode).void).void }
  def self.each_bg_block(body, &block)
    return unless body
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each { |n| bg_visit_recursive(n, &block) }
  end

  sig { params(node: T.nilable(AST::Node), block: T.proc.params(node: BgNode).void).void }
  def self.bg_visit_recursive(node, &block)
    if node.is_a?(BgBlock) || node.is_a?(BgStreamBlock)
      yield node
    end
    case node
    when HasBodies
      node.child_bodies.each { |b| each_bg_block(b, &block) }
    when VarDecl, BindExpr, Assignment, DestructuringAssignment, ReturnNode
      expr_each_bg_block_recursive(node.value, &block)
    when FuncCall
      node.args.each { |a| expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      expr_each_bg_block_recursive(node.object, &block)
      node.args.each { |a| expr_each_bg_block_recursive(a, &block) }
    end
  end

  sig { params(expr: T.nilable(AST::Node), block: T.proc.params(node: BgNode).void).void }
  def self.expr_each_bg_block_recursive(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      each_bg_block(expr.body, &block)
    when FuncCall
      expr.args.each { |a| expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      expr_each_bg_block_recursive(expr.object, &block)
      expr.args.each { |a| expr_each_bg_block_recursive(a, &block) }
    when StructLit, UnionVariantLit
      expr.fields.each_value { |v| expr_each_bg_block_recursive(v, &block) }
    when ListLit
      expr.items.each { |v| expr_each_bg_block_recursive(v, &block) }
    when HashLit
      hash_lit_pair_nodes(expr.pairs).each { |node| expr_each_bg_block_recursive(node, &block) }
    when BinaryOp
      expr_each_bg_block_recursive(expr.left, &block)
      expr_each_bg_block_recursive(expr.right, &block)
    end
    nil
  end

  # Yield ONLY the BgBlocks directly embedded in `stmt`'s expression
  # positions -- does NOT descend into nested control-flow branches OR
  # into the bodies of BGs found here. Use when emitting per-stmt MIR
  # markers (MIR::SuppressCleanup, MIR::Promote): nested control flow
  # gets its own transform_body call which handles its BGs separately;
  # nested BGs capture from their parent BG body's scope, not this
  # stmt's scope.
  sig { params(stmt: T.nilable(AST::Node), block: T.proc.params(node: BgNode).void).void }
  def self.each_bg_block_in_stmt(stmt, &block)
    case stmt
    when BgBlock, BgStreamBlock
      yield stmt
    when VarDecl, BindExpr, Assignment, DestructuringAssignment, ReturnNode
      expr_each_bg_block_shallow(stmt.value, &block) if stmt.respond_to?(:value)
    when FuncCall
      stmt.args.each { |a| expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      expr_each_bg_block_shallow(stmt.object, &block)
      stmt.args.each { |a| expr_each_bg_block_shallow(a, &block) }
    end
  end

  sig { params(expr: T.nilable(AST::Node), block: T.proc.params(node: BgNode).void).void }
  def self.expr_each_bg_block_shallow(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      # Stop here -- do not descend into BG body.
    when FuncCall
      expr.args.each { |a| expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      expr_each_bg_block_shallow(expr.object, &block)
      expr.args.each { |a| expr_each_bg_block_shallow(a, &block) }
    when StructLit, UnionVariantLit
      expr.fields.each_value { |v| expr_each_bg_block_shallow(v, &block) }
    when ListLit
      expr.items.each { |v| expr_each_bg_block_shallow(v, &block) }
    when HashLit
      hash_lit_pair_nodes(expr.pairs).each { |node| expr_each_bg_block_shallow(node, &block) }
    when BinaryOp
      expr_each_bg_block_shallow(expr.left, &block)
      expr_each_bg_block_shallow(expr.right, &block)
    end
    nil
  end

  # Yield every CaptureAnalysis instance reachable from `body`. A
  # CaptureAnalysis is attached to any "fiber-like context" -- BG block,
  # BgStream block, DO block branch, or ConcurrentOp (CONCURRENT
  # SELECT/WHERE/EACH/etc.). This lets BgCaptureClassifier process every
  # one with one pass per function. Replaces the per-source-type
  # iteration that used to live in lower_bg_block, lower_do_block, and
  # the pipeline_host concurrent lowerings.
  sig { params(body: RawBody, block: T.proc.params(analysis: CaptureAnalysisValue).void).void }
  def self.each_capture_analysis(body, &block)
    each_bg_block(body) do |bg|
      yield bg.capture_analysis if bg.capture_analysis
    end
    walk_body(body) do |node|
      if node.is_a?(DoBlock)
        node.branches.each do |b|
          yield b.capture_analysis if b.capture_analysis
        end
      end
      expr_each_concurrent_capture(node, &block)
    end
  end

  sig { params(node: T.nilable(AST::Node), block: T.proc.params(analysis: CaptureAnalysisValue).void).void }
  def self.expr_each_concurrent_capture(node, &block)
    case node
    when ConcurrentOp
      yield node.capture_analysis if node.capture_analysis
    when BinaryOp
      # `x |> CONCURRENT EACH { ... }` parses as BinaryOp(op=:SMOOTH);
      # the ConcurrentOp lives on .right. (Other binary ops can also
      # contain ConcurrentOps in either side via nested expressions.)
      expr_each_concurrent_capture(node.left, &block) if node.respond_to?(:left)
      expr_each_concurrent_capture(node.right, &block) if node.respond_to?(:right)
    when VarDecl, BindExpr, Assignment, DestructuringAssignment, ReturnNode
      expr_each_concurrent_capture(node.value, &block) if node.respond_to?(:value)
    when FuncCall
      node.args.each { |a| expr_each_concurrent_capture(a, &block) }
    when MethodCall
      expr_each_concurrent_capture(node.object, &block)
      node.args.each { |a| expr_each_concurrent_capture(a, &block) }
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
    sig { returns(T::Array[RawBody]) }
    def child_bodies
      []
    end
  end

  module HasExpression
    extend T::Sig

    sig { returns(AST::Node) }
    def expression
      T.unsafe(self)[:expression]
    end
  end

  # ruby-to-clear: skip
  # ruby-to-clear: no-expand
  module Locatable
      extend T::Sig

    # Immutable semantic operation plan published by annotation and consumed
    # by MIR lowering. Keeping this on every locatable node avoids a parallel
    # family of per-node flags while retaining a strongly typed phase handoff.
    sig { returns(T.nilable(AST::TensePlanValue)) }
    def tense_plan
      @tense_plan = T.let(nil, T.nilable(AST::TensePlanValue)) unless defined?(@tense_plan)
      @tense_plan
    end

    sig { params(value: AST::TensePlanValue).returns(AST::TensePlanValue) }
    def tense_plan=(value)
      @tense_plan = value
      value
    end

    sig { returns(Integer) }
    def line; token.line; end
    sig { returns(Integer) }
    def column; token.column; end
    sig { void }
    def token_value; token.value; end

    sig { returns(AST::SourceRange) }
    def source_range
      stored = @source_range
      return stored if stored

      start_offset = token.start_offset || 0
      end_offset = token.end_offset || (start_offset + token.value.to_s.bytesize)
      AST::SourceRange.new(
        file: token.file,
        start_offset: start_offset,
        end_offset: end_offset,
        start_line: token.line,
        start_column: token.column,
        end_line: token.end_line || token.line,
        end_column: token.end_column || (token.column + token.value.to_s.length),
      )
    end

    sig { params(range: AST::SourceRange).void }
    def source_range=(range)
      @source_range = T.let(range, T.nilable(AST::SourceRange))
    end

    sig { returns(T.nilable(Type)) }
    def coerced_type_object
      @coerced_type_object = T.let(@coerced_type_object, T.nilable(Type))
    end

    sig { returns(T.nilable(Type)) }
    def type_object
      @type_object = T.let(@type_object, T.nilable(Type))
    end

    sig { returns(T.nilable(T.any(String, Symbol))) }
    def zig_pattern
      @zig_pattern = T.let(@zig_pattern, T.nilable(T.any(String, Symbol)))
    end

    sig { params(val: T.nilable(T.any(String, Symbol))).returns(T.nilable(T.any(String, Symbol))) }
    def zig_pattern=(val)
      @zig_pattern = T.let(val, T.nilable(T.any(String, Symbol)))
    end

    sig { returns(T.nilable(FunctionSignature)) }
    def matched_stdlib_def
      @matched_stdlib_def = T.let(@matched_stdlib_def, T.nilable(FunctionSignature))
    end

    sig { params(val: T.nilable(FunctionSignature)).returns(T.nilable(FunctionSignature)) }
    def matched_stdlib_def=(val)
      @matched_stdlib_def = T.let(val, T.nilable(FunctionSignature))
      self.matched_signature = val
    end

    sig { returns(T.nilable(FunctionSignature)) }
    def matched_signature
      @matched_signature = T.let(@matched_signature, T.nilable(FunctionSignature))
    end

    sig { params(val: T.nilable(FunctionSignature)).returns(T.nilable(FunctionSignature)) }
    def matched_signature=(val)
      @matched_signature = T.let(val, T.nilable(FunctionSignature))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def stdlib_allocates
      @stdlib_allocates = T.let(@stdlib_allocates, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def stdlib_allocates=(val)
      @stdlib_allocates = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def mutates_receiver
      @mutates_receiver = T.let(@mutates_receiver, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def mutates_receiver=(val)
      @mutates_receiver = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def was_moved
      @was_moved = T.let(@was_moved, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def was_moved=(val)
      @was_moved = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def container_borrow
      @container_borrow = T.let(@container_borrow, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def container_borrow=(val)
      @container_borrow = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def needs_mut_ref
      @needs_mut_ref = T.let(@needs_mut_ref, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def needs_mut_ref=(val)
      @needs_mut_ref = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def needs_heap_create
      @needs_heap_create = T.let(@needs_heap_create, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def needs_heap_create=(val)
      @needs_heap_create = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def implicit_layout_cost
      @implicit_layout_cost = T.let(@implicit_layout_cost, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def implicit_layout_cost=(val)
      @implicit_layout_cost = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(Symbol)) }
    def layout_transport
      @layout_transport = T.let(@layout_transport, T.nilable(Symbol))
    end

    sig { params(val: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
    def layout_transport=(val)
      @layout_transport = T.let(val, T.nilable(Symbol))
    end

    sig { returns(T.nilable(Type)) }
    def collection_return
      @collection_return = T.let(@collection_return, T.nilable(Type))
    end

    sig { params(val: T.nilable(Type)).void }
    def collection_return=(val)
      @collection_return = T.let(val, T.nilable(Type))
    end

    sig { returns(T.nilable(Integer)) }
    def slot_size
      @slot_size = T.let(@slot_size, T.nilable(Integer))
    end

    sig { params(val: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def slot_size=(val)
      @slot_size = T.let(val, T.nilable(Integer))
    end

    sig { returns(T.nilable(Schemas::ResourceClosePlan)) }
    def resource_close_plan
      @resource_close_plan = T.let(@resource_close_plan, T.nilable(Schemas::ResourceClosePlan))
    end

    sig { params(val: T.nilable(Schemas::ResourceClosePlan)).returns(T.nilable(Schemas::ResourceClosePlan)) }
    def resource_close_plan=(val)
      @resource_close_plan = T.let(val, T.nilable(Schemas::ResourceClosePlan))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def can_fail
      @can_fail = T.let(@can_fail, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def can_fail=(val)
      @can_fail = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(Symbol)) }
    def error_kind
      @error_kind = T.let(@error_kind, T.nilable(Symbol))
    end

    sig { params(val: T.nilable(Symbol)).void }
    def error_kind=(val)
      @error_kind = T.let(val, T.nilable(Symbol))
    end

    sig { returns(T.nilable(Symbol)) }
    def error_type
      @error_type = T.let(@error_type, T.nilable(Symbol))
    end

    sig { params(val: T.nilable(Symbol)).void }
    def error_type=(val)
      @error_type = T.let(val, T.nilable(Symbol))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def var_used
      @var_used = T.let(@var_used, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def var_used=(val)
      @var_used = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(T::Boolean)) }
    def var_mutated
      @var_mutated = T.let(@var_mutated, T.nilable(T::Boolean))
    end

    sig { params(val: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def var_mutated=(val)
      @var_mutated = T.let(val, T.nilable(T::Boolean))
    end

    sig { returns(T.nilable(SymbolEntry)) }
    def symbol
      @symbol = T.let(@symbol, T.nilable(SymbolEntry))
    end

    sig { params(val: T.nilable(SymbolEntry)).returns(T.nilable(SymbolEntry)) }
    def symbol=(val)
      @symbol = T.let(val, T.nilable(SymbolEntry))
    end

    # Set full_type. Accepts a parsed or semantic type value and stores a
    # concrete Type at the AST boundary. Existing Type objects are preserved:
    # some tests and analysis hooks attach singleton behavior to the instance.
    sig { params(val: SyntheticTypeInput).returns(Type) }
    def full_type=(val)
      @type_object = T.let(
        if val.is_a?(Type)
          val
        elsif val.is_a?(FunctionSignature)
          Type.from_function_signature(val)
        else
          Type.new(val)
        end,
        T.nilable(Type)
      )
      T.must(@type_object)
    end

    # :Untyped sentinel (not nil) so no caller branches on nil; PreMirTypeCheck rejects it at the AST->MIR boundary.
    sig { returns(Type) }
    def full_type
      @type_object ||= Type.new(:Untyped)
    end

    sig { params(context: String).returns(Type) }
    def full_type!(context: "post-annotation AST")
      ft = full_type
      raise "#{context}: unresolved type info for #{self.class}" if ft.untyped?
      ft
    end

    # True when the node carries a real (stamped) type, i.e. full_type
    # is not the :Untyped sentinel.
    sig { returns(T::Boolean) }
    def typed?
      !full_type.untyped?
    end

    sig { params(val: CoerceTypeInput).returns(T.nilable(Type)) }
    def coerced_type=(val)
      if val.nil?
        @coerced_type_object = T.let(nil, T.nilable(Type))
        return @coerced_type_object
      end

      # Same logic: Wrap raw values, accept Type objects
      @coerced_type_object = T.let(val.is_a?(Type) ? val : Type.new(T.unsafe(val)), T.nilable(Type))
    end

    sig { returns(CoerceTypeInput) }
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
    sig { params(declared_type: CoerceTypeInput).returns(CoerceResult) }
    def coerce!(declared_type)
      # An inferred value already owns the authoritative semantic Type.
      # Flattening it to `resolved` loses collection topology, nested element
      # capabilities, and function metadata, forcing later phases to
      # reconstruct an incomplete type from a legacy symbol.
      if @type_object && (declared_type.nil? || declared_type == :Any)
        return [@type_object, nil]
      end

      inferred = @type_object&.resolved

      # No explicit type or :Any -> use inferred, no coercion needed
      return [inferred, nil] if declared_type.nil? || declared_type == :Any

      declared_type_info = declared_type.is_a?(FunctionSignature) ? Type.from_function_signature(declared_type) : Type.new(declared_type)
      if declared_type_info.symbol? && @type_object && !@type_object.symbol?
        error = Type.coerce_error(@type_object, declared_type_info)
        return [nil, error] if error
      end

      # Check if coercion is valid
      coerce_target = T.let(declared_type.is_a?(FunctionSignature) ? declared_type_info : declared_type, Type::TypeInput)
      error = Type.coerce_error(T.must(@type_object), coerce_target)
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
    # ruby-to-clear: skip
    sig { params(final_type: T.any(Symbol, Type), schema_lookup: T.nilable(SchemaLookup)).returns(Symbol) }
    def finalize_storage!(final_type, &schema_lookup)
      T.bind(self, T.untyped) rescue nil
      # Normalize the Symbol|Type input to a Type once at the seam, so
      # the body never re-derives via final_type.is_a?(Type). A Symbol
      # tag yields a bare Type (no shard/sync/soa/observable) -- exactly
      # what the old `is_a?(Type) && ...` false-branch produced.
      type_obj = T.let(final_type.is_a?(Type) ? final_type : Type.new(final_type), Type)
      # Calculate slot size
      @slot_size = T.let(type_obj.slot_size(&schema_lookup), T.nilable(Integer))

      # Determine storage from value's type if this node has a value
      node_value = T.let(nil, T.untyped)
      if respond_to?(:value)
        node_value = value
      end

      if node_value && node_value.type_object
        value_type = node_value.type_object
        storage = value_type.finalize_storage(@slot_size, node_value.storage)
        # Declared type overrides: pointer types (%Type annotation) or sync types
        storage = :heap if type_obj.heap? || type_obj.any_sync?
        # Declared @list annotation requires frame (unless already upgraded to heap)
        storage = :frame if type_obj.list_collection? && storage != :heap
        node_value.storage = storage if node_value.respond_to?(:storage=)
      else
        storage = type_obj.finalize_storage(T.must(@slot_size), nil)
      end

      # Determine if value has a sync capability
      value_sync = nil
      if node_value && node_value.type_object
        vt = node_value.type_object
        value_sync = vt.sync
      end

      # Build a Type that carries the full declared/inferred shape plus
      # storage-derived capabilities. Preserve optional/error-union/generic
      # wrappers and data capabilities such as String@symbol; rebuilding from
      # only resolved would collapse `?String@symbol` to bare `String`.
      # For fn_type, preserve the full type object — do not reduce to the return-type symbol.
      t = if type_obj.fn_type?
        type_obj
      else
        new_t = Type.new(type_obj)
        val_ti = node_value && node_value.respond_to?(:full_type) ? node_value.full_type : nil
        new_t.apply_finalized_value_shape!(final_type: type_obj, value_type: val_ti)
        new_t
      end
      # Propagate @link ownership from the value's LinkNode
      val_ti = node_value && node_value.respond_to?(:full_type) ? node_value.full_type : nil
      if val_ti&.link?
        storage = :link
      end

      t.apply_storage_capability!(storage, value_sync: value_sync)

      # Propagate additional capability fields from the value's type_object
      if node_value && node_value.type_object
        vt = node_value.type_object
        t.merge_capabilities_from!(vt)
      end
      # Rank topology belongs to the declared comma dimensions. A List[]
      # initializer is construction syntax, not an @list capability.
      t.collection = nil if type_obj.rank?

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
      @storage_override || :stack
    end

    sig { returns(T.nilable(Symbol)) }
    def storage_override
      @storage_override = T.let(@storage_override, T.nilable(Symbol))
    end

    # Canonical "is this expression's value heap-allocated?" — SIMP-13f.
    # Reads sym.storage when a symbol is attached (binding-level), else the
    # node's @storage_override (expression-level, stamped by annotator).
    sig { returns(T::Boolean) }
    def heap_storage?
      sym = respond_to?(:symbol) ? symbol : nil
      return true if sym&.heap_storage?
      @storage_override == :heap
    end

    sig { returns(T::Boolean) }
    def frame_provenance?
      sym = respond_to?(:symbol) ? symbol : nil
      return true if sym&.frame_provenance?
      @storage_override == :frame
    end

    sig { returns(T::Boolean) }
    def stack_storage?
      @storage_override == :stack
    end

    sig { returns(T::Boolean) }
    def stack_or_frame_storage?
      storage == :stack || storage == :frame
    end

    sig { returns(T::Boolean) }
    def rodata_provenance?
      sym = respond_to?(:symbol) ? symbol : nil
      return true if sym&.rodata_provenance?
      @storage_override == :rodata
    end

    sig { returns(T::Boolean) }
    def borrow_provenance?
      sym = respond_to?(:symbol) ? symbol : nil
      return true if sym&.borrow_provenance?
      @storage_override == :borrow
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

      return :void if t.void?
      return :die if t.resolved == :NoReturn
      return :array if t.array?
      return :hashmap if t.map?
      return :struct if !t.primitive?
      return :primitive
    end
  end

  Node = T.type_alias { Locatable }

  sig { params(body: LambdaBody).returns(RawBody) }
  def self.lambda_body_nodes(body)
    body.is_a?(Array) ? body : [body]
  end

  class PipelineShardContext < T::Struct
    extend T::Sig

    const :map_var, Node
    const :key_expr, Node
    const :shard_count, T.nilable(Integer), default: nil
    const :auto_detected, T::Boolean, default: false
    const :key_allocates_frame, T::Boolean, default: false
    const :body_allocates_frame, T::Boolean, default: false

    sig { params(key_allocates_frame: T::Boolean, body_allocates_frame: T::Boolean).returns(PipelineShardContext) }
    def with_frame_allocations(key_allocates_frame:, body_allocates_frame:)
      PipelineShardContext.new(
        map_var: map_var,
        key_expr: key_expr,
        shard_count: shard_count,
        auto_detected: auto_detected,
        key_allocates_frame: key_allocates_frame,
        body_allocates_frame: body_allocates_frame,
      )
    end
  end

  class PipelineShardedAccess < T::Struct
    const :map_name, String
    const :key_expr, Node
    const :map_token, Lexer::Token
  end

  class ErrorSelector < T::Struct
    const :form, Symbol
    const :name, Symbol
    const :token, T.nilable(Lexer::Token)
  end

  class ErrorActionKind < T::Enum
    enums do
      Raise = new("raise")
      Pass = new("pass")
      Return = new("return")
      Exit = new("exit")
      Block = new("block")
    end
  end

  class ErrorAction < T::Struct
    const :action, ErrorActionKind
    const :token, T.nilable(Lexer::Token)
    const :value, T.nilable(Node), default: nil
    const :message, T.nilable(Node), default: nil
    const :body, T::Array[Node], default: []
  end

  class ErrorClause < T::Struct
    extend T::Sig

    const :selectors, T::Array[ErrorSelector]
    const :action, ErrorActionKind
    const :retries, T.nilable(Integer)
    const :token, T.nilable(Lexer::Token)
    const :value, T.nilable(Node), default: nil
    const :message, T.nilable(Node), default: nil
    const :body, T::Array[Node], default: []
    prop :matched_types, T::Array[Symbol], default: []
    prop :bubble_types, T::Array[Symbol], default: []

    sig { params(selectors: T::Array[ErrorSelector], retries: T.nilable(Integer), action: ErrorAction).returns(ErrorClause) }
    def self.from_action(selectors:, retries:, action:)
      new(
        selectors: selectors,
        action: action.action,
        retries: retries,
        token: action.token,
        value: action.value,
        message: action.message,
        body: action.body,
      )
    end
  end

  class DeferredDrop < T::Struct
    const :name, String
    const :type, Type
    const :resource, T::Boolean, default: false
  end

  module DeferredDropsField
    extend T::Sig

    sig { returns(T::Array[AST::DeferredDrop]) }
    def deferred_drops
      drops = T.unsafe(self)[:deferred_drops]
      return drops if drops

      self.deferred_drops = []
      T.must(T.unsafe(self)[:deferred_drops])
    end

    sig { params(val: T.nilable(T::Array[AST::DeferredDrop])).void }
    def deferred_drops=(val)
      T.unsafe(self)[:deferred_drops] = val || []
    end
  end

  class ReturnFact < T::Struct
    const :storage, T.nilable(Symbol)
    const :type, Symbol
    const :metatype, T.nilable(Symbol)
  end

  sig { params(node: Node, blk: T.proc.params(arg0: Node).void).void }
  def self.each_child_node(node, &blk)
    node.class.members.each do |member|
      value = node[member]
      if value.is_a?(Array)
        value.each { |child| yield child if child.is_a?(Locatable) }
      elsif value.is_a?(Hash)
        value.each do |key, child|
          yield key if key.is_a?(Locatable)
          yield child if child.is_a?(Locatable)
        end
      elsif value.is_a?(Locatable)
        yield value
      end
    end
    nil
  end

  Program      = Struct.new(:token, :statements) do
    extend T::Sig
    include Locatable

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      @language_mode = T.let(:default, Symbol)
    end

    sig { returns(Symbol) }
    def language_mode = @language_mode

    sig { params(value: Symbol).void }
    def language_mode=(value)
      @language_mode = value
    end

    # Resolved program-level SYNC POLICY, either user-written or the baked-in
    # default. Lowering reads this when filling unhandled WITH error slots.
    attr_accessor :sync_policy
    attr_accessor :mir_pass_state
  end
  # kind: :local (REQUIRE "file.clear") or :package (REQUIRE "pkg:name")
  RequireNode  = Struct.new(:token, :path, :namespace, :kind) { include Locatable }

  class GenericBoundDecl < T::Struct
    const :token, T.nilable(Lexer::Token), default: nil
    const :type, Type
  end

  class GenericParamDecl < T::Struct
    const :token, T.nilable(Lexer::Token), default: nil
    const :name, String
    const :bounds, T::Array[GenericBoundDecl], default: []
  end

  class ProtocolRequirement < T::Struct
    include Locatable

    const :token, Lexer::Token
    const :name, String
    const :params, T::Array[AST::Param]
    const :return_type, Type
    const :is_method, T::Boolean, default: true
    const :effects_decl, T.nilable(Symbol), default: nil
    const :max_depth_n, T.nilable(Integer), default: nil
    const :tight_reentrance, T::Boolean, default: false
  end

  ProtocolDef = Struct.new(:token, :name, :name_token, :associated_types, :requirements, :visibility) do
    extend T::Sig
    include Locatable
    include HasBodies

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:associated_types] = (self[:associated_types] || []).dup
      self[:requirements] = (self[:requirements] || []).dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def associated_types = self[:associated_types]

    sig { returns(T::Array[AST::ProtocolRequirement]) }
    def requirements = self[:requirements]

    sig { returns(T::Array[RawBody]) }
    def child_bodies = []
  end

  FunctionDef  = Struct.new(:token, :name, :params, :captures, :return_type, :return_lifetime,
                            :body, :catch_clauses, :default_catch, :visibility, :deferred_drops,
                            :uses_frame, :explicit_return_type, :type_params, :tail_call, :requires,
                            :arrow_token, :name_token, :effects_decl, :effects_span, :max_depth_n,
                            :tight_reentrance, :requires_clauses, :return_type_token, :pre_clauses,
                            :post_clauses, :is_method) do
    # ruby-to-clear: field-type return_type=?Type
    # ruby-to-clear: field-type type_params=String[]
    # ruby-to-clear: field-type arrow_token=Token
    # ruby-to-clear: field-type name_token=?Token
    # ruby-to-clear: field-type return_type_token=?Token
    extend T::Sig
    include Locatable
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [body].compact

    # Seam: a function's declared/inferred return is always a Type
    # (or nil when undeclared — the implicit-return signal that
    # inference consumes). Coerced at BOTH construction (positional
    # Struct init from parser/synthetic builders) and post-parse
    # assignment (return inference, auto-infer) so no reader needs
    # an `is_a?(Type)` Symbol/Type discriminator.
    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      rt = self[:return_type]
      self[:return_type] = Type.new(rt) unless rt.nil?
      self[:params] = self[:params] || []
      self[:type_params] = (self[:type_params] || []).dup
      @generic_params = T.let(type_params.map do |name|
        AST::GenericParamDecl.new(token: token, name: name)
      end, T::Array[AST::GenericParamDecl])
      @semantic_with_blocks = T.let([], T::Array[AST::WithBlock])
      @implementation_owner = T.let(nil, T.nilable(String))
      @conformance_protocol = T.let(nil, T.nilable(String))
      @source_name = T.let(name, String)
    end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def return_type=(val)
      self[:return_type] = val.nil? ? nil : Type.new(val)
    end

    sig { returns(T::Boolean) }
    def implicit_return_type?
      self[:return_type].nil?
    end

    sig { returns(T.nilable(Type)) }
    def declared_return_type
      self[:return_type]
    end

    sig { returns(Type) }
    def annotation_return_type
      self[:return_type] || Type.new(:Any)
    end

    sig { returns(Type) }
    def lowering_return_type
      self[:return_type] || Type.new(:Void)
    end

    sig { params(val: T::Array[AST::Param]).void }
    def params=(val)
      self[:params] = val
    end

    sig { returns(T::Array[String]) }
    def type_params
      self[:type_params]
    end

    sig { params(value: T::Array[String]).void }
    def type_params=(value)
      self[:type_params] = value.dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def generic_params
      @generic_params
    end

    sig { params(value: T::Array[AST::GenericParamDecl]).void }
    def generic_params=(value)
      @generic_params = value.dup
    end

    sig { returns(T::Boolean) }
    def generic?
      !type_params.empty?
    end

    sig { returns(T.nilable(String)) }
    def implementation_owner = @implementation_owner

    sig { params(value: T.nilable(String)).void }
    def implementation_owner=(value)
      @implementation_owner = value
    end

    sig { returns(T.nilable(String)) }
    def conformance_protocol = @conformance_protocol

    sig { params(value: T.nilable(String)).void }
    def conformance_protocol=(value)
      @conformance_protocol = value
    end

    sig { returns(String) }
    def source_name = @source_name

    sig { params(value: String).void }
    def source_name=(value)
      @source_name = value
    end

    # True when the user wrote RETURNS explicitly; fallible-signature checks
    # only enforce on user-authored return types.
    # REQUIRES clause — { param_name => Set[Family] } or nil
                                 #     Family symbols: :LOCKED, :VERSIONED, :ACTOR, :LOCK_FREE
    attr_accessor :effect_set    # projected EffectSet (yield/alloc_heap/io/fail)
                                 #     view over fn.effects + fn.can_fail
    attr_accessor :inferred_effects  # alias of effect_set; used by formatter
    # tail_call is true for EFFECTS REENTRANT:TAIL_CALL or routed THUNK tail recursion.
    # Phase 4f.2: EffectSpan covering the full
    # `EFFECTS REENTRANT[:VARIANT]` clause text. Used by `clear fix`
    # to swap variants (e.g., `:THUNK` -> plain or `:NOT_LOGICAL`).
    # Phase 4f.3: positive Int from `EFFECTS REENTRANT:MAX_DEPTH(N)`.
    # Set on parse; the bridge validates `!T` return and the prologue
    # codegen path emits `safety.enterDepth(@src(), N)` /
    # `defer safety.exitDepth(@src())`.
    # When true, the function declared `:TIGHT` (or `:TIGHT:VARIANT`)
    # — skip the entry `rt.checkYield()` co-op-yield injection.
    # Mirrors `TIGHT WHILE`; same opt-out, same risks (long
    # workloads stall the scheduler). For `:MAX_DEPTH(N)` TIGHT is
    # IMPLIED and not user-settable; the bridge force-flips it on
    # iff `N <= YIELD_BUDGET`.
    # Token at the start of the return type annotation (after RETURNS,
    # past any lifetime-prefix). Used for fixable spans that prepend
    # `!` to the declared return type.
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
    # Thunk Phase 1.3: canonical, post-bridge reentrance kind. Read THIS, not
    # `effects_decl` directly. Same value space as effects_decl.
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
    attr_accessor :needs_rt      # computed by compute_needs_rt! post-pass; nil = not yet computed
    attr_accessor :fn_value_ref  # true when referenced as a function value; MIRPass finalizes needs_rt from it
    attr_accessor :can_fail      # computed by compute_can_fail! post-pass; nil = not yet computed
    attr_accessor :alloc_fault   # computed by compute_can_fail! post-pass: fn allocates (direct or via a non-OR-absorbed callee) -> can OOM. A FAULT (panics by default, catchable by OR/CATCH), NOT an ERROR (never forces RETURNS !T). #3/#12
    attr_accessor :error_fallible # computed by compute_can_fail! post-pass: GENUINE error fallibility only (RAISE/PRE/declared !T/transitive ERROR callee). can_fail = error_fallible || alloc_fault; only error_fallible forces RETURNS !T (step 4). #3
    attr_accessor :uses_heap     # true when body allocates from heap (rt.heapAlloc)
    attr_accessor :uses_alloc    # true when body calls stdlib fns that use rt.frameAlloc (e.g. append)
    attr_accessor :uses_rt       # true when body references rt without allocating (e.g. Versioned.read for EBR pin)
    # uses_runtime? = true iff this fn's body touches any allocator (frame/heap/alloc) or
    # references rt directly. Used by compute_needs_rt! and alloc_fault seed.
    # ONE predicate replaces the per-source disjunction (the four counters track distinct
    # signal sources but the consumer is "any of them?" -- there is one consumer-facing
    # decision, hence one predicate).
    sig { returns(T::Boolean) }
    def uses_runtime?
      uses_frame == true || uses_heap == true || uses_alloc == true || uses_rt == true
    end

    sig { returns(T::Boolean) }
    def declared_plain_reentrant?
      (reentrance_kind || effects_decl) == :reentrant
    end

    sig { returns(T::Boolean) }
    def plain_reentrant?
      reentrance_kind == :reentrant
    end

    sig { returns(T::Boolean) }
    def tail_call_reentrant?
      reentrance_kind == :reentrant_tail_call
    end

    sig { returns(T::Boolean) }
    def reentrance_guard_required?
      reentrance_kind == :reentrant_not_logical || reentrance_kind == :reentrant_max_depth
    end

    sig { returns(T::Boolean) }
    def recursive_reentrance_declared?
      reentrance_kind == :reentrant ||
        reentrance_kind == :reentrant_thunk ||
        reentrance_kind == :reentrant_tail_call
    end

    sig { params(recursion_yield: T::Boolean, declared_runtime_return: T::Boolean).returns(T::Boolean) }
    def runtime_stack_required?(recursion_yield, declared_runtime_return)
      uses_runtime? || fn_value_ref == true || !thunk_plan.nil? ||
        !mutual_thunk_plan.nil? || recursion_yield || declared_runtime_return
    end
    attr_accessor :effects       # Set of effect symbols, computed by EffectTracker post-pass
    attr_accessor :snapshot_types # Set of pipeline input types that could be snapshots (for CATCH)
    attr_accessor :stack_tier        # recommended fiber tier (:micro, :standard, :large, :xl)
    attr_accessor :stack_vars_bytes  # lower-bound estimate of stack-local variable bytes
    attr_accessor :moved_guard_info   # stamped by MIRPass: { var_name => bool } for has_moved_guard lookups
    attr_accessor :cleanup_bindings   # stamped by MIRPass: { var_name => entry_hash } for MIRLowering
    attr_accessor :heap_carry_return      # true when a heap carry var is the return value (caller must free)
    attr_accessor :heap_carry_return_vars # Set of var names that are heap carry return vars (their cleanup is skipped inside __pr_body)
    # FSM Phase A: set by FsmClassifier. fsm_eligible=true means this function can be
    # compiled as an FsmTask (state-machine resume fn) rather than a stackful fiber.
    # fsm_suspend_points is an Array of Semantic::SuspendPointFact enumerating
    # the yield-relevant call sites inside the body.
    attr_accessor :fsm_eligible
    attr_accessor :fsm_ineligible_reason  # Symbol: :reentrant, :extern, :self_recursive, :no_suspends, :suspending_callee
    attr_accessor :fsm_suspend_points
    # PRE clauses: Array of expression AST nodes parsed from
    # `PRE: <expr>` between RETURNS and `->`. Each predicate is checked
    # at function entry, fail-fast, raising PreconditionFail.
    # See docs / spec/with_pre_spec.rb for semantics.
    # DEBUG_POST clauses: same shape as pre_clauses (Array of
    # {expr:, source:}). Checked in a debug-only wrapper after the
    # function body returns; panics on violation. See spec/with_post_spec.rb.
    # True when declared via `METHOD name(...)` instead of `FN name(...)`.
    # Purely a fmt directive: METHOD-flagged FNs have their prefix call
    # sites (`foo(v, ...)`) rewritten to UFCS form (`v.foo(...)`) by
    # `clear fmt`. Semantically identical to FN — same lookup, same
    # call resolution, same UFCS at call sites at the language level.
  end

  ImplementationDef = Struct.new(:token, :owner_name, :owner_token, :binders, :members) do
    extend T::Sig
    include Locatable
    include HasBodies

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:binders] = (self[:binders] || []).dup
      self[:members] = (self[:members] || []).dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def binders = self[:binders]

    sig { returns(T::Array[AST::FunctionDef]) }
    def members = self[:members]

    sig { returns(T::Array[RawBody]) }
    def child_bodies = members.map(&:body)
  end

  ConformanceDef = Struct.new(:token, :binders, :protocol_type, :owner_type, :members) do
    extend T::Sig
    include Locatable
    include HasBodies

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:binders] = (self[:binders] || []).dup
      self[:protocol_type] = Type.new(self[:protocol_type])
      self[:owner_type] = Type.new(self[:owner_type])
      self[:members] = (self[:members] || []).dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def binders = self[:binders]

    sig { params(value: T::Array[AST::GenericParamDecl]).void }
    def binders=(value)
      self[:binders] = value.dup
    end

    sig { returns(Type) }
    def protocol_type = self[:protocol_type]

    sig { returns(Type) }
    def owner_type = self[:owner_type]

    sig { params(value: Type).void }
    def owner_type=(value)
      self[:owner_type] = Type.new(value)
    end

    sig { returns(T::Array[AST::FunctionDef]) }
    def members = self[:members]

    sig { returns(T::Array[RawBody]) }
    def child_bodies = members.map(&:body)
  end

  class StructField
    extend T::Sig

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      self[:borrowed] = false if self[:borrowed].nil?
      field_type = self[:type]
      self[:type] = Type.new(field_type || :Any)
    end

    sig { returns(Type) }
    def type; self[:type]; end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def type=(val)
      self[:type] = Type.new(val || :Any)
    end

    sig { returns(T.nilable(AST::Locatable)) }
    def default; self[:default]; end

    sig { returns(T::Boolean) }
    def borrowed; self[:borrowed]; end
  end

  StructDef    = Struct.new(:token, :name, :field_decls, :visibility, :type_params) do
    extend T::Sig
    include Locatable

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:type_params] ||= []
      @generic_params = T.let(type_params.map do |name|
        AST::GenericParamDecl.new(token: token, name: name)
      end, T::Array[AST::GenericParamDecl])
    end

    sig { returns(T::Hash[String, AST::StructField]) }
    def field_decls; self[:field_decls]; end

    sig { returns(T::Array[String]) }
    def type_params
      self[:type_params] ||= []
    end

    sig { params(value: T::Array[String]).void }
    def type_params=(value)
      self[:type_params] = value.dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def generic_params
      @generic_params
    end

    sig { params(value: T::Array[AST::GenericParamDecl]).void }
    def generic_params=(value)
      @generic_params = value.dup
    end
  end
	  VarDecl      = Struct.new(:token, :name, :type, :value, :mutable) do
	    # ruby-to-clear: field-type type=?Type
	    extend T::Sig
	    # ruby-to-clear: data-api
	    # ruby-to-clear: pub
	    sig { returns(Lexer::Token) }
	    def token = self[:token]
    extend T::Sig
    include Locatable
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)
    attr_accessor :ownership_transport_plan

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil?
    end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def type=(val)
      self[:type] = val.nil? ? nil : Type.new(val)
    end
	  end
  class AutoLockPlan < T::Struct
    extend T::Sig

    const :var, String
    const :sync, Symbol

    sig { params(other: T.nilable(AutoLockPlan)).returns(T::Boolean) }
    def ==(other)
      !!(other && other.var == var && other.sync == sync)
    end

    sig { params(other: T.nilable(AutoLockPlan)).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig { returns(Integer) }
    def hash = [var, sync].hash
  end
	  Assignment   = Struct.new(:token, :name, :value, :compound_op) do
	    include Locatable
	    include StatementVoidType
	    attr_accessor :auto_lock  # AutoLockPlan set by annotator for inline @locked/@writeLocked guards.
    attr_accessor :field_pre_cleanup  # stamped by MIRPass: Symbol (:heap or :frame) -- the allocator to free the OLD value with before the field overwrite. nil = no pre-cleanup needed.
    attr_accessor :field_lifecycle_plan # immutable Semantic::LifecyclePlan authorizing field replacement cleanup.
    # Preserves the source compound operator so atomic targets can lower to
    # fetch_<op> instead of load/modify/store.
    # Stamped by the annotator for @shared:atomic targets so MIR lowering emits
    # MethodCall(cell, op, args) instead of plain Set.
    attr_accessor :auto_atomic_op
  end
  DestructureTarget = Struct.new(:token, :name, :type, :mutable) do
    # ruby-to-clear: field-type type=?Type
    extend T::Sig
    # ruby-to-clear: data-api
    # ruby-to-clear: pub
    sig { returns(Lexer::Token) }
    def token = self[:token]
    include Locatable
    attr_accessor :mir_binding_entry

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil?
      self[:mutable] = false if self[:mutable].nil?
    end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def type=(val)
      self[:type] = val.nil? ? nil : Type.new(val)
    end
  end
  DestructuringAssignment = Struct.new(:token, :targets, :value) do
    extend T::Sig
    include Locatable
    include StatementVoidType

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:targets] ||= []
    end

    sig { returns(T::Array[AST::DestructureTarget]) }
    def targets
      self[:targets]
    end
  end
  # Keywordless bind: `x = val` or `x: Type = val`. Annotator sets mode to :decl or :assign.
  BindExpr     = Struct.new(:token, :name, :type, :value, :compound_op) do
    # ruby-to-clear: field-type type=?Type
    extend T::Sig
    include Locatable
    attr_accessor :mode
    attr_accessor :reassign_cleanup  # MIR::ReassignPlan(alloc:, zig_type:) when the OLD value of this :assign target needs cleanup before overwrite. nil = no pre-cleanup.
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)
    attr_accessor :auto_atomic_op
    attr_accessor :ownership_transport_plan

    # Seam: same contract as VarDecl#type — annotated/inferred type is
    # always a Type (or nil when unannotated). Coerced at construction
    # and post-parse assignment so no reader needs an `is_a?(Type)`
    # Symbol/Type discriminator.
    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      t = self[:type]
      self[:type] = Type.new(t) unless t.nil?
    end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def type=(val)
      self[:type] = val.nil? ? nil : Type.new(val)
    end
  end
  BinaryOp     = Struct.new(:token, :left, :op, :right, :paren_bind) do
    extend T::Sig
    include Locatable
    # ruby-to-clear: field-type op=String@symbol
    # Derived: comparison/logical -> Bool; otherwise an operand's type.
    sig { returns(Type) }
    def full_type
      @type_object ||=
        if BOOL_BINOPS.include?(op)
          Type.new(:Bool)
        else
          Type.new(left.full_type.resolved || right.full_type.resolved || :Any)
        end
    end
    attr_accessor :string_concat  # true when this is string + (stamped by annotator)
    attr_accessor :or_fallback_dupe  # true when OR_ELSE fallback struct needs string-field heap dupe
    attr_accessor :error_union_type # recoverable result preserved through pipeline composition
    sig { returns(T.nilable(T::Boolean)) }
    def retain_error_channel
      @retain_error_channel = T.let(nil, T.nilable(T::Boolean)) unless defined?(@retain_error_channel)
      @retain_error_channel
    end
    sig { params(value: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def retain_error_channel=(value)
      @retain_error_channel = value
    end
    # Lazy positions: fields whose lowering must NOT leak @pending_stmts to
    # outer scope. The lowering's `descend` helper consults this and wraps
    # the field's emission in MIR::BlockExpr when the field actually emitted
    # any pending allocs. OR_ELSE's right side is the fallback expression;
    # boolean AND/OR's right side must only run after short-circuiting allows it.
    sig { returns(T::Array[Symbol]) }
    def lazy_fields = (%i[AND OR OR_ELSE].include?(op) ? [:right] : [])
    sig { returns(T::Boolean) }
    def smooth?
      op == :SMOOTH
    end
    # True on a `|> SUM/MAX/MIN/COUNT/AVERAGE/ANY/ALL/FIND/DISTINCT/REDUCE`
    # whose source is a still-running tense stream — fold terminal is backed by
    # an Observable<T> / atomic accumulator and may be observed via WITH VIEW.
    attr_accessor :observable_terminal
    # Set when the pipe's destination is a `~T@observable` binding so
    # pipeline lowering switches to fiber-spawn-with-accumulator codegen.
    attr_accessor :observable_dest
  end
  IsA          = Struct.new(:token, :left, :right, :binding) do
    extend T::Sig
    include Locatable
    attr_accessor :runtime_variant_name
    attr_accessor :runtime_payload_type
    attr_accessor :runtime_indirect_payload_as

    sig { returns(Type) }
    def full_type; Type.new(:Bool); end
  end
  UnaryOp      = Struct.new(:token, :op, :right) do
    extend T::Sig
    include Locatable
    # Derived: NOT -> Bool; otherwise the operand's type.
    sig { returns(Type) }
    def full_type
      @type_object ||= op == :NOT ? Type.new(:Bool) : Type.new(right.full_type.resolved || :Any)
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
    attr_accessor :ownership_pending_transfer
    sig { returns(FalseClass) }
    def wildcard?; false end
    # ruby-to-clear: data-api
    sig { returns(String) }
    def name; self[:name].to_s end
  end
  Literal      = Struct.new(:token, :type, :value, :storage) do
    extend T::Sig
    include Locatable
    # Derived: a literal's value-type is a pure function of its token
    # kind. Never nil, never stamped.
    sig { returns(Type) }
    def full_type
      @type_object ||= Type.new(LITERAL_VALUE_TYPE.fetch(self[:type], :Any))
    end

    sig { returns(T::Boolean) }
    def true_boolean?
      self[:type] == :BOOLEAN && self[:value] == true
    end
  end
  ListLit      = Struct.new(:token, :items, :storage, :constructor_options) {
    extend T::Sig
    include Locatable 

    sig { returns(T.nilable(AST::CollectionConstructorFact)) }
    def constructor_options
      self[:constructor_options]
    end

    sig { params(value: T.nilable(AST::CollectionConstructorFact)).returns(T.nilable(AST::CollectionConstructorFact)) }
    def constructor_options=(value)
      self[:constructor_options] = value
    end

    sig { returns(T::Boolean) }
    def collection_constructor?
      !constructor_options.nil?
    end

    sig { returns(T.nilable(Symbol)) }
    def constructor_collection
      constructor_options&.collection
    end

    sig { returns(T::Boolean) }
    def constructor_soa?
      constructor_options&.soa == true
    end

    sig { returns(T.nilable(Integer)) }
    def constructor_shard_count
      constructor_options&.shard_count
    end

    sig { params(declared_type: CoerceTypeInput).returns(CoerceResult) }
    def coerce!(declared_type)
      res, error = super(declared_type)
      return [nil, error] if error

      # Recursively coerce items if the container is being coerced
      if res && items.any?
        element_type = Type.new(res).element_type
        if element_type
          # Preserve element ownership/synchronization. Reducing to
          # `resolved` turned `T@multiowned[]`/`T@shared[]` literals into a
          # request to cast Rc(T)/Arc(T) back to plain T after construction.
          items.each { |item| item.coerce!(element_type) }
        end
      end
      [res, nil]
    end
  }
  TupleLit     = Struct.new(:token, :items, :storage) do
    extend T::Sig
    include Locatable

    sig { returns(T::Array[AST::Node]) }
    def items
      self[:items]
    end

    sig { params(declared_type: CoerceTypeInput).returns(CoerceResult) }
    def coerce!(declared_type)
      return super(declared_type) if declared_type.nil? || declared_type == :Any

      target = declared_type.is_a?(FunctionSignature) ? Type.from_function_signature(declared_type) : Type.new(declared_type)
      return super(declared_type) unless target.tuple?
      return [nil, "Tuple arity mismatch: expected #{target.generic_args.length}, got #{items.length}"] if target.generic_args.length != items.length

      items.zip(target.generic_args).each do |item, item_type|
        _coerced, error = item.coerce!(item_type)
        return [nil, error] if error
      end
      self.coerced_type = target
      [target, nil]
    end
  end
  DefaultArrayLit = Struct.new(:token, :type_info, :storage) do
    extend T::Sig
    include Locatable

    sig { returns(Lexer::Token) }
    def token; self[:token]; end

    sig { returns(Type) }
    def full_type
      Type.new(type_info)
    end

    sig { params(declared_type: CoerceTypeInput).returns(CoerceResult) }
    def coerce!(declared_type)
      target = declared_type.is_a?(FunctionSignature) ? Type.from_function_signature(declared_type) : Type.new(T.unsafe(declared_type))
      return [nil, "Cannot initialize array of size #{target.capacity} with #{type_info.capacity} elements"] unless target.accepts?(type_info)

      [target.resolved, nil]
    end
  end
  HashLit      = Struct.new(:token, :pairs, :storage) { include Locatable }
  DefaultLit   = Struct.new(:token) { include Locatable }
  StructLit    = Struct.new(:token, :name, :fields, :storage, :type_args) do
    extend T::Sig
    include Locatable

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      @field_tokens = T.let({}, T::Hash[String, Lexer::Token])
    end

    # Parallel map of field_name (String) -> the lexer Token that parsed
    # the name. Populated by the parser so `clear fix` can locate a
    # misspelled field-name for a fixable edit span.
    sig { returns(T::Hash[String, Lexer::Token]) }
    def field_tokens = @field_tokens

    sig { params(value: T::Hash[String, Lexer::Token]).void }
    def field_tokens=(value)
      @field_tokens = value
    end
    # Set of field names the schema marks BORROWED, stamped by the
    # annotator. MIR lowering reads this instead of re-resolving the
    # struct schema (single-source-of-truth: the annotator already
    # knows which fields are borrowed when it validates the literal).
    attr_accessor :borrowed_field_names

    sig { returns(T::Boolean) }
    def borrowed_fields?
      borrowed_field_names&.any? == true
    end
  end
  LambdaLit    = Struct.new(:token, :params, :captures, :body, :storage, :deferred_drops) do
    extend T::Sig
    include Locatable
    include DeferredDropsField
    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:params] = self[:params] || []
    end

    sig { params(val: T.nilable(T::Array[AST::Param])).returns(T::Array[AST::Param]) }
    def params=(val)
      self[:params] = val || []
    end

    sig { returns(LambdaBody) }
    def body
      self[:body]
    end

    sig { params(val: LambdaBody).returns(LambdaBody) }
    def body=(val)
      self[:body] = val
    end
  end
  IfStatement  = Struct.new(:token, :condition, :then_branch, :else_branch, :then_drops, :else_drops, :comptime) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [then_branch, else_branch].compact

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:comptime] = !!self[:comptime]
    end

    sig { returns(T::Boolean) }
    def comptime = self[:comptime]

    sig { params(value: T::Boolean).void }
    def comptime=(value)
      self[:comptime] = value
    end

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
    include HasBodies

    sig { returns(T::Array[RawBody]) }
    def child_bodies = [then_branch, else_branch].compact

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:bindings] = [] if self[:bindings].nil?
    end

    sig { params(val: T::Array[AST::Binding]).void }
    def bindings=(val)
      self[:bindings] = val
    end
  end
  WhileLoop    = Struct.new(:token, :condition, :do_branch, :deferred_drops, :tight) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [do_branch].compact

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:tight] = !!self[:tight]
    end

    sig { returns(T::Boolean) }
    def tight = self[:tight]

    sig { params(value: T::Boolean).void }
    def tight=(value)
      self[:tight] = value
    end

    attr_accessor :mark_per_iter
  end
  WhileBindLoop = Struct.new(:token, :condition, :binding_name, :binding_token, :do_branch, :deferred_drops) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [do_branch].compact
    attr_accessor :mark_per_iter

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      @tight = T.let(false, T::Boolean)
    end

    sig { returns(T::Boolean) }
    def tight = @tight

    sig { params(value: T::Boolean).void }
    def tight=(value)
      @tight = value
    end
  end
  BreakNode    = Struct.new(:token) do
    include Locatable
    include StatementVoidType
  end
  ContinueNode = Struct.new(:token) do
    include Locatable
    include StatementVoidType
  end

  # Shared syntax metadata for calls with explicit mutable arguments. The
  # marker is consumed during annotation, so this keeps a source token rather
  # than introducing first-class reference semantics into MIR.
  module ExplicitMutableArguments
    extend T::Sig

    sig { params(index: Integer, token: Lexer::Token).void }
    def mark_explicit_mutable_argument!(index, token)
      explicit_mutable_argument_tokens[index] = token
    end

    sig { params(index: Integer).returns(T::Boolean) }
    def explicit_mutable_argument?(index)
      explicit_mutable_argument_tokens.key?(index)
    end

    sig { params(index: Integer).returns(T.nilable(Lexer::Token)) }
    def explicit_mutable_argument_token(index)
      explicit_mutable_argument_tokens[index]
    end

    sig { returns(T::Hash[Integer, Lexer::Token]) }
    def explicit_mutable_argument_tokens
      @explicit_mutable_argument_tokens = T.let(
        @explicit_mutable_argument_tokens,
        T.nilable(T::Hash[Integer, Lexer::Token])
      )
      @explicit_mutable_argument_tokens ||= {}
    end
  end

  FuncCall     = Struct.new(:token, :name, :args) do
    extend T::Sig
    include Locatable
    include ExplicitMutableArguments
    # ruby-to-clear: field-type name=Any
    attr_accessor :module_alias
    attr_accessor :extern_call       # true when calling a native EXTERN FN (no rt, no try)
    attr_accessor :extern_effects    # Set of effect symbols (:Alloc, etc.) from EXTERN FN EFFECTS declaration
    attr_accessor :extern_source
    attr_accessor :generic_type_args # Array of inferred type symbols for generic fns, e.g. [:Number]
    attr_accessor :fn_var_call       # true when calling a fn-type variable (not a named function)
    attr_accessor :pipe_lhs           # original LHS AST node when rewritten from pipeline (for CATCH snapshot)
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    # matched_signature is provided by Locatable for both function and method calls.
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
                                     # original `!T` is stashed here for OR_ELSE consumers
                                     # that need to know whether to emit `catch fallback`
                                     # (error union) or `orelse fallback` (optional).
    attr_accessor :retain_error_channel # explicit `x:!` / `x:!?` binding keeps the call result wrapped
    sig { returns(T.nilable(Symbol)) }
    def protocol_operation
      @protocol_operation = T.let(@protocol_operation, T.nilable(Symbol))
    end
    sig { params(value: Symbol).void }
    def protocol_operation=(value)
      @protocol_operation = value
    end
    sig { returns(T.nilable(String)) }
    def protocol_name
      @protocol_name = T.let(@protocol_name, T.nilable(String))
    end
    sig { params(value: String).void }
    def protocol_name=(value)
      @protocol_name = value
    end
    sig { returns(T.nilable(Integer)) }
    def protocol_receiver_index
      @protocol_receiver_index = T.let(@protocol_receiver_index, T.nilable(Integer))
    end
    sig { params(value: Integer).void }
    def protocol_receiver_index=(value)
      @protocol_receiver_index = value
    end
    sig { returns(FalseClass) }
    def wildcard?; false end
    sig { returns(String) }
    def name; self[:name].to_s end
  end

  MethodCall   = Struct.new(:token, :object, :name, :args) do
    extend T::Sig
    include Locatable
    include ExplicitMutableArguments
    attr_accessor :pool_method    # :insert, :get, :remove — set by annotator for Pool dispatch
    attr_accessor :set_method     # :insert, :contains, :remove, :count — set by annotator for Set dispatch
    attr_accessor :map_method     # :delete, :contains, :count, :keys, :values — set by annotator for HashMap dispatch
    attr_accessor :extern_call       # true when calling a native EXTERN method
    attr_accessor :extern_effects    # Hash of effect symbols from EXTERN FN EFFECTS declaration
    attr_accessor :extern_source
    attr_accessor :generic_type_args # Array of inferred type symbols for generic methods
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    attr_accessor :safe_nav_chain    # implicit continuation of an earlier ?. over non-optional members
    attr_accessor :error_union_type  # full !T requirement result before expression-level propagation unwraps it
    attr_accessor :retain_error_channel
    sig { params(token: Lexer::Token).void }
    def mark_explicit_mutable_receiver!(token)
      @explicit_mutable_receiver_token = T.let(token, T.nilable(Lexer::Token))
    end
    sig { returns(T::Boolean) }
    def explicit_mutable_receiver?
      !explicit_mutable_receiver_token.nil?
    end
    sig { returns(T.nilable(Lexer::Token)) }
    def explicit_mutable_receiver_token
      @explicit_mutable_receiver_token = T.let(@explicit_mutable_receiver_token, T.nilable(Lexer::Token))
    end
    sig { returns(T.nilable(Symbol)) }
    def protocol_operation
      @protocol_operation = T.let(@protocol_operation, T.nilable(Symbol))
    end
    sig { params(value: Symbol).void }
    def protocol_operation=(value)
      @protocol_operation = value
    end
    sig { returns(T.nilable(String)) }
    def protocol_name
      @protocol_name = T.let(@protocol_name, T.nilable(String))
    end
    sig { params(value: String).void }
    def protocol_name=(value)
      @protocol_name = value
    end
    sig { returns(T.nilable(String)) }
    def source_method_name
      @source_method_name = T.let(@source_method_name, T.nilable(String))
    end

    sig { params(value: String).void }
    def source_method_name=(value)
      @source_method_name = value
    end
    sig { returns(FalseClass) }
    def wildcard?; false end
    sig { returns(String) }
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
    # Set by visit_GetField when this reads an @boxed (heap-boxed) field:
    # the value is a one-level pointer that lower_get_field must deref.
    attr_accessor :indirect_field
    attr_accessor :safe_nav_chain
    # Zero-based Tuple position for `value._0`, `value._1`, ... . Kept
    # separate from field text so lowering never treats Tuple access as a
    # nominal struct lookup.
    sig { returns(T.nilable(Integer)) }
    def tuple_position
      @tuple_position = T.let(@tuple_position, T.nilable(Integer))
    end
    sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def tuple_position=(value)
      @tuple_position = T.let(value, T.nilable(Integer))
    end
    sig { returns(T::Boolean) }
    def wildcard?; field == '*' end
    sig { returns(String) }
    def name; target.name end
  end
  GetIndex     = Struct.new(:token, :target, :index) do
    extend T::Sig
    include Locatable
    attr_accessor :safe_nav_chain
    sig { returns(T.nilable(Symbol)) }
    def protocol_operation
      @protocol_operation = T.let(@protocol_operation, T.nilable(Symbol))
    end
    sig { params(value: Symbol).void }
    def protocol_operation=(value)
      @protocol_operation = value
    end
    sig { returns(String) }
    def name; target.name end
  end
  Cast         = Struct.new(:token, :value, :target) { include Locatable }
  ReturnNode   = Struct.new(:token, :value) do
    include Locatable
    end
  Assert       = Struct.new(:token, :condition, :message) { include Locatable }
  # RAISE Kind, ErrorName, "message"
  # kind: symbol (:Transient, :Input, :System, :NotFound, :Permission, :Canceled)
  # error_name: optional string (user-defined error enum name)
  # message_expr: optional string expression
  Raise        = Struct.new(:token, :kind, :error_name, :message_expr) { include Locatable }
  ThrowNode    = Struct.new(:token, :value) { include Locatable }
  DieNode      = Struct.new(:token, :status) { include Locatable }
  Slice        = Struct.new(:token, :target, :start, :end, :exclusive) do
    extend T::Sig
    include Locatable
  end
  Require      = Struct.new(:token, :path) { include Locatable }
  class WithMatchArm < T::Struct
    const :family, Symbol
    prop :body, RawBody, factory: -> { [] }
    prop :lock_error_clauses, T::Array[ErrorClause], factory: -> { [] }
    const :token, T.nilable(Lexer::Token), default: nil
  end

  # lock_error_clause: optional ErrorClause describing ON TIMEOUT / RETRY
  # handling for EXCLUSIVE / write_locked_read captures.
  # retries > 0 means RETRY(N) THEN <action>; retries nil/0 means plain ON TIMEOUT <action>.
  WithBlock    = Struct.new(:token, :capabilities, :body, :deferred_drops, :capability_plan) do
    extend T::Sig
    include Locatable
    include HasBodies
    include DeferredDropsField

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:capabilities] = [] if self[:capabilities].nil?
      @arms = T.let(nil, T.nilable(T::Array[AST::WithMatchArm]))
    end

    sig { params(val: T::Array[AST::Capability]).void }
    def capabilities=(val)
      self[:capabilities] = val
    end

    sig { returns(T::Array[RawBody]) }
    def child_bodies
      bodies = T.let([body].compact, T::Array[RawBody])
      match_arms = arms
      bodies.concat(match_arms.map(&:body)) if match_arms
      bodies
    end
    attr_accessor :lock_error_clause
    # Per-WITH opt-out from a static nested-lock check. Hash shape:
    #   { kind: :deadlock | :lock_cycle, token: Token }
    # nil = no opt-out; annotator rejects violating nesting.
    attr_accessor :deadlock_escape
    # Arms for the WITH MATCH form. nil for plain WITH (single-family).
    # Single-family WITH is a one-arm WithMatch internally; the parser
    # leaves arms nil when no MATCH keyword was used.
    sig { returns(T.nilable(T::Array[AST::WithMatchArm])) }
    def arms = @arms

    sig { params(value: T.nilable(T::Array[AST::WithMatchArm])).void }
    def arms=(value)
      @arms = value
    end
    # :view is a cheap immutable borrow on ~T@observable; :materialized_view is
    # an owned snapshot on any ~T aggregate; :unsafe_view is a scoped assertion
    # that a foreign pointer contains LENGTH elements. nil for traditional blocks.
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

  class FunctionDef
    extend T::Sig

    sig { returns(T::Array[AST::WithBlock]) }
    def semantic_with_blocks
      @semantic_with_blocks
    end

    sig { params(blocks: T::Array[AST::WithBlock]).void }
    def semantic_with_blocks=(blocks)
      @semantic_with_blocks = blocks
    end
  end

  # Top-level SYNC POLICY handlers use the same clause shape as
  # WithBlock#lock_error_clause. Policy validation lives in the annotator.
  SyncPolicyDecl = Struct.new(:token, :handlers) { include Locatable }

  # effect_mode is the compatibility classification consumed by existing
  # lowering. modifier_order preserves the exact SELECT annotation spelling
  # (`!~`, `~!`, `!~!`, etc.) so wrapper ordering remains a checked language
  # contract instead of being flattened into a set of effects.
  SelectOp = Struct.new(:token, :expression, :effect_mode, :stream_mode, :modifier_order, :capture_analysis) do
    extend T::Sig
    include Locatable
    include HasExpression
  end
  WhereOp      = Struct.new(:token, :expression) { include Locatable; include HasExpression }
  IndexOp      = Struct.new(:token, :expression) { include Locatable; include HasExpression }
  ReduceOp     = Struct.new(:token, :initial_value, :expression) { include Locatable; include HasExpression }
  OrderByOp    = Struct.new(:token, :expression) { include Locatable; include HasExpression }
  LimitOp      = Struct.new(:token, :count) { include Locatable }
  UnnestOp     = Struct.new(:token, :expression) { include Locatable; include HasExpression }
  DistinctOp   = Struct.new(:token, :expression) { include Locatable; include HasExpression }
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
  TakeWhileOp = Struct.new(:token, :expression) { include Locatable; include HasExpression }
  # WINDOW(size): sliding window of `size` elements. _ is the sub-slice.
  WindowOp = Struct.new(:token, :size, :expression) { include Locatable; include HasExpression }
  # WINDOW(size: N, time: 'Xms'): batch/tumbling window. _ is a T[] batch.
  # options = { "size" => size_node, "time" => time_node } (at least one required)
  BatchWindowOp = Struct.new(:token, :options, :expression) { include Locatable; include HasExpression }
  # JOIN(right_source) key_expr_or_lambda
  # Equi-join: shared key applied to both sides, or lambda(a, b) -> Bool.
  # Result: anonymous struct { left: L, right: ?R } for each left element.
  JoinOp = Struct.new(:token, :right_source, :key_expr) { include Locatable }
  # Phase 3 predicate query operators — return scalar values (not new lists).
  # All use `_` as the implicit item binding (like SELECT/WHERE).
  FindOp   = Struct.new(:token, :expression) { include Locatable; include HasExpression } # ?ElemType
  AnyOp    = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Bool
  AllOp    = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Bool
  CountOp  = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Int64
  # Phase 4 numeric aggregation operators — expression must be numeric.
  # SUM/AVERAGE return 0 for empty list; MIN/MAX panic on empty list.
  SumOp     = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Number
  AverageOp = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Number
  MinOp     = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Number (panics on empty)
  MaxOp     = Struct.new(:token, :expression) { include Locatable; include HasExpression } # Number (panics on empty)
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
    attr_accessor :shard_context  # set by annotator as PipelineShardContext
    attr_accessor :capture_analysis
  end
  Placeholder  = Struct.new(:token) { include Locatable }
  Copy         = Struct.new(:token, :value) { include Locatable }
  OptionalUnwrap = Struct.new(:token, :target) do
    # ruby-to-clear: field-type target=Node
    extend T::Sig
    include Locatable
    attr_accessor :error_union_type
    # ruby-to-clear: skip
    sig { returns(T.nilable(String)) }
    def name; target.respond_to?(:name) ? target.name : nil end

    # The postfix `?` spelling is also the marker used to continue a safe
    # navigation chain. Prefix `UNWRAP` is a definite-value operation and
    # must not silently turn a following field, index, or method access back
    # into an optional result.
    sig { returns(T::Boolean) }
    def safe_navigation?
      token.type == :CHAR && token.value == '?'
    end
  end
  # Explicit call-site mutation marker. It never denotes a first-class
  # reference: call annotation consumes it and records the marker on the
  # enclosing call before type checking/lowering the target value.
  MutableBorrow = Struct.new(:token, :target) do
    extend T::Sig
    include Locatable
  end
  OrElseRaise        = Struct.new(:token) { include Locatable }  # OR_ELSE RAISE - bubble up error (Zig's try)
  # OR_ELSE EXIT forms under the unified error system. Unspecified fields
  # inherit from the pre-existing rt.__error set by the failing call:
  #   OR_ELSE EXIT "msg"                — message-only override (kind/type inherited)
  #   OR_ELSE EXIT Kind                 — set kind, clear type
  #   OR_ELSE EXIT Kind, "msg"          — kind + msg, clear type
  #   OR_ELSE EXIT Kind, Type           — kind + type
  #   OR_ELSE EXIT Kind, Type, "msg"    — full override
  #   OR_ELSE EXIT Type                 — set type (kind auto-resolved)
  #   OR_ELSE EXIT Type, "msg"          — type + msg
  OrElseExit         = Struct.new(:token, :kind, :error_name, :message) { include Locatable }
  OrElsePass         = Struct.new(:token) { include Locatable }  # OR_ELSE PASS - ignore error, use undefined
  OrElsePrune        = Struct.new(:token) { include Locatable }  # OR_ELSE PRUNE - discard error, skip item (concurrent only)
  OrElseBreak        = Struct.new(:token) { include Locatable }  # OR_ELSE BREAK - error-to-break coercion in loops
  CatchItem = Struct.new(:form, :name, :token, keyword_init: true) do
    extend T::Sig
    sig { returns(Symbol) }
    def form; self[:form]; end
    sig { returns(String) }
    def name; self[:name]; end
    sig { returns(Lexer::Token) }
    def token; self[:token]; end
  end

  CatchFilter = Struct.new(:form, :value, :token, keyword_init: true) do
    extend T::Sig
    sig { returns(Symbol) }
    def form; self[:form]; end
    sig { returns(T.any(String, AST::Node)) }
    def value; self[:value]; end
    sig { returns(Lexer::Token) }
    def token; self[:token]; end
  end

  CatchClause = Struct.new(:items, :filters, :body, :kinds, :types,
                           :filter_types, :filter_messages,
                           keyword_init: true) do
    extend T::Sig

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      self[:items]           = [] if self[:items].nil?
      self[:filters]         = [] if self[:filters].nil?
      self[:body]            = [] if self[:body].nil?
      self[:kinds]           = [] if self[:kinds].nil?
      self[:types]           = [] if self[:types].nil?
      self[:filter_types]    = [] if self[:filter_types].nil?
      self[:filter_messages] = [] if self[:filter_messages].nil?
    end

    sig { returns(T::Array[CatchItem]) }
    def items; self[:items]; end
    sig { returns(T::Array[CatchFilter]) }
    def filters; self[:filters]; end
    sig { returns(T::Array[AST::Node]) }
    def body; self[:body]; end
    sig { params(val: T::Array[AST::Node]).void }
    def body=(val); self[:body] = val; end

    sig { returns(T::Array[Symbol]) }
    def kinds; self[:kinds]; end
    sig { params(val: T::Array[Symbol]).void }
    def kinds=(val); self[:kinds] = val; end

    sig { returns(T::Array[String]) }
    def types; self[:types]; end
    sig { params(val: T::Array[String]).void }
    def types=(val); self[:types] = val; end

    sig { returns(T::Array[String]) }
    def filter_types; self[:filter_types]; end
    sig { params(val: T::Array[String]).void }
    def filter_types=(val); self[:filter_types] = val; end

    sig { returns(T::Array[AST::Locatable]) }
    def filter_messages; self[:filter_messages]; end
    sig { params(val: T::Array[AST::Locatable]).void }
    def filter_messages=(val); self[:filter_messages] = val; end
  end

  # CATCH block: error handler at function bottom. Multiple CATCH clauses + optional DEFAULT.
  # catch_clauses: [AST::CatchClause]; default_body: [ASTNode] or nil
  CatchBlock     = Struct.new(:token, :catch_clauses, :default_body) do
    # ruby-to-clear: field-type catch_clauses=CatchClause[]
    # ruby-to-clear: field-type default_body=?(Node[])
    include Locatable
  end
  # RECOVER(default): pipeline operator that replaces errors with a default value.
  RecoverOp      = Struct.new(:token, :default_expr) { include Locatable }

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_fusible_stage?(node)
    case node
    when AST::WhereOp, AST::SelectOp, AST::TapOp, AST::TakeWhileOp,
         AST::LimitOp, AST::SkipOp
      true
    else
      false
    end
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_select_filter_op?(node)
    node.is_a?(AST::SelectOp) || node.is_a?(AST::WhereOp)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_stream_value_op?(node)
    pipeline_select_filter_op?(node) || node.is_a?(AST::EachOp)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_terminal_fold?(node)
    case node
    when AST::SumOp, AST::AverageOp, AST::CountOp, AST::ReduceOp,
         AST::MinOp, AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp
      true
    else
      false
    end
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_range_fold?(node)
    case node
    when AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp,
         AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp
      true
    else
      false
    end
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_list_terminal?(node)
    node.is_a?(AST::UnnestOp) || node.is_a?(AST::DistinctOp)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.pipeline_complex_op?(node)
    case node
    when AST::SelectOp, AST::WhereOp, AST::IndexOp, AST::ReduceOp,
         AST::OrderByOp, AST::LimitOp, AST::UnnestOp, AST::DistinctOp,
         AST::EachOp, AST::FindOp, AST::AnyOp, AST::AllOp,
         AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp,
         AST::TakeWhileOp, AST::WindowOp, AST::BatchWindowOp, AST::JoinOp,
         AST::TapOp, AST::SkipOp, AST::ShardOp, AST::ConcurrentOp
      true
    else
      false
    end
  end

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
  end

  # CapabilityWrap: single AST node for all capability wrapping.
  # ownership: nil | :multiowned | :shared
  # sync:      nil | :locked | :write_locked | :local
  # layout:    nil | :indirect
  CapabilityWrap    = Struct.new(:token, :value, :ownership, :sync, :layout, :lock_rank) do
    include Locatable
    extend T::Sig
    # Optional integer rank on @locked(rank: N) / @writeLocked(rank: N).
    # Used by Phase 3 to prove LockCycle freedom: when all participating
    # locks are ranked, acquiring any lock requires the new rank to be
    # strictly greater than every held rank, which makes cycles
    # structurally unrepresentable.
    # Mirror of Type#atomic? / indirect? / atomic_ptr?. The
    # `node.sync == :atomic [&& node.layout == :indirect]` checks were
    # reinvented inline across visit_CapabilityWrap / lower_cap_wrap
    # (decomplex Reification-Miss).
    sig { returns(T::Boolean) }
    def atomic? = sync == :atomic
    sig { returns(T::Boolean) }
    def indirect? = layout == :indirect
    sig { returns(T::Boolean) }
    def atomic_ptr? = atomic? && indirect?
    sig { returns(T::Boolean) }
    def locked? = sync == :locked
    sig { returns(T::Boolean) }
    def local? = sync == :local
    sig { returns(T::Boolean) }
    def multiowned? = ownership == :multiowned
	    sig { returns(T::Boolean) }
	    def shared_node? = ownership == :shared_node
	    sig { returns(T::Boolean) }
	    def write_locked? = sync == :write_locked
	    sig { returns(T::Boolean) }
	    def capability? = !!(ownership || sync || layout)
	    sig { returns(T::Boolean) }
	    def locked_sync? = locked? || write_locked?
	    sig { returns(T::Boolean) }
	    def local_storage_wrap? = local? || (indirect? && !sync && !ownership)
	  end
  MoveNode          = Struct.new(:token, :value) { include Locatable }  # MOVE expr               -> transfer Rc/Arc handle without retain
  # CopyNode -- explicit COPY expr (deep copy of value).
  #   deep_copy: true for unions with heap variants.
  #   alloc:     :heap (default) | :frame -- the allocator the duped buffer
  #              lives in. Inherited from the CONTAINER at auto-COPY sites
  #              so a `String[]@list` (frame list) auto-COPY allocates the
  #              new string in frame, not heap. Without this, frame
  #              containers ended up with heap elements -- the "mixed
  #              provenance" bug that forced cleanupAlloc. lower_copy reads
  #              this; hard-coded :heap pre-policy.
  CopyNode          = Struct.new(:token, :value) do
    extend T::Sig
    include Locatable
    attr_accessor :deep_copy
    sig { params(val: Symbol).returns(Symbol) }
    def alloc=(val); T.must(@alloc = T.let(val, T.nilable(Symbol))); end
    sig { returns(Symbol) }
    def alloc; @alloc = T.let(@alloc, T.nilable(Symbol)); @alloc || :heap; end
  end
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

    sig { params(args: InitArgs).void }
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
  ExternFnDecl     = Struct.new(:token, :name, :params, :return_type, :from_module, :effects,
                                :owner_type, :owner_type_params, :fn_type_params, :extern_source,
                                :return_lifetime) do
    # ruby-to-clear: field-type return_type=?Type
    # ruby-to-clear: field-type owner_type=?String
    # ruby-to-clear: field-type owner_type_params=String[]@symbol
    # ruby-to-clear: field-type fn_type_params=String[]@symbol
    # ruby-to-clear: field-type return_lifetime=Any
    extend T::Sig
    include Locatable
    # [:T, :U] for TypeName<T, U>.method
    sig { returns(T::Array[Symbol]) }
    def owner_type_params
      self[:owner_type_params]
    end

    # [:T] for fnName<T>(...)
    sig { returns(T::Array[Symbol]) }
    def fn_type_params
      self[:fn_type_params]
    end

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:params] = self[:params] || []
      rt = self[:return_type]
      self[:return_type] = Type.new(rt) unless rt.nil?
      self[:owner_type_params] = (self[:owner_type_params] || []).dup
      self[:fn_type_params] = (self[:fn_type_params] || []).dup
      self[:extern_source] ||= Schemas::ExternSource.new(
        dependency: self[:from_module] || "",
        symbol: self[:name]
      )
    end

    sig { params(value: T::Array[Symbol]).void }
    def owner_type_params=(value)
      self[:owner_type_params] = value.dup
    end

    sig { params(value: T::Array[Symbol]).void }
    def fn_type_params=(value)
      self[:fn_type_params] = value.dup
    end

    sig { params(val: T.nilable(T::Array[AST::Param])).returns(T::Array[AST::Param]) }
    def params=(val)
      self[:params] = val || []
    end

    sig { params(val: T.nilable(T.any(Type, Symbol, String))).void }
    def return_type=(val)
      self[:return_type] = val.nil? ? nil : Type.new(val)
    end

    sig { returns(Type) }
    def annotation_return_type
      self[:return_type] || Type.new(:Any)
    end
  end
  # ExternStructDecl: EXTERN STRUCT Name { fields } [CLOSE "method"] FROM "module"
  # Declares a native Zig/C struct type for CLEAR type-checking purposes.
  # CLOSE registers the type as a resource with auto-defer cleanup (RAII).
  ExternStructDecl = Struct.new(:token, :name, :field_decls, :from_module,
                                :type_params, :close_method, :as_type, :extern_source) do
    # ruby-to-clear: field-type from_module=?String
    # ruby-to-clear: field-type type_params=String[]@symbol
    # ruby-to-clear: field-type close_method=?String
    # ruby-to-clear: field-type as_type=?String
    extend T::Sig
    include Locatable
    # [:T, :U] for EXTERN STRUCT Name<T, U>
    sig { returns(T::Array[Symbol]) }
    def type_params
      self[:type_params]
    end

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:type_params] = (self[:type_params] || []).dup
      self[:extern_source] ||= Schemas::ExternSource.new(
        dependency: self[:from_module] || "",
        symbol: self[:as_type] || self[:name]
      )
    end

    sig { params(value: T::Array[Symbol]).void }
    def type_params=(value)
      self[:type_params] = value.dup
    end

    sig { returns(T::Hash[String, AST::StructField]) }
    def field_decls; self[:field_decls]; end
  end
  # EnumDef: ENUM Name { Variant1, Variant2, ... }
  # Declares a Zig enum type. variants is an Array of variant name strings.
  EnumDef          = Struct.new(:token, :name, :variants, :visibility) { include Locatable }
  class UnionMethodParamRequirement < T::Struct
    extend T::Sig

    const :name, String
    const :type, Type

    sig { returns(AST::Param) }
    def to_param
      AST::Param.new(name: name, type: type, default: nil, mutable: false, takes: false)
    end
  end

  class UnionMethodRequirement < T::Struct
    const :token, Lexer::Token
    const :name, String
    const :params, T::Array[UnionMethodParamRequirement]
    const :return_type, T.nilable(Type), default: nil
    const :body, T::Array[AST::Node], default: []
    const :has_default_body, T::Boolean, default: false
    const :visibility, Symbol, default: :package
  end

  # UnionDef: UNION Name { Variant1: Type, Variant2: Type, UnitVariant }
  # Declares a Zig tagged union (union(enum)). variants is a Hash of
  # { "VariantName" => value } where value is:
  #   nil                                          — unit variant (void payload)
  #   Type object                                  — single-type payload (existing)
  #   Schemas::InlineStructVariant                 — inline struct payload
  # methods: Array of UnionMethodRequirement records; empty when absent.
  #   — compile-time constraints verified after function registration.
  UnionDef         = Struct.new(:token, :name, :variants, :visibility, :type_params, :methods) do
    # ruby-to-clear: field-type type_params=String[]
    # ruby-to-clear: field-type methods=UnionMethodRequirement[]
    extend T::Sig
    include Locatable
    # Array of type param name strings, e.g. ["T"]
    sig { returns(T::Array[String]) }
    def type_params
      self[:type_params]
    end

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:type_params] = (self[:type_params] || []).dup
      @generic_params = T.let(type_params.map do |name|
        AST::GenericParamDecl.new(token: token, name: name)
      end, T::Array[AST::GenericParamDecl])
    end

    sig { params(value: T::Array[String]).void }
    def type_params=(value)
      self[:type_params] = value.dup
    end

    sig { returns(T::Array[AST::GenericParamDecl]) }
    def generic_params
      @generic_params
    end

    sig { params(value: T::Array[AST::GenericParamDecl]).void }
    def generic_params=(value)
      @generic_params = value.dup
    end
  end

  # UnionVariantLit: TypeName.VariantName{ field: val, ... }
  # Constructs an inline-struct variant of a union type.
  # union_name: String (e.g., "Shape"), variant_name: String (e.g., "Circle")
  # fields: Hash<String, ASTNode>
  UnionVariantLit  = Struct.new(:token, :union_name, :variant_name, :fields, :storage) { include Locatable }

  # StaticCall: TypeName::method(args) — type-level static method call.
  # type_name: AST::Identifier (the type), method_name: String, args: Array of ASTNode
  StaticCall        = Struct.new(:token, :type_name, :method_name, :args) do
    extend T::Sig
    include Locatable
    include ExplicitMutableArguments
    attr_accessor :error_union_type
    attr_accessor :retain_error_channel

    sig { returns(String) }
    def name = "#{type_name.name}::#{method_name}"

    sig { returns(T.nilable(AST::FuncCall)) }
    def inherent_call
      @inherent_call = T.let(@inherent_call, T.nilable(AST::FuncCall))
    end

    sig { params(value: AST::FuncCall).void }
    def inherent_call=(value)
      @inherent_call = value
    end


  end

  class DoBranch < T::Struct
    prop :body, T::Array[AST::Node], factory: -> { [] }
    prop :pinned, T::Boolean, default: false
    const :parallel, T::Boolean, default: false
    const :stack_size, T.nilable(Symbol), default: nil
    const :can_smash, T::Boolean, default: false
    prop :computed_stack_tier, T.nilable(Symbol), default: nil
    prop :capture_analysis, T.untyped, default: nil
  end

  # DoBlock: fork-join parallel execution.
  # branches: Array of DoBranch records.
  # pinned=true      → dispatch to least-loaded scheduler (spawnBest) instead of current (submitSpawn)
  # stack_size nil   → defaults to :standard (16 KB total: 12 KB stack + 4 KB arena)
  DoBlock           = Struct.new(:token, :branches) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[T::Array[AST::Node]]) }
    def child_bodies = branches.map(&:body)
  end

  # BgBlock: background execution — spawns a fiber and returns a linear Promise (~T).
  # body: Array of expression nodes. The last expression's type determines T.
  # Captured affine variables are MOVED into the fiber (not borrowed by pointer).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgBlock           = Struct.new(:token, :body, :deferred_drops, :stack_size, :pinned, :parallel, :arena_mode, :can_smash) do
    extend T::Sig
    include Locatable
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [body].compact
    attr_accessor :computed_stack_tier  # auto-computed tier from call-graph analysis (:micro, :standard, :large, :xl)
    attr_accessor :captures_resource  # true when BG captures a TCP/resource fd — spawn on accepting scheduler
    attr_accessor :capture_analysis  # CaptureAnalysis: captures, strategies, derived sets, safety flags
    attr_accessor :async_result_shape # AsyncResultShape: single authority for BG's spawned handle.
    # Contextual payload contract supplied by a directly enclosing declaration
    # or RETURN.  This distinguishes `~!T` (a promise whose payload is fallible)
    # from the ordinary `BG { fallibleCall() }` transport-error shorthand.
    attr_accessor :declared_async_payload
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

  class ThenStep < T::Struct
    prop :expr, AST::Node
    const :binding, T.nilable(String), default: nil
  end

  # ThenChain: sequential chaining of steps inside a BG block fiber.
  # steps: Array of ThenStep records.
  # Each step may bind its result to a name for use in subsequent steps.
  # The last step's type determines the ThenChain's full_type.
  ThenChain         = Struct.new(:token, :steps) { include Locatable }

  # BgStreamBlock: background generator — spawns a fiber that YIELDs values into a Stream.
  # body: Array of statements; YIELD expressions push values. Returns [~]T (finite stream).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgStreamBlock     = Struct.new(:token, :body, :deferred_drops, :stack_size) do
    extend T::Sig
    include Locatable
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [body].compact
    attr_accessor :computed_stack_tier
    attr_accessor :capture_analysis  # CaptureAnalysis with captures hash
      # FSM Phase A: set by FsmClassifier (see effects.rb).
    attr_accessor :spawn_form
    attr_accessor :fsm_ineligible_reason
    attr_accessor :fsm_suspend_points

    sig { returns(T.nilable(Type)) }
    def declared_yield_type
      @declared_yield_type
    end

    sig { returns(T.nilable(Lexer::Token)) }
    def yields_token
      @yields_token
    end

    sig { params(type: T.nilable(Type), token: T.nilable(Lexer::Token)).void }
    def set_yield_contract(type, token)
      @declared_yield_type = T.let(type, T.nilable(Type))
      @yields_token = T.let(token, T.nilable(Lexer::Token))
    end
  end

  # YieldExpr: push a value into the enclosing BG STREAM's buffer.
  # Only valid inside a BgStreamBlock body. expr: the value to yield.
  YieldExpr         = Struct.new(:token, :expr) do
    extend T::Sig
    include Locatable

    sig { returns(AST::Node) }
    def expr
      self[:expr]
    end
  end

  # CloseStream: explicitly terminate the enclosing finite BG STREAM.
  # Completion is a control event and carries no item payload.
  CloseStream       = Struct.new(:token) do
    include Locatable
    include StatementVoidType
  end

  # NextExpr: consume a Promise (~T), blocking the current fiber until the result is ready.
  # expr: the ~T expression to wait on (must be a tense type). Marks the promise as moved.
  NextExpr          = Struct.new(:token, :expr) do
    extend T::Sig
    include Locatable

    sig { returns(AST::Node) }
    def expr
      self[:expr]
    end
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

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:cases] = [] if self[:cases].nil?
    end

    sig { params(val: T::Array[AST::MatchCase]).void }
    def cases=(val)
      self[:cases] = val
    end

    sig { returns(AST::Node) }
    def expr
      self[:expr]
    end

    sig { returns(T::Array[RawBody]) }
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
  ForRange          = Struct.new(:token, :var_name, :start_expr, :end_expr, :inclusive, :body, :deferred_drops, :mark_per_iter, :tight) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [body].compact

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      self[:tight] = !!self[:tight]
    end

    sig { returns(T::Boolean) }
    def tight = self[:tight]

    sig { params(value: T::Boolean).void }
    def tight=(value)
      self[:tight] = value
    end
  end

  # ForEach: FOR var IN collection DO body END
  ForEach           = Struct.new(:token, :var_name, :collection, :body, :deferred_drops, :is_mutable) do
    extend T::Sig
    include Locatable
    include StatementVoidType
    include HasBodies
    include DeferredDropsField
    sig { returns(T::Array[RawBody]) }
    def child_bodies = [body].compact
    attr_accessor :mark_per_iter

    sig { params(args: InitArgs).void }
    def initialize(*args)
      super
      @tight = T.let(false, T::Boolean)
    end

    sig { returns(T::Boolean) }
    def tight = @tight

    sig { params(value: T::Boolean).void }
    def tight=(value)
      @tight = value
    end
  end

  # ── Test Framework ───────────────────────────────────────────────

  # TEST name DO setup... WHEN... END
  TestBlock = Struct.new(:token, :name, :setup, :whens) do
    extend T::Sig
    include Locatable
    include HasBodies
    sig { returns(T::Array[RawBody]) }
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
  LetBinding = Struct.new(:token, :name, :expr) do
    extend T::Sig
    include Locatable

    sig { returns(AST::Node) }
    def expr
      self[:expr]
    end
  end

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
  AssertRaises = Struct.new(:token, :kind, :error_name, :expression) { include Locatable; include HasExpression }

  # BENCHMARK expr x<N>
  BenchmarkStmt = Struct.new(:token, :expression, :iterations) { include Locatable; include HasExpression }

  # SMASH expr
  SmashStmt = Struct.new(:token, :expression) { include Locatable; include HasExpression }

  # PROFILE expr
  ProfileStmt = Struct.new(:token, :expression) { include Locatable; include HasExpression }

  class SelectOp
    extend T::Sig
    sig { returns(T.untyped) }
    def capture_analysis; self[:capture_analysis]; end
    sig { params(value: T.untyped).returns(T.untyped) }
    def capture_analysis=(value); self[:capture_analysis] = value; end
    sig { returns(AST::Node) }
    def expression; self[:expression]; end

    sig { returns(T.nilable(Symbol)) }
    def effect_mode; self[:effect_mode]; end
  end
  class WhereOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class IndexOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class ReduceOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class OrderByOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class UnnestOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class DistinctOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class TakeWhileOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class WindowOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class BatchWindowOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class FindOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class AnyOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class AllOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class CountOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class SumOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class AverageOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class MinOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class MaxOp
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class AssertRaises
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class BenchmarkStmt
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class SmashStmt
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end
  class ProfileStmt
    extend T::Sig
    sig { returns(AST::Node) }
    def expression; self[:expression]; end
  end

  # STUB fn RETURNS value | STUB fn CAPTURES var | STUB fn SEQUENCE [...] | STUB fn WITH lambda
  StubDecl = Struct.new(:token, :function_name, :kind, :value) { include Locatable }
  # kind: :returns, :captures, :sequence, :with

  # ruby-to-clear: data-api
  UNARY_OPS = ['-', '!', '~']

  PRIMITIVE_TYPES = [:Number, :Bool, :Byte, :Int64, :Float64,
                     :Int8, :Int16, :Int32,
                     :UInt8, :UInt16, :UInt32, :UInt64,
                     :Float32, :TargetInt, :TargetUInt, :TargetLong,
                     :TargetULong, :TargetLongLong, :TargetULongLong]

  # ruby-to-clear: data-api
  sig { params(ops: T::Array[String], assoc: Symbol).returns(PrecedenceInfo) }
  def self.precedence_info(ops:, assoc:)
    info = T.let({}, PrecedenceInfo)
    info[:ops] = ops
    info[:assoc] = assoc
    info
  end

  PRECEDENCE_MAP = T.let({
    13 => precedence_info(ops: ['**'], assoc: :right),
    12 => precedence_info(ops: ['*', '/', 'MOD'], assoc: :left),
    11 => precedence_info(ops: ['+', '$+', '-'], assoc: :left),
    10 => precedence_info(ops: ['<<', '>>'], assoc: :left),
    9 => precedence_info(ops: ['BIT_AND'], assoc: :left),
    8 => precedence_info(ops: ['XOR'], assoc: :left),
    7 => precedence_info(ops: ['BIT_OR'], assoc: :left),
    6 => precedence_info(ops: ['IS_A', '==', '!=', '<', '>', '<=', '>='], assoc: :left),
    5 => precedence_info(ops: ['AND'], assoc: :left),
    4 => precedence_info(ops: ['OR'], assoc: :left),
    3 => precedence_info(ops: ['..<', '..<=', '..='], assoc: :left),
    2 => precedence_info(ops: ['OR_ELSE', 'AS'], assoc: :left),
    1 => precedence_info(ops: ['|>'], assoc: :left)
  }, T::Hash[Integer, PrecedenceInfo])
  MAX_PRECEDENCE = T.let(T.must(PRECEDENCE_MAP.keys.max), Integer)

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
    :XOR => :^,
    :BIT_AND => :&,
    :BIT_OR => :|,
    :SHL => :<<,
    :SHR => :>>,
  }, T::Hash[Symbol, Symbol])

  # Canonical definitions are in Type class. These aliases maintain backward compat.
  NUMBER_RESULT_OPS = Type::NUMBER_RESULT_OPS
  BOOL_RESULT_OPS = Type::BOOL_RESULT_OPS

  # ruby-to-clear: data-api
  OP_TO_OP_CODE = T.let({
    '+' => :ADD,
    '$+' => :CONCAT,
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
    'AND' => :AND,
    'OR' => :OR,
    'MOD' => :MOD,
    'OR_ELSE' => :OR_ELSE,
    '~' => :BITWISE_NOT,
    'XOR' => :XOR,
    'BIT_AND' => :BIT_AND,
    'BIT_OR' => :BIT_OR,
    '<<' => :SHL,
    '>>' => :SHR,
    'AS' => :BIND_VAR,
    '%+' => :WRAP_ADD,
    '%-' => :WRAP_SUB,
    '%*' => :WRAP_MUL,
    '!+' => :CHECK_ADD,
    '!-' => :CHECK_SUB,
    '!*' => :CHECK_MUL,
  }, T::Hash[String, Symbol])

  # ruby-to-clear: data-api
  CAPABILITIES = [:RESTRICT, :EXCLUSIVE, :BORROWED, :VIEW, :MATERIALIZED_VIEW, :UNSAFE_VIEW, :SNAPSHOT]
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
  #                    :heap_union, :heap_struct, :struct_with_cleanup_fields,
  #                    :struct_rc, :non_copy_union, :takes_union,
  #                    :takes_string, :takes_slice
  # alloc:             :heap or :frame — which allocator owns this value
  # has_moved_guard:   boolean — emit `var x_moved = false; defer if (!x_moved) ...`
  # resource_close_plan: structural close/deinit plan for :resource kind.
  # MIR::Drop carries a cleanup_entry that captures the full classifier
  # output (zig_type / alloc / has_moved_guard / kind side-channels). The
  # raw Struct fields (token, name) are the marker; everything cleanup-
  # relevant lives on the cleanup_entry attribute.
  Drop = Struct.new(:token, :name) do
    extend T::Sig
    include AST::Locatable
    attr_accessor :cleanup_entry
  end

  # SuppressCleanup: move suppression marker inserted at consumption points
  # (TAKES calls, GIVE, return escapes). Emits `x_moved = true;` to prevent
  # double-free via the defer guard emitted by Drop.
  SuppressCleanup = Struct.new(:token, :name) do
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

  # ReassignPlan: stamped on AST::BindExpr (:assign mode) by MIRPass when
  # the OLD value of the binding needs cleanup before the overwrite.
  # Replaces a `{ alloc:, zig_type: }` hash; the struct is the single
  # consumer-facing contract.
  ReassignPlan = Struct.new(:alloc, :zig_type, :lifecycle_plan, keyword_init: true) do
    extend T::Sig

    sig { returns(Symbol) }
    def alloc!
      alloc
    end

    sig { returns(String) }
    def zig_type!
      zig_type
    end

    sig { returns(T.untyped) }
    def lifecycle_plan
      self[:lifecycle_plan]
    end
  end

end
