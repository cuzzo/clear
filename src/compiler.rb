require 'logger'
require 'byebug'

require_relative "./ast"

# ==========================================
# COMPILER
# ==========================================
class Compiler
  class Chunk
    attr_accessor :code, :constants, :name, :handler_info, :line_info
    def initialize(name = "main")
      @name = name
      @code = []
      @constants = []
      @handler_info = {}
      @line_info = []
      @logger = $logger || Logger.new(STDOUT)
    end

    def add_constant(val)
      idx = @constants.index(val) || @constants.size
      @constants << val unless @constants.include?(val)
      idx
    end

    def emit(node, opcode, *operands)
      line_number = node.nil? ? -1 : node.line
      @code << [opcode, *operands]
      @line_info << line_number
    end

    # Returns the index of the instruction we just added
    # so we can patch it later.
    def emit_with_index(node, opcode, *operands)
      line_number = node.nil? ? -1 : node.line
      @code << [opcode, *operands]
      @line_info << line_number
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
    @scope_depth = 0
    @loop_stack = []
    @struct_defs = {}
    @expected_return = return_type
    @logger = $logger || Logger.new(STDOUT)
  end

  def compile(ast)
    last_used_reg = 0 # Default to 0 if program is empty
    ast.statements.each do |s|
      if s.is_a?(AST::VarDecl)
        # FIX: Call directly. Let VarDecl manage @reg_top internally.
        # It will increment it and KEEP it incremented.
        result_reg = visit(s)
      else
        with_temp_reg do |r|
          visit(s, r)
          result_reg = r
        end
      end
      last_used_reg = result_reg if result_reg.is_a?(Integer)
    end
    # FIX: Always return R0, which usually holds nil or a standard default.
    # If you want to force 0:
    k_zero = @chunk.add_constant(0.to_i)

    # TODO: What do I put for the current node here?
    @chunk.emit(nil, :LOADK, "R0", "K#{k_zero}") # Ensure R0 is 0r
    @chunk.emit(nil, :RETURN, "R0")
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
    when AST::BreakNode then compile_break(node);
    when AST::ContinueNode then compile_continue(node);
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
    when AST::DieNode then compile_exit_program(node, target_reg);
    end
  end

  def compile_smooth_operator(node, target_reg, auto_throw_pipe)
    # 1. Compile the Left Side (The Input)
    visit(node.left, target_reg, auto_throw_pipe: auto_throw_pipe)

    # 2. Input Guard: Check if the *Input* is already an error

    skip_jump = nil
    if auto_throw_pipe
      # Default Mode: Crash if input is error
      @chunk.emit(node, :THROW_IF_ERROR, "R#{target_reg}")
    else
      # Soft Mode: Skip everything if input is error
      skip_jump = @chunk.emit_with_index(node, :JMP_IF_ERROR, "R#{target_reg}", 0)
    end

    # 3. Compile the Function Call
    if node.right.is_a?(AST::FuncCall)
      # Case 1: Explicit Call -> f(args)

      with_temp_reg do |r_snapshot|
        # A. Save Snapshot
        @chunk.emit(node, :MOVE, "R#{r_snapshot}", "R#{target_reg}")

        # B. Collect Arguments
        args_regs = compile_args(node.right.args)
        # Force piped val to the front
        args_regs.unshift("R#{target_reg}")

        # C. Call Helper (Fixed Name and Variables)
        _compile_func_with_args(node, r_snapshot, target_reg, args_regs)

        # D. Cleanup
        @reg_top -= (args_regs.size - 1)
      end

    elsif node.right.is_a?(AST::Identifier)
      # Case 2: Bare Identifier: x s> f

      with_temp_reg do |r_snapshot|
        # A. Save Snapshot
        @chunk.emit(node, :MOVE, "R#{r_snapshot}", "R#{target_reg}")

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

    if auto_throw_pipe
      # Crash if the result of the function call (R{target_reg}) is an error.
      @chunk.emit(node, :THROW_IF_ERROR, "R#{target_reg}")
    end
  end

  def compile_bind_var(node, target_reg)
    # 1. Compile the Expression (The Left side) into target_reg
    #    This puts the result of the pipe chain into 'target_reg'
    visit(node.left, target_reg)

    var_name = node.right.name
    existing_reg = current_scope.resolve_reg(var_name)

    if existing_reg
      # === ASSIGNMENT CASE ===
      # The variable exists. We just move the value into its register.

      # Check mutability if you implemented that feature
      if current_scope.is_immutable?(var_name)
         raise "Compile Error: Cannot rebind immutable variable '#{var_name}'."
      end

      @chunk.emit(node, :MOVE, "R#{existing_reg}", "R#{target_reg}")

    else
      # === DECLARATION CASE ===
      # The variable is new. We allocate a NEW register for it.

      # 1. Allocate a permanent register
      var_reg = @reg_top
      @reg_top += 1

      # 2. Move the result: target_reg (temp) -> var_reg (permanent)
      @chunk.emit(node, :MOVE, "R#{var_reg}", "R#{target_reg}")

      # 3. Register in Scope
      #    Since we don't have an AST node for the value to infer from,
      #    we default to :Any. (Or you can try to infer from node.left if you have advanced inference)
      current_scope.declare(var_name, var_reg, :Any)

      # 4. Handle Global Scope
      if @scope_depth == 0
        @chunk.emit(node, :DEF_GLOBAL, var_name, "R#{var_reg}")
      end
    end

    # 3. Return nil to signal "Pass Through"
    #    The value is still sitting in 'target_reg', ready for the next pipe step.
    return nil
  end

  def _compile_func_with_args(node, r_snapshot, target_reg, args_regs)
    # A. Emit the Call
    # This overwrites 'target_reg' with the Result (or new Error)
    func_name = node.right.name

    if func_name == "print"
       @chunk.emit(node, :PRINT, *args_regs)
    elsif func_name == "native_call"
       raise "Compiler Error: Cannot pipe to native_call directly."
    else
       @chunk.emit(node, :CALL_FUNC, "R#{target_reg}", func_name, args_regs.size, *args_regs)
    end

    # B. Error Enrichment (Snapshot)
    # 1. If result is OK, jump over the enrichment logic
    ok_jump = @chunk.emit_with_index(node, :JMP_IF_OK, "R#{target_reg}", 0)

    # 2. If we are here, it IS an Error. Attach snapshot.
    @chunk.emit(node, :SETFIELD, "R#{target_reg}", "snapshot", "R#{r_snapshot}")

    # 3. Patch the jump
    @chunk.patch(ok_jump, @chunk.current_address, 2)
  end

  def compile_function_def(node, target_reg)
    fn_compiler = Compiler.new(node.name, node.return_type)
    fn_compiler.instance_variable_set(:@scope_depth, @scope_depth + 1)

    # 2. Register Parameters in Child Scope
    node.params.each_with_index do |p, i|
      fn_compiler.current_scope.declare(p[:name], i, p[:type])

      if p[:default]
        # We need to inject code: IF param IS NIL -> param = default_val

        # 1. We need a register holding NIL to compare against
        fn_compiler.send(:with_temp_reg) do |r_nil|
          # Add literal nil to constants
          k_nil = fn_compiler.chunk.add_constant(nil)
          fn_compiler.chunk.emit(node, :LOADK, "R#{r_nil}", "K#{k_nil}")

          # 2. Compare Param (R_i) with NIL
          fn_compiler.send(:with_temp_reg) do |r_check|
            # R_check = (R_param == R_nil)
            fn_compiler.chunk.emit(node, :EQ, "R#{r_check}", "R#{i}", "R#{r_nil}")

            # 3. Jump if FALSE (If it's not nil, it was passed by user; skip default)
            # We emit a jump with offset 0, we will patch it later
            skip_jump = fn_compiler.chunk.emit_with_index(node, :JMP_FALSE, "R#{r_check}", 0)

            # 4. Compile the Default Value Expression
            fn_compiler.send(:with_temp_reg) do |r_def_val|
              # Compile the expression (e.g., "Hello" or 5 + 5)
              fn_compiler.visit(p[:default], r_def_val)

              # Move result into the Parameter Register (overwriting nil)
              fn_compiler.chunk.emit(node, :MOVE, "R#{i}", "R#{r_def_val}")
            end

            # 5. Patch the Jump (Target is right here, after the assignment)
            fn_compiler.chunk.patch(skip_jump, fn_compiler.chunk.current_address, 2)
          end
        end
      end
    end

    # 3. REUSED LOGIC: Process Captures
    # This handles finding outer regs and registering inner regs
    captured_regs = process_captures(node, fn_compiler)

    # 4. Compile Body
    node.body.each do |stmt|
      if stmt.is_a?(AST::VarDecl)
        fn_compiler.send(:visit, stmt)
      else
        fn_compiler.send(:with_temp_reg) do |r|
          fn_compiler.send(:visit, stmt, r)
        end
      end
    end

    # 5. Handle Catch/Return (Same as before...)
    compile_catch_and_return(fn_compiler, node)

    # 6. REUSED LOGIC: Create the Closure
    fn_chunk = fn_compiler.instance_variable_get(:@chunk)
    emit_closure(node, target_reg, fn_chunk, captured_regs)

    # 7. (Specific to Named Functions) Define Global if at top level
    if @scope_depth == 0
      @chunk.emit(node, :DEF_GLOBAL, node.name, "R#{target_reg}")
    else
      current_scope.declare(node.name, target_reg, :Closure, false) # Closures are immutable
    end

    # Cleanup: since we added a reg in step 6
    # We should not decrement @reg_top here, as the register holds the function value

    # Note: The main compiler loop assumes 'visit' handles @reg_top,
    # but since we did it manually, the register is now "used."
    # We return the register index where the function is stored.
    return target_reg
  end

  def compile_func_call(node, target_reg)
    # 1. Handle Intrinsics (Only applies if the name is a static String)
    if node.name.is_a?(String)
      return compile_print(node) if node.name == "print"
      return compile_native_call(node, target_reg) if node.name == "native_call"
    end

    # 2. Compile Arguments
    #    We compile these first so the registers are populated.
    arg_regs = compile_args(node.args)

    # 3. Resolve the Function Target
    if node.name.is_a?(String)
      # --- CASE A: Simple Name (e.g., "add", "myFunc") ---
      # Check if it is a Local Register or Global Name
      func_reg = current_scope.resolve_reg(node.name)
      operand  = func_reg ? "R#{func_reg}" : node.name

      @chunk.emit(node, :CALL_FUNC, "R#{target_reg}", operand, node.args.size, *arg_regs)
    else
      # --- CASE B: Expression / Currying (e.g., "getFunc()(1)") ---
      # The target is an AST Node. We must compile it into a temp register first.
      with_temp_reg do |r_func|
        visit(node.name, r_func) # Recurse: compiles the 'getFunc()' part

        # Now call the result stored in r_func
        @chunk.emit(node, :CALL_FUNC, "R#{target_reg}", "R#{r_func}", node.args.size, *arg_regs)
      end
    end

    # 4. Cleanup Argument Registers
    @reg_top -= arg_regs.size
  end

  def compile_print(node)
    args = compile_args(node.args)
    @chunk.emit(node, :PRINT, *args)
    @reg_top -= args.size
  end

  def compile_native_call(node, target_reg)
    if node.args.size < 2
      raise "Compile Error: native_call requires 'Class' and 'Method' string literals."
    end

    class_node, method_node = node.args[0], node.args[1]

    unless class_node.is_a?(AST::Literal) && class_node.type == :STRING
      raise "Compile Error: native_call arg 1 must be a static String (Class Name)"
    end

    # Compile the ACTUAL arguments (skipping Class/Method strings)
    # We slice the args array, compile the rest, and get their registers
    real_args_regs = compile_args(node.args[2..-1])

    @chunk.emit(node, :CALL_NATIVE, "R#{target_reg}", class_node.value, method_node.value, *real_args_regs)
    @reg_top -= real_args_regs.size
  end

  def compile_args(args)
    args.map do |arg|
      r = @reg_top
      @reg_top += 1
      visit(arg, r)
      "R#{r}"
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

    if @scope_depth == 0
      # CASE A: GLOBAL
      # We must explicitly tell the VM to save this register into the Global Map.
      @chunk.emit(node, :DEF_GLOBAL, node.name, "R#{r}")
    else
      # CASE B: LOCAL
      # We do NOTHING.
      # The value is already sitting in Register 'r'.
    end

    current_scope.declare(node.name, r, final_type)
    return r
  end

  def compile_assignment(node, result_reg)
    # 1. Compile the Value (R-Value) into a temporary register
    #    We do this FIRST so the value is ready to be moved anywhere.
    with_temp_reg do |val_reg|
      visit(node.value, val_reg)

      # 1. Capture the L-Value (The "Left Hand Side")
      #    For "SET p.x = 10", node.name is the GetField node (p.x)
      l_value = node.name

      case l_value
      when AST::GetField then compile_field_set(l_value, val_reg)
      when AST::GetIndex then compile_index_set(l_value, val_reg)
      when AST::Identifier then compile_var_set(l_value, val_reg)
      # Legacy support for raw strings
      when String then compile_var_set(l_value, val_reg)
      else
        raise "Compile Error: Invalid assignment target: #{target.class}"
      end

      # 3. If the assignment is used as an expression, return the value
      if result_reg
        @chunk.emit(node, :MOVE, "R#{result_reg}", "R#{val_reg}")
      end
    end
  end

  def compile_var_set(node, val_reg)
    var_name = node.is_a?(AST::Identifier) ? node.name : node

    # 1. Check Mutability (Optional feature)
    if current_scope.is_immutable?(var_name)
      raise "Compile Error: Variable '#{var_name}' is immutable."
    end

    # 2. Resolve the Register for this variable
    target_reg = current_scope.resolve_reg(var_name)

    # 3. Handle Local vs Global
    if target_reg
      # It's a Local Variable (in a Register)
      @chunk.emit(node, :MOVE, "R#{target_reg}", "R#{val_reg}")

    elsif @chunk.globals_include?(var_name) # Assuming you track globals
      # It's a Global Variable (Needs explicit SET_GLOBAL if your VM supports it)
      # If your VM maps globals to registers in main, this might need adjustment.
      @chunk.emit(node, :SET_GLOBAL, var_name, "R#{val_reg}")
    else
      # 4. Error if not found
      raise "Compile Error: Cannot SET '#{var_name}' because it has not been declared with VAR."
    end
  end

  def compile_field_set(node, val_reg)
    # node is the AST::GetField(target, field)
    with_temp_reg do |obj_reg|
      visit(node.target, obj_reg) # Compile 'obj'

      # Emit: SETFIELD R_obj, "field_name", R_val
      @chunk.emit(node, :SETFIELD, "R#{obj_reg}", node.field, "R#{val_reg}")
    end
  end

  def compile_index_set(node, val_reg)
    # node is the AST::GetIndex(target, index)
    with_temp_reg do |obj_reg|
      visit(node.target, obj_reg) # Compile array/hash

      with_temp_reg do |key_reg|
        visit(node.index, key_reg) # Compile the index/key

        # Emit: SETHASH R_obj, R_key, R_val
        @chunk.emit(node, :SETHASH, "R#{obj_reg}", "R#{key_reg}", "R#{val_reg}")
      end
    end
  end

  def compile_binary_op(node, target_reg, auto_throw_pipe)
    # Don't do the normal math logic for non-sendable symbols
    case node.op # op_sym # node.op
      when :SMOOTH then return compile_smooth_operator(node, target_reg, auto_throw_pipe);
      when :BIND_VAR then return compile_bind_var(node, target_reg);
      when :OR_RESCUE then return compile_or_rescue(node, target_reg);
      when :AND then return compile_logical_and(node, target_reg);
      when :OR then return compile_logical_or(node, target_reg);
    end

    with_temp_reg do |r1|
      visit(node.left, r1)
      with_temp_reg do |r2|
        visit(node.right, r2)
        @chunk.emit(node, node.op, "R#{target_reg}", "R#{r1}", "R#{r2}")
      end
    end
  end

  def compile_logical_or(node, target_reg)
    # 1. Compile Left
    visit(node.left, target_reg)

    # 2. Short Circuit: If Left is TRUE, Jump to End
    end_jump = @chunk.emit_with_index(node, :JMP_TRUE, "R#{target_reg}", 0)

    # 3. Compile Right
    visit(node.right, target_reg)

    # 4. Patch
    @chunk.patch(end_jump, @chunk.current_address, 2)
    return # Don't do the normal math logic
  end

  def compile_logical_and(node, target_reg)
    # 1. Compile Left into target_reg
    visit(node.left, target_reg)

    # 2. Short Circuit: If Left is FALSE, Jump to End
    # The result (FALSE) is already sitting in target_reg, so we are done.
    end_jump = @chunk.emit_with_index(node, :JMP_FALSE, "R#{target_reg}", 0)

    # 3. Compile Right
    # If we didn't jump, calculate Right and put it in target_reg
    visit(node.right, target_reg)

    # 4. Patch the Jump
    @chunk.patch(end_jump, @chunk.current_address, 2)
    return # Don't do the normal math logic
  end

  def compile_or_rescue(node, target_reg)
    # 1. Compile Left Side (The Pipe/Expression)
    # auto_throw_pipe: false -> Return Error struct, don't crash
    visit(node.left, target_reg, auto_throw_pipe: false)

    # 2. Emit Check: "Jump to End if OK"
    # If target_reg is valid data, we skip the recovery block.
    success_jump = @chunk.emit_with_index(node, :JMP_IF_OK, "R#{target_reg}", 0)

    # 3. Compile Right Side (The Recovery)
    # At this point, target_reg holds the %Error object.
    if node.right.is_a?(AST::ReturnNode) && node.right.value.nil?
      # Syntax: OR RETURN
      # Action: Return the current register (the Error)
      @chunk.emit(node, :RETURN, "R#{target_reg}")

    elsif node.right.is_a?(AST::ThrowNode)
      # Syntax: OR EXIT (with optional context)
      if node.right.value # context_expr exists
        # 1. Compile the Context String
        with_temp_reg do |r_ctx|
          visit(node.right.value, r_ctx)

          # 2. Set the Context Field on the Error
          # target_reg currently holds the Error object
          @chunk.emit(node, :SETFIELD, "R#{target_reg}", "context", "R#{r_ctx}")
        end
      end
      # Action: Throw the current register (the Error)
      @chunk.emit(node, :THROW, "R#{target_reg}")

    else
      # Syntax: OR ELSE <value>
      # Action: Compile the value into the target register (overwriting the Error)
      visit(node.right, target_reg)
    end

    # 4. Patch the Jump
    @chunk.patch(success_jump, @chunk.current_address, 2)
    return nil
  end

  def compile_unary_op(node, target_reg)
    if node.op == :SUB
      # Optimization: If it's a literal number, just load the negative version directly
      if node.right.is_a?(AST::Literal) && node.right.type == :NUMBER
         # Emit LOADK -5 directly
         k = @chunk.add_constant(-node.right.value)
         @chunk.emit(node, :LOADK, "R#{target_reg}", "K#{k}")
         return
      end

      # Generic Case: Calculate (0 - value)
      with_temp_reg do |r_zero|
        # 1. Load 0
        k_zero = @chunk.add_constant(0)
        emit(node, :LOADK, r_zero, "K#{k_zero}")

        # 2. Compile the expression being negated
        # Note: Depending on your register allocator, ensure 'visit' puts result in a known reg
        # For this example, let's assume 'visit' returns the register it used.
        r_val = visit(node.right)

        # 3. Perform 0 - value
        emit(node, :SUB, r_val, r_zero, r_val) # Target, LHS, RHS
      end

    elsif node.op == :NOT
      with_temp_reg do |r_src|
        visit(node.right, r_src)
        @chunk.emit(node, :NOT, "R#{target_reg}", "R#{r_src}")
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
        @chunk.emit(node, :GET_INDEX, "R#{target_reg}", "R#{r_target}", "R#{r_index}")
      end
    end
  end

  def compile_get_field(node, target_reg)
    # x.name
    with_temp_reg do |r_target|
      visit(node.target, r_target)
      # We assume field names are static strings for now
      # Emit GET_FIELD R_result, R_target, "field_name"
      @chunk.emit(node, :GET_FIELD, "R#{target_reg}", "R#{r_target}", node.field)
    end
  end

  def compile_cast(node, target_reg)
    visit(node.value, target_reg)
    @chunk.emit(node, :CAST, "R#{target_reg}", node.target)
  end

  def compile_literal(node, target_reg)
    k = @chunk.add_constant(node.value)
    @chunk.emit(node, :LOADK, "R#{target_reg}", "K#{k}")
  end

  def compile_if_statement(node, target_reg)
    # 1. Compile Condition
    with_temp_reg do |r_cond|
      visit(node.condition, r_cond)

      # 2. Emit JMP_FALSE
      # "If condition (r_cond) is false, jump to... Unknown (0) for now"
      else_jump = @chunk.emit_with_index(node, :JMP_FALSE, "R#{r_cond}", 0)

      # 3. Compile THEN branch
      node.then_branch.each { |stmt| visit(stmt) }

      # 4. Emit JMP (Unconditional)
      # If we finished the THEN block, we must skip the ELSE block.
      # Target is unknown (0) for now.
      end_jump = @chunk.emit_with_index(node, :JMP, 0)

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
      # 1. MARK START (Target for CONTINUE)
      loop_start_index = @chunk.code.length

      # PUSH CONTEXT
      @loop_stack.push({
        start: loop_start_index,
        breaks: []
      })

      # 2. Compile Condition
      visit(node.condition, r_cond)

      # 3. Exit Jump (If condition is false)
      do_jump = @chunk.emit_with_index(node, :JMP_FALSE, "R#{r_cond}", 0)

      # 4. Compile Body
      node.do_branch.each { |stmt| visit(stmt) }

      # 5. Loop Back
      @chunk.emit_with_index(node, :JMP, loop_start_index)

      # 6. PATCH EXIT JUMP
      loop_end_index = @chunk.code.length
      @chunk.patch(do_jump, loop_end_index, 2) # Patch the JMP_FALSE

      # 7. PATCH BREAK JUMPS (New Logic)
      context = @loop_stack.pop # Remove context
      context[:breaks].each do |break_index|
        # Patch every BREAK instruction to jump to loop_end_index
        @chunk.patch(break_index, loop_end_index, 1)
      end
    end
  end

  def compile_break(node)
    if @loop_stack.empty?
      raise "Compile Error: 'BREAK' used outside of a loop."
    end

    # Emit a JMP to 0 (Placeholder).
    # We save this index into the current loop context to patch later.
    idx = @chunk.emit_with_index(node, :JMP, 0)

    # Add to the current loop's list of breaks
    @loop_stack.last[:breaks] << idx
  end

  def compile_continue(node)
    if @loop_stack.empty?
      raise "Compile Error: 'CONTINUE' used outside of a loop."
    end

    # Simple JMP to the start of the current loop
    target = @loop_stack.last[:start]
    @chunk.emit(node, :JMP, target)
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

    @chunk.emit(node, :NEWLIST, "R#{target_reg}")
    node.items.each { |item| with_temp_reg { |r| visit(item, r); @chunk.emit(node, :APPEND, "R#{target_reg}", "R#{r}") } }
  end

  def compile_struct_lit(node, target_reg)
    @chunk.emit(node, :NEWSTRUCT, "R#{target_reg}", node.name)

    def_fields = @struct_defs[node.name] || {} # Non-struct hashmaps have no schema
    final_fields = def_fields.transform_values { |v| v[:default] }.compact.merge(node.fields)

    # TOOD: TEST
    # Check if the Struct definition requires something we don't have yet.
    def_fields.each do |key, info|
      unless final_fields.key?(key)
        raise "Compile Error: Missing required field '#{key}' in instantiation of '%#{node.name}'"
      end
    end

    node.fields.each { |k,v| with_temp_reg { |r| visit(v, r); @chunk.emit(node, :SETFIELD, "R#{target_reg}", k, "R#{r}") } }
  end

  def compile_struct_def(node, target_reg)
    # 1. Store full info (Type + Default AST) for the Compiler to use later
    @struct_defs[node.name] = node.fields

    # 2. Strip defaults for the VM (VM only wants { field => TypeString })
    vm_schema = node.fields.transform_values { |info| info[:type] }

    # 3. Emit the simplified schema to the VM
    @chunk.emit(node, :DEF_STRUCT, node.name, vm_schema)
  end

  def compile_hash_lit(node, target_reg)
    # Treat Hash like a Struct or List (for v0.1, let's use NEWSTRUCT for simplicity)
    @chunk.emit(node, :NEWHASH, "R#{target_reg}")
    node.pairs.each do |k, v|
      with_temp_reg do |r|
        visit(v, r)
        # Assuming keys are strings/identifiers
        # If 'k' is an expression, you'd need to visit it too.
        # For v0.1 simple string keys:
        key_name = k.is_a?(AST::Literal) ? k.value : k.name
        @chunk.emit(node, :SETHASH, "R#{target_reg}", key_name, "R#{r}")
      end
    end
  end

  def compile_identifier(node, target_reg)
    r = current_scope.resolve_reg(node.name)
    raise "Compile Error: Undefined variable '#{node.name}'" unless r
    @chunk.emit(node, :MOVE, "R#{target_reg}", "R#{r}") if target_reg != r # TODO: shouldn't need check
  end

  def compile_method_call(node, target_reg)
    with_temp_reg do |r_obj|
      visit(node.object, r_obj)
      args = compile_args(node.args)
      @chunk.emit(node, :CALL_METHOD, "R#{target_reg}", "R#{r_obj}", node.method, *args)
      @reg_top -= args.size
    end
  end

  def compile_lambda(node, target_reg)
    # 1. Setup Child Compiler (Anonymous name)
    fn_compiler = Compiler.new("lambda", :Any)
    fn_compiler.instance_variable_set(:@scope_depth, @scope_depth + 1)

    # 2. Register Parameters
    node.params.each_with_index do |p, i|
      fn_compiler.current_scope.declare(p[:name], i, p[:type])
    end

    # 3. REUSED LOGIC: Process Captures
    captured_regs = process_captures(node, fn_compiler)

    # 4. Compile Body (Lambdas usually have a single expression body)
    # We assume 'node.body' is an Expression, so we visit it and return it
    fn_compiler.send(:with_temp_reg) do |r|
      fn_compiler.visit(node.body, r)
      fn_compiler.instance_variable_get(:@chunk).emit(node, :RETURN, "R#{r}")
    end

    # 5. REUSED LOGIC: Create the Closure
    fn_chunk = fn_compiler.instance_variable_get(:@chunk)
    emit_closure(node, target_reg, fn_chunk, captured_regs)
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
      @chunk.emit(node, :RETURN, "R#{r}")
    end
  end

  def compile_assert(node, target_reg)
    with_temp_reg do |r_cond|
      # 1. Compile Condition
      visit(node.condition, r_cond)

      # 2. Store Message in Constants
      k_msg = @chunk.add_constant(node.message)

      # 3. Emit ASSERT R_cond, K_msg
      @chunk.emit(node, :ASSERT, "R#{r_cond}", "K#{k_msg}")
    end
  end

  def compile_raise(node, target_reg)
    # This logic compiles the expression into a function call:
    # VAR temp = make_error(message_expr);
    # RETURN temp;

    # 1. Compile the message expression (or NIL literal if no message)
    msg_node = node.message_expr || AST::Literal.new(node.line, :NIL, nil)

    # 2. Build the AST node for the function call: make_error(msg_node)
    error_call_node = AST::FuncCall.new(node.line, "make_error", [msg_node])

    # 3. Compile the function call result (the Error Struct) into a register
    with_temp_reg do |r_err|
      # Compile the call (will emit LOADK, CALL_FUNC, etc.)
      visit(error_call_node, r_err)

      # 4. Emit THROW instruction
      # This is the actual instruction that interrupts the program flow and
      # initiates stack unwinding via the raise_error helper function.
      @chunk.emit(node, :THROW, "R#{r_err}")
    end
  end

  def compile_exit_program(node, target_reg)
    # 1. Compile the status/message into the target register
    visit(node.status, target_reg)

    # 2. Emit the new opcode
    @chunk.emit(node, :EXIT_PROGRAM, "R#{target_reg}")
  end

  def process_captures(node, fn_compiler)
    captured_op_args = []

    # Captures sit immediately after parameters in the new function's registers
    # Params are 0..n, Captures are n+1..m
    capture_reg_offset = node.params.size

    node.captures.each do |cap|
      cap_name = cap[:name]
      cap_type = cap[:type]

      # 1. Find the register in the CURRENT (Outer) scope
      outer_reg = current_scope.resolve_reg(cap_name)
      unless outer_reg
        raise "Compile Error: Cannot capture '#{cap_name}' - undefined in outer scope."
      end

      # 2. Add to the list for the CLOSURE opcode (e.g., "R5")
      captured_op_args << "R#{outer_reg}"

      # 3. Tell the NEW (Inner) compiler where to find this variable
      # It will be automatically loaded into 'capture_reg_offset' by the VM
      fn_compiler.current_scope.declare(cap_name, capture_reg_offset, cap_type)

      capture_reg_offset += 1
    end

    # Update the inner compiler's register counter so it doesn't overwrite captures
    fn_compiler.instance_variable_set(:@reg_top, capture_reg_offset)

    return captured_op_args
  end

  # Helper 3: Handles the function footer (CATCH blocks, Jumps, and Returns)
  def compile_catch_and_return(fn_compiler, node)
    # 1. Emit Jump over the catch block (Success Path)
    # We don't want the main execution to fall through into the error handler.
    success_jump = fn_compiler.chunk.emit_with_index(node, :JMP, 0)

    # 2. Compile Catch Block (If one exists)
    if node.catch_body.any?
      handler_ip = fn_compiler.chunk.current_address

      # A. Allocate register for the error variable 'e'
      r_err = fn_compiler.reg_top
      $logger.debug("Compiling CATCH for #{node.name}: r_err=#{r_err.inspect}")
      fn_compiler.reg_top += 1

      # B. Declare 'e' in the scope so the catch block can see it
      fn_compiler.current_scope.declare(node.catch_var, r_err, :Error)

      # C. Compile the CATCH body statements
      node.catch_body.each { |s| fn_compiler.send(:visit, s) }

      # D. Ensure the catch block returns something (nil) if it finishes
      fn_compiler.chunk.emit(node, :RETURN, "R0")

      # E. Store handler metadata on the Chunk for the VM to find during unwinding
      fn_compiler.chunk.handler_info = {
        handler: handler_ip,
        err_reg: r_err
      }
    end

    # 3. Patch the Success Jump
    # If code ran successfully, jump OVER the catch block to here.
    fn_compiler.chunk.patch(success_jump, fn_compiler.chunk.current_address)

    # 4. Emit Implicit Return
    # If the user's code didn't return, we return R0 (usually nil/last val)
    fn_compiler.instance_variable_get(:@chunk).emit(node, :RETURN, "R0")

    # 5. Name the Chunk (for debugging)
    fn_chunk = fn_compiler.instance_variable_get(:@chunk)
    fn_chunk.name = node.name
  end

  def emit_closure(node, target_reg, fn_chunk, captured_args)
    k_idx = @chunk.add_constant(fn_chunk)
    @chunk.emit(node, :CLOSURE, "R#{target_reg}", "K#{k_idx}", *captured_args)
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
      return current_scope.resolve_type(node.name)

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

