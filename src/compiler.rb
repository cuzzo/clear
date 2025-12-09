require 'logger'
require 'byebug'
require 'set'

require_relative "./ast"
require_relative "./types"
require_relative "./opcodes"
require_relative "./scope"
require_relative "./chunk"
require_relative "./source_error"

# ==========================================
# COMPILER
# ==========================================
class Compiler
  include ErrorHelper

  KNOWN_GLOBALS = %w[argv].to_set

  attr_accessor :chunk, :reg_top
  def initialize(name = "main", return_type = :Any, source_code = "", source_path = Dir.pwd)
    @chunk = Chunk.new(name)
    @scopes = [Scope.new]
    @reg_top = 0
    @scope_depth = 0
    @loop_stack = []
    @struct_defs = {}
    @fn_signatures = {}
    @expected_return = return_type
    @source_code = source_code
    @source_path = source_path
    @imported_files = {}
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

  # Give me the value of THIS expression now (for THIS node), and put it here (target_reg)
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
    when AST::LambdaLit then compile_lambda_lit(node, target_reg);
    when AST::FunctionDef then compile_function_def(node, target_reg);
    when AST::ReturnNode then compile_return_node(node, target_reg);
    when AST::Assert then compile_assert(node, target_reg);
    when AST::Raise then compile_raise(node, target_reg);
    when AST::DieNode then compile_exit_program(node, target_reg);
    when AST::Slice then compile_slice(node, target_reg);
    when AST::Require then compile_require(node, target_reg)
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
    func_name = node.right.name

    # 1. Emit the Call (Delegated to Helper)
    #    This handles PRINT, RVO, and Standard CALL_FUNC
    emit_named_func_call(node, func_name, args_regs, target_reg)

    # 2. Error Enrichment (Snapshot)
    ok_jump = @chunk.emit_with_index(node, :JMP_IF_OK, "R#{target_reg}", 0)
    @chunk.emit(node, :SET_FIELD, "R#{target_reg}", "snapshot", "R#{r_snapshot}")
    @chunk.patch(ok_jump, @chunk.current_address, 2)
  end

  def compile_function_def(node, target_reg)
    # 1. SAVE PREVIOUS STATE
    # We push the current state onto the stack (local vars) so we can restore it later.
    prev_return_type = @current_fn_return_type
    prev_is_stack_rvo = @current_fn_is_stack_rvo

    # 2. SET NEW STATE
    @current_fn_return_type = node.return_type

    # It is RVO if the return type is a Struct or Fixed Array
    @current_fn_is_stack_rvo = is_stack_type?(node.return_type)

    # TODO: why do params & return type need symbolized?
    signature = node.resolved_type
    @fn_signatures[node.name] = signature

    fn_compiler = Compiler.new(node.name, signature[:return_type], @source_code)

    if @current_fn_is_stack_rvo
      # We inject '__ret_ptr' as the first argument (R0).
      # It is a :StackPtr (Pointer to Caller's Stack).
      node.params.unshift({
        name: "__ret_ptr",
        type: :StackPtr,
        mutable: true, # Pointers must be mutable to write to them
        default: nil
      })
    end

    fn_compiler.reg_top = node.params.size

    # TODO: Create a clone
    fn_compiler.instance_variable_set(:@scope_depth, @scope_depth + 1)
    fn_compiler.instance_variable_set(:@struct_defs, @struct_defs)
    fn_compiler.instance_variable_set(:@fn_signatures, @fn_signatures)
    fn_compiler.instance_variable_set(:@current_fn_return_type, @current_fn_return_type)
    fn_compiler.instance_variable_set(:@current_fn_is_stack_rvo, @current_fn_is_stack_rvo)

    # 2. Register Parameters in Child Scope
    node.params.each_with_index do |p, i|
      fn_compiler.current_scope.declare(p[:name], i, p[:type], p[:mutable])

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

    @current_fn_return_type = prev_return_type
    @current_fn_is_stack_rvo = prev_is_stack_rvo

    # Note: The main compiler loop assumes 'visit' handles @reg_top,
    # but since we did it manually, the register is now "used."
    # We return the register index where the function is stored.
    return target_reg
  end

  def compile_func_call(node, target_reg)
    # 1. Handle Native Calls (Special Argument Parsing)
    if node.name == "native_call"
      return compile_native_call(node, target_reg)
    end

    # 2. Resolve Local Register (Closure Call)
    local_reg = nil
    if node.name.is_a?(String)
      local_reg = current_scope.resolve_reg(node.name)
    end

    # 3. Standard Argument Compilation
    #    (We pass empty signature/local_reg for now, as validation
    #     is handled mostly at runtime or separate pass)
    args_regs = compile_args(node.args)

    if local_reg
      # --- CLOSURE CALL ---
      # Closures don't support RVO in this version (dynamic return type)
      operand = "R#{local_reg}"
      @chunk.emit(node, :CALL_CLOSURE, "R#{target_reg}", operand, node.args.size, *args_regs)
    elsif node.name.is_a?(String)
      # --- NAMED FUNCTION CALL (Uses Helper) ---
      emit_named_func_call(node, node.name, args_regs, target_reg)
    else
      # --- EXPRESSION CALL ---
      # e.g. get_callback()(args)
      with_temp_reg do |r_func|
        visit(node.name, r_func)
        @chunk.emit(node, :CALL_CLOSURE, "R#{target_reg}", "R#{r_func}", node.args.size, *args_regs)
      end
    end
    @reg_top -= args_regs.size
  end

  def emit_named_func_call(node, func_name, args_regs, target_reg)
    # 1. Handle Intrinsics
    if func_name == "print"
      @chunk.emit(node, :PRINT, *args_regs)
      return
    elsif func_name == "native_call"
      # native_call requires special parsing in compile_func_call,
      # so if we hit it here (e.g. via pipe), it's an error.
      error!(node, "Cannot pipe to native_call directly.")
    end

    if !@fn_signatures.key?(func_name)
      error!(node, :MISSING_FUNCTION, func_name)
    end

    # 2. Look up Signature for RVO
    return_type = :Any
    if @fn_signatures.key?(func_name)
      return_type = @fn_signatures[func_name][:return_type]
    end

    # 3. RVO PATH (Hidden Pointer Injection)
    #    If the function returns a Stack Type, we must allocate space
    #    in the Caller's frame and pass the pointer as the first arg.
    if is_stack_type?(return_type)
       with_temp_reg do |r_ptr|
         # A. Allocate Stack Space
         size = get_type_slot_size(return_type)
         @chunk.emit(node, :ALLOCA, "R#{r_ptr}", return_type.to_s)

         # B. Inject Pointer as Arg 0
         args_regs.unshift("R#{r_ptr}")

         # C. Emit Call (Result is Void/Nil)
         with_temp_reg do |r_void|
            @chunk.emit(node, :CALL_FUNC, "R#{r_void}", func_name, args_regs.size, *args_regs)
         end

         # D. The "Real" Result is the Pointer we allocated
         @chunk.emit(node, :MOVE, "R#{target_reg}", "R#{r_ptr}")
       end

    # 4. STANDARD PATH
    else
       @chunk.emit(node, :CALL_FUNC, "R#{target_reg}", func_name, args_regs.size, *args_regs)
    end
  end

  def compile_slice(node, target_reg)
    with_temp_reg do |r_owner|
      visit(node.target, r_owner)
      with_temp_reg do |r_start|
        visit(node.start, r_start)
        with_temp_reg do |r_end|
          visit(node.end, r_end)
          @chunk.emit(node, :NEW_SLICE, "R#{target_reg}", "R#{r_owner}", "R#{r_start}", "R#{r_end}")
        end
      end
    end
  end

  def compile_print(node)
    args = compile_args(node.args)
    @chunk.emit(node, :PRINT, *args)
    @reg_top -= args.size
  end

  def compile_native_call(node, target_reg)
    if node.args.size < 2
      error!(node, :NATIVE_CALL_ERROR)
    end

    class_node, method_node = node.args[0], node.args[1]

    unless class_node.is_a?(AST::Literal) && class_node.type == :STRING
      error!(class_node, "native_call arg 1 must be a static String (Class Name)")
    end

    # Compile the ACTUAL arguments (skipping Class/Method strings)
    # We slice the args array, compile the rest, and get their registers
    real_args_regs = compile_args(node.args[2..-1])

    @chunk.emit(node, :CALL_NATIVE, "R#{target_reg}", class_node.value, method_node.value, *real_args_regs)
    @reg_top -= real_args_regs.size
  end

  def compile_args(args, signature_params = [], local_reg = nil)
    args.each_with_index.map do |arg, arg_idx|
      r = @reg_top
      @reg_top += 1
      visit(arg, r)
      #implicit_deref_coerce_arg(arg, r, signature_params[arg_idx], local_reg)
      "R#{r}"
    end
  end

  def is_stack_candidate?(node)
    node.is_a?(AST::ListLit) ||
      node.is_a?(AST::StructLit) ||
      (node.is_a?(AST::Literal) && node.type == :STRING)
  end

  def compile_var_declare(node, target_reg)
    r = @reg_top;
    @reg_top += 1

    storage = node.value.storage rescue :stack
    final_type = infer_type(node.value) #node.resolved_type
    known_size = get_known_size(node)

    if storage == :stack && is_stack_candidate?(node.value)
      compile_stack_literal(node.value, final_type, r)
    else
      visit(node.value, r)
    end

    if @scope_depth == 0
      @chunk.emit(node, :DEF_GLOBAL, node.name, "R#{r}")
    end

    if storage == :heap && AST::PRIMITIVE_TYPES.include?(final_type)
      error!(node, :HEAP_PRIMITIVE, node.name)
    end

    coerce_type(node, r)
    handle_view(node) # TODO: Move to the annotator

    current_scope.declare(node.name, r, final_type, node.mutable, false, known_size, storage)
    return r
  end

  # TODO: To work with strings, they follow the list-lit path
  # TODO: Stack strings are Int32! %b"" is a Byte string
  def compile_stack_literal(node, final_type, target_reg)
    @chunk.emit(node, :ALLOCA, "R#{target_reg}", final_type.to_s)

    # B. INITIALIZATION (The "Fill" Step)
    if node.is_a?(AST::ListLit) || (node.is_a?(AST::Literal) && node.type == :STRING)
      items = node.is_a?(AST::ListLit) ?
        node.items :
        node.value.bytes.map { |b| AST::Literal.new(node.token, :BYTE, b, :stack) } # TODO: SLOW!

      # Loop by Index
      items.each_with_index do |item, idx|
        with_temp_reg do |r_val|
          visit(item, r_val)
          # Optimization: If item is a constant, we could emit specialized opcode,
          # but generic SET_INDEX works fine.
          with_temp_reg do |r_idx|
             k = @chunk.add_constant(idx)
             @chunk.emit(node, :LOADK, "R#{r_idx}", "K#{k}")
             @chunk.emit(node, :SET_INDEX, "R#{target_reg}", "R#{r_idx}", "R#{r_val}")
          end
        end
      end

    elsif node.is_a?(AST::StructLit)
      # Loop by Field
      # 1. Merge Defaults (Crucial for Structs!)
      def_fields = @struct_defs[node.name] || {}

      # We iterate over the DEFINITION order to ensure we fill gaps with defaults
      def_fields.each do |field_name, info|
        val_node = node.fields[field_name] || info[:default]

        if val_node.nil?
          error!(node, :MISSING_FIELD_VALUE, field_name, node.name)
        end

        with_temp_reg do |r_val|
           visit(val_node, r_val)
           type = infer_type(node)
           field_idx = resolve_struct_field_index(node, type, field_name)
           @chunk.emit(node, :SET_FIELD, "R#{target_reg}", "R#{r_val}", field_idx)
        end
      end
    end
  end

  # TODO: Do I need to raise an error here?
  def handle_view(node)
    return if !node.value.is_a?(AST::GetIndex) && !node.value.is_a?(AST::Slice)
    source_node = node.value.target

    return if !source_node.is_a?(AST::Identifier)
    current_scope.register_dependency(source_node.name, node.name)
  end

  def get_known_size(node)
    if node.value.is_a?(AST::ListLit)
      # 1. Literal: We count the items
      return node.value.items.size

    elsif node.value.is_a?(AST::Identifier)
      # 2. Variable: We ask the scope
      return current_scope.get_size(node.value.name)
    end

    return nil
  end

  def handle_deep_freeze(node, r)
    return if node.mutable # Nothing to freeze here
    return if !node.value.is_a?(AST::ListLit) && !node.value.is_a?(AST::StructLit) # Still nothing to freeze
    @chunk.emit(node, :FREEZE, "R#{r}")
  end

  def coerce_type(node, r)
    new_type = node.value.coerced_type
    if new_type && new_type != node.value.resolved_type
      @chunk.emit(node, :CAST, "R#{r}", new_type.to_s)
    end
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
      when AST::GetField then compile_set_field(l_value, val_reg)
      when AST::GetIndex then compile_set_index(l_value, val_reg)
      when AST::Identifier then compile_set_var(l_value, val_reg)
      # Legacy support for raw strings
      when String then compile_set_var(l_value, val_reg)
      else
        error!(node, "Invalid assignment target: #{target.class}")
      end

      # 3. If the assignment is used as an expression, return the value
      if result_reg
        @chunk.emit(node, :MOVE, "R#{result_reg}", "R#{val_reg}")
      end
    end
  end

  def compile_set_var(node, val_reg)
    var_name = node.is_a?(AST::Identifier) ? node.name : node

    # 2. Resolve the Register for this variable
    target_reg = current_scope.resolve_reg(var_name)

    # 3. Handle Local vs Global
    if target_reg
      # It's a Local Variable (in a Register)
      @chunk.emit(node, :MOVE, "R#{target_reg}", "R#{val_reg}")

    else
      # 4. Error if not found
      error!(node, :SET_UNDECLARED_VAR, var_name)
    end
  end

  def compile_set_field(node, val_reg)
    with_temp_reg do |obj_reg|
      visit(node.target, obj_reg)
      type = infer_type(node.target)
      if type == :HashMap
        @chunk.emit(node, :SET_HASH, "R#{obj_reg}", "R#{val_reg}", node.field)
      else
        field_idx = resolve_struct_field_index(node, type, node.field)
        @chunk.emit(node, :SET_FIELD, "R#{obj_reg}", "R#{val_reg}", field_idx)
      end
    end
  end

  def compile_set_index(node, val_reg)
    # node is the AST::GetIndex(target, index)
    with_temp_reg do |obj_reg|
      visit(node.target, obj_reg) # Compile array/hash

      with_temp_reg do |key_reg|
        visit(node.index, key_reg) # Compile the index/key

        # Emit: SET_INDEX R_obj, R_key, R_val
        @chunk.emit(node, :SET_INDEX, "R#{obj_reg}", "R#{key_reg}", "R#{val_reg}")
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
        if node.op == :ADD then compile_add(node, target_reg, r1, r2)
        else @chunk.emit(node, node.op, "R#{target_reg}", "R#{r1}", "R#{r2}") end
      end
    end
  end

  def compile_add(node, target_reg, lhs, rhs)
    opcode = compile_add_autocast_and_get_opcode(node, lhs, rhs)
    @chunk.emit(node, opcode, "R#{target_reg}", "R#{lhs}", "R#{rhs}")
  end

  def compile_add_autocast_and_get_opcode(node, lhs, rhs)
    type_left = infer_type(node.left)
    type_right = infer_type(node.right)

    if type_left == :Int64 && type_right == :Int64
      return :ADD_INT64
    elsif type_left == :Number
      if type_right == :Number
        return :ADD_NAN
      elsif type_right == :Int64
        # TODO: AUTOCAST, RETURN
      end
    elsif type_right == :Number
      if type_left == :Number
        return :ADD_NAN
      elsif type_left == :Int64
        # TODO: AUTOCAST, RETURN
      end
    end

    type_left_str = is_string_type?(type_left)
    type_right_str = is_string_type?(type_right)

    if type_left_str && type_right_str
      return :CONCAT_STR
    elsif type_left_str && is_safe_to_autocast_str?(type_right)
      @chunk.emit(node, :CAST, "R#{rhs}", "String")
      return :CONCAT_STR
    elsif is_safe_to_autocast_str?(type_left) && type_right_str
      @chunk.emit(node, :CAST, "R#{lhs}", "String")
      return :CONCAT_STR

    # Since String[] is the type for a String array,
    # This *MUST* come after the string comparison
    elsif type_left.to_s.include?("[") && type_right.to_s.include?("[")
      return :CONCAT_ARR
    end

    error!(node, "Type Error: Cannot add type: #{type_left} and #{type_right}")
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
          # TODO: ERROR FIELD
          @chunk.emit(node, :SET_FIELD, "R#{target_reg}", "context", "R#{r_ctx}")
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
      type = infer_type(node.target)
      if type == :HashMap
        @chunk.emit(node, :GET_HASH, "R#{target_reg}", "R#{r_target}", node.field)
      else
        field_idx = resolve_struct_field_index(node, type, node.field)
        @chunk.emit(node, :GET_FIELD, "R#{target_reg}", "R#{r_target}", field_idx)
      end
    end
  end

  def compile_cast(node, target_reg)
    visit(node.value, target_reg)
    @chunk.emit(node, :CAST, "R#{target_reg}", node.target)
  end

  def compile_literal(node, target_reg)
    val = node.value
    if node.type == :BYTE
      val = node.storage == :heap ? Value.box_byte(val) : val
    elsif node.type == :STRING
      # Register as Static so it survives Arena.reset! and is found by ID
      val = FluxString.new(val, register: :static)
    elsif node.type == :INT64
      val = FluxInt64.new(node.value, register: :static)
    end
    k = @chunk.add_constant(val)
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
    # Emit a JMP to 0 (Placeholder).
    # We save this index into the current loop context to patch later.
    idx = @chunk.emit_with_index(node, :JMP, 0)

    # Add to the current loop's list of breaks
    @loop_stack.last[:breaks] << idx
  end

  def compile_continue(node)
    # Simple JMP to the start of the current loop
    target = @loop_stack.last[:start]
    @chunk.emit(node, :JMP, target)
  end

  def compile_list_lit(node, target_reg)
    type_name = infer_type(node)
    fixed_size = node.storage == :stack ? get_type_slot_size(type_name) : nil
    @chunk.emit(node, :NEW_LIST, "R#{target_reg}", fixed_size)

    node.items.each_with_index do |item, index|
      with_temp_reg do |r| visit(item, r)
        if node.storage == :stack
          with_temp_reg do |key_reg|
            @chunk.emit(node, :LOADK, "R#{key_reg}", index) # TODO: This requires a literal
            @chunk.emit(node, :SET_INDEX, "R#{target_reg}", "R#{key_reg}", "R#{r}")
          end
        else
          @chunk.emit(node, :APPEND, "R#{target_reg}", "R#{r}")
        end
      end
    end
  end

  def compile_struct_lit(node, target_reg)
    @chunk.emit(node, :NEW_STRUCT, "R#{target_reg}", node.name)

    def_fields = @struct_defs[node.name] || {} # Non-struct hashmaps have no schema
    final_fields = def_fields.transform_values { |v| v[:default] }.compact.merge(node.fields)

    # TOOD: TEST
    # Check if the Struct definition requires something we don't have yet.
    def_fields.each do |key, info|
      unless final_fields.key?(key)
        error!(node, :MISSING_REQUIRED_STRUCT_FIELD, key, node.name)
      end
    end

    type = infer_type(node)
    node.fields.each do |field, val_node|
      field_idx = resolve_struct_field_index(node, type, field)
      with_temp_reg do |r|
        visit(val_node, r)
        @chunk.emit(node, :SET_FIELD, "R#{target_reg}", "R#{r}", field_idx)
      end
    end
  end

  def compile_struct_def(node, target_reg)
    # 1. Store full info (Type + Default AST) for the Compiler to use later
    @struct_defs[node.name] = node.fields

    # 2. Strip defaults for the VM (VM only wants { field => TypeString })
    vm_schema = node.fields
      .transform_values { |info| info[:type] }
      .transform_keys(&:to_sym)

    # 3. Emit the simplified schema to the VM
    @chunk.emit(node, :DEF_STRUCT, node.name, vm_schema)
  end

  def compile_hash_lit(node, target_reg)
    # Treat Hash like a Struct or List (for v0.1, let's use NEW_STRUCT for simplicity)
    @chunk.emit(node, :NEW_HASH, "R#{target_reg}")
    node.pairs.each do |k, v|
      with_temp_reg do |val_reg|
        visit(v, val_reg)
        # Assuming keys are strings/identifiers
        # If 'k' is an expression, you'd need to visit it too.
        # For v0.1 simple string keys:
        key_name = k.is_a?(AST::Literal) ? k.value : k.name
        @chunk.emit(node, :SET_HASH, "R#{target_reg}", "R#{val_reg}", key_name)
      end
    end
  end

  def compile_identifier(node, target_reg)
    r = current_scope.resolve_reg(node.name)
    if r
      @chunk.emit(node, :MOVE, "R#{target_reg}", "R#{r}") if target_reg != r # TODO: shouldn't need check
    elsif KNOWN_GLOBALS.include?(node.name)
      @chunk.emit(node, :GET_GLOBAL, "R#{target_reg}", node.name)
    else
      error!(node, :UNDEFINED_VAR, node.name) unless r
    end
  end

  def compile_method_call(node, target_reg)
    with_temp_reg do |r_obj|
      visit(node.object, r_obj)
      args = compile_args(node.args)
      @chunk.emit(node, :CALL_METHOD, "R#{target_reg}", "R#{r_obj}", node.method, *args)
      @reg_top -= args.size
    end
  end

  def compile_lambda_lit(node, target_reg)
    # 1. Setup Child Compiler (Anonymous name)
    fn_compiler = Compiler.new("lambda", :Any, @source_code)
    # TODO: What about other instance variables???
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

    if @current_fn_is_stack_rvo
      byebug
      return compile_stack_rvo_return_node(node, target_reg)
    end

    if node.value.is_a?(AST::FuncCall)
      return compile_tail_call(node.value)
    end

    # 2. We need a register to hold the return value
    with_temp_reg do |r|
      # 3. Compile the expression into that register
      visit(node.value, r)
      # 4. Emit the instruction
      @chunk.emit(node, :RETURN, "R#{r}")
    end
  end

  def compile_tail_call(node)
    # 1. Compile Arguments into temporary registers (Just like a normal call)
    # Note: We pass 'nil' for local_reg because we haven't implemented TCO for closures yet
    args_regs = compile_args(node.args, [], nil)

    # 2. Emit the specialized Opcode
    # Note: We do NOT need a target_reg. The return value of the *next* function
    # becomes the return value of *this* function automatically.
    if node.name.is_a?(String)
      @chunk.emit(node, :TAIL_CALL, node.name, args_regs.size, *args_regs)
    else
      # TODO: Handle Closure Tail Calls (slightly harder, skip for now)
    end

    # We do NOT emit :RETURN here. The TAIL_CALL opcode handles the control flow.
    @reg_top -= args_regs.size
  end

  # TODO: This is copy on return, not SRVO
  def compile_stack_rvo_return_node(node, target_reg)
    # The hidden return pointer is ALWAYS in Register 0 (if we injected it first)
    r_ret_ptr = 0

    # OPTIMIZATION: Anonymous RVO (Direct Construction)
    # Only if the literal is meant for the stack!
    # (Check if it has storage == :stack)
    is_stack_literal = (node.value.is_a?(AST::StructLit) || node.value.is_a?(AST::ListLit)) &&
                       node.value.storage == :stack

    if is_stack_literal
      # Call a specialized method that DOES NOT allocate, but fills R0
      compile_literal_into_ptr(node.value, r_ret_ptr)

    # Named Variable
    elsif node.value.is_a?(AST::Identifier)
      src_reg = current_scope.resolve_reg(node.value.name)
      error!(node, :UNDEFINED_VAR, node.value.name) unless src_reg

      size = get_type_slot_size(@current_fn_return_type)
      @chunk.emit(node, :MEM_COPY, "R#{r_ret_ptr}", "R#{src_reg}", size)

    # CASE 3: Fallback (Complex Expression OR Heap Literal)
    else
      with_temp_reg do |r_src|
        visit(node.value, r_src)
        # We must copy from local 'x' to 'caller slot'
        size = get_type_slot_size(@current_fn_return_type)
        @chunk.emit(node, :MEM_COPY, "R#{r_ret_ptr}", "R#{r_src}", size)
      end
    end

    # Return Void (The data is already in the caller's frame)
    k_nil = @chunk.add_constant(nil)
    @chunk.emit(node, :RETURN, "R0")
  end

  def compile_literal_into_ptr(node, ptr_reg)
    if node.is_a?(AST::StructLit)
      # 1. Merge Defaults
      def_fields = @struct_defs[node.name] || {}

      # Iterate over the DEFINITION order to ensure we fill the memory linearly
      # (Important for binary compatibility)
      def_fields.each do |field_name, info|
        val_node = node.fields[field_name] || info[:default]

        error!(node, :MISSING_REQUIRED_STRUCT_FIELD, field_name, node.name) unless val_node

        # 2. Compile the Value (e.g., "10" or "x + y")
        with_temp_reg do |r_val|
          visit(val_node, r_val)

          # 3. DIRECT WRITE to Caller's Stack
          # ptr_reg holds the __ret_ptr.
          # The VM will resolve this pointer and write to the Caller's blob.

          type = infer_type(node)
          field_idx = resolve_struct_field_index(node, type, field_name)
          @chunk.emit(node, :SET_FIELD, "R#{ptr_reg}", "R#{r_val}", field_idx)
        end
      end

    elsif node.is_a?(AST::ListLit)
      # Fixed Array Logic
      node.items.each_with_index do |item, idx|
        with_temp_reg do |r_val|
          visit(item, r_val)

          # We need a register for the index
          with_temp_reg do |r_idx|
            k_idx = @chunk.add_constant(idx)
            @chunk.emit(node, :LOADK, "R#{r_idx}", "K#{k_idx}")

            # DIRECT WRITE
            @chunk.emit(node, :SET_INDEX, "R#{ptr_reg}", "R#{r_idx}", "R#{r_val}")
          end
        end
      end
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
    msg_node = node.message_expr || AST::Literal.new(node.token, :NIL, nil)

    # 2. Build the AST node for the function call: make_error(msg_node)
    error_call_node = AST::FuncCall.new(node.token, "make_error", [msg_node])

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
        error!(node, :ILLEGAL_UPVALUE, cap_name)
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

  def compile_require(node, target_reg)
    # 1. Resolve Path (Relative to current file)
    current_dir = File.dirname(@source_path)

    full_path = File.expand_path(node.path, current_dir)

    unless File.exist?(full_path)
      error!(node, "Import Error: File not found: #{full_path}")
    end

    # 2. Read Source
    code = File.read(full_path)

    # 3. Compile the File (Recursively!)
    # We create a new Compiler for the imported file.
    # It gets its own Scope, Registers, etc.
    sub_lex = Lexer.new(code)
    sub_parser = Parser.new(sub_lex.tokenize, code)
    sub_ast = sub_parser.parse

    # Note: We pass full_path so it can handle its own relative imports
    sub_compiler = Compiler.new("module:#{File.basename(full_path)}", :Any, code, full_path)
    module_chunk = sub_compiler.compile(sub_ast)

    # 4. Embed the Module as a Constant
    # We treat the entire file as a Function that we are about to call.
    k_idx = @chunk.add_constant(module_chunk)

    # 5. Emit Instructions to Execute the Module
    # LOADK R_temp, <ModuleChunk>
    # NEW_CLOSURE R_closure, R_temp
    # CALL_CLOSURE R_target, R_closure


    # Wrap chunk in closure (0 upvalues because imports are isolated)
    with_temp_reg do |r_closure|
      @chunk.emit(node, :NEW_CLOSURE, "R#{r_closure}", "R#{k_idx}") # No captures
      @chunk.emit(node, :CALL_CLOSURE, "R#{target_reg}", "R#{r_closure}", 0)
    end
  end

  def emit_closure(node, target_reg, fn_chunk, captured_args)
    k_idx = @chunk.add_constant(fn_chunk)
    @chunk.emit(node, :NEW_CLOSURE, "R#{target_reg}", "K#{k_idx}", *captured_args)
  end

