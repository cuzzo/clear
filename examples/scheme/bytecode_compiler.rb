#!/usr/bin/env ruby
# BytecodeCompiler: CLEAR AST -> bytecodes for the Scheme VM's exec!
# Emits Int64[] ops + Value[] consts that exec! consumes directly.

class BytecodeCompiler
  # Opcode constants (must match interpreter's exec!)
  LOAD_CONST = 1
  LOAD_NAME = 2
  STORE_NAME = 3
  POP = 4
  ADD = 10; SUB = 11; MUL = 12; DIV = 13
  EQ = 20; LT = 21; GT = 22; LTE = 23; GTE = 24
  NOT = 30
  JUMP = 40; JUMP_IF_FALSE = 41
  CALL = 42
  SET_NAME = 61
  NATIVE_CALL = 70; HALT = 71
  ADD_I64 = 82; SUB_I64 = 83; MUL_I64 = 84; LT_I64 = 85; EQ_I64 = 86
  INT_TO_F64 = 87; F64_TO_INT = 88

  # Native function IDs (must match interpreter's setupEnv!)
  NATIVES = {
    "+" => 1, "-" => 2, "*" => 3, "/" => 4,
    "=" => 5, "<" => 6, ">" => 7, "<=" => 8, ">=" => 9,
    "list" => 10, "list?" => 11, "empty?" => 12, "count" => 13,
    "not" => 14, "prn" => 15, "display" => 33,
    "list-ref" => 34, "list-length" => 35, "list-push" => 36,
    "modulo" => 37, "startsWith?" => 38, "split" => 39,
    "indexOf" => 40, "contains?" => 41, "trim" => 42,
    "substr" => 43, "toInt" => 44,
    "readFile" => 45, "writeFile" => 46, "shell" => 47,
    "endsWith?" => 48, "join" => 49,
    "abs" => 50, "min" => 51, "max" => 52, "floor" => 53,
    "timestampMs" => 54, "random" => 55, "randomInt" => 56,
    "string-append" => 26, "string-length" => 27, "substring" => 28,
    "string-ref" => 29, "number->string" => 30, "string->number" => 31,
    "string?" => 32, "charAt" => 29,
    "vector" => 16, "vector-ref" => 17, "vector-length" => 19,
    "cons" => 21, "car" => 22, "cdr" => 23, "pair?" => 24, "eq?" => 25,
  }

  OP_MAP = {
    ADD: ADD, SUB: SUB, MUL: MUL, DIV: DIV, MOD: nil,
    EQ: EQ, NEQ: nil, LT: LT, GT: GT, LTE: LTE, GTE: GTE,
  }

  def initialize
    @ops = []
    @consts = []
    @mutables = Set.new
  end

  def compile_program(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse

    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        # Type defs don't emit bytecode
      when AST::FunctionDef
        if stmt.name == "main"
          stmt.body.each do |node|
            next if node.is_a?(AST::ReturnNode) && node.value.nil?
            compile(node)
            emit(POP) # discard statement results
          end
        else
          # Compile function as lambda + store
          compile_function(stmt)
        end
      end
    end

    emit(HALT)
    { ops: @ops, consts: @consts }
  end

  def compile_function(stmt)
    params = stmt.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }

    # Compile body to sub-bytecode
    saved_ops = @ops
    saved_consts = @consts
    @ops = []
    @consts = []
    @mutables = Set.new

    body = stmt.body
    # Handle early returns
    compile_body_stmts(body)
    emit(HALT)

    sub_ops = @ops
    sub_consts = @consts

    @ops = saved_ops
    @consts = saved_consts

    # Store compiled function as a constant (encoded as list of ops + consts)
    # For now, we use NATIVE_CALL pattern - store as a scheme lambda via S-expr
    # The function is stored as a named constant in the env
    # Actually, for the bytecode path, emit the function as a named S-expr lambda
    # that the tree-walker can handle. The bytecode compiler focuses on main() body.
    #
    # Simpler approach: compile function body inline, store as named closure.
    # For now, emit the function definition as LOAD_CONST + STORE_NAME
    # with the value being a placeholder that the tree-walker handles.

    # Store function name + S-expr representation for the tree-walker fallback
    # The key insight: we can compile main() to bytecode and leave function defs
    # as STORE_NAME with lambda values. The CALL opcode invokes them via the
    # tree-walker. This gives us bytecode speed for the hot loop and tree-walker
    # for function calls.

    # Encode: store params + body ops as a "compiled lambda" constant
    param_str = params.join(",")
    cidx = add_const([:compiled_fn, param_str, sub_ops, sub_consts])
    emit(LOAD_CONST, cidx)
    name_idx = add_const(stmt.name.to_s)
    emit(STORE_NAME, name_idx)
    emit(POP)
  end

  private

  def emit(op, *args)
    @ops << op
    args.each { |a| @ops << a }
  end

  def add_const(val)
    idx = @consts.length
    @consts << val
    idx
  end

  def compile(node)
    case node
    when AST::Literal
      compile_literal(node)
    when AST::Identifier
      name_idx = add_const(node.name.to_s)
      emit(LOAD_NAME, name_idx)
    when AST::BinaryOp
      compile_binary(node)
    when AST::UnaryOp
      compile_unary(node)
    when AST::BindExpr
      compile_bind(node)
    when AST::VarDecl
      compile_vardecl(node)
    when AST::Assignment
      compile_assignment(node)
    when AST::IfStatement
      compile_if(node)
    when AST::WhileLoop
      compile_while(node)
    when AST::ForRange
      compile_for_range(node)
    when AST::ForEach
      compile_for_each(node)
    when AST::ReturnNode
      compile(node.value) if node.value
    when AST::FuncCall
      compile_func_call(node)
    when AST::MethodCall
      compile_method_call(node)
    when AST::Assert
      compile_assert(node)
    when AST::GetField
      compile_get_field(node)
    when AST::GetIndex
      compile_get_index(node)
    when AST::ListLit
      compile_list_lit(node)
    when NilClass
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
    else
      # Fallback: emit nil for unhandled nodes
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
    end
  end

  def compile_literal(node)
    case node.type
    when :INT64
      cidx = add_const([:i64, node.value])
      emit(LOAD_CONST, cidx)
    when :NUMBER, :FLOAT
      cidx = add_const([:f64, node.value])
      emit(LOAD_CONST, cidx)
    when :STRING
      cidx = add_const([:str, node.value])
      emit(LOAD_CONST, cidx)
    when :BOOL, :TRUE
      cidx = add_const([:bool, true])
      emit(LOAD_CONST, cidx)
    when :FALSE
      cidx = add_const([:bool, false])
      emit(LOAD_CONST, cidx)
    when :NIL
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
    else
      cidx = add_const([:f64, node.value.to_f])
      emit(LOAD_CONST, cidx)
    end
  end

  def compile_binary(node)
    op = node.op

    if op == :OR_RESCUE
      # For now, compile left side; OR fallback needs error handling
      compile(node.left)
      return
    end

    if op == :SMOOTH
      # Pipeline - compile left, then call right
      compile(node.left)
      # TODO: handle pipeline ops
      return
    end

    compile(node.left)
    compile(node.right)

    case op
    when :ADD then emit(ADD)
    when :SUB then emit(SUB)
    when :MUL then emit(MUL)
    when :DIV then emit(DIV)
    when :EQ then emit(EQ)
    when :NEQ then emit(EQ); emit(NOT)
    when :LT then emit(LT)
    when :GT then emit(GT)
    when :LTE then emit(LTE)
    when :GTE then emit(GTE)
    when :MOD
      emit(NATIVE_CALL, NATIVES["modulo"], 2)
    when :AND
      # Short-circuit: if left false, skip right
      # For now, just evaluate both
    when :OR
      # Short-circuit
    else
      emit(ADD) # fallback
    end
  end

  def compile_unary(node)
    compile(node.right)
    case node.op
    when :NOT, :BANG, :EXCL
      emit(NOT)
    when :SUB, :NEG
      cidx = add_const([:i64, 0])
      # Swap: push 0, swap with operand, subtract
      # Simpler: load 0, load operand, SUB
      # Actually we already compiled operand. Push 0 before it.
      # Rewrite: emit 0 first, then operand, then SUB
      # Can't reorder - operand already on stack. Use NEG pattern:
      # push -1, MUL
      neg_idx = add_const([:i64, -1])
      emit(LOAD_CONST, neg_idx)
      emit(MUL)
    end
  end

  def compile_bind(node)
    compile(node.value)
    if @mutables.include?(node.name.to_s)
      name_idx = add_const(node.name.to_s)
      emit(SET_NAME, name_idx)
    else
      name_idx = add_const(node.name.to_s)
      emit(STORE_NAME, name_idx)
    end
  end

  def compile_vardecl(node)
    @mutables.add(node.name.to_s) if node.mutable
    if node.value
      compile(node.value)
    else
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
    end
    name_idx = add_const(node.name.to_s)
    emit(STORE_NAME, name_idx)
  end

  def compile_assignment(node)
    compile(node.value)
    if node.name.is_a?(String) || node.name.is_a?(Symbol)
      name_idx = add_const(node.name.to_s)
      emit(SET_NAME, name_idx)
    else
      # Field assignment etc - store result, discard for now
    end
  end

  def compile_if(node)
    compile(node.condition)
    emit(JUMP_IF_FALSE)
    jump_false_idx = @ops.length
    emit(0) # placeholder

    # Then branch
    compile_body_stmts(node.then_branch)

    if node.else_branch && !node.else_branch.empty?
      emit(JUMP)
      jump_end_idx = @ops.length
      emit(0) # placeholder

      @ops[jump_false_idx] = @ops.length

      compile_body_stmts(node.else_branch)

      @ops[jump_end_idx] = @ops.length
    else
      @ops[jump_false_idx] = @ops.length
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
    end
  end

  def compile_while(node)
    loop_start = @ops.length

    compile(node.condition)
    emit(JUMP_IF_FALSE)
    jump_exit_idx = @ops.length
    emit(0) # placeholder

    node.do_branch.each do |stmt|
      compile(stmt)
      emit(POP)
    end

    emit(JUMP, loop_start)

    @ops[jump_exit_idx] = @ops.length

    # While returns nil
    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
  end

  def compile_for_range(node)
    var = node.var_name
    @mutables.add(var)

    # Init counter
    compile(node.start_expr)
    var_idx = add_const(var)
    emit(STORE_NAME, var_idx)
    emit(POP)

    # Loop start
    loop_start = @ops.length

    # Condition: var < end
    emit(LOAD_NAME, var_idx)
    compile(node.end_expr)
    emit(LT)
    emit(JUMP_IF_FALSE)
    jump_exit_idx = @ops.length
    emit(0)

    # Body
    node.body.each do |stmt|
      compile(stmt)
      emit(POP)
    end

    # Increment
    emit(LOAD_NAME, var_idx)
    one_idx = add_const([:i64, 1])
    emit(LOAD_CONST, one_idx)
    emit(ADD)
    emit(SET_NAME, var_idx)
    emit(POP)

    emit(JUMP, loop_start)

    @ops[jump_exit_idx] = @ops.length
    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
  end

  def compile_for_each(node)
    var = node.var_name
    idx_var = "__idx_#{var}"
    @mutables.add(idx_var)

    # Init index = 0
    zero_idx = add_const([:i64, 0])
    emit(LOAD_CONST, zero_idx)
    idx_name = add_const(idx_var)
    emit(STORE_NAME, idx_name)
    emit(POP)

    # Compile collection
    compile(node.collection)
    coll_name = add_const("__coll_#{var}")
    emit(STORE_NAME, coll_name)
    emit(POP)

    # Loop start
    loop_start = @ops.length

    # Condition: idx < list-length(collection)
    emit(LOAD_NAME, idx_name)
    emit(LOAD_NAME, coll_name)
    emit(NATIVE_CALL, NATIVES["list-length"], 1)
    emit(LT)
    emit(JUMP_IF_FALSE)
    jump_exit_idx = @ops.length
    emit(0)

    # var = list-ref(collection, idx)
    emit(LOAD_NAME, coll_name)
    emit(LOAD_NAME, idx_name)
    emit(NATIVE_CALL, NATIVES["list-ref"], 2)
    var_name_idx = add_const(var)
    emit(STORE_NAME, var_name_idx)
    emit(POP)

    # Body
    node.body.each do |stmt|
      compile(stmt)
      emit(POP)
    end

    # Increment idx
    emit(LOAD_NAME, idx_name)
    one_idx = add_const([:i64, 1])
    emit(LOAD_CONST, one_idx)
    emit(ADD)
    emit(SET_NAME, idx_name)
    emit(POP)

    emit(JUMP, loop_start)

    @ops[jump_exit_idx] = @ops.length
    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
  end

  def compile_func_call(node)
    name = node.name.to_s

    # Check for native function
    native_id = NATIVES[name]
    if native_id
      node.args.each { |a| compile(a) }
      emit(NATIVE_CALL, native_id, node.args.length)
      return
    end

    # Map builtins
    case name
    when "print"
      node.args.each { |a| compile(a) }
      emit(NATIVE_CALL, NATIVES["display"], node.args.length)
      return
    when "eql?"
      node.args.each { |a| compile(a) }
      emit(EQ)
      return
    when "toInt"
      compile(node.args[0])
      emit(F64_TO_INT)
      return
    when "toFloat"
      compile(node.args[0])
      emit(INT_TO_F64)
      return
    end

    # User-defined function: load fn, load args, CALL
    fn_idx = add_const(name)
    emit(LOAD_NAME, fn_idx)
    node.args.each { |a| compile(a) }
    emit(CALL, node.args.length)
  end

  def compile_method_call(node)
    name = node.name.to_s
    case name
    when "length"
      compile(node.object)
      emit(NATIVE_CALL, NATIVES["list-length"], 1)
    when "append"
      # list.append(val) -> set! list (list-push list val)
      compile(node.object)
      compile(node.args[0])
      emit(NATIVE_CALL, NATIVES["list-push"], 2)
      if node.object.is_a?(AST::Identifier)
        name_idx = add_const(node.object.name.to_s)
        emit(SET_NAME, name_idx)
      end
    when "toString"
      compile(node.object)
      emit(NATIVE_CALL, NATIVES["number->string"], 1)
    when "trim"
      compile(node.object)
      emit(NATIVE_CALL, NATIVES["trim"], 1)
    when "split"
      compile(node.object)
      compile(node.args[0])
      emit(NATIVE_CALL, NATIVES["split"], 2)
    else
      # UFCS: obj.method(args) -> (method obj args)
      compile(node.object)
      node.args.each { |a| compile(a) }
      native_id = NATIVES[name]
      if native_id
        emit(NATIVE_CALL, native_id, 1 + node.args.length)
      else
        fn_idx = add_const(name)
        emit(LOAD_NAME, fn_idx)
        # Reorder: fn should be before args on stack... this is tricky
        # For now, use CALL
        emit(CALL, 1 + node.args.length)
      end
    end
  end

  def compile_assert(node)
    compile(node.condition)
    emit(NOT)
    emit(JUMP_IF_FALSE)
    jump_ok_idx = @ops.length
    emit(0) # placeholder

    # Assertion failed - print message and halt
    msg = (node.message.is_a?(String) && !node.message.empty?) ? node.message : "assertion failed"
    msg_idx = add_const([:str, "ASSERT FAILED: #{msg}"])
    emit(LOAD_CONST, msg_idx)
    emit(NATIVE_CALL, NATIVES["display"], 1)
    emit(POP)

    @ops[jump_ok_idx] = @ops.length
    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
  end

  def compile_get_field(node)
    # For now, fall back to loading and using vector-ref
    compile(node.target)
    # We'd need struct schema here - for now emit as native call
    # TODO: proper field index resolution
    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
  end

  def compile_get_index(node)
    compile(node.target)
    compile(node.index)
    emit(NATIVE_CALL, NATIVES["list-ref"], 2)
  end

  def compile_list_lit(node)
    if node.items.empty?
      cidx = add_const([:empty_list])
      emit(LOAD_CONST, cidx)
    else
      node.items.each { |i| compile(i) }
      cidx = add_const([:i64, node.items.length])
      emit(LOAD_CONST, cidx)
      # Use make_list pattern: push items, push count, native call
      # Actually, we don't have a MAKE_LIST that takes count from stack.
      # Build incrementally: start with empty list, push each
      # Simpler: emit as native "list" call
      # Undo the individual pushes - emit all at once via native call
      emit(NATIVE_CALL, NATIVES["list"], node.items.length)
    end
  end

  def compile_body_stmts(stmts)
    return unless stmts
    stmts = stmts.reject { |s| s.is_a?(AST::ReturnNode) && s.value.nil? }
    return if stmts.empty?

    # Handle early returns
    stmts.each_with_index do |stmt, i|
      if stmt.is_a?(AST::ReturnNode) && stmt.value
        compile(stmt.value)
        return
      end
      compile(stmt)
      emit(POP) if i < stmts.length - 1
    end
  end

  public

  # Serialize bytecodes to a format the interpreter can read:
  # Line 1: comma-separated ops (integers)
  # Line 2: serialized constants (one per line after)
  def serialize
    lines = []
    lines << @ops.join(",")
    @consts.each do |c|
      case c
      when nil
        lines << "N"
      when Array
        type, val = c[0], c[1]
        case type
        when :i64 then lines << "I:#{val}"
        when :f64 then lines << "F:#{val}"
        when :str then lines << "S:#{val}"
        when :bool then lines << "B:#{val}"
        when :empty_list then lines << "L"
        when :compiled_fn
          # Encode compiled function: params,sub_ops,sub_consts
          lines << "FN:#{c[1]}:#{c[2].join(',')}:#{c[3].map { |sc| serialize_const(sc) }.join(';')}"
        else
          lines << "N"
        end
      when String
        lines << "SYM:#{c}"
      else
        lines << "N"
      end
    end
    lines.join("\n")
  end

  def serialize_const(c)
    case c
    when nil then "N"
    when Array
      type = c[0]
      case type
      when :i64 then "I:#{c[1]}"
      when :f64 then "F:#{c[1]}"
      when :str then "S:#{c[1]}"
      when :bool then "B:#{c[1]}"
      else "N"
      end
    when String then "SYM:#{c}"
    else "N"
    end
  end
end
