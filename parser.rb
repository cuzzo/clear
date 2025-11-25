#! /usr/bin/env ruby

require 'strscan'
require 'logger'
require 'byebug'

# ==========================================
# 1. AST
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
  UNARY_OPS = ['-', '!']

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
    'OR' => :OR_RESCUE
  }
end

# ==========================================
# 2. LEXER 
# ==========================================
class Lexer
  Token = Struct.new(:type, :value, :line)

  # We use a hash for O(1) lookups
  # TODO: Should MOD be a keyword ???
  KEYWORDS = %w[
      VAR SET
      FN RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END 
      WHILE DO 
      CAST AS
      STRUCT TRUE FALSE NIL 
      ASSERT RAISE CATCH OR EXIT
    ].map { |k| [k, true] }.to_h

  def initialize(source)
    @s = StringScanner.new(source)
    @line = 1
    @tokens = []
  end

  def tokenize
    until @s.eos?
      case
      when @s.scan(/\s+/)
        @line += @s.matched.count("\n")

      when @s.scan(/--.*$/)
        # Comment - ignore

      when @s.scan(/->/) then add(:ARROW, '->')
      when @s.scan(/s>/) then add(:SMOOTH, 's>')
      when @s.scan(/==/) then add(:CHAR, '==')
      when @s.scan(/>=/) then add(:CHAR, '>=')
      when @s.scan(/<=/) then add(:CHAR, '<=')
      when @s.scan(/!=/) then add(:CHAR, '!=')
      when @s.scan(/&&/) then add(:CHAR, '&&')
      when @s.scan(/\*\*/) then add(:CHAR, '**')
      when @s.scan(/\|\|/) then add(:CHAR, '||')

      # Triple Quote Strings (Multiline)
      # Match """ then anything (non-greedy) until the next """
      # Must come before the match for single quotes below
      when @s.scan(/"""((?:.|\n)*?)"""/)
        # 1. Extract content (strip the surrounding """)
        content = @s.matched[3..-4]

        # 2. Update line counter (Crucial for error messages!)
        # We count how many newlines were inside the string
        @line += content.count("\n")

        add(:STRING, content)

      # Operators and Punctuation
      when @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:]/)
        add(:CHAR, @s.matched)

      when @s.scan(/%/)
        add(:PERCENT, '%')

      # Identifiers (The logic here is critical)
      when @s.scan(/[a-zA-Z_]\w*/)
        word = @s.matched
        if KEYWORDS[word]
          add(:KEYWORD, word)
        elsif word =~ /^[A-Z]/
          add(:TYPE_ID, word) # Uppercase start = Type
        else
          add(:VAR_ID, word)  # Lowercase start = Var
        end

      when @s.scan(/\d+\.?\d*/)
        add(:NUMBER, @s.matched.to_f)

      when @s.scan(/"[^"]*"/)
        add(:STRING, @s.matched[1..-2])

      else
        raise "Unexpected char: #{@s.peek(1)} on line #{@line}"
      end
    end
    add(:EOF, nil)
    @tokens
  end

  def add(type, val)
    @tokens << Token.new(type, val, @line)
  end
end