private
  def infer_type(node)
    node.resolved_type
  end

  def infer_binary_op_add_type(node)
    t_left = infer_type(node.left)
    t_right = infer_type(node.right)

    # 1. String Propagation (Fixes your bug)
    # If we are adding strings, the result is a String
    return :String if is_string_type?(t_left) || is_string_type?(t_right)

    # 2. Int64 Propagation
    return :Int64 if t_left == :INT64 && t_right == :INT64

    # 3. Array Propagation
    return t_left if t_left.to_s.include?("[")

    return :Number
  end

  def is_string_type?(type)
    t = type.to_s
    return true if t == "String" || t == "STRING"
    # Matches "String[]" (Heap String) and "Byte[...]" (Stack String)
    return true if t.start_with?("String") || t.start_with?("Byte")
    false
  end
  # --- OLD IFT ---

  def is_stack_type?(type_sym)
    str = type_sym.to_s
    # It's a stack type if it's a known Struct or a Fixed Array
    return true if @struct_defs.key?(str)
    return true if str.include?("[") && !str.include?("[]") # Fixed size like [3]
    false
  end

  # Returns size in slots
  def get_type_slot_size(type_name)
    type_str = type_name.to_s

    # CASE A: Primitive / Reference (1 Slot = 8 Bytes)
    # Number, Byte, Bool, Any, StackPtr, or any Heap Object (String, List)
    # These all take up exactly 1 register/stack slot (64-bit).
    if AST::PRIMITIVE_TYPES.include?(type_name) ||
       type_name == :Any ||
       type_name == :StackPtr ||
       type_name == :String || # Strings are heap pointers
       type_name.to_s.start_with?("List") # Heap Lists are pointers
      return 1
    end

    # CASE B: Fixed Array "Type[N]"
    # Recursive Size = N * SizeOf(Type)
    if type_str.include?("[")
      match = type_str.match(/^(\w+)\[(\d+)\]$/)
      if match
        base_type = match[1].to_sym
        count = match[2].to_i

        base_size = get_type_slot_size(base_type)
        return count * base_size
      end

      # If it is "Type[]" (Dynamic) or "Type[*]" (Inferred but allocated on Heap),
      # it is just a Pointer (8 bytes).
      return 1
    end

    # CASE C: Struct
    # Size = Sum(SizeOf(Fields))
    if @struct_defs.key?(type_str)
      schema = @struct_defs[type_str] # This is the hash of fields { x: {type: ...}, ...}

      total_bytes = 0
      schema.each do |field_name, field_info|
        # Recursively calculate size of each field
        total_bytes += get_type_slot_size(field_info[:type])
      end
      return total_bytes
    end

    # Fallback / Error
    # If we don't know what it is, assume it's a pointer/value fitting in 1 register.
    # Or raise an error if you want strictness.
    return 1
  end

  # TODO: Symbolize struct names
  def resolve_struct_field_index(node, type_name, field_name)
    schema = @struct_defs[type_name.to_s]
    if schema.nil?
      error!(node, :ILLEGAL_FIELD_LOOKUP, field_name, type_name)
    end

    # 2. Find the index of the field in the keys
    # IMPORTANT: Ruby hashes preserve insertion order, which matches your memory layout
    index = schema.keys.index(field_name)

    if index.nil?
      error!(node, :STRUCT_FIELD_UNRESOLVABLE, field_name, type_name)
    end

    index
  end

  def is_safe_to_autocast_str?(type)
    [:Number, :INT64, :Bool, :Byte].include?(type)
  end
end

