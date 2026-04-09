#!/usr/bin/env ruby
# BytecodeCompiler: CLEAR AST -> bytecodes for the Scheme VM's exec!
# Emits Int64[] ops + Value[] consts that exec! consumes directly.

class BytecodeCompiler
  # Opcode constants - dense numbering for jump table efficiency.
  # Must match interpreter's exec! MATCH cases exactly.
  LOAD_CONST  = 0;  LOAD_NAME   = 1;  STORE_NAME  = 2;  POP         = 3
  ADD         = 4;  SUB         = 5;  MUL         = 6;  DIV         = 7
  EQ          = 8;  LT          = 9;  GT          = 10; LTE         = 11; GTE = 12
  NOT         = 13; JUMP        = 14; JUMP_IF_FALSE = 15
  CALL        = 16; SET_NAME    = 17; NATIVE_CALL = 18; HALT        = 19
  LOAD_SLOT   = 20; STORE_SLOT  = 21
  ADD_I64     = 22; SUB_I64     = 23; MUL_I64     = 24; LT_I64      = 25; EQ_I64 = 26
  INT_TO_F64  = 27; F64_TO_INT  = 28; MOD_I64     = 29; GTE_I64     = 30
  GT_I64      = 31; LTE_I64     = 32; NEQ_I64     = 33; DIV_I64     = 34
  JUMP_BACK   = 35; CONCAT      = 36; DEFINE_FN   = 37
  # Typed stack opcodes: i64 and f64 operate on dedicated 8-byte stacks
  LOAD_SLOT_I64  = 38; STORE_SLOT_I64 = 39; LOAD_CONST_I64 = 40; JUMP_IF_FALSE_I = 41
  LOAD_SLOT_F64  = 42; STORE_SLOT_F64 = 43; LOAD_CONST_F64 = 44
  ADD_F64     = 45; SUB_F64     = 46; MUL_F64     = 47; DIV_F64     = 48
  LT_F64      = 49; GT_F64      = 50; LTE_F64     = 51; GTE_F64     = 52
  EQ_F64      = 53; NEQ_F64     = 54
  I_TO_VAL    = 55; F_TO_VAL    = 56; BOOL_TO_VAL = 57
  DEBUG_BREAK = 58

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
    @slots = {}       # var_name -> slot_index
    @slot_types = {}  # var_name -> :i64, :f64, :str, :any
    @next_slot = 0
    @type_stack = []  # tracks type of each expression on the compile stack
  end

  def alloc_slot(name, type = :any)
    unless @slots[name]
      @slots[name] = @next_slot
      @next_slot += 1
    end
    @slot_types[name] = type
    @slots[name]
  end

  def var_type(name)
    @slot_types[name] || :any
  end

  def push_type(t)
    @type_stack.push(t)
  end

  def pop_type
    @type_stack.pop || :any
  end

  def peek_type
    @type_stack.last || :any
  end

  # Ensure the top value is on the Value stack (for untyped consumers like CALL, NATIVE_CALL, CONCAT).
  # If top is on a typed stack, emit a transfer opcode.
  # :bool from typed comparisons is on istack (as 0/1), so it also needs I_TO_VAL.
  def ensure_value_stack
    t = peek_type
    case t
    when :i64
      emit(I_TO_VAL)
      @type_stack[-1] = :any
    when :bool
      emit(BOOL_TO_VAL)
      @type_stack[-1] = :any
    when :f64
      emit(F_TO_VAL)
      @type_stack[-1] = :any
    end
  end

  # Compile a node and ensure the result is on the Value stack.
  def compile_to_value(node)
    compile(node)
    ensure_value_stack
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
            t = pop_type
            emit(POP) unless t == :i64 || t == :f64 || t == :bool
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
    # Emit function as S-expression define for the tree-walker.
    # main() body runs as bytecode; function defs are registered via eval!
    # so CALL can invoke them as lambdas.
    transpiler = SchemeTranspiler.new
    sexpr = transpiler.emit_function_def(stmt)
    cidx = add_const([:str, sexpr])
    name_idx = add_const(stmt.name.to_s)
    emit(DEFINE_FN, cidx, name_idx)
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
      name = node.name.to_s
      if @slots[name]
        vt = var_type(name)
        case vt
        when :i64 then emit(LOAD_SLOT_I64, @slots[name])
        when :f64 then emit(LOAD_SLOT_F64, @slots[name])
        else emit(LOAD_SLOT, @slots[name])
        end
        push_type(vt)
      else
        name_idx = add_const(name)
        emit(LOAD_NAME, name_idx)
        push_type(:any)
      end
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
      emit(LOAD_CONST_I64, cidx)
      push_type(:i64)
    when :NUMBER, :FLOAT
      cidx = add_const([:f64, node.value])
      emit(LOAD_CONST_F64, cidx)
      push_type(:f64)
    when :STRING
      cidx = add_const([:str, node.value])
      emit(LOAD_CONST, cidx)
      push_type(:str)
    when :BOOL, :TRUE
      cidx = add_const([:bool, true])
      emit(LOAD_CONST, cidx)
      push_type(:bool)
    when :FALSE
      cidx = add_const([:bool, false])
      emit(LOAD_CONST, cidx)
      push_type(:bool)
    when :NIL
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
      push_type(:any)
    else
      cidx = add_const([:f64, node.value.to_f])
      emit(LOAD_CONST, cidx)
      push_type(:f64)
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
    left_type = pop_type
    compile(node.right)
    right_type = pop_type

    both_i64 = (left_type == :i64 && right_type == :i64)
    both_f64 = (left_type == :f64 && right_type == :f64)

    case op
    when :ADD
      if left_type == :str || right_type == :str then emit(CONCAT); push_type(:str)
      elsif both_i64 then emit(ADD_I64); push_type(:i64)
      elsif both_f64 then emit(ADD_F64); push_type(:f64)
      else emit(ADD); push_type(:f64) end
    when :SUB
      if both_i64 then emit(SUB_I64); push_type(:i64)
      elsif both_f64 then emit(SUB_F64); push_type(:f64)
      else emit(SUB); push_type(:f64) end
    when :MUL
      if both_i64 then emit(MUL_I64); push_type(:i64)
      elsif both_f64 then emit(MUL_F64); push_type(:f64)
      else emit(MUL); push_type(:f64) end
    when :DIV
      if both_i64 then emit(DIV_I64); push_type(:i64)
      elsif both_f64 then emit(DIV_F64); push_type(:f64)
      else emit(DIV); push_type(:f64) end
    when :EQ
      if both_i64 then emit(EQ_I64)
      elsif both_f64 then emit(EQ_F64)
      else emit(EQ) end
      push_type(:bool)
    when :NEQ
      if both_i64 then emit(NEQ_I64)
      elsif both_f64 then emit(NEQ_F64)
      else emit(EQ); emit(NOT) end
      push_type(:bool)
    when :LT
      if both_i64 then emit(LT_I64)
      elsif both_f64 then emit(LT_F64)
      else emit(LT) end
      push_type(:bool)
    when :GT
      if both_i64 then emit(GT_I64)
      elsif both_f64 then emit(GT_F64)
      else emit(GT) end
      push_type(:bool)
    when :LTE
      if both_i64 then emit(LTE_I64)
      elsif both_f64 then emit(LTE_F64)
      else emit(LTE) end
      push_type(:bool)
    when :GTE
      if both_i64 then emit(GTE_I64)
      elsif both_f64 then emit(GTE_F64)
      else emit(GTE) end
      push_type(:bool)
    when :MOD
      if both_i64 then emit(MOD_I64) else emit(NATIVE_CALL, NATIVES["modulo"], 2) end
      push_type(:i64)
    when :AND then push_type(:bool)
    when :OR then push_type(:bool)
    else emit(ADD); push_type(:any)
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
    val_type = pop_type
    name = node.name.to_s

    if @mutables.include?(name) && @slots[name]
      case val_type
      when :i64 then emit(STORE_SLOT_I64, @slots[name])
      when :f64 then emit(STORE_SLOT_F64, @slots[name])
      else emit(STORE_SLOT, @slots[name])
      end
    elsif @mutables.include?(name)
      slot = alloc_slot(name, val_type)
      case val_type
      when :i64 then emit(STORE_SLOT_I64, slot)
      when :f64 then emit(STORE_SLOT_F64, slot)
      else emit(STORE_SLOT, slot)
      end
    else
      slot = alloc_slot(name, val_type)
      case val_type
      when :i64 then emit(STORE_SLOT_I64, slot)
      when :f64 then emit(STORE_SLOT_F64, slot)
      else emit(STORE_SLOT, slot)
      end
    end
    push_type(val_type)
  end

  def compile_vardecl(node)
    @mutables.add(node.name.to_s) if node.mutable
    name = node.name.to_s

    if node.value
      compile(node.value)
      val_type = pop_type
    else
      cidx = add_const(nil)
      emit(LOAD_CONST, cidx)
      val_type = :any
    end

    # Infer type from declaration if available
    if node.type
      type_str = node.type.to_s
      if type_str.include?("Int64") && !type_str.include?("[]")
        val_type = :i64
      elsif type_str.include?("Float64") && !type_str.include?("[]")
        val_type = :f64
      elsif type_str.include?("String")
        val_type = :str
      end
    end

    slot = alloc_slot(name, val_type)
    case val_type
    when :i64 then emit(STORE_SLOT_I64, slot)
    when :f64 then emit(STORE_SLOT_F64, slot)
    else emit(STORE_SLOT, slot)
    end
    push_type(val_type)
  end

  def compile_assignment(node)
    compile(node.value)
    val_type = pop_type
    if node.name.is_a?(String) || node.name.is_a?(Symbol)
      name = node.name.to_s
      if @slots[name]
        case val_type
        when :i64 then emit(STORE_SLOT_I64, @slots[name])
        when :f64 then emit(STORE_SLOT_F64, @slots[name])
        else emit(STORE_SLOT, @slots[name])
        end
        @slot_types[name] = val_type
      else
        name_idx = add_const(name)
        emit(SET_NAME, name_idx)
      end
    end
    push_type(val_type)
  end

  def compile_if(node)
    compile(node.condition)
    cond_type = pop_type
    emit(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    push_type(cond_type)  # restore for balance
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
    cond_type = pop_type
    emit(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    jump_exit_idx = @ops.length
    emit(0) # placeholder

    node.do_branch.each do |stmt|
      compile(stmt)
      t = pop_type
      emit(POP) unless t == :i64 || t == :f64 || t == :bool
    end

    emit(JUMP, loop_start)

    @ops[jump_exit_idx] = @ops.length

    cidx = add_const(nil)
    emit(LOAD_CONST, cidx)
    push_type(:any)
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
      node.args.each { |a| compile_to_value(a) }
      emit(NATIVE_CALL, native_id, node.args.length)
      return
    end

    # Map builtins
    case name
    when "print"
      node.args.each { |a| compile_to_value(a) }
      emit(NATIVE_CALL, NATIVES["display"], node.args.length)
      return
    when "eql?"
      node.args.each { |a| compile_to_value(a) }
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
    when "debug"
      emit(DEBUG_BREAK)
      return
    end

    # User-defined function: load fn, load args, CALL
    fn_idx = add_const(name)
    emit(LOAD_NAME, fn_idx)
    node.args.each { |a| compile_to_value(a) }
    emit(CALL, node.args.length)
  end

  def compile_method_call(node)
    name = node.name.to_s
    case name
    when "length"
      compile_to_value(node.object)
      emit(NATIVE_CALL, NATIVES["list-length"], 1)
    when "append"
      # list.append(val) -> set! list (list-push list val)
      compile_to_value(node.object)
      compile_to_value(node.args[0])
      emit(NATIVE_CALL, NATIVES["list-push"], 2)
      if node.object.is_a?(AST::Identifier)
        name_idx = add_const(node.object.name.to_s)
        emit(SET_NAME, name_idx)
      end
    when "toString"
      compile_to_value(node.object)
      emit(NATIVE_CALL, NATIVES["number->string"], 1)
    when "trim"
      compile_to_value(node.object)
      emit(NATIVE_CALL, NATIVES["trim"], 1)
    when "split"
      compile_to_value(node.object)
      compile_to_value(node.args[0])
      emit(NATIVE_CALL, NATIVES["split"], 2)
    else
      # UFCS: obj.method(args) -> (method obj args)
      compile_to_value(node.object)
      node.args.each { |a| compile_to_value(a) }
      native_id = NATIVES[name]
      if native_id
        emit(NATIVE_CALL, native_id, 1 + node.args.length)
      else
        fn_idx = add_const(name)
        emit(LOAD_NAME, fn_idx)
        emit(CALL, 1 + node.args.length)
      end
    end
  end

  def compile_assert(node)
    compile(node.condition)
    cond_type = pop_type
    if cond_type == :bool
      # Typed bool is on istack as 0/1. Transfer to Value stack as TrueVal/FalseVal,
      # then use standard NOT + JUMP_IF_FALSE for the assert logic.
      emit(BOOL_TO_VAL)
      emit(NOT)
      emit(JUMP_IF_FALSE)
    else
      ensure_value_stack
      emit(NOT)
      emit(JUMP_IF_FALSE)
    end
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
      t = pop_type
      emit(POP) if i < stmts.length - 1 && t != :i64 && t != :f64 && t != :bool
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