# ==========================================
# 3. PARSER
# ==========================================
class Parser
  def initialize(tokens); @tokens = tokens; @pos = 0; end

  def parse
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    AST::Program.new(stmts)
  end

  private
  def current; @tokens[@pos]; end

  def consume(type, value=nil)
    # 1. Capture the current token BEFORE moving the pointer
    token = current

    # 2. Validate it matches what we expect
    if (token.type == type) || (value && token.value == value)
      if value && token.value != value
         raise "Expected value '#{value}', got '#{token.value}'"
      end

      # 3. Advance the pointer
      @pos += 1

      # 4. RETURN THE CAPTURED TOKEN (Not 'current', which is now the next one!)
      token
    else
      raise "Expected #{value || type}, got #{token.value} (#{token.type}) line #{token.line}"
    end
  end

  def match?(type, val=nil)
    current.type == type && (val.nil? || current.value == val)
  end

  def parse_statement
    if match?(:KEYWORD, 'VAR') then parse_var_declare();
    elsif match?(:KEYWORD, 'SET') then parse_set_var();
    elsif match?(:KEYWORD, 'FN') then parse_function_def();
    elsif match?(:KEYWORD, 'IF') then parse_if_statement();
    elsif match?(:KEYWORD, 'WHILE') then parse_while_loop();
    elsif match?(:KEYWORD, 'STRUCT') then parse_struct_def();
    elsif match?(:KEYWORD, 'RETURN') then parse_return();
    elsif match?(:KEYWORD, 'ASSERT') then parse_assert();
    elsif match?(:KEYWORD, 'RAISE') then parse_raise();
    elsif match?(:HEWORD, 'EXIT') then parse_exit();
    else
      expr = parse_expression
      consume(:CHAR, ';')
      expr
    end
  end

  def parse_assert()
    consume(:KEYWORD)

    # 1. Parse the Condition
    condition = parse_expression

    # 2. Parse Optional Message
    message = "Assertion Failed"
    if match?(:CHAR, ',')
      consume(:CHAR)
      # For simplicity v1, strict string literal.
      # (For v2, use parse_expression to allow dynamic strings)
      message = consume(:STRING).value
    end

    consume(:CHAR, ';')
    AST::Assert.new(condition, message)
  end

  def parse_raise()
   consume(:KEYWORD)

   message_expr = nil

   # Check for optional message expression
   if !match?(:CHAR, ';')
     message_expr = parse_expression
   end

   consume(:CHAR, ';')
   AST::Raise.new(message_expr)
  end

  def parse_exit()
    consume(:KEYWORD)
    # Check for optional context message
    # (Look ahead: if it's a string or variable, parse it)
    # We assume EXIT is followed by an expression if not ')' or ';' or 'END'
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
    # unless ['}', ')', ';', 'END'].include?(current.value)
       context_expr = parse_primary
    end

    # Store the context in the ThrowNode
    byebug
    rhs = AST::ThrowNode.new(context_expr)
  end

  def parse_return()
    consume(:KEYWORD)
    val = parse_expression
    consume(:CHAR, ';')
    AST::ReturnNode.new(val)
  end

  def parse_set_var()
    consume(:KEYWORD)
    name = consume(:VAR_ID).value
    consume(:CHAR, '=')
    val = parse_expression
    consume(:CHAR, ';')
    AST::Assignment.new(name, val)
  end

  def parse_var_declare()
    consume(:KEYWORD)
    name = consume(:VAR_ID).value
    type_node = :Any
    if match?(:CHAR, ':')
      consume(:CHAR)
      type_node = parse_type_annotation.to_sym
    end
    consume(:CHAR, '=')
    val = parse_expression
    consume(:CHAR, ';')
    AST::VarDecl.new(name, type_node, val)
  end

  def parse_argument_list()
    parse_comma_seq(:CHAR, '(', ')') do
      p_name = consume(:VAR_ID).value
      p_type = :Any

      if match?(:CHAR, ":")
        consume(:CHAR)
        p_type = parse_type_annotation
      end

      { name: p_name, type: p_type }
    end
  end

  def parse_function_def
    consume(:KEYWORD, 'FN')
    name = consume(:VAR_ID).value
    consume(:PERCENT, '%')

    # 1. Parse Params
    params = parse_argument_list

    # 2. Parse USE() UpValues
    captures = []
    if current.value == 'USE'
      consume(:KEYWORD)
      captures = parse_argument_list()
    end

    # 3. Parse optional RETURNS
    return_type = :Any
    if current.value == 'RETURNS'
      consume(:KEYWORD)
      return_type = parse_type_annotation.to_sym
    end

    consume(:ARROW, '->')
    body = []
    until match?(:KEYWORD, 'END') || match?(:KEYWORD, 'CATCH')
      stmt = parse_statement()
      body << stmt if stmt # Handle nil from STRUCT skip
    end

    # 2. Parse Optional CATCH block
    catch_body = []
    catch_var = nil
    if match?(:KEYWORD, 'CATCH')
      consume(:KEYWORD)
      catch_var = consume(:VAR_ID).value # Capture 'e' in CATCH e

      until match?(:KEYWORD, 'END')
        stmt = parse_statement()
        catch_body << stmt if stmt
      end
    end

    consume(:KEYWORD, 'END')
    AST::FunctionDef.new(name, params, captures, return_type, body, catch_body, catch_var)
  end

  def parse_expression
    lhs = parse_primary
    while AST::BINARY_OPS.include?(current.value) || current.value == 'OR'
      op = current.value
      consume(current.type)
      rhs = nil
      if op == 'OR'
        rhs = parse_or_rescue
        lhs = AST::BinaryOp.new(lhs, :OR_RESCUE, rhs)
      else
        #current.type == :SMOOTH ? consume(:SMOOTH) : consume(:CHAR)
        rhs = parse_primary
        lhs = AST::BinaryOp.new(lhs, op, rhs)
      end
    end
    lhs
  end

  def parse_or_rescue
    if match?(:KEYWORD, 'RETURN')
      # Syntax: ... OR RETURN
      # Meaning: Return the error object to the caller
      consume(:KEYWORD)
      rhs = AST::ReturnNode.new(nil) # Nil value implies "Use the Pipe Result"

    elsif match?(:KEYWORD, 'EXIT')
      # Syntax: ... OR EXIT
      # Meaning: Throw the error object (triggering local CATCH)
      consume(:KEYWORD)
      context = nil

      # CRITICAL FIX: Look ahead for the context string
      if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
         context = parse_primary
      end
      rhs = AST::ThrowNode.new(context) # Nil value implies "Use the Pipe Result"

    elsif match?(:KEYWORD, 'ELSE')
      # Syntax: ... OR ELSE value
      # Meaning: Replace the error with a default value
      consume(:KEYWORD)
      rhs = parse_primary # Parse the value (e.g., 0 or "default")

    else
      # Syntax: ... OR expression
      # Standard OR behavior
      rhs = parse_primary
    end
  end

  def parse_unary
    v = current.value
    if AST::UNARY_OPS.include?(v)
      consume(:CHAR)
      # Recursively parse the thing being negated (handles --5)
      right = parse_unary
      return AST::UnaryOp.new(AST::OP_TO_OP_CODE[v], right)
    end

    parse_primary
  end

  def parse_var_id
    name = consume(:VAR_ID).value
    if match?(:CHAR, '(')
       args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
       node = AST::FuncCall.new(name, args)
    else
       node = AST::Identifier.new(name)
    end

    # 2. Suffix Loop: Handle .method(), .field, and [index]
    loop do
      if match?(:CHAR, '.')
        consume(:CHAR)
        member = consume(:VAR_ID).value

        if match?(:CHAR, '(')
          # It's a Method Call: x.pop()
          args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
          node = AST::MethodCall.new(node, member, args)
        else
          # It's a Field Access: x.name (New!)
          # We need a new AST node for this, or treat it as "Get Field"
          node = AST::GetField.new(node, member)
        end

      elsif match?(:CHAR, '[')
        # It's an Index Access: x[0] (New!)
        consume(:CHAR, '[')
        index_expr = parse_expression
        consume(:CHAR, ']')
        node = AST::GetIndex.new(node, index_expr)

      else
        # No more suffixes, we are done.
        break
      end
    end
    return node
  end

  def parse_if_statement
    consume(:KEYWORD, 'IF')
    parse_if_chain
  end

  def parse_if_chain
    condition = parse_expression
    consume(:KEYWORD, 'THEN')

    # 2. Parse 'THEN' Block
    then_branch = []
    until match?(:KEYWORD, 'ELSE') || match?(:KEYWORD, 'ELSE_IF') || match?(:KEYWORD, 'END')
      stmt = parse_statement()
      then_branch << stmt if stmt
    end

    # 3. Parse Optional 'ELSE' Block
    else_branch = []
    if match?(:KEYWORD, 'ELSE_IF')
      consume(:KEYWORD, 'ELSE_IF')
      # We recurse! We treat the ELSIF as the start of a new IF node.
      # This new node becomes the single statement inside our 'else_branch'.
      # Note: We do NOT consume 'END' here, the recursion handles it.
      nested_if = parse_if_chain
      else_branch << nested_if

    elsif match?(:KEYWORD, 'ELSE')
      consume(:KEYWORD)
      until match?(:KEYWORD, 'END')
        stmt = parse_statement()
        else_branch << stmt if stmt
      end
      consume(:KEYWORD, 'END') # The chain finally ends here
    else
      consume(:KEYWORD, 'END')
    end

    AST::IfStatement.new(condition, then_branch, else_branch)
  end

  def parse_while_loop
    consume(:KEYWORD, 'WHILE')
    condition = parse_expression
    consume(:KEYWORD, 'DO')

    # Parse 'DO' Block
    do_branch = []
    until match?(:KEYWORD, 'END')
      stmt = parse_statement()
      do_branch << stmt if stmt
    end

    consume(:KEYWORD, 'END')
    AST::WhileLoop.new(condition, do_branch)
  end

  def parse_struct_def
    consume(:KEYWORD)
    name = consume(:TYPE_ID).value
    consume(:CHAR, '{')

    fields = {}

    # Parse fields: name: Type, name: Type...
    until match?(:CHAR, '}')
       field_name = consume(:VAR_ID).value
       consume(:CHAR, ':')
       field_type = parse_type_annotation

       fields[field_name] = field_type

       consume(:CHAR, ',') if match?(:CHAR, ',')
    end

    consume(:CHAR, '}')

    # Return a new AST Node (Make sure to add StructDef to AST module!)
    AST::StructDef.new(name, fields)
  end

  def parse_primary
    return AST::Literal.new(:NUMBER, consume(:NUMBER).value) if match?(:NUMBER)
    return AST::Literal.new(:STRING, consume(:STRING).value) if match?(:STRING)

    # CAST LOGIC
    if current.value == 'CAST'
      return parse_cast()

    elsif match?(:PERCENT)
      return parse_sigil_construct()

    elsif match?(:KEYWORD, 'TRUE')
      consume(:KEYWORD)
      return AST::Literal.new(:BOOLEAN, true)

    elsif match?(:KEYWORD, 'FALSE')
      consume(:KEYWORD)
      return AST::Literal.new(:BOOLEAN, false)

    elsif match?(:KEYWORD, 'NIL')
      consume(:KEYWORD)
      return AST::Literal.new(:NIL, nil)

    elsif current.value == '-' || current.value == '!'
      return parse_unary()

    elsif match?(:VAR_ID)
      return parse_var_id()
    end

    raise "Unexpected token #{current.value} (#{current.type}) line #{current.line}"
  end

  def parse_cast
    consume(current.type) # CAST
    consume(:CHAR, '(')

    val = parse_expression

    if current.value != 'AS'
      raise "Expected AS, got #{current.value}"
    end
    consume(current.type) # AS
    target = parse_type_annotation
    consume(:CHAR, ')')
    return AST::Cast.new(val, target)
  end

  def parse_sigil_construct
    consume(:PERCENT)
    if match?(:TYPE_ID)
      name = consume(:TYPE_ID).value
      fields = parse_comma_seq(:CHAR, '{', '}') do
        k = consume(:VAR_ID).value; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::StructLit.new(name, fields.to_h)
    elsif match?(:CHAR, '[')
      items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      return AST::ListLit.new(items)
    elsif match?(:CHAR, '{')
      pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = parse_expression; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::HashLit.new(pairs.to_h)
    elsif match?(:CHAR, '(')
      params = parse_argument_list
      captures = []
      if match?(:KEYWORD, 'USE')
        consume(:KEYWORD)
        captures = parse_argument_list
      end
      consume(:ARROW, '->')
      # TODO - Lambdas can be multiple statements...
      body = parse_expression
      consume(:CHAR, ';')
      return AST::Lambda.new(params, captures, body)
    end
  end

  def parse_type_annotation
    base = consume(:TYPE_ID).value
    if match?(:CHAR, '[')
      consume(:CHAR, '[')
      inner = parse_type_annotation
      consume(:CHAR, ']')
      return "#{base}[#{inner}]"
    end
    base
  end

  def parse_comma_seq(type, open, close)
    consume(type, open)
    items = []
    until match?(:CHAR, close)
      items << yield
      consume(:CHAR, ',') if match?(:CHAR, ',')
    end
    consume(:CHAR, close)
    items
  end
