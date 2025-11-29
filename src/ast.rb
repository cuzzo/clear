# ==========================================
# AST
# ==========================================
module AST
  Program     = Struct.new(:line, :statements)
  FunctionDef = Struct.new(:line, :name, :params, :captures, :return_type, :body, :catch_body, :catch_var)
  VarDecl     = Struct.new(:line, :name, :type, :value)
  Assignment  = Struct.new(:line, :name, :value)
  BinaryOp    = Struct.new(:line, :left, :op, :right)
  UnaryOp     = Struct.new(:line, :op, :right)
  Literal     = Struct.new(:line, :type, :value)
  Identifier  = Struct.new(:line, :name)
  ListLit     = Struct.new(:line, :items)
  HashLit     = Struct.new(:line, :pairs)
  StructLit   = Struct.new(:line, :name, :fields)
  StructDef   = Struct.new(:line, :name, :fields)
  IfStatement = Struct.new(:line, :condition, :then_branch, :else_branch)
  WhileLoop   = Struct.new(:line, :condition, :do_branch)
  BreakNode   = Struct.new(:line)
  ContinueNode = Struct.new(:line)
  Lambda      = Struct.new(:line, :params, :captures, :body)
  FuncCall    = Struct.new(:line, :name, :args)
  MethodCall  = Struct.new(:line, :object, :method, :args)
  GetField    = Struct.new(:line, :target, :field)
  GetIndex    = Struct.new(:line, :target, :index)
  Cast        = Struct.new(:line, :value, :target)
  ReturnNode  = Struct.new(:line, :value)
  Assert      = Struct.new(:line, :condition, :message)
  Raise       = Struct.new(:line, :message_expr)
  ThrowNode   = Struct.new(:line, :value)
  DieNode     = Struct.new(:line, :status)

  UNARY_OPS = ['-', '!', '~']

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

