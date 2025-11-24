#! /usr/bin/env ruby

require 'strscan'

# ==========================================
# 1. AST
# ==========================================
module AST
  Program     = Struct.new(:statements)
  FunctionDef = Struct.new(:name, :params, :captures, :return_type, :body)
  VarDecl     = Struct.new(:name, :type, :value)
  Assignment  = Struct.new(:name, :value)
  BinaryOp    = Struct.new(:left, :op, :right)
  UnaryOp     = Struct.new(:op, :right)
  Literal     = Struct.new(:type, :value)
  Identifier  = Struct.new(:name)
  ListLit     = Struct.new(:items)
  HashLit     = Struct.new(:pairs)
  StructLit   = Struct.new(:name, :fields)
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

  BINARY_OPS = ['+', '*', '/', '==', '!=', '>', '>=', '<', '<=', '|>', '&&', '||', 'MOD', '**']
  UNARY_OPS = ['-', '!']

  OP_CODE_SENDABLE_SYMS = {
    :ADD => :+,
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
    :MOD => :%
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
    'MOD' => :MOD
  }
end

# ==========================================
# 2. LEXER (Robust)
# ==========================================
class Lexer
  Token = Struct.new(:type, :value, :line)

  # We use a hash for O(1) lookups
  # TODO: Should MOD be a keyword ???
  KEYWORDS = %w[
      FN VAR IF THEN ELSE ELSE_IF END WHILE DO RETURN RETURNS SET CAST AS USE 
      STRUCT TRUE FALSE NIL ASSERT
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
      when @s.scan(/\|>/) then add(:PIPE, '|>')
      when @s.scan(/==/) then add(:CHAR, '==') # TODO: Is this right?
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
    stmts << parse_statement while current.type != :EOF
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
    if match?(:KEYWORD, 'VAR')
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

    elsif match?(:KEYWORD, 'SET')
      consume(:KEYWORD)
      name = consume(:VAR_ID).value
      consume(:CHAR, '=')
      val = parse_expression
      consume(:CHAR, ';')
      AST::Assignment.new(name, val)

    elsif match?(:KEYWORD, 'FN')
      parse_function_def

    elsif match?(:KEYWORD, 'IF')
      parse_if_statement

    elsif match?(:KEYWORD, 'WHILE')
      parse_while_loop

    elsif match?(:KEYWORD, 'STRUCT')
      consume(:KEYWORD)
      name = consume(:TYPE_ID).value
      consume(:CHAR, '{')
      until match?(:CHAR, '}')
         # Skip fields for v0.1 demo
         consume(current.type)
      end
      consume(:CHAR, '}')
      # Return nil or AST node (ignored in this simple loop)
      nil

    elsif match?(:KEYWORD, 'RETURN')
      consume(:KEYWORD)
      val = parse_expression
      consume(:CHAR, ';')
      AST::ReturnNode.new(val)

    elsif match?(:KEYWORD, 'ASSERT')
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

    else
      expr = parse_expression
      consume(:CHAR, ';')
      expr
    end
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
    until match?(:KEYWORD, 'END')
      stmt = parse_statement
      body << stmt if stmt # Handle nil from STRUCT skip
    end
    consume(:KEYWORD, 'END')
    AST::FunctionDef.new(name, params, captures, return_type, body)
  end

  def parse_expression
    lhs = parse_primary
    while AST::BINARY_OPS.include?(current.value)
      op = current.value
      consume(current.type)
      #current.type == :PIPE ? consume(:PIPE) : consume(:CHAR)
      rhs = parse_primary
      lhs = AST::BinaryOp.new(lhs, op, rhs)
    end
    lhs
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
      stmt = parse_statement
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
        stmt = parse_statement
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
      stmt = parse_statement
      do_branch << stmt if stmt
    end

    consume(:KEYWORD, 'END')
    AST::WhileLoop.new(condition, do_branch)
  end

  def parse_primary
    return AST::Literal.new(:NUMBER, consume(:NUMBER).value) if match?(:NUMBER)
    return AST::Literal.new(:STRING, consume(:STRING).value) if match?(:STRING)

    # CAST LOGIC
    if current.value == 'CAST'
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

    elsif match?(:PERCENT)
      return parse_sigil_construct

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
      return parse_unary

    elsif match?(:VAR_ID)
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

    raise "Unexpected token #{current.value} (#{current.type}) line #{current.line}"
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
    attr_accessor :code, :constants, :name
    def initialize(name = "main")
      @name = name
      @code = []
      @constants = []
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
      puts "== #{@name} =="
      @code.each_with_index do |ins, i|
        puts sprintf("%04d  %-10s %s", i, ins[0], ins[1..-1].join(" "))
      end
      puts ""
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

  def initialize(name = "main", return_type = :Any)
    @chunk = Chunk.new(name)
    @scopes = [Scope.new]
    @reg_top = 0
    @expected_return = return_type
  end

  def compile(ast)
    ast.statements.each do |s|
      # If it's a VarDecl, it handles its own register.
      # If it's an Expression (like the pipe), we must give it a temp register.
      if s.is_a?(AST::VarDecl) || s.is_a?(AST::FunctionDef)
        with_temp_reg { |r| visit(s, r) }
      else
        with_temp_reg { |r| visit(s, r) }
      end
    end
    @chunk.emit(:RETURN, "R0")
    @chunk
  end

  def current_scope; @scopes.last; end
  def with_temp_reg; r = @reg_top; @reg_top += 1; yield r; @reg_top -= 1; end

  def visit(node, target_reg = nil)
    case node
    when AST::VarDecl
      r = @reg_top; @reg_top += 1
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

    when AST::Assignment
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

    when AST::Literal
      k = @chunk.add_constant(node.value)
      @chunk.emit(:LOADK, "R#{target_reg}", "K#{k}")

    when AST::BinaryOp
      if node.op == '|>'
         # 1. Compile the Left Side (The Data)
         with_temp_reg do |r_data|
            visit(node.left, r_data)

            # 2. Check if Right Side is a Call
            if node.right.is_a?(AST::FuncCall)
               # 3. Inject r_data as the FIRST argument
               # We manually compile the function call here
               if node.right.name == "print"
                  @chunk.emit(:PRINT, "R#{r_data}")
               else
                  # Generic function call handling...
                  # (For v0.1, we can just say Pipelines only work with print for now)
               end
            end
         end
         return # Don't do the normal math logic

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

    when AST::UnaryOp
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

    when AST::GetIndex
      # x[i]
      with_temp_reg do |r_target|
        visit(node.target, r_target) # Compile 'x'
        with_temp_reg do |r_index|
          visit(node.index, r_index) # Compile 'i'
          # Emit GET_INDEX R_result, R_target, R_index
          @chunk.emit(:GET_INDEX, "R#{target_reg}", "R#{r_target}", "R#{r_index}")
        end
      end

    when AST::GetField
      # x.name
      with_temp_reg do |r_target|
        visit(node.target, r_target)
        # We assume field names are static strings for now
        # Emit GET_FIELD R_result, R_target, "field_name"
        @chunk.emit(:GET_FIELD, "R#{target_reg}", "R#{r_target}", node.field)
      end

    when AST::Cast
      visit(node.value, target_reg)
      @chunk.emit(:CAST, "R#{target_reg}", node.target)

    when AST::IfStatement
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

    when AST::WhileLoop
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

    when AST::ListLit
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

    when AST::StructLit
      @chunk.emit(:NEWSTRUCT, "R#{target_reg}", node.name)
      node.fields.each { |k,v| with_temp_reg { |r| visit(v, r); @chunk.emit(:SETFIELD, "R#{target_reg}", k, "R#{r}") } }

     when AST::HashLit
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

    when AST::Identifier
      r = current_scope.resolve_reg(node.name)
      raise "Compile Error: Undefined variable '#{node.name}'" unless r
      @chunk.emit(:MOVE, "R#{target_reg}", "R#{r}") if target_reg != r # TODO: shouldn't need check

    when AST::FuncCall 
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
          # In a real VM, resolve function name to register/closure
          # For v0.1, assume intrinsic or placeholder
          @chunk.emit(:CALL_FUNC, node.name, node.args.size)
       end

    when AST::MethodCall
       with_temp_reg do |r_obj|
         visit(node.object, r_obj)
         args = []
         node.args.each { |a| r=@reg_top; @reg_top+=1; args<<"R#{r}"; visit(a,r) }
         @chunk.emit(:CALL_METHOD, "R#{target_reg}", "R#{r_obj}", node.method, *args)
         @reg_top -= args.size
       end

    when AST::Lambda
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

    when AST::FunctionDef
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
       node.body.each { |s| fn_compiler.send(:visit, s) }

       # Always emit an implicit return
       # If the user already wrote a return statement, this cannot be reached
       fn_compiler.instance_variable_get(:@chunk).emit(:RETURN, "R0")

       fn_chunk = fn_compiler.instance_variable_get(:@chunk)
       fn_chunk.name = node.name
       k = @chunk.add_constant(fn_chunk)

       # Closure creates the function in the target register
       @chunk.emit(:CLOSURE, "R#{target_reg}", "K#{k}", *captured_regs)
       # We also declare the function name in the current scope so we can call it later
       # (Not fully implemented in this snippet, but this is where it goes)

    when AST::ReturnNode
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

    when AST::Assert
      with_temp_reg do |r_cond|
        # 1. Compile Condition
        visit(node.condition, r_cond)

        # 2. Store Message in Constants
        k_msg = @chunk.add_constant(node.message)

        # 3. Emit ASSERT R_cond, K_msg
        @chunk.emit(:ASSERT, "R#{r_cond}", "K#{k_msg}")
      end
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