end

# ==========================================
# 4. COMPILER
# ==========================================
class Compiler
  class Chunk
    attr_accessor :code, :constants, :name, :handler_info
    def initialize(name = "main")
      @name = name
      @code = []
      @constants = []
      @logger = $logger || Logger.new(STDOUT)
    end

    def add_constant(val)
      idx = @constants.index(val) || @constants.size
      @constants << val unless @constants.include?(val)
      idx
    end

    def emit(opcode, *operands); @code << [opcode, *operands]; end

    # Returns the index of the instruction we just added
    # so we can patch it later.
    def emit_with_index(opcode, *operands)
      @code << [opcode, *operands]
      @code.size - 1
    end

    # Updates an operand of a previously emitted instruction
    # offset: the index returned by emit_with_index
    # operand_index: usually 1 (the first operand after the opcode)
    # value: the jump target
    def patch(offset, value, op_index = 1)
      # instruction is [OPCODE, OP1, OP2...]
      # We usually want to patch OP1, which is at index 1
      @code[offset][op_index] = value
    end

    def current_address
      @code.size
    end

    def disassemble
      @logger.debug("== #{@name} ==")
      @code.each_with_index do |ins, i|
        @logger.debug(sprintf("%04d  %-10s %s", i, ins[0], ins[1..-1].join(" ")))
      end
      @logger.debug("")
    end

    def to_h
      {
        name: @name,
        code: @code,
        constants: @constants.map do |c| 
          v = c.is_a?(Chunk) ? c.to_h : c
          k = c.is_a?(Chunk) ? "chunks" : c.is_a?(String) ? "string" : "number"
          { k => v }
        end
      }
    end
  end

  class Scope
    attr_accessor :locals
    def initialize; @locals = {}; end

    def declare(name, reg, type, is_mutable = true)
      @locals[name] = { reg: reg, type: type, mutable: is_mutable }
    end

    def resolve_reg(name)
      entry = @locals[name]
      entry ? entry[:reg] : nil
    end

    def resolve_type(name)
      entry = @locals[name]
      entry ? entry[:type] : :Any
    end

    def is_mutable?(name)
      entry = @locals[name]
      entry ? entry[:mutable] : true
    end

    def is_immutable?(name)
      !is_mutable?(name)
    end
  end

  attr_accessor :chunk, :reg_top
  def initialize(name = "main", return_type = :Any)
    @chunk = Chunk.new(name)
    @scopes = [Scope.new]
    @reg_top = 0
    @expected_return = return_type
    @logger = $logger || Logger.new(STDOUT)
  end

  def compile(ast)
    ast.statements.each do |s|
      if s.is_a?(AST::VarDecl)
        # FIX: Call directly. Let VarDecl manage @reg_top internally.
        # It will increment it and KEEP it incremented.
        visit(s)
      else
        with_temp_reg { |r| visit(s, r) }
      end
    end
    @chunk.emit(:RETURN, "R0")
    @chunk
  end

  def current_scope; @scopes.last; end
  def with_temp_reg; r = @reg_top; @reg_top += 1; yield r; @reg_top -= 1; end

  def visit(node, target_reg = nil, auto_throw_pipe: true)
    case node
    when AST::VarDecl then compile_var_declare(node, target_reg);
    when AST::Assignment then compile_assignment(node, target_reg);
    when AST::Literal then compile_literal(node, target_reg);
    when AST::BinaryOp then compile_binary_op(node, target_reg, auto_throw_pipe);
    when AST::UnaryOp then compile_unary_op(node, target_reg);
    when AST::GetIndex then compile_get_index(node, target_reg);
    when AST::GetField then compile_get_field(node, target_reg);
    when AST::Cast then compile_cast(node, target_reg);
    when AST::IfStatement then compile_if_statement(node, target_reg);
    when AST::WhileLoop then compile_while_loop(node, target_reg);
    when AST::ListLit then compile_list_lit(node, target_reg);
    when AST::StructLit then compile_struct_lit(node, target_reg);
    when AST::StructDef then compile_struct_def(node, target_reg);
    when AST::HashLit then compile_hash_lit(node, target_reg);
    when AST::Identifier then compile_identifier(node, target_reg);
    when AST::FuncCall then compile_func_call(node, target_reg);
    when AST::MethodCall then compile_method_call(node, target_reg);
    when AST::Lambda then compile_lambda(node, target_reg);
    when AST::FunctionDef then compile_function_def(node, target_reg);
    when AST::ReturnNode then compile_return_node(node, target_reg);
    when AST::Assert then compile_assert(node, target_reg);
    when AST::Raise then compile_raise(node, target_reg);
    end
  end

  def compile_smooth_operator(node, target_reg, auto_throw_pipe)
    # 1. Compile the Left Side (The Input)
    visit(node.left, target_reg, auto_throw_pipe: auto_throw_pipe)

    # 2. Input Guard: Check if the *Input* is already an error
    if auto_throw_pipe
      # Default Mode: Crash if input is error
      @chunk.emit(:THROW_IF_ERROR, "R#{target_reg}")
      skip_jump = nil
    else
      # Soft Mode: Skip everything if input is error
      skip_jump = @chunk.emit_with_index(:JMP_IF_ERROR, "R#{target_reg}", 0)
    end

    # 3. Compile the Function Call
    if node.right.is_a?(AST::FuncCall)
       # Case 1: Explicit Call -> f(args)
       
       with_temp_reg do |r_snapshot|
         # A. Save Snapshot
         @chunk.emit(:MOVE, "R#{r_snapshot}", "R#{target_reg}")

         # B. Collect Arguments (Start with Piped Data)
         args_regs = ["R#{target_reg}"] 
         
         node.right.args.each do |arg|
            r_arg = @reg_top
            @reg_top += 1
            visit(arg, r_arg)
            args_regs << "R#{r_arg}"
         end
         
         # C. Call Helper (Fixed Name and Variables)
         _compile_func_with_args(node, r_snapshot, target_reg, args_regs)
         
         # D. Cleanup
         @reg_top -= (args_regs.size - 1) 
       end

    elsif node.right.is_a?(AST::Identifier)
       # Case 2: Bare Identifier: x s> f
       
       with_temp_reg do |r_snapshot|
         # A. Save Snapshot
         @chunk.emit(:MOVE, "R#{r_snapshot}", "R#{target_reg}")

         # B. Arguments
         # The only argument is the piped value (target_reg)
         args_regs = ["R#{target_reg}"] 

         # C. Call Helper (Pass args_regs, NOT empty array)
         _compile_func_with_args(node, r_snapshot, target_reg, args_regs)
       end
    end

    # 4. Patch the Input Guard Jump (Only if we were in Soft Mode)
    if skip_jump
      @chunk.patch(skip_jump, @chunk.current_address, 2)
    end
  end

  def _compile_func_with_args(node, r_snapshot, target_reg, args_regs)
    # A. Emit the Call
    # This overwrites 'target_reg' with the Result (or new Error)
    func_name = node.right.name

    if func_name == "print"
       @chunk.emit(:PRINT, *args_regs)
    elsif func_name == "native_call"
       raise "Compiler Error: Cannot pipe to native_call directly."
    else
       @chunk.emit(:CALL_FUNC, "R#{target_reg}", func_name, args_regs.size, *args_regs)
    end

    # B. Error Enrichment (Snapshot)
    # 1. If result is OK, jump over the enrichment logic
    ok_jump = @chunk.emit_with_index(:JMP_IF_OK, "R#{target_reg}", 0)

    # 2. If we are here, it IS an Error. Attach snapshot.
    @chunk.emit(:SETFIELD, "R#{target_reg}", "snapshot", "R#{r_snapshot}")

    # 3. Patch the jump
    @chunk.patch(ok_jump, @chunk.current_address, 2)
  end

  def compile_function_def(node, target_reg)
    fn_compiler = Compiler.new(node.name, node.return_type)

    node.params.each_with_index do |p, i|
      fn_compiler.current_scope.declare(p[:name], i, p[:type])
    end

    reg_offset = node.params.size

    # TODO -> This look identical to the logic to build a closure later
    # REUSE it.
    captured_regs = []
    node.captures.each do |cap|
       cap_name, cap_type = cap.values_at(:name, :type)

       # A. Resolve the register in the OUTER scope
       outer_reg = current_scope.resolve_reg(cap_name)

       unless outer_reg
         raise "Compile Error: Cannot capture '#{cap_name}' inside function '#{node.name}' - undefined in outer scope."
       end

       # B. Add to the list for the CLOSURE instruction
       captured_regs << "R#{outer_reg}"

       # C. Declare it in the INNER scope
       fn_compiler.current_scope.declare(cap_name, reg_offset, cap_type, false)
       reg_offset += 1
    end

    fn_compiler.instance_variable_set(:@reg_top, reg_offset)
    node.body.each do |stmt|
      # VarDecls manage their own registers.
      # Everything else (Expressions, Returns) needs a temp register assigned.
      if stmt.is_a?(AST::VarDecl)
        fn_compiler.send(:visit, stmt)
      else
        fn_compiler.send(:with_temp_reg) do |r|
          fn_compiler.send(:visit, stmt, r)
        end
      end
    end

    success_jump = fn_compiler.chunk.emit_with_index(:JMP, 0)

    if node.catch_body.any?
      handler_ip = fn_compiler.chunk.current_address

       # A. Allocate register for the error variable 'e'
       r_err = fn_compiler.reg_top
       fn_compiler.reg_top += 1
       fn_compiler.current_scope.declare(node.catch_var, r_err, :Error)

       # B. Compile CATCH block
       node.catch_body.each { |s| fn_compiler.send(:visit, s) }
       fn_compiler.chunk.emit(:RETURN, "R0") # ENSURE IMPLICIT RETURN

       # C. Store handler metadata on the Chunk (for VM to find)
       fn_compiler.chunk.handler_info = {
           handler: handler_ip,
           err_reg: r_err
       }
    end

    fn_compiler.chunk.patch(success_jump, fn_compiler.chunk.current_address)

    # Always emit an implicit return
    # If the user already wrote a return statement, this cannot be reached
    fn_compiler.instance_variable_get(:@chunk).emit(:RETURN, "R0")

    fn_chunk = fn_compiler.instance_variable_get(:@chunk)
    fn_chunk.name = node.name
    k = @chunk.add_constant(fn_chunk)

    # Closure creates the function in the target register
    @chunk.emit(:CLOSURE, "R#{target_reg}", "K#{k}", *captured_regs)
    # Register it as a global, so it can be called later with CALL_FUNC
    @chunk.emit(:DEF_GLOBAL, node.name, "R#{target_reg}")
  end

  def compile_func_call(node, target_reg)
    # Check if it's a print call (intrinsic) or regular
    if node.name == "print"
       args = []
       node.args.each { |a| r=@reg_top; @reg_top+=1; args<<"R#{r}"; visit(a,r) }
       @chunk.emit(:PRINT, *args)
       @reg_top -= args.size

    # 2. Handle Intrinsic: NATIVE_CALL (New!)
    elsif node.name == "native_call"
       # Usage: native_call("ClassName", "MethodName", arg1, arg2...)
       
       # Extract Class/Method literals (Must be string literals for simplicity)
       if node.args.size < 2
          raise "native_call requires at least 'Class' and 'Method' string literals."
       end
       
       class_node = node.args[0]
       method_node = node.args[1]

       # Verify they are strings
       unless class_node.is_a?(AST::Literal) && class_node.type == :STRING
          raise "native_call arg 1 must be a static String (Class Name)"
       end
       class_name = class_node.value
       method_name = method_node.value

       # Compile the ACTUAL arguments (index 2 onwards)
       real_args_regs = []
       node.args[2..-1].each do |arg|
          r = @reg_top
          @reg_top += 1
          real_args_regs << "R#{r}"
          visit(arg, r)
       end

       # Emit: CALL_NATIVE Target, "Class", "Method", ArgRegs...
       @chunk.emit(:CALL_NATIVE, "R#{target_reg}", class_name, method_name, *real_args_regs)
       
       # Clean up temp registers
       @reg_top -= real_args_regs.size

    # 3. Handle Regular Functions
    else
       # A. Compile Arguments into registers
       args_regs = []
       node.args.each do |arg|
          r = @reg_top
          @reg_top += 1
          args_regs << "R#{r}"
          visit(arg, r)
       end

       # B. Emit New Format: [OP, Target, Name, ArgCount, *ArgRegs]
       @chunk.emit(:CALL_FUNC, "R#{target_reg}", node.name, node.args.size, *args_regs)

       # C. Cleanup registers
       @reg_top -= args_regs.size
    end
  end

  def compile_var_declare(node, target_reg)
    r = @reg_top; 
    @reg_top += 1
    visit(node.value, r)

    # 1. Determine the Type
    actual_type = infer_type(node.value)
    declared_type = node.type

    final_type = :Any

    if declared_type && declared_type != :Any
      # Case A: Explicit Type (VAR x: Number = ...)
      # Verify it matches!
      if declared_type != actual_type && actual_type != :Any
         raise "Type Error: Variable '#{node.name}' declared as #{declared_type} but assigned #{actual_type}"
      end
      final_type = declared_type
    else
      # Case B: Inferred Type (VAR x = ...)
      final_type = actual_type
    end

    current_scope.declare(node.name, r, final_type)
  end

  def compile_assignment(node, target_reg)
    if current_scope.is_immutable?(node.name)
      raise "Compile Error: Variable '#{node.name}' is immutable/captured and cannot be SET."
    end

    # 1. Compile the new value into a temporary register
    with_temp_reg do |r_new_val|
      visit(node.value, r_new_val)

      # 2. Look up the variable's existing register
      target_reg = current_scope.resolve_reg(node.name)

      # 3. If it doesn't exist, fail
      if target_reg.nil?
        raise "Compile Error: Cannot SET '#{node.name}' because it has not been declared with VAR."
      end

      existing_type = current_scope.resolve_type(node.name)
      new_type = infer_type(node.value)
      new_type = new_type == :Any ? existing_type : new_type
      if new_type != existing_type
        raise "Type Error: Cannot assign #{new_type} to variable '#{node.name}' of type #{existing_type}"
      end

      @chunk.emit(:MOVE, "R#{target_reg}", "R#{r_new_val}")
    end
  end

  def compile_binary_op(node, target_reg, auto_throw_pipe)
    # TODO: Figure out why some of these are strings...
    if node.op == 's>'
       # Don't do the normal math logic
       return compile_smooth_operator(node, target_reg, auto_throw_pipe)

    elsif node.op == :OR_RESCUE
      # 1. Compile Left Side (The Pipe/Expression)
      # auto_throw_pipe: false -> Return Error struct, don't crash
      visit(node.left, target_reg, auto_throw_pipe: false)

      # 2. Emit Check: "Jump to End if OK"
      # If target_reg is valid data, we skip the recovery block.
      success_jump = @chunk.emit_with_index(:JMP_IF_OK, "R#{target_reg}", 0)

      # 3. Compile Right Side (The Recovery)
      # At this point, target_reg holds the %Error object.
      if node.right.is_a?(AST::ReturnNode) && node.right.value.nil?
         # Syntax: OR RETURN
         # Action: Return the current register (the Error)
         @chunk.emit(:RETURN, "R#{target_reg}")

      elsif node.right.is_a?(AST::ThrowNode)
         # Syntax: OR EXIT (with optional context)
         if node.right.value # context_expr exists
            # 1. Compile the Context String
            with_temp_reg do |r_ctx|
              visit(node.right.value, r_ctx)

              # 2. Set the Context Field on the Error
              # target_reg currently holds the Error object
              @chunk.emit(:SETFIELD, "R#{target_reg}", "context", "R#{r_ctx}")
            end
         end
         # Action: Throw the current register (the Error)
         @chunk.emit(:THROW, "R#{target_reg}")

      else
         # Syntax: OR ELSE <value>
         # Action: Compile the value into the target register (overwriting the Error)
         visit(node.right, target_reg)
      end

      # 4. Patch the Jump
      @chunk.patch(success_jump, @chunk.current_address, 2)
      return

    elsif node.op == '&&'
      # 1. Compile Left into target_reg
      visit(node.left, target_reg)

      # 2. Short Circuit: If Left is FALSE, Jump to End
      # The result (FALSE) is already sitting in target_reg, so we are done.
      end_jump = @chunk.emit_with_index(:JMP_FALSE, "R#{target_reg}", 0)

      # 3. Compile Right
      # If we didn't jump, calculate Right and put it in target_reg
      visit(node.right, target_reg)

      # 4. Patch the Jump
      @chunk.patch(end_jump, @chunk.current_address, 2)
      return # Don't do the normal math logic

    elsif node.op == '||'
      # 1. Compile Left
      visit(node.left, target_reg)

      # 2. Short Circuit: If Left is TRUE, Jump to End
      end_jump = @chunk.emit_with_index(:JMP_TRUE, "R#{target_reg}", 0)

      # 3. Compile Right
      visit(node.right, target_reg)

      # 4. Patch
      @chunk.patch(end_jump, @chunk.current_address, 2)
      return # Don't do the normal math logic
    end

    with_temp_reg do |r1|
      visit(node.left, r1)
      with_temp_reg do |r2|
        visit(node.right, r2)

        if AST::OP_TO_OP_CODE[node.op]
          @chunk.emit(AST::OP_TO_OP_CODE[node.op], "R#{target_reg}", "R#{r1}", "R#{r2}")
        else
          raise "Unknown binary operator: #{node.op}"
        end
      end
    end
  end

  def compile_unary_op(node, target_reg)
    if node.op == :SUB
      # Optimization: If it's a literal number, just load the negative version directly
      if node.right.is_a?(AST::Literal) && node.right.type == :NUMBER
         # Emit LOADK -5 directly
         k = @chunk.add_constant(-node.right.value)
         @chunk.emit(:LOADK, "R#{target_reg}", "K#{k}")
         return
      end

      # Generic Case: Calculate (0 - value)
      with_temp_reg do |r_zero|
        # 1. Load 0
        k_zero = @chunk.add_constant(0)
        emit(:LOADK, r_zero, "K#{k_zero}")

        # 2. Compile the expression being negated
        # Note: Depending on your register allocator, ensure 'visit' puts result in a known reg
        # For this example, let's assume 'visit' returns the register it used.
        r_val = visit(node.right)

        # 3. Perform 0 - value
        emit(:SUB, r_val, r_zero, r_val) # Target, LHS, RHS
      end
    
    elsif node.op == :NOT
      with_temp_reg do |r_src|
        visit(node.right, r_src)
        @chunk.emit(:NOT, "R#{target_reg}", "R#{r_src}")
      end
    end
  end

  def compile_get_index(node, target_reg)
    # x[i]
    with_temp_reg do |r_target|
      visit(node.target, r_target) # Compile 'x'
      with_temp_reg do |r_index|
        visit(node.index, r_index) # Compile 'i'
        # Emit GET_INDEX R_result, R_target, R_index
        @chunk.emit(:GET_INDEX, "R#{target_reg}", "R#{r_target}", "R#{r_index}")
      end
    end
  end

  def compile_get_field(node, target_reg)
    # x.name
    with_temp_reg do |r_target|
      visit(node.target, r_target)
      # We assume field names are static strings for now
      # Emit GET_FIELD R_result, R_target, "field_name"
      @chunk.emit(:GET_FIELD, "R#{target_reg}", "R#{r_target}", node.field)
    end
  end

  def compile_cast(node, target_reg)
    visit(node.value, target_reg)
    @chunk.emit(:CAST, "R#{target_reg}", node.target)
  end

  def compile_literal(node, target_reg)
    k = @chunk.add_constant(node.value)
    @chunk.emit(:LOADK, "R#{target_reg}", "K#{k}")
  end

  def compile_if_statement(node, target_reg)
    # 1. Compile Condition
    with_temp_reg do |r_cond|
      visit(node.condition, r_cond)

      # 2. Emit JMP_FALSE
      # "If condition (r_cond) is false, jump to... Unknown (0) for now"
      else_jump = @chunk.emit_with_index(:JMP_FALSE, "R#{r_cond}", 0)

      # 3. Compile THEN branch
      node.then_branch.each { |stmt| visit(stmt) }

      # 4. Emit JMP (Unconditional)
      # If we finished the THEN block, we must skip the ELSE block.
      # Target is unknown (0) for now.
      end_jump = @chunk.emit_with_index(:JMP, 0)

      # 5. Patch the JMP_FALSE
      # If the condition failed, we land HERE (start of else)
      @chunk.patch(else_jump, @chunk.current_address, 2)

      # 6. Compile ELSE branch (if exists)
      node.else_branch.each { |stmt| visit(stmt) }

      # 7. Patch the JMP
      # If we finished the THEN block, we land HERE (end of everything)
      @chunk.patch(end_jump, @chunk.current_address)
    end
  end

  def compile_while_loop(node, target_reg)
    with_temp_reg do |r_cond|
      # 1. MARK START
      # We need to know where to jump BACK to.
      # Current instruction index is the start of the loop.
      loop_start_index = @chunk.code.length

      visit(node.condition, r_cond)

      # 2. EMIT EXIT JUMP (Placeholder)
      # If condition is false, we jump to the END.
      # We don't know where the END is yet, so we write '0' for now.
      do_jump = @chunk.emit_with_index(:JMP_FALSE, "R#{r_cond}", 0)
      exit_jump_index = @chunk.code.length - 1

      # 3. COMPILE BODY
      # This emits the code inside the loop
      node.do_branch.each { |stmt| visit(stmt) }

      # 4. EMIT LOOP BACK
      # Unconditionally jump back to the top (loop_start_index)
      @chunk.emit_with_index(:JMP, loop_start_index)

      # 5. PATCH THE EXIT JUMP
      # Now that the body is done, we know the current index is the "End".
      # Go back to the JMP_FALSE instruction and update the '0' to the current index.
      loop_end_index = @chunk.code.length
      @chunk.code[exit_jump_index][2] = loop_end_index
    end
  end

  def compile_list_lit(node, target_reg)
    # 1. Homogeneity Check (Compile Time)
    if node.items.any?
      # Guess type of first item (e.g. :Number)
      expected_type = infer_type(node.items.first)

      node.items.each_with_index do |item, idx|
        current_type = infer_type(item)
        if current_type != expected_type
           raise "Type Error: List contains mixed types. Item #{idx} is #{current_type}, expected #{expected_type}."
        end
      end
    else
      # TODO - next, add optional type annotations to initializations
      # Then - if not declared when empty, raise error

      # Edge Case: Empty List %[]
      # You either force a type annotation (VAR x: Vector[Number] = %[])
      # or assume Vector[Any].
    end

    @chunk.emit(:NEWLIST, "R#{target_reg}")
    node.items.each { |item| with_temp_reg { |r| visit(item, r); @chunk.emit(:APPEND, "R#{target_reg}", "R#{r}") } }
  end

  def compile_struct_lit(node, target_reg)
    @chunk.emit(:NEWSTRUCT, "R#{target_reg}", node.name)
    node.fields.each { |k,v| with_temp_reg { |r| visit(v, r); @chunk.emit(:SETFIELD, "R#{target_reg}", k, "R#{r}") } }
  end

  def compile_struct_def(node, target_reg)
    # Emit: DEF_STRUCT "Name", { "field" => "Type" }
    @chunk.emit(:DEF_STRUCT, node.name, node.fields)
  end

  def compile_hash_lit(node, target_reg)
    # Treat Hash like a Struct or List (for v0.1, let's use NEWSTRUCT for simplicity)
    @chunk.emit(:NEWHASH, "R#{target_reg}")
    node.pairs.each do |k, v|
      with_temp_reg do |r|
        visit(v, r)
        # Assuming keys are strings/identifiers
        # If 'k' is an expression, you'd need to visit it too.
        # For v0.1 simple string keys:
        key_name = k.is_a?(AST::Literal) ? k.value : k.name
        @chunk.emit(:SETHASH, "R#{target_reg}", key_name, "R#{r}")
      end
    end
  end

  def compile_identifier(node, target_reg)
    r = current_scope.resolve_reg(node.name)
    raise "Compile Error: Undefined variable '#{node.name}'" unless r
    @chunk.emit(:MOVE, "R#{target_reg}", "R#{r}") if target_reg != r # TODO: shouldn't need check
  end

  def compile_method_call(node, target_reg)
    with_temp_reg do |r_obj|
      visit(node.object, r_obj)
      args = []
      node.args.each { |a| r=@reg_top; @reg_top+=1; args<<"R#{r}"; visit(a,r) }
      @chunk.emit(:CALL_METHOD, "R#{target_reg}", "R#{r_obj}", node.method, *args)
      @reg_top -= args.size
    end
  end

  def compile_lambda(node, target_reg)
    # 1. Spin up a new compiler for the anonymous function
    fn_compiler = Compiler.new("lambda")

    # 2. Register parameters (e.g., "x" becomes R0)
    node.params.each_with_index do |p, i|
      fn_compiler.current_scope.declare(p[:name], i, p[:type])
    end

    # Start allocating registers after the params
    reg_offset = node.params.size

    captured_regs = []
    # 2. Register Captures (multiple -> R1)
    # We treat captures like "Hidden Parameters" that get loaded into
    # registers R1, R2, etc., immediately after the real arguments.
    node.captures.each do |cap|
      cap_name, cap_type = cap.values_at(:name, :type)

      outer_reg = current_scope.resolve_reg(cap_name)

      # A. Ensure it exists in the outer scope
      unless outer_reg
         raise "Compile Error: Cannot capture '#{cap_name}' - undefined in outer scope."
      end

      captured_regs << "R#{outer_reg}"

      # B. Declare it in the inner scope
      fn_compiler.current_scope.declare(cap_name, reg_offset, cap_type, false)
      reg_offset += 1
    end

    # 3. Set register offset (Next free reg is after params)
    # If we have 1 param (R0), next is R1.
    result_reg = reg_offset
    fn_compiler.instance_variable_set(:@reg_top, result_reg)

    # 4. Compile the Body
    # The body is a single expression (x * 10).
    # We visit it, putting the result into 'result_reg'.
    fn_compiler.send(:visit, node.body, result_reg)

    # 5. Emit Return
    fn_compiler.instance_variable_get(:@chunk).emit(:RETURN, "R#{result_reg}")

    # 6. Store the Chunk as a Constant
    fn_chunk = fn_compiler.instance_variable_get(:@chunk)
    k = @chunk.add_constant(fn_chunk)

    # 7. Emit the CLOSURE op with the Constant ID
    # NOTE: In a real VM, this instruction would also need to list
    # the registers to capture (e.g., CLOSURE R6 K3 [R_multiple]).
    # For v0.1, we are just fixing the Scope resolution.
    @chunk.emit(:CLOSURE, "R#{target_reg}", "K#{k}", *captured_regs)
  end

  def compile_return_node(node, target_reg)
    # 1. Check type
    actual_type = infer_type(node.value)
    if @expected_return && @expected_return != :Any
      if actual_type != :Any && actual_type != @expected_return
        raise "Type Error: Function expected to return #{@expected_return}, but returned #{actual_type}"
      end
    end

    # 2. We need a register to hold the return value
    with_temp_reg do |r|
      # 3. Compile the expression into that register
      visit(node.value, r)
      # 4. Emit the instruction
      @chunk.emit(:RETURN, "R#{r}")
    end
  end

  def compile_assert(node, target_reg)
    with_temp_reg do |r_cond|
      # 1. Compile Condition
      visit(node.condition, r_cond)

      # 2. Store Message in Constants
      k_msg = @chunk.add_constant(node.message)

      # 3. Emit ASSERT R_cond, K_msg
      @chunk.emit(:ASSERT, "R#{r_cond}", "K#{k_msg}")
    end
  end

  def compile_raise(node, target_reg)
    # This logic compiles the expression into a function call:
    # VAR temp = make_error(message_expr);
    # RETURN temp;

    # 1. Compile the message expression (or NIL literal if no message)
    msg_node = node.message_expr || AST::Literal.new(:NIL, nil)

    # 2. Build the AST node for the function call: make_error(msg_node)
    error_call_node = AST::FuncCall.new("make_error", [msg_node])

    # 3. Compile the function call result (the Error Struct) into a register
    with_temp_reg do |r_err|
      # Compile the call (will emit LOADK, CALL_FUNC, etc.)
      visit(error_call_node, r_err)

      # 4. Emit THROW instruction
      # This is the actual instruction that interrupts the program flow and
      # initiates stack unwinding via the raise_error helper function.
      @chunk.emit(:THROW, "R#{r_err}")
    end
  end

private
  def infer_type(node)
    case node
    when AST::Literal
      return :Number if node.type == :NUMBER
      return :String if node.type == :STRING
      return :Bool if node.type == :BOOL

    when AST::Identifier
      # Look up the variable in the current scope
      return current_scope.resolve_reg(node.name)

    when AST::BinaryOp
      # Simple inference: if it's math, it's a Number
      if ['+', '-', '*', '/'].include?(node.op)
        return :Number
      end
      # If it's comparison, it's a Bool
      if ['==', '!=', '<', '>'].include?(node.op)
        return :Bool
      end

    when AST::Cast
      # CAST(x AS T) -> The type is T
      return node.target.to_sym
    end

    :Any # Fallback if we don't know
  end
end

