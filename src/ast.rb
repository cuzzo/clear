# ==========================================
# AST
# ==========================================
module AST
  module Locatable
    def line; token.line; end
    def column; token.column; end
    def token_value; token.value; end
    attr_accessor :full_type
    attr_accessor :coerced_type
    attr_accessor :zig_pattern

    def resolved_type
      # function_signature
      if full_type.is_a?(Hash)
        ft = full_type[:return_type]
      # Lambda
      elsif full_type.is_a?(Array)
        ft = full_type[2]
      else
        ft = full_type
      end

      if ft[0] == "%"
        full_type[1..].to_sym
      else
        full_type
      end
    end

    def storage
      full_type[0] == "%" ? :heap : :stack
    end

    def metatype
      return :lambda if self.is_a?(LambdaLit)
      return :named_function if self.is_a?(FunctionDef)
      return nil if resolved_type.nil?
      return :hashmap if resolved_type == :HashMap
      return :void if resolved_type == :Void
      return :die if resolved_type == :NoReturn
      return :array if resolved_type.to_s.end_with?("]")
      return :struct if !PRIMITIVE_TYPES.include?(resolved_type)
      return :primitive
    end
  end

  Program      = Struct.new(:token, :statements) { include Locatable }
  FunctionDef  = Struct.new(:token, :name, :params, :captures, :return_type, :body, :catch_body, :catch_var) { include Locatable }
  StructDef    = Struct.new(:token, :name, :fields) { include Locatable }
  VarDecl      = Struct.new(:token, :name, :type, :value, :mutable) { include Locatable }
  Assignment   = Struct.new(:token, :name, :value) { include Locatable }
  BinaryOp     = Struct.new(:token, :left, :op, :right) { include Locatable }
  UnaryOp      = Struct.new(:token, :op, :right) { include Locatable }
  Identifier   = Struct.new(:token, :name) { include Locatable }
  Literal      = Struct.new(:token, :type, :value, :storage) { include Locatable }
  ListLit      = Struct.new(:token, :items, :storage) { include Locatable }
  HashLit      = Struct.new(:token, :pairs, :storage) { include Locatable }
  StructLit    = Struct.new(:token, :name, :fields, :storage) { include Locatable }
  LambdaLit    = Struct.new(:token, :params, :captures, :body, :storage) { include Locatable }
  IfStatement  = Struct.new(:token, :condition, :then_branch, :else_branch) { include Locatable }
  WhileLoop    = Struct.new(:token, :condition, :do_branch) { include Locatable }
  BreakNode    = Struct.new(:token) { include Locatable }
  ContinueNode = Struct.new(:token) { include Locatable }
  FuncCall     = Struct.new(:token, :name, :args) { include Locatable }
  MethodCall   = Struct.new(:token, :object, :name, :args) { include Locatable }
  GetField     = Struct.new(:token, :target, :field) { include Locatable }
  GetIndex     = Struct.new(:token, :target, :index) { include Locatable }
  Cast         = Struct.new(:token, :value, :target) { include Locatable }
  ReturnNode   = Struct.new(:token, :value) { include Locatable }
  Assert       = Struct.new(:token, :condition, :message) { include Locatable }
  Raise        = Struct.new(:token, :message_expr) { include Locatable }
  ThrowNode    = Struct.new(:token, :value) { include Locatable }
  DieNode      = Struct.new(:token, :status) { include Locatable }
  Slice        = Struct.new(:token, :target, :start, :end) { include Locatable }
  Require      = Struct.new(:token, :path) { include Locatable }

  UNARY_OPS = ['-', '!', '~']

  PRIMITIVE_TYPES = [:Number, :Bool, :Byte]

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
end

