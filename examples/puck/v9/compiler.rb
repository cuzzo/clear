require_relative 'parser'
require 'set'

# An instruction / command for the VM to run
ByteCode = Struct.new(:op, :arg)

class Compiler
  COMPARE_OPS = {
    :"="  => :==,
    :"#"  => :!=,
    :"<"  => :<,
    :"<=" => :<=,
    :">"  => :>,
    :">=" => :>=
  }.freeze

  # Calls to these names are recognised as direct SYSCALL invocations rather
  # than as regular procedure calls — `OPEN_READ(path)` compiles to
  # `compile path; SYSCALL 3` without any procedure-table lookup. core.puck
  # wraps each of these in a lowercase procedure for stylistic consistency.
  BUILTIN_SYSCALLS = {
    "OPEN_READ"      => 3,   # path -> handle
    "READ_LINE_FROM" => 4,   # handle -> string
    "CLOSE_FILE"     => 5,   # handle -> (none)
    "OPEN_WRITE"     => 7,   # path -> handle
    "WRITE_LINE"     => 8,   # handle, string -> (none)
    "HALT"           => 9    # exit code -> (program exits)
  }.freeze

  # A Scope tracks (a) the variable -> slot mapping for one procedure body
  # and (b) which of those slots hold a heap-backed REF cell instead of a
  # plain value. Two reasons a slot becomes boxed:
  #   1. It's declared `VAR` in this procedure's parameter list (the caller
  #      passed a ref into that slot already).
  #   2. Some procedure call in this body passes this name as a VAR arg, so
  #      the value has to live on the heap for the callee to mutate it.
  Scope = Struct.new(:mem, :boxed_slots, :param_slots) do
    def slot_for(name)
      mem[name] ||= mem.length
    end

    def boxed?(name)
      mem.key?(name) && boxed_slots.include?(mem[name])
    end

    def box_name!(name)
      boxed_slots << slot_for(name)
    end
  end

  def compile(ast)
    procedures = {}
    # Pre-pass 1: register every procedure's signature (params + var_params)
    # so any other body's VAR-pass analysis can look up the callee. Bodies
    # are filled in by the normal compile pass below.
    register_signatures(ast, procedures)
    scope = build_scope([], [], ast, procedures)
    codes = []
    emit_local_box_init(scope, codes)
    compile_statements(ast, scope, procedures, [], codes)
    { codes: codes, procedures: procedures }
  end

  def register_signatures(nodes, procedures)
    nodes.each do |node|
      case node[:type]
      when :Module
        register_signatures(node.val[:declarations] || [], procedures)
        register_signatures(node.val[:body] || [], procedures)
      when :Block
        register_signatures(node.val, procedures)
      when :Procedure
        procedures[node.var] = {
          params: node.val[:params],
          var_params: node.val[:var_params] || [],
          codes: nil  # filled in during compile_statements
        }
      end
    end
  end

  # Build a fresh scope. Params come first (and may be boxed if VAR);
  # boxed locals are discovered by pre-walking the body for VAR call args.
  def build_scope(params, var_params, body, procedures)
    scope = Scope.new({}, Set.new, Set.new)
    params.each do |name|
      slot = scope.slot_for(name)
      scope.param_slots << slot
      scope.box_name!(name) if var_params.include?(name)
    end
    collect_var_passed_names(body, procedures).each { |n| scope.box_name!(n) }
    scope
  end

  # At procedure entry, every boxed local (not param) gets a heap cell
  # allocated with initial value 0. Params don't need this; their slot
  # already holds a ref the caller passed.
  def emit_local_box_init(scope, codes)
    scope.boxed_slots.sort.each do |slot|
      next if scope.param_slots.include?(slot)
      codes << ByteCode.new(:PUSH, 0)
      codes << ByteCode.new(:ALLOC_CELL)
      codes << ByteCode.new(:STORE, slot)
    end
  end

  # Pre-pass: find every variable name that is passed as a VAR argument to
  # some procedure call in this body. Those names need to be heap-boxed in
  # this scope so the callee can mutate them.
  def collect_var_passed_names(nodes, procedures)
    names = Set.new
    walk_for_var_passes(nodes, names, procedures)
    names
  end

  def walk_for_var_passes(nodes, names, procedures)
    nodes.each do |node|
      case node.type
      when :Module
        # The Module wrapper isn't a scope of its own; its body shares the
        # caller's scope. Recurse into declarations (just to be safe; they
        # are usually only Procedures, which themselves are skipped) and
        # the executable body.
        walk_for_var_passes(node.val[:declarations] || [], names, procedures)
        walk_for_var_passes(node.val[:body] || [], names, procedures)
      when :Procedure
        # Don't recurse — inner procedures have their own scope.
      when :Block
        # Transparent wrapper (e.g. CASE lowering) — descend into its inner
        # statements; they live in the surrounding scope.
        walk_for_var_passes(node.val, names, procedures)
      when :CallStatement
        check_var_args(node.var, node.val, names, procedures)
        node.val.each { |arg| walk_expr_for_var_passes(arg, names, procedures) }
      when :Assignment, :Return
        walk_expr_for_var_passes(node.val, names, procedures)
      when :Syscall
        # New SYSCALL shape carries args as expressions; walk each.
        (node.val[:args] || []).each { |a| walk_expr_for_var_passes(a, names, procedures) }
      when :ArraySet
        walk_expr_for_var_passes(node.val[:index], names, procedures)
        walk_expr_for_var_passes(node.val[:val], names, procedures)
      when :If
        walk_expr_for_var_passes(node.val[:condition], names, procedures)
        walk_for_var_passes(node.val[:body], names, procedures)
        walk_for_var_passes(node.val[:else_body] || [], names, procedures)
      when :Loop
        body = node.val.is_a?(Array) ? node.val : (node.val[:body] || [])
        walk_for_var_passes(body, names, procedures)
      end
    end
  end

  def walk_expr_for_var_passes(expr, names, procedures)
    return unless expr.respond_to?(:type)
    case expr.type
    when :Call
      check_var_args(expr.name, expr.args, names, procedures)
      expr.args.each { |a| walk_expr_for_var_passes(a, names, procedures) }
    when :Math, :Compare
      walk_expr_for_var_passes(expr.left, names, procedures)
      walk_expr_for_var_passes(expr.right, names, procedures)
    when :ArrayAlloc
      walk_expr_for_var_passes(expr.value, names, procedures)
    when :ArrayGet
      walk_expr_for_var_passes(expr.value, names, procedures)
    end
  end

  # For each VAR-bound parameter on the called procedure, the matching arg
  # at the call site must be a bare Variable (we can't pass an expression
  # like `x + 1` by reference). Mark that name as boxed in the caller.
  def check_var_args(name, args, names, procedures)
    proc = procedures[name]
    return unless proc && proc[:var_params]
    proc[:var_params].each do |vp_name|
      idx = proc[:params].index(vp_name)
      arg = args[idx]
      next unless arg.respond_to?(:type) && arg.type == :Variable
      names << arg.name
    end
  end

  def compile_statements(ast, scope, procedures, loop_exits, codes)
    ast.each do |node|
      if node[:type] == :Module
        compile_statements(node.val[:declarations], scope, procedures, loop_exits, codes)
        compile_statements(node.val[:body], scope, procedures, loop_exits, codes)

      elsif node[:type] == :Block
        # A transparent wrapper produced by parser lowering (e.g. CASE).
        # Compile its inner statements in the current scope.
        compile_statements(node.val, scope, procedures, loop_exits, codes)

      elsif node[:type] == :Procedure
        proc_scope = build_scope(node.val[:params], node.val[:var_params] || [], node.val[:body], procedures)
        proc_codes = []
        emit_local_box_init(proc_scope, proc_codes)
        # Procedure signature was pre-registered in compile(); fill in the
        # compiled body now.
        procedures[node.var][:codes] = compile_statements(node.val[:body], proc_scope, procedures, [], proc_codes)

      elsif node[:type] == :Assignment
        compile_expression(node.val, codes, scope, procedures)
        # The slot has to exist already if it's boxed (we pre-allocated at
        # scope entry). For unboxed names, this is also the FIRST assignment
        # site — slot_for creates the slot on demand.
        slot = scope.slot_for(node.var)
        codes << ByteCode.new(scope.boxed?(node.var) ? :STORE_REF : :STORE, slot)

      elsif node[:type] == :CallStatement
        emit_call(node.var, node.val, scope, procedures, codes)

      elsif node[:type] == :ArraySet
        emit_load_var(node.var, scope, codes)
        compile_expression(node.val[:index], codes, scope, procedures)
        compile_expression(node.val[:val], codes, scope, procedures)
        codes << ByteCode.new(:ARRAY_SET)

      elsif node[:type] == :If
        compile_expression(node.val[:condition], codes, scope, procedures)
        jump_to_else = codes.length
        codes << ByteCode.new(:JUMP_IF_FALSE)
        compile_statements(node.val[:body], scope, procedures, loop_exits, codes)
        if node.val[:else_body]&.any?
          jump_after_else = codes.length
          codes << ByteCode.new(:JUMP)
          codes[jump_to_else].arg = codes.length
          compile_statements(node.val[:else_body], scope, procedures, loop_exits, codes)
          codes[jump_after_else].arg = codes.length
        else
          codes[jump_to_else].arg = codes.length
        end

      elsif node[:type] == :Loop
        loop_start = codes.length
        exits = []
        compile_statements(node.val, scope, procedures, loop_exits + [exits], codes)
        codes << ByteCode.new(:JUMP, loop_start)
        exits.each { |exit| codes[exit].arg = codes.length }

      elsif node[:type] == :Exit
        raise "EXIT outside LOOP" if loop_exits.empty?
        loop_exits.last << codes.length
        codes << ByteCode.new(:JUMP)

      elsif node[:type] == :Return
        compile_expression(node.val, codes, scope, procedures)
        codes << ByteCode.new(:RETURN)

      elsif node[:type] == :Syscall
        # New shape: { id:, args: [expressions] }. Push each arg, then SYSCALL.
        (node.val[:args] || []).each { |a| compile_expression(a, codes, scope, procedures) }
        codes << ByteCode.new(:SYSCALL, node.val[:id])
      end
    end

    codes
  end

  # Push the value of a variable onto the stack, dereferencing if it's
  # boxed in this scope.
  def emit_load_var(name, scope, codes)
    slot = scope.mem.fetch(name)
    codes << ByteCode.new(scope.boxed?(name) ? :LOAD_REF : :LOAD, slot)
  end

  # Emit args + CALL. Args bound to VAR params push the raw ref; all other
  # args compile as expressions (which dereferences boxed names).
  def emit_call(name, args, scope, procedures, codes)
    if BUILTIN_SYSCALLS.key?(name)
      # Direct-syscall builtins: push each arg, then SYSCALL the id. No
      # procedure-table lookup; no VAR-param distinction (all args are
      # ordinary values).
      args.each { |a| compile_expression(a, codes, scope, procedures) }
      codes << ByteCode.new(:SYSCALL, BUILTIN_SYSCALLS[name])
      return
    end

    procedure = procedures.fetch(name)
    procedure[:params].each_with_index do |param, i|
      arg = args[i]
      if procedure[:var_params].include?(param)
        raise "VAR arg must be a variable name" unless arg.respond_to?(:type) && arg.type == :Variable
        # Push the ref WITHOUT dereferencing. The callee's matching slot
        # will hold this ref and access it via LOAD_REF/STORE_REF.
        codes << ByteCode.new(:LOAD, scope.mem.fetch(arg.name))
      else
        compile_expression(arg, codes, scope, procedures)
      end
    end
    codes << ByteCode.new(:CALL, procedure)
  end

  def compile_expression(expression, codes, scope, procedures)
    case expression.type
    when :Integer
      codes << ByteCode.new(:PUSH, expression.value)

    when :Float
      # PUSH carries any literal value; the VM just pushes it onto the stack.
      # Math/compare ops use `send`, which works the same for Float as Int.
      codes << ByteCode.new(:PUSH, expression.value)

    when :String
      codes << ByteCode.new(:ALLOC, expression.value)

    when :Variable
      emit_load_var(expression.name, scope, codes)

    when :ArrayAlloc
      compile_expression(expression.value, codes, scope, procedures)  # size
      codes << ByteCode.new(:ALLOC_ARRAY)

    when :ArrayGet
      emit_load_var(expression.name, scope, codes)
      compile_expression(expression.value, codes, scope, procedures)  # index
      codes << ByteCode.new(:ARRAY_GET)

    when :Length
      # `LEN(x)` — works for any heap value (string or array); the VM op
      # pops a ref, releases it, pushes the payload's length.
      compile_expression(expression.value, codes, scope, procedures)
      codes << ByteCode.new(:ARRAY_LEN)

    when :Input
      # `INPUT()` — no args. SYSCALL 2 reads a line and pushes a string ref.
      codes << ByteCode.new(:SYSCALL, 2)

    when :Time
      # `TIME()` — no args. SYSCALL 6 pushes the current ms timestamp.
      codes << ByteCode.new(:SYSCALL, 6)

    when :Math
      compile_expression(expression.left, codes, scope, procedures)
      compile_expression(expression.right, codes, scope, procedures)
      codes << ByteCode.new(:MATH, expression.value)

    when :Compare
      compile_expression(expression.left, codes, scope, procedures)
      compile_expression(expression.right, codes, scope, procedures)
      codes << ByteCode.new(:COMPARE, COMPARE_OPS.fetch(expression.value))

    when :Call
      # Sub-expression call. Same arg-handling rules as a CallStatement.
      emit_call(expression.name, expression.args, scope, procedures, codes)
    end
  end
end
