require_relative "type"

# ==========================================
# AST
# ==========================================
module AST
  module Locatable
    def line; token.line; end
    def column; token.column; end
    def token_value; token.value; end

    attr_reader :coerced_type_object
    attr_reader :type_object
    attr_accessor :zig_pattern
    attr_accessor :was_moved
    attr_accessor :slot_size

    # Set full_type. Accepts a Type object (stored directly) or any other
    # value (wrapped in Type.new for backward compatibility).
    def full_type=(val)
      @type_object = val.is_a?(Type) ? val : Type.new(val)
    end

    # Returns the Type object directly. Callers use type_info for rich access
    # and == / .to_s / Type.new(full_type) for interop.
    def full_type
      @type_object
    end

    def coerced_type=(val)
      return @coerced_type_object = nil if val.nil?

      # Same logic: Wrap raw values, accept Type objects
      @coerced_type_object = val.is_a?(Type) ? val : Type.new(val)
    end

    def coerced_type
      @coerced_type_object&.raw
    end

    # Use this to access the rich object for coerced types
    def coerced_type_info
      @coerced_type_object
    end

    # Resolves the final type, handling coercion if needed.
    # Returns [final_type, error]. Error is nil if ok.
    #
    # @param declared_type [Symbol, nil] The explicitly declared type (or nil/:Any for inference)
    # @return [Array(Symbol, String|nil)] [final_type, error_message]
    #
    def coerce!(declared_type)
      inferred = @type_object&.resolved

      # No explicit type or :Any -> use inferred, no coercion needed
      return [inferred, nil] if declared_type.nil? || declared_type == :Any

      # Explicit type matches inferred -> no coercion needed
      return [declared_type, nil] if declared_type == inferred

      # Check if coercion is valid
      error = Type.coerce_error(@type_object, declared_type)
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
    def finalize_storage!(final_type, &schema_lookup)
      # Calculate slot size
      type_obj = Type.new(final_type)
      @slot_size = type_obj.slot_size(&schema_lookup)

      # Determine storage from value's type if this node has a value
      if respond_to?(:value) && value.respond_to?(:type_object) && value.type_object
        value_type = value.type_object
        storage = value_type.finalize_storage(@slot_size, value.storage)
        # Declared type may require heap: pointer types (%Type annotation)
        storage = :heap if type_obj.heap?
        value.storage = storage if value.respond_to?(:storage=)
      else
        storage = type_obj.finalize_storage(@slot_size, nil)
      end

      # Determine if value has a sync capability
      value_sync = nil
      if respond_to?(:value) && value.respond_to?(:type_object) && value.type_object
        vt = value.type_object
        value_sync = vt.sync if vt.respond_to?(:sync)
      end

      # Build a Type that carries the resolved base type plus storage-derived capabilities.
      base_sym = final_type.is_a?(Type) ? final_type.resolved : final_type
      t = Type.new(base_sym)
      case storage
      when :multiowned
        t.ownership = :multiowned   # also sets t.location = :multiowned via setter
      when :shared
        t.ownership = :shared       # also sets t.location = :shared via setter
      when :heap
        if value_sync == :locked
          t.sync = :locked          # sync= setter sets location = :heap
        elsif value_sync == :write_locked
          t.sync = :write_locked    # sync= setter sets location = :heap
        else
          t.location = :heap
        end
      end

      # Propagate additional capability fields from the value's type_object
      if respond_to?(:value) && value.respond_to?(:type_object) && value.type_object
        vt = value.type_object
        t.ownership = vt.ownership if vt.respond_to?(:ownership) && vt.ownership && vt.ownership != :affine
        t.sync      = vt.sync      if vt.respond_to?(:sync) && vt.sync
      end

      self.full_type = t

      # Override storage in case Type's default differs from finalized storage
      self.storage = storage

      storage
    end

    # -- NEW PREFERRED ACCESSOR --
    # Use this in new code to get the rich object
    def type_info
      @type_object
    end

    # -- REFACTORED HELPERS --
    # Delegate to the new class
    def resolved_type
      @type_object&.resolved
    end

    def base_type
      @type_object&.base_type
    end

    def storage
      @type_object&.location
    end

    def storage=(val)
      @type_object.location = val
    end


    def metatype
      return :lambda if self.is_a?(LambdaLit)
      return :named_function if self.is_a?(FunctionDef)

      t = @type_object
      return nil unless t

      return :void if t.resolved == :Void
      return :die if t.resolved == :NoReturn
      return :array if t.resolved.to_s.end_with?("]")
      return :hashmap if t.resolved.to_s.start_with?("HashMap")
      return :struct if !t.primitive?
      return :primitive
    end
  end

  Program      = Struct.new(:token, :statements) { include Locatable }
  # kind: :local (REQUIRE "file.cht") or :package (REQUIRE "pkg:name")
  RequireNode  = Struct.new(:token, :path, :namespace, :kind) { include Locatable }
  FunctionDef  = Struct.new(:token, :name, :params, :captures, :return_type, :return_lifetime, :body, :catch_body, :catch_var, :visibility, :deferred_drops, :uses_frame) { include Locatable }
  StructDef    = Struct.new(:token, :name, :fields, :visibility) { include Locatable }
  VarDecl      = Struct.new(:token, :name, :type, :value, :mutable) { include Locatable }
  Assignment   = Struct.new(:token, :name, :value) { include Locatable }
  # Keywordless bind: `x = val` or `x: Type = val`. Annotator sets mode to :decl or :assign.
  BindExpr     = Struct.new(:token, :name, :type, :value) { include Locatable; attr_accessor :mode }
  BinaryOp     = Struct.new(:token, :left, :op, :right) { include Locatable }
  UnaryOp      = Struct.new(:token, :op, :right) { include Locatable }
  Identifier   = Struct.new(:token, :name) do
    include Locatable
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  Literal      = Struct.new(:token, :type, :value, :storage) { include Locatable }
  ListLit      = Struct.new(:token, :items, :storage) { 
    include Locatable 

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
  StructLit    = Struct.new(:token, :name, :fields, :storage) { include Locatable }
  LambdaLit    = Struct.new(:token, :params, :captures, :body, :storage, :deferred_drops) { include Locatable }
  IfStatement  = Struct.new(:token, :condition, :then_branch, :else_branch, :then_drops, :else_drops) { include Locatable }
  WhileLoop    = Struct.new(:token, :condition, :do_branch, :deferred_drops) { include Locatable }
  BreakNode    = Struct.new(:token) { include Locatable }
  ContinueNode = Struct.new(:token) { include Locatable }
  FuncCall     = Struct.new(:token, :name, :args) do
    include Locatable
    attr_accessor :module_alias
    attr_accessor :extern_call   # true when calling a native EXTERN FN (no rt, no try)
    def wildcard?; false end
    def name; self[:name].to_s end
  end

  MethodCall   = Struct.new(:token, :object, :name, :args) do
    include Locatable
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  GetField     = Struct.new(:token, :target, :field) do
    include Locatable
    def wildcard?; field == '*' end
    def name; target.name end
  end
  GetIndex     = Struct.new(:token, :target, :index) { include Locatable }
  Cast         = Struct.new(:token, :value, :target) { include Locatable }
  ReturnNode   = Struct.new(:token, :value) { include Locatable }
  Assert       = Struct.new(:token, :condition, :message) { include Locatable }
  Raise        = Struct.new(:token, :message_expr) { include Locatable }
  ThrowNode    = Struct.new(:token, :value) { include Locatable }
  DieNode      = Struct.new(:token, :status) { include Locatable }
  Slice        = Struct.new(:token, :target, :start, :end) { include Locatable }
  Require      = Struct.new(:token, :path) { include Locatable }
  WithBlock    = Struct.new(:token, :capabilities, :body, :deferred_drops) { include Locatable }

  SelectOp     = Struct.new(:token, :expression) { include Locatable }
  WhereOp      = Struct.new(:token, :expression) { include Locatable }
  IndexOp      = Struct.new(:token, :expression) { include Locatable }
  ReduceOp     = Struct.new(:token, :initial_value, :expression) { include Locatable }
  OrderByOp    = Struct.new(:token, :expression) { include Locatable }
  LimitOp      = Struct.new(:token, :count) { include Locatable }
  UnnestOp     = Struct.new(:token, :expression) { include Locatable }
  DistinctOp   = Struct.new(:token, :expression) { include Locatable }
  Placeholder  = Struct.new(:token) { include Locatable }
  Copy         = Struct.new(:token, :value) { include Locatable }
  OptionalUnwrap = Struct.new(:token, :target) { include Locatable }
  OrRaise        = Struct.new(:token) { include Locatable }  # OR RAISE - bubble up error (Zig's try)
  OrPass         = Struct.new(:token) { include Locatable }  # OR PASS - ignore error, use undefined
  # CapabilityWrap: single AST node for all capability wrapping.
  # ownership: nil | :multiowned | :shared
  # sync:      nil | :locked | :write_locked
  CapabilityWrap    = Struct.new(:token, :value, :ownership, :sync) { include Locatable }
  MoveNode          = Struct.new(:token, :value) { include Locatable }  # MOVE expr               -> transfer Rc/Arc handle without retain
  # PassStmt: no-op statement (like Python's `pass`).
  PassStmt          = Struct.new(:token) { include Locatable }
  # StructPattern: destructuring pattern for MATCH.
  # fields: Array of { name: String, value: ASTNode | :wildcard }
  # partial: Boolean — true when `...` is present (remaining fields ignored)
  StructPattern     = Struct.new(:token, :fields, :partial) { include Locatable }
  # RangeLit: a range expression (start..<end) or (start..<=end).
  # inclusive: false = exclusive end (..<), true = inclusive end (..<=)
  RangeLit          = Struct.new(:token, :start, :finish, :inclusive) { include Locatable }
  # ExternFnDecl: EXTERN FN name(params) RETURNS type FROM "module"
  # Declares a native Zig/C function importable via @import("module").
  ExternFnDecl     = Struct.new(:token, :name, :params, :return_type, :from_module) { include Locatable }
  # ExternStructDecl: EXTERN STRUCT Name { fields } FROM "module"
  # Declares a native Zig/C struct type for CLEAR type-checking purposes.
  ExternStructDecl = Struct.new(:token, :name, :fields, :from_module) { include Locatable }
  # EnumDef: ENUM Name { Variant1, Variant2, ... }
  # Declares a Zig enum type. variants is an Array of variant name strings.
  EnumDef          = Struct.new(:token, :name, :variants, :visibility) { include Locatable }

  # DoBlock: fork-join parallel execution.
  # branches: Array of expression arrays — each sub-array is one parallel branch.
  DoBlock           = Struct.new(:token, :branches) { include Locatable }

  # MatchStatement: pattern-matching on a value.
  # cases: Array of { value: ASTNode, body: [ASTNode] }
  # default_case: [ASTNode] or nil
  # case_drops: Array of drop-arrays (parallel to cases), filled by annotator
  # default_drops: drop-array for default branch (or nil), filled by annotator
  MatchStatement    = Struct.new(:token, :expr, :cases, :default_case, :case_drops, :default_drops) { include Locatable }

  UNARY_OPS = ['-', '!', '~']

  PRIMITIVE_TYPES = [:Number, :Bool, :Byte, :Int64, :Float64]

  PRECEDENCE_MAP = {
    8 => { ops: ['**'], assoc: :right },
    7 => { ops: ['*', '/', 'MOD'], assoc: :left },
    6 => { ops: ['+', '-'], assoc: :left },
    5 => { ops: ['==', '!=', '<', '>', '<=', '>='], assoc: :left },
    4 => { ops: ['&&'], assoc: :left },
    3 => { ops: ['||'], assoc: :left },
    # LEVEL 1: Both Pipe and Rescue live here.
    # They bind loosely and strictly left-to-right.
    1 => { ops: ['OR', 's>', 'AS'], assoc: :left }
  }
  MAX_PRECEDENCE = PRECEDENCE_MAP.keys.max

  OP_CODE_SENDABLE_SYMS = {
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
  }

  NUMBER_RESULT_OPS = [:SUB, :MUL, :DIV, :POW, :MOD]
  BOOL_RESULT_OPS = [:EQ, :NEQ, :LT, :GT, :LTE, :GTE]

  # TODO: Make these symbols
  OP_TO_OP_CODE = {
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
    'OR' => :OR_RESCUE, # TODO: Check if this is necessary
    '~' => :BITWISE_NOT,
    'AS' => :BIND_VAR
  }

  CAPABILITIES = [:RESTRICT, :EXCLUSIVE]
end

