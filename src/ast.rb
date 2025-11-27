# ==========================================
# AST
# ==========================================
module AST
  Program     = Struct.new(:statements)
  FunctionDef = Struct.new(:name, :params, :captures, :return_type, :body, :catch_body, :catch_var)
  VarDecl     = Struct.new(:name, :type, :value)
  Assignment  = Struct.new(:name, :value)
  BinaryOp    = Struct.new(:left, :op, :right)
  UnaryOp     = Struct.new(:op, :right)
  Literal     = Struct.new(:type, :value)
  Identifier  = Struct.new(:name)
  ListLit     = Struct.new(:items)
  HashLit     = Struct.new(:pairs)
  StructLit   = Struct.new(:name, :fields)
  StructDef   = Struct.new(:name, :fields)
  IfStatement = Struct.new(:condition, :then_branch, :else_branch)
  WhileLoop   = Struct.new(:condition, :do_branch)
  Lambda      = Struct.new(:params, :captures, :body)
  FuncCall    = Struct.new(:name, :args)
  MethodCall  = Struct.new(:object, :method, :args)
  GetField    = Struct.new(:target, :field)
  GetIndex    = Struct.new(:target, :index)
  Cast        = Struct.new(:value, :target)
  ReturnNode  = Struct.new(:value)
  Assert      = Struct.new(:condition, :message)
  Raise       = Struct.new(:message_expr)
  ThrowNode   = Struct.new(:value)

  BINARY_OPS = ['+', '*', '/', '==', '!=', '>', '>=', '<', '<=', 's>', '&&', '||', 'MOD', '**']
  UNARY_OPS = ['-', '!', '~']

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
    :BITWISE_NOT => :~
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
    'OR' => :OR_RESCUE,
    '~' => :BITWISE_NOT
  }

end



