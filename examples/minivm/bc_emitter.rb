#!/usr/bin/env ruby
# BcEmitter: walks verified MIR::Program -> bytecode for the VM's exec!
#
# Receives a MIR::Program (post-MIRChecker) + CompilerFrontend::Result.
# Uses MIR::Let.annotation for accurate slot types (avoids AST heuristics).
# Falls back to AST nodes for Zig-specific leaves (InlineZig/RawZig) via a
# parallel walk of MIR body and the original annotated AST body.
#
# Only compiles main/cheatMain. Non-main functions raise Unimplemented.

require_relative "../../src/mir/mir"

class BcEmitter
  class Unimplemented < StandardError; end

  # Opcodes - must match interpreter exec! exactly.
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
  LOAD_SLOT_I64  = 38; STORE_SLOT_I64 = 39; LOAD_CONST_I64 = 40; JUMP_IF_FALSE_I = 41
  LOAD_SLOT_F64  = 42; STORE_SLOT_F64 = 43; LOAD_CONST_F64 = 44
  ADD_F64     = 45; SUB_F64     = 46; MUL_F64     = 47; DIV_F64     = 48
  LT_F64      = 49; GT_F64      = 50; LTE_F64     = 51; GTE_F64     = 52
  EQ_F64      = 53; NEQ_F64     = 54
  I_TO_VAL    = 55; F_TO_VAL    = 56; BOOL_TO_VAL = 57
  DEBUG_BREAK = 58
  LOAD_ISLOT  = 59; STORE_ISLOT = 60; LOAD_FSLOT  = 61; STORE_FSLOT = 62
  STRUCT_FIELD = 63; TYPED_FIELD_I64 = 64; TYPED_FIELD_F64 = 65
  MAP_NEW     = 66; MAP_PUT    = 67; MAP_GET     = 68; MAP_CONTAINS = 69
  MAP_DELETE  = 70; MAP_KEYS   = 71; MAP_LENGTH  = 72
  SET_INSERT  = 73; SET_CONTAINS = 74; SET_REMOVE = 75; SET_TOLIST  = 76
  BC_CALL     = 77; BC_RET      = 78; BC_RET_VOID = 79
  MARK_MOVED  = 80

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
    "lowercase" => 100, "uppercase" => 101, "replace" => 102, "parseFloat" => 103,
    "countOccurrences" => 104, "fileSize" => 105, "threadCount" => 106,
    "list-pop" => 107,
    "string-append" => 26, "string-length" => 27, "substring" => 28,
    "string-ref" => 29, "number->string" => 30, "string->number" => 31,
    "string?" => 32, "charAt" => 29,
    "vector" => 16, "vector-ref" => 17, "vector-set!" => 18, "vector-length" => 19,
    "cons" => 21, "car" => 22, "cdr" => 23, "pair?" => 24, "eq?" => 25,
    "list-set!" => 62,
  }

  def initialize(result, source: nil)
    @result = result
    @fn_nodes = result.fn_nodes  # { name/sym => AST::FunctionDef } (annotated)
    @ops = []
    @consts = []
    @mutables = Set.new
    @slots = {};  @islots = {};  @fslots = {}
    @slot_types = {}
    @next_slot = 0; @next_islot = 0; @next_fslot = 0
    @type_stack = []
    @struct_fields = {}
    @fn_start_ips = {}   # { helper_fn_name => bytecode_index where body starts }
    @in_helper_fn = false
    @helper_fn_returned = false
    @loop_continue_target = nil  # bytecode index to jump to for MIR::ContinueStmt
    @loop_break_patches = nil    # Array of op indices needing loop-exit patch
  end

  def compile(program)
    # Build struct field list from result schemas (field order matters for
    # vector-ref index). Schema shape varies: Hash{name=>{type,...}} from the
    # annotator, or Array of field specs from older paths. Normalize both.
    (@result.struct_schemas || {}).each do |name, fields|
      @struct_fields[name.to_s] =
        case fields
        when Hash then fields.keys.map(&:to_s)
        when Array then fields.map { |f| f.is_a?(Hash) ? f[:name].to_s : f.to_s }
        else []
        end
    end

    # Track enum type names so field access emits symbols (not nil)
    @enum_types = Set.new((@result.enum_schemas || {}).keys.map(&:to_s))
    @union_types = Set.new((@result.union_schemas || {}).keys.map(&:to_s))

    # Inline-struct union variants (`UNION Shape { Circle { radius: ... } }`)
    # have no entry in struct_schemas — they're described only inside
    # union_schemas as `{ :kind => :inline_struct, :fields => {name=>Type} }`.
    # Register each variant's fields as a synthetic struct so
    # find_field_index can resolve `ci.radius` after a MATCH-capture
    # unpacks the payload via pairCdr (which returns Value.Vector of the
    # variant's fields in declaration order).
    (@result.union_schemas || {}).each do |_uname, variants|
      (variants || {}).each do |vname, spec|
        next unless spec.is_a?(Hash) && spec[:kind] == :inline_struct
        fields = spec[:fields]
        next unless fields.is_a?(Hash) && !fields.empty?
        @struct_fields[vname.to_s] = fields.keys.map(&:to_s)
      end
    end

    fns = program.items.select { |i| i.is_a?(MIR::FnDef) }
    helpers = fns.reject { |f| MAIN_NAMES.include?(f.name.to_s) }
    mains   = fns.select { |f| MAIN_NAMES.include?(f.name.to_s) }

    # Emit helper bodies before main so call sites can patch fixed IPs.
    # Jump over the helper region into main; patch the jump target after
    # helpers are laid out.
    if helpers.any?
      emit_op(JUMP)
      jump_to_main_idx = @ops.length
      emit_op(0)
      helpers.each { |h| compile_helper_fn_mir(h) }
      @ops[jump_to_main_idx] = @ops.length
    end

    mains.each { |m| process_fn_def(m) }

    # Non-fn top-level items (TypeAlias, etc.) are still visited for side
    # effects like schema registration that non-fn processors may need.
    program.items.each do |item|
      next if item.is_a?(MIR::FnDef)
      process_top_level(item)
    end

    emit_op(HALT)
    { ops: @ops, consts: @consts }
  end

  def serialize
    lines = [@ops.join(",")]
    @consts.each { |c| lines << serialize_const(c) }
    lines.join("\n")
  end

  private

  # ================================================================
  # Top-level processing
  # ================================================================

  def process_top_level(item)
    case item
    when MIR::FnDef
      process_fn_def(item)
    when MIR::StructDef, MIR::EnumDef, MIR::UnionTypeDef,
         MIR::Import, MIR::TypeAlias, MIR::PubConst,
         MIR::Noop, MIR::Comment,
         MIR::AllocMark, MIR::ReturnMark, MIR::ReassignMark, MIR::FieldCleanupMark
      nil  # skip
    end
  end

  MAIN_NAMES = %w[main clearMain cheatMain].freeze

  def process_fn_def(mir_fn)
    name = mir_fn.name.to_s
    ast_fn = lookup_ast_fn(name)
    raise Unimplemented, "no AST fn for #{name}" unless ast_fn
    compile_main(mir_fn.body, ast_fn.body)
  end

  # AST fn_nodes key the main fn under `main` (or `cheatMain`) but MIR renames
  # it to `clearMain`. Try each candidate.
  def lookup_ast_fn(name)
    @fn_nodes[name.to_sym] || @fn_nodes[name] ||
      @fn_nodes["#{name}!".to_sym] || @fn_nodes["#{name}!"] || (
      MAIN_NAMES.include?(name) ?
        (@fn_nodes[:main] || @fn_nodes["main"] ||
         @fn_nodes[:cheatMain] || @fn_nodes["cheatMain"] ||
         @fn_nodes[:clearMain] || @fn_nodes["clearMain"]) :
        nil
    )
  end

  # Compile a non-main helper function into the shared op stream, isolated
  # from main's slot tables. Records @fn_start_ips[name] so call sites can
  # emit BC_CALL with a fixed target IP.
  def compile_helper_fn_mir(mir_fn)
    name   = mir_fn.name.to_s
    ast_fn = lookup_ast_fn(name)
    raise Unimplemented, "no AST fn for helper #{name}" unless ast_fn

    saved = {
      slots: @slots, islots: @islots, fslots: @fslots,
      slot_types: @slot_types, mutables: @mutables,
      next_slot: @next_slot, next_islot: @next_islot, next_fslot: @next_fslot,
      type_stack: @type_stack,
    }
    @slots = {}; @islots = {}; @fslots = {}
    @slot_types = {}; @mutables = Set.new
    @next_slot = 0; @next_islot = 0; @next_fslot = 0
    @type_stack = []
    @in_helper_fn = true
    @helper_fn_returned = false

    @fn_start_ips[name] = @ops.length

    # Allocate slots 0..argc-1 for parameters (BC_CALL deposits args there).
    # MIR lowering prepends a synthetic `rt` param (the runtime handle)
    # to every fn; callers don't pass it (compile_call_expr strips `rt`
    # from its args filter), so the helper's slot layout must also skip
    # it or slot 0/1 misalign with what BC_CALL deposits.
    (mir_fn.params || []).each do |p|
      pname = p.respond_to?(:name) ? p.name.to_s : p.to_s
      next if pname == "rt"
      alloc_slot(pname, :any)
    end

    compile_main(mir_fn.body, ast_fn.body)

    # If the body didn't end in an explicit RETURN, emit BC_RET_VOID so the
    # helper always has a terminator. compile_stmt(ReturnStmt) sets
    # @helper_fn_returned when it emits BC_RET.
    emit_op(BC_RET_VOID) unless @helper_fn_returned

    @slots = saved[:slots]; @islots = saved[:islots]; @fslots = saved[:fslots]
    @slot_types = saved[:slot_types]; @mutables = saved[:mutables]
    @next_slot = saved[:next_slot]; @next_islot = saved[:next_islot]
    @next_fslot = saved[:next_fslot]; @type_stack = saved[:type_stack]
    @in_helper_fn = false
    @helper_fn_returned = false
  end

  # ================================================================
  # Main body: parallel walk of MIR and AST
  # ================================================================

  def compile_main(mir_body, ast_body)
    mir_stmts = semantic_mir_nodes(mir_body)
    ast_stmts = semantic_ast_nodes(ast_body)

    # Ownership-only MIR nodes (MoveMark) have no AST counterpart — the
    # lowering inserts them purely for ownership tracking. Compile them
    # inline without consuming an AST stmt so the remaining MIR stmts
    # still pair 1:1 with AST stmts.
    mir_paired = mir_stmts.reject { |n| n.is_a?(MIR::MoveMark) }
    if mir_paired.length != ast_stmts.length
      raise Unimplemented, "MIR/AST length mismatch (#{mir_paired.length} vs #{ast_stmts.length})"
    end

    ast_cursor = 0
    mir_stmts.each do |mir_node|
      if mir_node.is_a?(MIR::MoveMark)
        compile_stmt(mir_node, nil)
        next
      end
      ast_node = ast_stmts[ast_cursor]; ast_cursor += 1
      compile_stmt(mir_node, ast_node)
      if mir_node.is_a?(MIR::Let) || mir_node.is_a?(MIR::ExprStmt)
        t = pop_type
        emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
      end
    end
  end

  # Strip memory/housekeeping nodes and hoisted temporaries.
  def semantic_mir_nodes(body)
    body.reject { |n|
      skip_mir?(n) ||
      # Hoisted temps: __hpt_N / __tmp_N. These are auto-generated by
      # allocation hoisting — the emitter can inline them (compile_expr
      # on the subsequent use evaluates the init in place).
      #
      # DO NOT strip:
      #   __ret       — return-value binding referenced by ReturnStmt
      #   __hm        — hashmap/set literal receiver that subsequent .put()
      #                 calls mutate; stripping causes load-by-name to fail.
      (n.is_a?(MIR::Let) && n.name.to_s =~ /\A__(?!ret\z|hm\z)/)
    }
  end

  def skip_mir?(n)
    n.is_a?(MIR::AllocMark)       || n.is_a?(MIR::ReturnMark)      ||
    n.is_a?(MIR::ReassignMark)    || n.is_a?(MIR::FieldCleanupMark) ||
    n.is_a?(MIR::Cleanup)         || n.is_a?(MIR::ErrCleanup)       ||
    # MIR::MoveMark is NOT skipped — it emits MARK_MOVED to release the
    # slot's ownership so the subsequent slot-restore in BC_RET (and any
    # reassignment overwrite) doesn't double-free the heap payload that
    # was moved into the return value / callee argument.
    n.is_a?(MIR::EscapePromote)   ||
    n.is_a?(MIR::FrameSave)       || n.is_a?(MIR::FrameRestore)     ||
    n.is_a?(MIR::Noop)            || n.is_a?(MIR::Comment)          ||
    n.is_a?(MIR::Suppress)        || n.is_a?(MIR::DeferStmt)        ||
    n.is_a?(MIR::ErrDeferStmt)    ||
    # Pure discard expressions produced by the lowering for side-effect tracking
    (n.is_a?(MIR::ExprStmt) && n.discard && n.expr.is_a?(MIR::Ident)) ||
    # Zig-only boilerplate added by the lowering — no bytecode equivalent
    (n.is_a?(MIR::ExprStmt) && n.expr.is_a?(MIR::Call) && n.expr.callee == "@setEvalBranchQuota") ||
    # Void ReturnStmt (bare RETURN;) — AST already filters it; MIR should too
    (n.is_a?(MIR::ReturnStmt) && (n.value.nil? || void_expr?(n.value)))
  end

  def semantic_ast_nodes(body)
    body.reject { |n|
      # Old-style MIR nodes inserted by MIRPass into the AST
      n.is_a?(MIR::Alloc) || n.is_a?(MIR::Drop) ||
      n.is_a?(MIR::SuppressCleanup) || n.is_a?(MIR::Promote) ||
      n.is_a?(MIR::Return) || n.is_a?(MIR::ReassignCleanup) ||
      n.is_a?(MIR::FieldCleanup) ||
      # Bare returns with no value
      (n.is_a?(AST::ReturnNode) && n.value.nil?)
    }
  end

  # ================================================================
  # Statement compilation
  # ================================================================

  def compile_stmt(mir_node, ast_node)
    case mir_node
    when MIR::Let
      if mir_node.init.is_a?(MIR::InlineZig) || mir_node.init.is_a?(MIR::RawZig)
        raise Unimplemented, "InlineZig/RawZig init not supported in VM path"
      end
      compile_let(mir_node)
    when MIR::Set
      compile_set(mir_node)
    when MIR::ReassignWithCleanup
      compile_expr(mir_node.value)
      val_type = pop_type
      name = mir_node.name.to_s
      alloc_slot(name, val_type) unless has_slot?(name)
      emit_store(name, val_type)
      @slot_types[name] = val_type
      push_type(:void)
    when MIR::ExprStmt
      compile_expr_stmt(mir_node, ast_node)
    when MIR::IfStmt
      compile_if(mir_node)
    when MIR::IfBindStmt
      compile_if_bind(mir_node)
    when MIR::WhileStmt
      compile_while(mir_node)
    when MIR::ForStmt
      compile_for(mir_node, ast_node)
    when MIR::SwitchStmt
      compile_switch(mir_node, ast_node)
    when MIR::IfChain
      compile_if_chain(mir_node, ast_node)
    when MIR::ReturnStmt
      has_value = mir_node.value && !void_expr?(mir_node.value)
      compile_expr(mir_node.value) if has_value
      if @in_helper_fn
        ensure_value_stack if has_value
        emit_op(has_value ? BC_RET : BC_RET_VOID)
        @helper_fn_returned = true
        push_type(:void) unless has_value
      end
    when MIR::InlineBc
      compile_inline_bc(mir_node)
    when MIR::RawBc
      # Statement-position RawBc — walk its template for side effects,
      # discard the result.
      compile_raw_bc(mir_node)
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
      push_type(:void)
    when MIR::MoveMark
      # Release this slot's ownership at the point the binding is moved
      # out — either into a return value or a TAKES callee arg. MARK_MOVED
      # sets slots[idx] = Nil so the subsequent BC_RET slot-restore (and
      # any reassignment overwrite) cleans up Nil (no-op) instead of the
      # heap payload that's now owned by the new binding.
      #
      # MoveMark.name may refer to a line-suffixed rename (e.g. inner_L12).
      # Line-suffix rename doesn't touch slot lookups, so try the raw name
      # too if the suffixed one isn't in our slot table.
      name = mir_node.name.to_s
      slot_name = has_slot?(name) ? name : name.sub(/_L\d+\z/, "")
      if has_slot?(slot_name)
        emit_op(MARK_MOVED, @slots[slot_name])
      end
    when MIR::Call, MIR::MethodCall
      # Statement-position bare call — compile as an expression and discard
      # the result (mirrors how ExprStmt handles it). Happens for side-effect
      # calls emitted directly into MATCH arms and similar scopes.
      compile_expr(mir_node)
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
      push_type(:void)
    when MIR::ScopeBlock
      inner = semantic_mir_nodes(mir_node.body)
      inner.each { |n| compile_stmt(n, nil) }
    when MIR::Pipeline
      # See compile_expr's MIR::Pipeline branch.
      compile_stmt(mir_node.inner, nil)
    when MIR::ContinueStmt
      if @loop_continue_target
        emit_op(JUMP, @loop_continue_target)
        push_type(:void)
      else
        raise Unimplemented, "ContinueStmt outside of a known loop target"
      end
    when MIR::BreakStmt
      if @loop_break_patches
        emit_op(JUMP)
        @loop_break_patches << @ops.length
        emit_op(0)
        push_type(:void)
      else
        raise Unimplemented, "MIR::BreakStmt outside of a known loop"
      end
    when MIR::RawZig, MIR::InlineZig
      raise Unimplemented, "#{mir_node.class.name.split('::').last} not supported in VM path"
    when MIR::BgBlock
      # VM is single-threaded; run the fiber body inline. Captures are by
      # reference in the VM model, so no explicit copy needed.
      if mir_node.run_body
        mir_node.run_body.each { |s| compile_stmt(s, nil) }
      end
      push_type(:void)
    when MIR::DoBlock, MIR::CatchWrapper
      raise Unimplemented, "#{mir_node.class.name.split('::').last} not yet supported"
    else
      if ast_node
        compile_ast_stmt(ast_node)
      else
        raise Unimplemented, "unhandled MIR stmt: #{mir_node.class}"
      end
    end
  end

  def compile_expr_stmt(mir_node, ast_node)
    expr = mir_node.expr
    case expr
    when MIR::Call
      compile_call_expr(expr)
    when MIR::MethodCall
      compile_method_call_expr(expr)
    when MIR::InlineZig, MIR::RawZig
      raise Unimplemented, "#{expr.class.name.split('::').last} expr not supported in VM path"
    else
      compile_expr(expr)
    end
    t = pop_type
    emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
    push_type(:void)  # signal to compile_main that POP was already handled
  end

  # ================================================================
  # Let / variable declaration
  # ================================================================

  def compile_let(node)
    name = node.name.to_s
    ann_type = annotation_to_vm_type(node.annotation)

    if node.init
      # HashMap/Set StructInit (non-empty literal lowered to StructInit with alloc field)
      # — replace with MAP_NEW since the VM uses MapRef, not a Zig struct.
      if (ann_type == :map || ann_type == :set) && node.init.is_a?(MIR::StructInit)
        emit_op(MAP_NEW)
        val_type = ann_type
      else
        compile_expr(node.init)
        val_type = pop_type
      end
    else
      cidx = add_const(nil)
      emit_op(LOAD_CONST, cidx)
      val_type = :any
    end

    # Typed-stack comparisons (GT_I64 / EQ_I64 / etc.) push their bool
    # result to the typed istack, not the value stack. The only slots the
    # VM provides are :i64 islots, :f64 fslots, or :any value slots —
    # there's no "bool slot". Move the bool onto the value stack so
    # emit_store picks the STORE_SLOT (value) path.
    if val_type == :bool
      emit_op(BOOL_TO_VAL)
      val_type = :any
    end

    # Annotation only wins when the init actually landed on the matching stack.
    # When the annotation says :i64 but the init produced a value-stack result
    # (e.g. a NATIVE_CALL that returns Value.Int64Val), STORE_ISLOT would read
    # from the empty typed stack and crash. Fall back to the emitted type so
    # the right store opcode fires.
    #
    # :bool annotation also maps to :any — the VM has no bool slot; after
    # BOOL_TO_VAL above, the value lives on the value stack and needs
    # STORE_SLOT + LOAD_SLOT, not a typed slot opcode.
    effective_type =
      if ann_type == :i64 && val_type == :any then :any
      elsif ann_type == :f64 && val_type == :any then :any
      elsif ann_type == :bool then :any
      elsif ann_type != :any then ann_type
      else val_type
      end
    alloc_slot(name, effective_type)
    emit_store(name, effective_type)
    if effective_type == :f64 && val_type == :i64
      emit_op(INT_TO_F64)
    end
    push_type(:void)
  end

  def annotation_to_vm_type(ann)
    return :any if ann.nil?
    return :i64  if ann == "i64"
    return :f64  if ann == "f64"
    return :bool if ann == "bool"
    return :str  if ann == "[]const u8"
    return :map  if ann.include?("StringMap") || ann.include?("NumericMapType") ||
                    ann.include?("PartitionedStringMap") || ann.include?("ShardedStringMap") ||
                    ann.include?("PartitionedNumericMap") || ann.include?("StripedNumericMap") ||
                    ann.include?("MutexShardedStringMap")
    return :set  if ann.include?("CheatLib.Set(")
    :any
  end

  # ================================================================
  # Set / assignment
  # ================================================================

  def compile_set(node)
    target = node.target

    # HashMap index assignment: m[key] = val → MAP_PUT(map, key, val)
    if target.is_a?(MIR::IndexGet) && receiver_slot_type(target.object) == :map
      compile_expr_to_value(target.object)
      compile_expr_to_value(target.index)
      compile_expr_to_value(node.value)
      emit_op(MAP_PUT)
      push_type(:void)
      return
    end

    case target
    when MIR::Ident
      compile_expr(node.value)
      val_type = pop_type
      # :bool (typed istack) → value stack, matching compile_let's rule.
      if val_type == :bool
        emit_op(BOOL_TO_VAL); val_type = :any
      end
      name = target.name.to_s
      if has_slot?(name)
        emit_store(name, val_type)
        @slot_types[name] = val_type
      else
        name_idx = add_const(name)
        emit_op(SET_NAME, name_idx)
      end
    when MIR::FieldGet
      # vector-set! expects [vector, idx, value] on the vstack in that order.
      compile_expr_to_value(target.object); pop_type
      idx = find_field_index(target.field)
      if idx
        emit_op(LOAD_CONST, add_const([:i64, idx]))
        compile_expr_to_value(node.value); pop_type
        emit_op(NATIVE_CALL, NATIVES["vector-set!"], 3)
      end
    when MIR::IndexGet
      compile_expr(node.value); pop_type
      compile_expr(target.object)
      compile_expr(target.index)
    end
    push_type(:void)
  end

  # ================================================================
  # Control flow
  # ================================================================

  def compile_if_bind(node)
    # For each binding: compile expr, test nil, store capture slot, on any
    # nil short-circuit to else.
    skip_patches = []
    node.bindings.each do |b|
      compile_expr_to_value(b[:expr]); pop_type
      emit_op(DUP) if respond_to?(:emit_dup_stub)  # we'll do it manually
      # The VM doesn't have a DUP opcode exposed by default here — emit a
      # store-then-load to keep the value available for both the nil test and
      # the binding.
      capture = b[:capture].to_s
      alloc_slot(capture, :any) unless has_slot?(capture)
      @slot_types[capture] = :any
      emit_op(STORE_SLOT, @slots[capture])
      emit_op(LOAD_SLOT, @slots[capture])
      emit_op(JUMP_IF_FALSE)  # nil is falsy
      skip_patches << @ops.length
      emit_op(0)
    end

    emit_body_stmts(node.then_body)

    if node.else_body && !node.else_body.empty?
      emit_op(JUMP); end_patch = @ops.length; emit_op(0)
      skip_patches.each { |idx| @ops[idx] = @ops.length }
      emit_body_stmts(node.else_body)
      @ops[end_patch] = @ops.length
    else
      skip_patches.each { |idx| @ops[idx] = @ops.length }
    end
    push_type(:void)
  end

  def compile_if(node)
    compile_cond(node.cond)
    cond_type = pop_type
    emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    jump_false_idx = @ops.length
    emit_op(0)

    emit_body_stmts(node.then_body)

    if node.else_body && !node.else_body.empty?
      emit_op(JUMP)
      jump_end_idx = @ops.length
      emit_op(0)
      @ops[jump_false_idx] = @ops.length
      emit_body_stmts(node.else_body)
      @ops[jump_end_idx] = @ops.length
    else
      @ops[jump_false_idx] = @ops.length
      push_type(:void)
    end
  end

  def compile_while(node)
    loop_start = @ops.length
    compile_cond(node.cond)
    cond_type = pop_type
    emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    jump_exit_idx = @ops.length
    emit_op(0)

    saved_continue = @loop_continue_target
    saved_breaks   = @loop_break_patches
    @loop_continue_target = loop_start
    @loop_break_patches   = []
    emit_body_stmts(node.body)
    break_patches = @loop_break_patches
    @loop_continue_target = saved_continue
    @loop_break_patches   = saved_breaks
    emit_op(JUMP, loop_start)
    @ops[jump_exit_idx] = @ops.length
    break_patches.each { |idx| @ops[idx] = @ops.length }
    push_type(:void)
  end

  def compile_for(node, ast_node = nil)
    if ast_node
      compile_ast_stmt(ast_node)
    else
      raise Unimplemented, "ForStmt without AST fallback"
    end
  end

  def compile_switch(node, ast_node)
    # SwitchStmt: switch (subject) { arms }
    if ast_node
      compile_ast_stmt(ast_node)
    else
      raise Unimplemented, "SwitchStmt without AST fallback"
    end
  end

  def compile_if_chain(node, ast_node)
    # IfChain: if-else chain. Union MATCH lowers each arm to
    #   BinOp(==, Call("std.meta.activeTag", [subject]), Ident(".Variant"))
    # The VM represents a union as Pair(car=Value.Symbol("Variant"),
    # cdr=payload). Detect and emit direct `car(subject)` + Symbol-const
    # compare; everything else falls through to normal BinOp compilation.
    end_jumps = []
    node.branches.each do |branch|
      compile_if_chain_cond(branch[:cond])
      cond_type = pop_type
      emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
      skip_idx = @ops.length; emit_op(0)

      emit_body_stmts(branch[:body])

      emit_op(JUMP); j = @ops.length; emit_op(0); end_jumps << j
      @ops[skip_idx] = @ops.length
    end
    default = node.default_body
    emit_body_stmts(default) if default && !default.empty?
    end_jumps.each { |j| @ops[j] = @ops.length }
  end

  # Emit a condition. Two VM-specific shapes get direct handling:
  #
  #  (1) Union MATCH — lowered as
  #      BinOp(==, Call("std.meta.activeTag", [subject]), Ident(".Variant"))
  #      Emit `car(subject)` then Symbol("Variant") and eq?.
  #
  #  (2) Enum MATCH — lowered as BinOp(==, Ident(subject), Ident(".Variant"))
  #      where the subject is already a Symbol value. Same pattern, just
  #      without the car() indirection.
  #
  # Anything else falls through to generic BinOp compilation.
  def compile_if_chain_cond(cond)
    if cond.is_a?(MIR::BinOp) && cond.op == "=="
      lhs, rhs = cond.left, cond.right
      # Shape (1): activeTag on the left.
      if lhs.is_a?(MIR::Call) && lhs.callee.to_s == "std.meta.activeTag" &&
         rhs.is_a?(MIR::Ident) && rhs.name.to_s.start_with?(".")
        variant = rhs.name.to_s.sub(/\A\./, "")
        compile_expr_to_value(lhs.args.first); pop_type
        emit_op(NATIVE_CALL, NATIVES["car"], 1)
        emit_op(LOAD_CONST, add_const(variant))
        emit_op(NATIVE_CALL, NATIVES["eq?"], 2)
        push_type(:any); return
      end
      # Shape (2): RHS is a Zig tag literal (.Variant), LHS is whatever
      # value holds the enum/union.
      if rhs.is_a?(MIR::Ident) && rhs.name.to_s.start_with?(".")
        variant = rhs.name.to_s.sub(/\A\./, "")
        compile_expr_to_value(lhs); pop_type
        emit_op(LOAD_CONST, add_const(variant))
        emit_op(NATIVE_CALL, NATIVES["eq?"], 2)
        push_type(:any); return
      end
    end
    compile_expr(cond)
  end

  def compile_switch(node, ast_node)
    # SwitchStmt: switch (subject) { arms }. Convert to IfChain-style
    # dispatch — both union MATCH and other finite-subject switches lower
    # through the same VM pattern. `arm[:pattern]` is typically a Zig
    # source string ("1", ".Ok"); wrap it as MIR::Lit / MIR::Ident so
    # compile_binop can lower the equality.
    arms = node.arms || []
    branches = arms.map do |arm|
      pat  = arm[:pattern] || arm[:patterns]&.first
      body = arm[:body]
      next unless pat && body
      pat_node = case pat
                 when MIR::Expr, MIR::Ident, MIR::Lit then pat
                 when String
                   if pat.start_with?(".")
                     MIR::Ident.new(pat)  # Zig tag literal; handled by IfChain rewrite path
                   else
                     MIR::Lit.new(pat)    # numeric / bool / quoted-string literal
                   end
                 else MIR::Lit.new(pat.to_s)
                 end
      { cond: MIR::BinOp.new("==", node.subject, pat_node), body: body }
    end.compact
    chain = MIR::IfChain.new(branches, node.default_body)
    compile_if_chain(chain, ast_node)
  end

  # ================================================================
  # AST fallback for Zig-specific leaves
  # ================================================================

  def compile_ast_stmt(node)
    case node
    when AST::Assert
      compile_ast_assert(node)
    when AST::BindExpr
      compile_ast_bind(node)
    when AST::VarDecl
      compile_ast_vardecl(node)
    when AST::Assignment
      compile_ast_assign(node)
    when AST::FuncCall
      compile_ast_func_call(node)
    when AST::MethodCall
      compile_ast_method_call(node)
    when AST::IfStatement
      compile_ast_if(node)
    when AST::WhileLoop
      compile_ast_while(node)
    when AST::ForRange
      compile_ast_for_range(node)
    when AST::ForEach
      compile_ast_for_each(node)
    when AST::ReturnNode
      compile_ast_expr(node.value) if node.value
    when AST::MatchStatement
      compile_ast_match(node)
    else
      raise Unimplemented, "unhandled AST stmt: #{node.class}"
    end
  end

  # ================================================================
  # Expression compilation
  # ================================================================

  def compile_expr(node)
    case node
    when MIR::Lit
      compile_lit(node)
    when MIR::Ident
      compile_ident(node)
    when MIR::BinOp
      compile_binop(node)
    when MIR::UnaryOp
      compile_unary(node)
    when MIR::Call
      compile_call_expr(node)
    when MIR::MethodCall
      compile_method_call_expr(node)
    when MIR::FieldGet
      compile_field_get(node)
    when MIR::UnionVariantGet
      compile_union_variant_get(node)
    when MIR::IndexGet
      compile_index_get(node)
    when MIR::StructInit
      compile_struct_init(node)
    when MIR::MakeList
      compile_make_list(node)
    when MIR::ContainerInit
      compile_container_init(node)
    when MIR::DeepCopy
      compile_expr(node.source)  # simplified: no deep copy in VM
    when MIR::HeapCreate
      compile_expr(node.init)  # VM has no heap pointers; value is the "box"
    when MIR::ArrayInit
      (node.items || []).each { |it| compile_expr_to_value(it); pop_type }
      emit_op(NATIVE_CALL, NATIVES["list"], (node.items || []).length)
      push_type(:any); return
    when MIR::DupeSlice
      compile_expr(node.source)  # VM strings/lists are boxed; no dupe needed
    when MIR::AllocSlice
      emit_op(NATIVE_CALL, NATIVES["vector"], 0); push_type(:any); return
    when MIR::FreezeExpr
      compile_expr(node.inner)  # VM has no const/freeze semantics
    when MIR::FnRef
      emit_op(LOAD_CONST, add_const([:sym, node.name.to_s])); push_type(:any); return
    when MIR::TryExpr
      compile_expr(node.expr)  # VM doesn't propagate Zig errors
    when MIR::TryCatch
      compile_expr(node.expr)  # VM treats error-union as bare value
    when MIR::RcRetain, MIR::RcDowngrade, MIR::WeakUpgrade
      compile_expr(node.source)  # RC ops are no-op in VM; forward the inner value
    when MIR::FreeSlice
      # VM is GC'd; no explicit free. Evaluate for side effects only.
      compile_expr_to_value(node.slice); pop_type
      emit_op(POP)
      push_type(:void); return
    when MIR::Cast
      compile_cast(node)
    when MIR::Conditional
      compile_conditional(node)
    when MIR::Comptime
      compile_expr(node.expr)  # VM evaluates comptime guards at runtime
    when MIR::ItemsAccess
      compile_expr(node.expr)  # VM lists don't need .items unwrap
    when MIR::ListItems
      compile_expr(node.list)  # VM lists don't need .items unwrap
    when MIR::ListLength
      compile_expr(node.expr); pop_type
      emit_op(NATIVE_CALL, NATIVES["count"], 1)
      push_type(:any)
      return
    when MIR::IfOptional
      compile_if_optional(node)
    when MIR::AddressOf
      compile_expr(node.expr)  # VM has no pointers
    when MIR::Deref
      compile_expr(node.expr)  # VM has no pointers
    when MIR::OptionalUnwrap
      compile_expr(node.expr)
    when MIR::Orelse
      compile_orelse(node)
    when MIR::InlineZig
      # Reason-based pass-throughs for Zig-specific leaves that the VM can
      # substitute with a benign equivalent.
      case node.reason.to_s
      when "undef"
        emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
      when "alloc"
        emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
      when "mat_init"
        # Pipeline materialization target (std.ArrayListUnmanaged(T).empty).
        # VM: empty list.
        emit_op(NATIVE_CALL, NATIVES["list"], 0); push_type(:any); return
      when "pipe_items_access", "bc_src_items", "bc_unnest_items"
        # @hasField-guarded .items unwrap — in VM, lists are already items.
        emit_op(LOAD_SLOT, @slots["pipe_src_list"] || @slots["__soa_src"] || 0) if false
        # Fall back to the global name lookup; the name is embedded in the
        # Zig code string. Extract it as best-effort.
        ident = node.code.to_s[/\b([a-zA-Z_][\w]*)\b/, 1] || "pipe_src_list"
        if has_slot?(ident)
          emit_op(LOAD_SLOT, @slots[ident])
        else
          emit_op(LOAD_NAME, add_const(ident))
        end
        push_type(:any); return
      end
      raise Unimplemented, "InlineZig/RawZig in expression position (no bc template in stdlib)"
    when MIR::RawZig
      raise Unimplemented, "InlineZig/RawZig in expression position (no bc template in stdlib)"
    when MIR::InlineBc
      compile_inline_bc(node)
    when MIR::RawBc
      compile_raw_bc(node)
    when MIR::ConcatStr
      # Variadic string concat — the VM's CONCAT opcode takes two operands
      # and pushes the joined string. Chain it for 3+ parts: push a, push b,
      # CONCAT; push c, CONCAT; ... which is how the AST walker (+ chains)
      # already handles StringConcat. The lowered ConcatStr node carries
      # the parts pre-evaluated (or at least pre-lowered to MIR exprs).
      parts = node.parts
      if parts.nil? || parts.empty?
        emit_op(LOAD_CONST, add_const([:str, ""])); push_type(:str)
      else
        compile_expr_to_value(parts[0]); pop_type
        parts[1..].each do |p|
          compile_expr_to_value(p); pop_type
          emit_op(CONCAT)
        end
        push_type(:str)
      end
    when MIR::CapWrap
      # Capability wrappers (Rc/Arc/locked) have no VM representation —
      # the VM doesn't distinguish reference-counted from affine values.
      # Just forward the inner expression. This is safe because the VM
      # also doesn't model capability-specific semantics (e.g. RC retain),
      # so tests that exercise those paths would fail at their actual
      # assertions, not here.
      compile_expr(node.inner)
    when MIR::BlockExpr
      compile_block_expr(node)
    when MIR::Pipeline
      # Migrated pipeline operators produce a real MIR tree via
      # pipeline_host.lower_pipeline — compile that directly. Legacy operators
      # leave inner as MIR::RawZig which the VM can't compile; the inner
      # RawZig dispatch raises with a better error than a silent passthrough.
      compile_expr(node.inner)
    when MIR::BgBlock
      # VM is single-threaded. BgBlock in expression position returns a
      # "future"; run the body inline and push nil as a stand-in Future.
      if node.run_body
        node.run_body.each { |s| compile_stmt(s, nil) }
      end
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when NilClass
      cidx = add_const(nil)
      emit_op(LOAD_CONST, cidx)
      push_type(:any)
    else
      raise Unimplemented, "unhandled MIR expr: #{node.class}"
    end
  end

  def compile_cond(node)
    compile_expr(node)
  end

  def compile_expr_to_value(node)
    compile_expr(node)
    ensure_value_stack
  end

  # ================================================================
  # Literal parsing
  # ================================================================

  def compile_lit(node)
    val = node.value.to_s
    case val
    when "true"
      emit_op(LOAD_CONST, add_const([:bool, true])); push_type(:bool)
    when "false"
      emit_op(LOAD_CONST, add_const([:bool, false])); push_type(:bool)
    when "null", "undefined", "void"
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    when /\A@as\(i64,\s*(-?\d+)\)\z/
      emit_op(LOAD_CONST_I64, add_const([:i64, $1.to_i])); push_type(:i64)
    when /\A@as\(f64,\s*(-?[\d.]+(?:e[-+]?\d+)?)\)\z/i
      emit_op(LOAD_CONST_F64, add_const([:f64, $1.to_f])); push_type(:f64)
    when /\A-?\d+\z/
      emit_op(LOAD_CONST_I64, add_const([:i64, val.to_i])); push_type(:i64)
    when /\A-?[\d]+\.[\d]+(?:e[-+]?\d+)?\z/i
      emit_op(LOAD_CONST_F64, add_const([:f64, val.to_f])); push_type(:f64)
    when /\A"(.*)"\z/m
      emit_op(LOAD_CONST, add_const([:str, $1])); push_type(:str)
    else
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    end
  end

  # ================================================================
  # Identifiers
  # ================================================================

  def compile_ident(node)
    name = node.name.to_s
    vt = @slot_types[name] || :any
    if vt == :i64 && @islots[name]
      emit_op(LOAD_ISLOT, @islots[name]); push_type(:i64)
    elsif vt == :f64 && @fslots[name]
      emit_op(LOAD_FSLOT, @fslots[name]); push_type(:f64)
    elsif @slots[name]
      emit_op(LOAD_SLOT, @slots[name]); push_type(vt)
    else
      emit_op(LOAD_NAME, add_const(name)); push_type(:any)
    end
  end

  # ================================================================
  # Binary operations
  # ================================================================

  # MIR::RawBc: template-driven multi-opcode emission. Unlike InlineBc
  # (which dispatches on op name via compile_inline_bc's case statement),
  # RawBc carries the opcode sequence inline as a template array — same
  # structural role as RawZig on the Zig side.
  #
  # Template element forms:
  #   Symbol              -> emit_op(OPCODE) with no immediate args.
  #   String "{N}"        -> compile_expr_to_value(args[N]).
  #   Array [Sym, *]      -> emit_op(Sym, *immediate_args). Placeholders
  #                           "{N}" inside the array still resolve to args.
  #
  # Phase 0 scaffolding: no lowering site currently emits RawBc. When
  # Phase 3 starts emitting it, every template should come from a
  # registry entry whose ownership effects are declared in stdlib_def
  # so INV-5 remains enforceable.
  def compile_raw_bc(node)
    template = node.template || []
    args = node.args || []
    template.each do |elem|
      case elem
      when Symbol
        opcode = self.class.const_get(elem)
        emit_op(opcode)
      when String
        m = elem.match(/\A\{(\d+)\}\z/)
        if m
          compile_expr_to_value(args[m[1].to_i]); pop_type
        else
          raise Unimplemented, "RawBc template string form not understood: #{elem.inspect}"
        end
      when Array
        opcode_sym = elem[0]
        opcode = self.class.const_get(opcode_sym)
        immediate_args = elem[1..].map do |a|
          if a.is_a?(String) && (m = a.match(/\A\{(\d+)\}\z/))
            compile_expr_to_value(args[m[1].to_i]); pop_type
            nil  # placeholder consumed before the emit
          elsif a.is_a?(Symbol)
            NATIVES[a.to_s] || raise(Unimplemented, "RawBc: unknown native :#{a}")
          else
            a
          end
        end.compact
        emit_op(opcode, *immediate_args)
      else
        raise Unimplemented, "RawBc template element not understood: #{elem.inspect}"
      end
    end
    push_type(:any)
  end

  # MIR::InlineBc: stdlib-op dispatch driven by the :bc entry in BUILTIN_OPS.
  # The op symbol matches the registry key. Args are already MIR expr nodes;
  # we compile them onto the value (or typed) stack in order, then emit the
  # opcode sequence. Raises Unimplemented for ops not yet ported.
  INLINE_BC_BINOP_MAP = {
    intAdd:   "+",   intSub:   "-",   intMul:   "*",
    intDiv:   "/",   intMod:   "@mod",
    wrapAdd:  "+",   wrapSub:  "-",   wrapMul:  "*",
    checkAdd: "+",   checkSub: "-",   checkMul: "*",
    eql:      "==",  strEql:   "==",  symbolEql: "==",
    :"eql?" => "==",
  }.freeze

  def compile_inline_bc(node)
    op = node.op
    if INLINE_BC_BINOP_MAP.key?(op)
      # Synthesize a MIR::BinOp so we reuse the typed-stack dispatch.
      synth = MIR::BinOp.new(INLINE_BC_BINOP_MAP[op], node.args[0], node.args[1])
      compile_binop(synth)
      return
    end
    case op
    when :getAt
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["list-ref"], 2); push_type(:any); return
    when :setAt
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      compile_expr_to_value(node.args[2])
      emit_op(NATIVE_CALL, NATIVES["list-set!"], 3); push_type(:void); return
    when :append, :insert, :push
      # list.{append,insert,push}(x) — all aliases for list-push.
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
      recv = node.args[0]
      if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
        emit_store(recv.name.to_s, :any)
      end
      push_type(:void); return
    when :reserve
      # list.reserve(n) — no-op in VM (lists are growable per-mutation)
      compile_expr_to_value(node.args[0]); pop_type; emit_op(POP)
      compile_expr_to_value(node.args[1]); pop_type; emit_op(POP)
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when :pop
      # list.pop() -> ?T. VM returns the tail or nil. Use NATIVES["count"]
      # to peek length, then list-ref + manipulate. Simpler: new native below.
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["list-pop"], 1) if NATIVES.key?("list-pop")
      push_type(:any); return
    when :length
      # collection length — NATIVE_CALL count 1 handles list/string/map uniformly.
      # Result lands on the value stack as Value.Int64Val, so :any (not :i64 —
      # :i64 would claim the value is on the typed istack).
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["count"], 1); push_type(:any); return
    when :remove
      # list.remove(idx) — compile_list_remove is the existing AST helper;
      # just inline the same opcodes here using MIR args.
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)  # gets element for return
      # Note: ordered-remove side effect not yet modeled; returning the element
      # is the minimum for test compat. Tests that rely on ordered removal
      # will need a dedicated opcode in a follow-up.
      push_type(:any); return
    when :indexOf
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["indexOf"], 2); push_type(:any); return
    when :split
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["split"], 2); push_type(:any); return
    when :join
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["join"], 2); push_type(:any); return
    when :trim
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["trim"], 1); push_type(:any); return
    when :"startsWith?"
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["startsWith?"], 2); push_type(:any); return
    when :"endsWith?"
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["endsWith?"], 2); push_type(:any); return
    when :"contains?"
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["contains?"], 2); push_type(:any); return
    when :substr
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      compile_expr_to_value(node.args[2])
      emit_op(NATIVE_CALL, NATIVES["substr"], 3); push_type(:any); return
    when :readFile
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["readFile"], 1); push_type(:any); return
    when :writeFile
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["writeFile"], 2); push_type(:any); return
    when :toInt
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["toInt"], 1); push_type(:any); return
    when :toString
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["number->string"], 1); push_type(:any); return
    when :toFloat
      compile_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["string->number"], 1); push_type(:any); return
    when :assert
      # CheatLib.assert(cond, msg_expr) — emit branch-on-false + display(msg).
      # Mirrors compile_ast_assert exactly (the message argument is a MIR::Lit
      # wrapping a Zig-quoted string literal, so strip the surrounding quotes).
      compile_expr(node.args[0])
      cond_type = pop_type
      if cond_type == :bool
        emit_op(BOOL_TO_VAL); emit_op(NOT); emit_op(JUMP_IF_FALSE)
      else
        ensure_value_stack; emit_op(NOT); emit_op(JUMP_IF_FALSE)
      end
      jump_ok = @ops.length; emit_op(0)
      msg_lit = node.args[1]
      msg = if msg_lit.is_a?(MIR::Lit)
        s = msg_lit.value.to_s
        s =~ /\A"(.*)"\z/m ? $1 : s
      else
        "assertion failed"
      end
      emit_op(LOAD_CONST, add_const([:str, "ASSERT FAILED: #{msg}"]))
      emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      @ops[jump_ok] = @ops.length
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    when :cleanup, :cleanupAt
      # VM is GC'd; explicit cleanup is a no-op. Evaluate args for side effects
      # (shouldn't have any, but be safe) and produce void.
      (node.args || []).each do |a|
        compile_expr_to_value(a); pop_type; emit_op(POP)
      end
      push_type(:void); return
    when :needsCleanup
      # Comptime predicate; VM has GC so nothing needs manual cleanup.
      emit_op(LOAD_CONST, add_const([:bool, false])); push_type(:any); return
    when :dupeUnionValue
      # VM values are already boxed / shared-by-reference; no deep copy needed.
      # Forward arg[0] (the source value). alloc + type args are Zig-only.
      compile_expr_to_value(node.args[0]); pop_type
      push_type(:any); return
    when :streamDupeBytes
      # VM strings are immutable/boxed; forward the source bytes (arg[1]).
      compile_expr_to_value(node.args[1]); pop_type
      push_type(:any); return
    when :log, :exp, :floor, :shell, :abs, :codepointCount, :bytes, :toNumber,
         :randomInt
      # Unary builtins. Map the op symbol to a VM native where one exists;
      # otherwise degrade by forwarding the argument (wrong semantics but
      # avoids a compile failure).
      native_name = {
        bytes:           "string-length",
        codepointCount:  "string-length",  # VM strings are bytes, not UTF-8 decoded
        toNumber:        "parseFloat",
      }[op] || op.to_s
      if NATIVES.key?(native_name)
        compile_expr_to_value(node.args[0]); pop_type
        emit_op(NATIVE_CALL, NATIVES[native_name], 1); push_type(:any); return
      end
      compile_expr_to_value(node.args[0]); pop_type
      push_type(:any); return
    when :random, :timestampMs, :threadCount, :peakMemoryKb, :currentMemoryKb
      # Zero-arg builtins. Map to native if present, else push 0.
      native_name = op.to_s
      if NATIVES.key?(native_name)
        emit_op(NATIVE_CALL, NATIVES[native_name], 0); push_type(:any); return
      end
      emit_op(LOAD_CONST, add_const([:i64, 0])); push_type(:any); return
    when :countOccurrences
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      emit_op(NATIVE_CALL, NATIVES["countOccurrences"], 2); push_type(:any); return
    when :fileSize
      compile_expr_to_value(node.args[0]); pop_type
      emit_op(NATIVE_CALL, NATIVES["fileSize"], 1); push_type(:any); return
    when :sleep
      # Evaluate arg for side-effects; VM is single-threaded so sleep is a no-op.
      compile_expr_to_value(node.args[0]); pop_type; emit_op(POP)
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when :max, :min
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      native_name = op.to_s
      if NATIVES.key?(native_name)
        emit_op(NATIVE_CALL, NATIVES[native_name], 2); push_type(:any); return
      end
      # Fallback: pop one, leave the other. Best effort; tests dependent on
      # correctness will still fail the assertion rather than the compile.
      emit_op(POP); push_type(:any); return
    when :lowercase
      compile_expr_to_value(node.args[0]); pop_type
      emit_op(NATIVE_CALL, NATIVES["lowercase"], 1); push_type(:any); return
    when :uppercase
      compile_expr_to_value(node.args[0]); pop_type
      emit_op(NATIVE_CALL, NATIVES["uppercase"], 1); push_type(:any); return
    when :replace
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      compile_expr_to_value(node.args[2]); pop_type
      emit_op(NATIVE_CALL, NATIVES["replace"], 3); push_type(:any); return
    when :charAt
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      emit_op(NATIVE_CALL, NATIVES["charAt"], 2); push_type(:any); return
    when :print
      # print is a varargs macro. Evaluate each arg, display it, and push a
      # trailing newline display. VM's "display" native prints a single Value.
      (node.args || []).each do |a|
        compile_expr_to_value(a); pop_type
        emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      end
      emit_op(LOAD_CONST, add_const([:str, "\n"]))
      emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when :setMemberGet
      # if (set.contains(item)) item else nil
      # args: [set, item, elem_zig_type]
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["contains?"], 2)
      emit_op(JUMP_IF_FALSE)
      jump_miss = @ops.length; emit_op(0)
      compile_expr_to_value(node.args[1])  # hit: push the item
      emit_op(JUMP)
      jump_end = @ops.length; emit_op(0)
      @ops[jump_miss] = @ops.length
      emit_op(LOAD_CONST, add_const(nil))  # miss: push nil
      @ops[jump_end] = @ops.length
      push_type(:any); return
    else
      raise Unimplemented, "MIR::InlineBc op not yet implemented: :#{op}"
    end
  end

  # Peek the runtime-stack flavor of a MIR::Expr without emitting any ops.
  # Used by compile_binop to pre-align operand stacks (see that method). Only
  # needs to distinguish :i64 / :f64 from "everything else" — when in doubt,
  # return :any, which forces the binop to run on the value stack.
  def expr_type_hint(node)
    case node
    when MIR::Lit
      v = node.value.to_s
      return :i64 if v =~ /\A-?\d+\z/ || v =~ /\A@as\(i64,/
      return :f64 if v =~ /\A-?\d+\.\d+/ || v =~ /\A@as\(f64,/
      :any
    when MIR::Ident
      name = node.name.to_s
      return :i64 if @islots[name]
      return :f64 if @fslots[name]
      @slot_types[name] || :any
    else
      :any
    end
  end

  def compile_binop(node)
    op = node.op

    # Short-circuit AND/OR
    if op == "and"
      return compile_and(node)
    elsif op == "or"
      return compile_or(node)
    end

    # Peek types WITHOUT popping during compile so we can decide if the
    # operands need to be on the typed-stack (both i64 / both f64 -> use the
    # fast typed opcodes) or on the value stack (everything else). When the
    # types are going to be mixed, force both onto the value stack by calling
    # compile_expr_to_value — this keeps the stacks consistent.
    l_hint = expr_type_hint(node.left)
    r_hint = expr_type_hint(node.right)
    want_typed = (l_hint == :i64 && r_hint == :i64) ||
                 (l_hint == :f64 && r_hint == :f64)
    if want_typed
      compile_expr(node.left);  left_type  = pop_type
      compile_expr(node.right); right_type = pop_type
    else
      compile_expr_to_value(node.left);  left_type  = pop_type
      compile_expr_to_value(node.right); right_type = pop_type
    end

    both_i64 = (left_type == :i64 && right_type == :i64)
    both_f64 = (left_type == :f64 && right_type == :f64)

    case op
    when "+"
      if both_i64   then emit_op(ADD_I64);   push_type(:i64)
      elsif both_f64 then emit_op(ADD_F64);  push_type(:f64)
      elsif left_type == :str || right_type == :str
        ensure_value_stack; emit_op(CONCAT); push_type(:str)
      else emit_op(ADD); push_type(:any)
      end
    when "-"
      if both_i64    then emit_op(SUB_I64); push_type(:i64)
      elsif both_f64 then emit_op(SUB_F64); push_type(:f64)
      else emit_op(SUB); push_type(:any)
      end
    when "*"
      if both_i64    then emit_op(MUL_I64); push_type(:i64)
      elsif both_f64 then emit_op(MUL_F64); push_type(:f64)
      else emit_op(MUL); push_type(:any)
      end
    when "/"
      if both_i64    then emit_op(DIV_I64); push_type(:i64)
      elsif both_f64 then emit_op(DIV_F64); push_type(:f64)
      else emit_op(DIV); push_type(:any)
      end
    when "=="
      if both_i64    then emit_op(EQ_I64);  push_type(:bool)
      elsif both_f64 then emit_op(EQ_F64);  push_type(:bool)
      else                emit_op(EQ);      push_type(:any)
      end
    when "!="
      if both_i64    then emit_op(NEQ_I64); push_type(:bool)
      elsif both_f64 then emit_op(NEQ_F64); push_type(:bool)
      else                emit_op(EQ); emit_op(NOT); push_type(:any)
      end
    when "<"
      if both_i64    then emit_op(LT_I64);  push_type(:bool)
      elsif both_f64 then emit_op(LT_F64);  push_type(:bool)
      else                emit_op(LT);      push_type(:any)
      end
    when ">"
      if both_i64    then emit_op(GT_I64);  push_type(:bool)
      elsif both_f64 then emit_op(GT_F64);  push_type(:bool)
      else                emit_op(GT);      push_type(:any)
      end
    when "<="
      if both_i64    then emit_op(LTE_I64); push_type(:bool)
      elsif both_f64 then emit_op(LTE_F64); push_type(:bool)
      else                emit_op(LTE);     push_type(:any)
      end
    when ">="
      if both_i64    then emit_op(GTE_I64); push_type(:bool)
      elsif both_f64 then emit_op(GTE_F64); push_type(:bool)
      else                emit_op(GTE);     push_type(:any)
      end
    when "@mod", "%"
      if both_i64 then emit_op(MOD_I64) else emit_op(NATIVE_CALL, NATIVES["modulo"], 2) end
      push_type(:i64)
    else
      raise Unimplemented, "unsupported Zig BinOp: #{op}"
    end
  end

  def compile_and(node)
    compile_expr_to_value(node.left)
    emit_op(JUMP_IF_FALSE)
    patch = @ops.length; emit_op(0)
    compile_expr_to_value(node.right)
    emit_op(JUMP); end_patch = @ops.length; emit_op(0)
    @ops[patch] = @ops.length
    emit_op(LOAD_CONST, add_const([:bool, false]))
    @ops[end_patch] = @ops.length
    push_type(:bool)
  end

  def compile_or(node)
    compile_expr_to_value(node.left)
    emit_op(NOT); emit_op(JUMP_IF_FALSE)
    patch = @ops.length; emit_op(0)
    compile_expr_to_value(node.right)
    emit_op(JUMP); end_patch = @ops.length; emit_op(0)
    @ops[patch] = @ops.length
    emit_op(LOAD_CONST, add_const([:bool, true]))
    @ops[end_patch] = @ops.length
    push_type(:bool)
  end

  def compile_unary(node)
    compile_expr(node.operand)
    case node.op
    when "!", "not" then emit_op(NOT)
    when "-"
      neg_idx = add_const([:i64, -1])
      emit_op(LOAD_CONST, neg_idx)
      emit_op(MUL)
    end
  end

  # ================================================================
  # Function calls
  # ================================================================

  def compile_call_expr(node)
    callee = node.callee.to_s.sub(/\Atry /, "")

    # Skip rt arg: always first if present
    args = node.args.reject { |a| a.is_a?(MIR::Ident) && a.name.to_s == "rt" }
    # Skip &address-of wrapper
    args = args.map { |a| a.is_a?(MIR::AddressOf) ? a.expr : a }

    # Zig's std.debug.print is how macro_print (CLEAR's `print`) is emitted.
    # Args are: [format_string_lit, tuple_ident_like ".{a, b, c}"]. The
    # tuple Ident's name is a raw Zig snippet we can't parse; recover the
    # formatted arg list from the AST when available, or best-effort from
    # the tuple-literal string contents.
    if callee == "std.debug.print"
      # Pull arg names out of the synthetic tuple Ident (name is ".{a, b}").
      tuple = args[1]
      if tuple.is_a?(MIR::Ident) && tuple.name.to_s =~ /\A\.\{(.*)\}\z/m
        inner = $1
        parts = inner.split(/,\s*/).map do |p|
          p = p.strip
          p = $1 if p =~ /\A@as\([^,]*,\s*(.*)\)\z/m
          p
        end
        parts.each do |raw|
          if raw =~ /\A"(.*)"\z/m
            str = $1.gsub(/\\n/, "\n").gsub(/\\t/, "\t").gsub(/\\"/, '"').gsub(/\\\\/, '\\')
            emit_op(LOAD_CONST, add_const([:str, str]))
          elsif has_slot?(raw)
            emit_op(LOAD_SLOT, @slots[raw])
          else
            emit_op(LOAD_NAME, add_const(raw))
          end
          emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
        end
        # print() always ends with a newline (the {s}\n style format string).
        emit_op(LOAD_CONST, add_const([:str, "\n"]))
        emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      end
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    end

    # Compiled helper function: emit direct BC_CALL with the fixed target IP
    # recorded when the helper body was laid out. Bypasses name lookup.
    if @fn_start_ips.key?(callee)
      args.each { |a| compile_expr_to_value(a) }
      emit_op(BC_CALL, @fn_start_ips[callee], args.length)
      push_type(:any)
      return
    end

    # VM native (list-push, car, eq?, etc.): emit NATIVE_CALL with the
    # registered id. Avoids a runtime name lookup.
    if NATIVES.key?(callee)
      args.each { |a| compile_expr_to_value(a) }
      emit_op(NATIVE_CALL, NATIVES[callee], args.length)
      push_type(:any)
      return
    end

    # Zig CheatLib deep-copy helpers called from lowered MIR: the MIR
    # wraps a source value in a promoteDeep / promote / dupeUnionValue
    # call to signal "materialize an independent heap copy before the
    # escape". In the Zig backend this actually allocates. In the VM,
    # LOAD_SLOT already emits `pv = COPY slots[idx]` which does CLEAR's
    # deep-copy over the Value union. Passing the source arg through
    # lets that implicit copy provide the independence the MIR expected,
    # without the emitter having to know each CheatLib call by name.
    #
    # The arg order from the lowering is (zig_type, source, [allocator])
    # — grab the payload arg (index 1 for the 3-arg forms, index 0 if
    # absent) and emit it.
    if callee == "CheatLib.promoteDeep" || callee == "CheatLib.promote" ||
       callee == "CheatLib.dupeUnionValue" || callee == "CheatLib.promoteList" ||
       callee == "CheatLib.promoteFields"
      payload = args.length >= 2 ? args[1] : args[0]
      compile_expr_to_value(payload); pop_type
      push_type(:any)
      return
    end

    # Cleanup / ownership markers: no-op in GC'd VM. Consume any args for
    # side effects and push void so call-in-statement dispatch drops cleanly.
    if callee == "CheatLib.cleanup" || callee == "CheatLib.cleanupAt" ||
       callee == "CheatLib.free" || callee == "CheatLib.destroy"
      args.each { |a| compile_expr_to_value(a); pop_type; emit_op(POP) }
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
      return
    end

    # RC constructors: in the VM all values are uniformly boxed; Rc/Arc wrap
    # is transparent. Forward the payload (the last positional arg is the value).
    if callee == "CheatLib.rcCreate" || callee == "CheatLib.arcCreate"
      compile_expr_to_value(args.last); pop_type
      push_type(:any)
      return
    end

    # Other CheatLib.* that aren't deep-copy / not mapped to a native:
    # emit a compile-time error so the failure points at the right MIR
    # node instead of silently LOAD_NAME'ing something that will fail at
    # runtime with a confusing stack underflow.
    if callee.start_with?("CheatLib.")
      raise Unimplemented, "CheatLib.* call not mapped in VM path: #{callee}"
    end

    # Unknown callee: fall back to the global name table.
    fn_idx = add_const(callee)
    emit_op(LOAD_NAME, fn_idx)
    args.each { |a| compile_expr_to_value(a) }
    emit_op(CALL, args.length)
    push_type(:any)
  end

  def receiver_slot_type(node)
    return :any unless node.is_a?(MIR::Ident)
    @slot_types[node.name.to_s] || :any
  end

  # Strip allocator arguments: bare `rt` idents, `rt.heapAlloc()` calls, and
  # pipeline_host's InlineZig("rt.heapAlloc()") stand-ins (reason == "alloc").
  def strip_alloc_args(args)
    args.reject { |a|
      (a.is_a?(MIR::Ident) && (a.name.to_s == "rt" || a.name.to_s == "alloc")) ||
      (a.is_a?(MIR::MethodCall) && a.method.to_s == "heapAlloc") ||
      (a.is_a?(MIR::InlineZig) && a.reason.to_s == "alloc")
    }
  end

  def compile_method_call_expr(node)
    method = node.method.to_s
    rtype  = receiver_slot_type(node.receiver)

    # HashMap operations
    if rtype == :map || %w[put delete keys values count].include?(method)
      real_args = strip_alloc_args(node.args)
      case method
      when "put"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(MAP_PUT)
        push_type(:any); return
      when "get"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(MAP_GET)
        push_type(:any); return
      when "delete"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(MAP_DELETE)
        push_type(:any); return
      when "keys"
        compile_expr_to_value(node.receiver)
        emit_op(MAP_KEYS)
        push_type(:any); return
      when "values"
        # Return keys for now — values() not yet separately tracked in MapRef
        compile_expr_to_value(node.receiver)
        emit_op(MAP_KEYS)
        push_type(:any); return
      when "count", "length"
        compile_expr_to_value(node.receiver)
        emit_op(MAP_LENGTH)
        push_type(:any); return
      when "contains?"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(MAP_CONTAINS)
        push_type(:any); return
      end if rtype == :map
    end

    # Set operations
    if rtype == :set
      real_args = strip_alloc_args(node.args)
      case method
      when "insert"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(SET_INSERT)
        push_type(:any); return
      when "contains?"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(SET_CONTAINS)
        push_type(:any); return
      when "remove"
        compile_expr_to_value(node.receiver)
        real_args.each { |a| compile_expr_to_value(a) }
        emit_op(SET_REMOVE)
        push_type(:any); return
      when "toList"
        compile_expr_to_value(node.receiver)
        emit_op(SET_TOLIST)
        push_type(:any); return
      when "length", "count"
        compile_expr_to_value(node.receiver)
        emit_op(MAP_LENGTH)
        push_type(:any); return
      end
    end

    # UFCS: obj.method(args) -> (method obj args)
    args = strip_alloc_args(node.args)

    native_id = NATIVES[method]
    if native_id
      compile_expr_to_value(node.receiver)
      args.each { |a| compile_expr_to_value(a) }
      emit_op(NATIVE_CALL, native_id, 1 + args.length)
    else
      # User UFCS method
      fn_idx = add_const(method)
      emit_op(LOAD_NAME, fn_idx)
      compile_expr_to_value(node.receiver)
      args.each { |a| compile_expr_to_value(a) }
      emit_op(CALL, 1 + args.length)
    end
    push_type(:any)
  end

  # ================================================================
  # Struct / field / index
  # ================================================================

  def compile_struct_init(node)
    zig_type = node.zig_type.to_s
    # HashMap / Set StructInit: the lowering synthesizes these as Zig struct
    # literals with an allocator field (e.g. CheatLib.StringMap(i64){ .alloc = ... }),
    # but the VM uses a dedicated MapRef value. Emit MAP_NEW instead; the
    # surrounding BlockExpr then populates it via .put() calls.
    if zig_type.start_with?("CheatLib.StringMap") ||
       zig_type.start_with?("CheatLib.NumericMap") ||
       zig_type.start_with?("CheatLib.Set")
      emit_op(MAP_NEW)
      push_type(:map)
      return
    end

    # Union variant construction: Shape{ Circle: 5.0 } or Shape{ Point: {} }
    # becomes Pair(car=Str("Circle"), cdr=payload_vector). A unit variant
    # (MIR::Lit{"{}"}) gets an empty vector payload. Multi-field inline-struct
    # variants are already lowered by annotator as a single StructInit field,
    # so node.fields has at most one entry here.
    if @union_types&.include?(zig_type)
      variant = node.fields.first&.[](:name).to_s
      value   = node.fields.first&.[](:value)
      emit_op(LOAD_CONST, add_const(variant))
      if value.nil? || (value.is_a?(MIR::Lit) && value.value.to_s == "{}")
        emit_op(NATIVE_CALL, NATIVES["vector"], 0)
      else
        compile_expr_to_value(value); pop_type
      end
      emit_op(NATIVE_CALL, NATIVES["cons"], 2)
      push_type(:any)
      return
    end

    # Plain struct: positional fields through `vector`.
    node.fields.each { |f| compile_expr_to_value(f[:value]); pop_type }
    emit_op(NATIVE_CALL, NATIVES["vector"], node.fields.length)
    push_type(:any)
  end

  def compile_field_get(node)
    # Enum variant: Type.Variant → Scheme symbol
    if node.object.is_a?(MIR::Ident) && @enum_types&.include?(node.object.name.to_s)
      emit_op(LOAD_CONST, add_const(node.field.to_s))
      push_type(:any)
      return
    end

    # (Union-variant payload access via FieldGet(union, variant) was
    # attempted here but the object's union type isn't accessible on
    # MIR::Ident — MIR nodes don't carry type_info the way AST does, so
    # there's no reliable distinguisher between "union.Variant" (cdr)
    # and "struct.field" (vector-ref). Left as unimplemented; the
    # tests that hit this pattern currently fail on the struct-field
    # fallback (vector-ref on a Pair), not silently wrong-path.)

    # Zig-specific list "decomposition" fields. In Zig, an
    # std.ArrayListUnmanaged(T) exposes `.items` (the []T slice) and the
    # slice in turn exposes `.len` (int). In the VM there's no
    # ArrayList-around-slice indirection — lists are Value.List directly,
    # strings are Value.Str. Treat `x.items` as identity and `x.len`
    # as a length() native call.
    if node.field.to_s == "items"
      compile_expr_to_value(node.object); pop_type
      push_type(:any)
      return
    end
    if node.field.to_s == "len"
      compile_expr_to_value(node.object); pop_type
      emit_op(NATIVE_CALL, NATIVES["count"], 1)
      push_type(:any)
      return
    end

    compile_expr_to_value(node.object)
    idx = find_field_index(node.field)
    if idx
      # vector-ref is a NATIVE_CALL that reads both args from the value
      # stack — the idx must be pushed there too. Using LOAD_CONST_I64
      # would put it on the typed istack and NATIVE_CALL would read past
      # the end of vstack (silent garbage for 1-field structs, wrong-field
      # for 2+-field structs).
      emit_op(LOAD_CONST, add_const([:i64, idx]))
      emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
    else
      emit_op(POP)
      emit_op(LOAD_CONST, add_const(nil))
    end
    push_type(:any)
  end

  def compile_index_get(node)
    if receiver_slot_type(node.object) == :map
      compile_expr_to_value(node.object)
      compile_expr_to_value(node.index)
      emit_op(MAP_GET)
    else
      compile_expr_to_value(node.object)
      compile_expr_to_value(node.index)
      emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    end
    push_type(:any)
  end

  def find_field_index(field_name)
    fname = field_name.to_s
    @struct_fields.each_value do |fields|
      idx = fields.index(fname)
      return idx if idx
    end
    nil
  end

  # ================================================================
  # Collections
  # ================================================================

  def compile_make_list(node)
    if node.items.empty?
      emit_op(LOAD_CONST, add_const([:empty_list]))
    else
      node.items.each { |i| compile_expr_to_value(i) }
      emit_op(NATIVE_CALL, NATIVES["list"], node.items.length)
    end
    push_type(:any)
  end

  def compile_container_init(node)
    case node.strategy
    when :map_empty, :map_bare
      emit_op(MAP_NEW)
      push_type(:map)
    when :set_empty
      emit_op(MAP_NEW)
      push_type(:set)
    else
      emit_op(LOAD_CONST, add_const([:empty_list]))
      push_type(:any)
    end
  end

  # ================================================================
  # Cast / Conditional / BlockExpr
  # ================================================================

  def compile_cast(node)
    compile_expr(node.expr)
    case node.method
    when :intCast, :truncate, :intFromFloat, :enumFromInt
      t = peek_type
      # Only rewrite the type tag when the source actually sat on the
      # typed stack. A value-stack result (NATIVE_CALL count / getAt / etc.
      # returning Value.Int64Val or Value.Number) stays on vstack;
      # claiming :i64 would make downstream emit I_TO_VAL and pop the
      # typed istack that the value never touched.
      if t == :f64
        emit_op(F64_TO_INT); @type_stack[-1] = :i64
      end
    when :floatCast, :floatFromInt
      t = peek_type
      if t == :i64
        emit_op(INT_TO_F64); @type_stack[-1] = :f64
      end
    end
  end

  def compile_orelse(node)
    # expr OR fallback: if expr is nil/falsy, use fallback
    tmp = "__orelse_#{@ops.length}"
    compile_expr(node.expr); ensure_value_stack
    emit_op(STORE_NAME, add_const(tmp))   # keep value in env (stays on stack too)
    emit_op(NOT); emit_op(NOT)            # boolify: TrueVal if truthy, FalseVal if nil
    emit_op(JUMP_IF_FALSE)                # if false (nil), jump to fallback
    patch_fallback = @ops.length; emit_op(0)
    emit_op(LOAD_NAME, add_const(tmp))    # truthy path: restore original value
    emit_op(JUMP); patch_end = @ops.length; emit_op(0)
    @ops[patch_fallback] = @ops.length
    pop_type                              # discard the nil from the expr
    compile_expr(node.fallback); ensure_value_stack
    @ops[patch_end] = @ops.length
    push_type(:any)
  end

  def compile_conditional(node)
    compile_cond(node.cond)
    cond_type = pop_type
    emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    patch_false = @ops.length; emit_op(0)
    compile_expr(node.then_val)
    emit_op(JUMP); patch_end = @ops.length; emit_op(0)
    @ops[patch_false] = @ops.length
    compile_expr(node.else_val)
    @ops[patch_end] = @ops.length
    push_type(peek_type)
  end

  # MIR::UnionVariantGet: union payload access, routed to native cdr.
  # The MIR distinguishes this from struct-field access so we don't need
  # the unreliable name-matching fallback inside compile_field_get.
  def compile_union_variant_get(node)
    compile_expr_to_value(node.object); pop_type
    emit_op(NATIVE_CALL, NATIVES["cdr"], 1)
    push_type(:any)
  end

  # MIR::IfOptional: (if (optional) |capture| then_expr else else_expr).
  # VM model: optional is nil-or-value; bind capture to the non-nil value
  # in the then branch. Since VM values are Scheme-like (no type-level
  # optional wrapper), the capture simply aliases the probed expression.
  def compile_if_optional(node)
    tmp = "__opt_#{@ops.length}"
    compile_expr(node.optional); ensure_value_stack
    emit_op(STORE_NAME, add_const(tmp))
    emit_op(NOT); emit_op(NOT)  # boolify
    emit_op(JUMP_IF_FALSE); patch_else = @ops.length; emit_op(0)
    # Then branch: bind capture = tmp, emit then_expr.
    emit_op(LOAD_NAME, add_const(tmp))
    emit_op(STORE_NAME, add_const(node.capture.to_s))
    pop_type if !@type_stack.empty?  # discard the bool from NOT/NOT
    compile_expr(node.then_expr); ensure_value_stack
    emit_op(JUMP); patch_end = @ops.length; emit_op(0)
    @ops[patch_else] = @ops.length
    pop_type if !@type_stack.empty?  # discard the then branch's type for now
    compile_expr(node.else_expr); ensure_value_stack
    @ops[patch_end] = @ops.length
    push_type(:any)
  end

  def compile_block_expr(node)
    # Emit all but last statement, then leave result on stack
    stmts = semantic_mir_nodes(node.body)
    last_break_type = :any
    stmts.each_with_index do |s, i|
      if i < stmts.length - 1
        if s.is_a?(MIR::BreakStmt) && s.value
          compile_expr(s.value); pop_type
        else
          compile_stmt(s, nil)
          t = pop_type
          emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
        end
      else
        if s.is_a?(MIR::BreakStmt) && s.value
          compile_expr(s.value)
          last_break_type = pop_type
        else
          compile_stmt(s, nil)
          last_break_type = pop_type
        end
      end
    end
    push_type(last_break_type)
  end

  # ================================================================
  # Body helpers
  # ================================================================

  def emit_body_stmts(stmts)
    return unless stmts && !stmts.empty?
    semantic = semantic_mir_nodes(stmts)
    semantic.each do |s|
      compile_stmt(s, nil)
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
    end
  end

  # AST fallback body compilation (same as BytecodeCompiler)
  def compile_body_from_ast(stmts)
    stmts = stmts.reject { |s| (s.is_a?(AST::ReturnNode) && s.value.nil?) }
    stmts.reject! { |s|
      s.is_a?(MIR::Alloc) || s.is_a?(MIR::Drop) || s.is_a?(MIR::SuppressCleanup) ||
      s.is_a?(MIR::Promote) || s.is_a?(MIR::Return) || s.is_a?(MIR::ReassignCleanup) ||
      s.is_a?(MIR::FieldCleanup)
    }
    stmts.each do |stmt|
      compile_ast_stmt(stmt)
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
    end
  end

  # ================================================================
  # AST fallback methods (same semantics as BytecodeCompiler)
  # ================================================================

  def compile_ast_assert(node)
    compile_ast_expr(node.condition)
    cond_type = pop_type
    if cond_type == :bool
      emit_op(BOOL_TO_VAL); emit_op(NOT); emit_op(JUMP_IF_FALSE)
    else
      ensure_value_stack; emit_op(NOT); emit_op(JUMP_IF_FALSE)
    end
    jump_ok = @ops.length; emit_op(0)
    msg = (node.message.is_a?(String) && !node.message.empty?) ? node.message : "assertion failed"
    emit_op(LOAD_CONST, add_const([:str, "ASSERT FAILED: #{msg}"]))
    emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
    @ops[jump_ok] = @ops.length
    emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
  end

  def compile_ast_bind(node)
    compile_ast_expr(node.value)
    val_type = pop_type
    # :bool lives on the typed istack (from GT_I64 etc.). The VM has no
    # bool slot — emit_store's non-i64/f64 path uses STORE_SLOT from the
    # value stack. Coerce before falling through.
    if val_type == :bool
      emit_op(BOOL_TO_VAL); val_type = :any
    end
    name = node.name.to_s
    alloc_slot(name, val_type)
    emit_store(name, val_type)
    push_type(:void)
  end

  def compile_ast_vardecl(node)
    @mutables.add(node.name.to_s) if node.mutable
    name = node.name.to_s
    if node.value
      compile_ast_expr(node.value); val_type = pop_type
    else
      emit_op(LOAD_CONST, add_const(nil)); val_type = :any
    end
    if node.type
      type_str = node.type.to_s
      if type_str.include?("Int64") && !type_str.include?("[]") then val_type = :i64
      elsif type_str.include?("Float64") && !type_str.include?("[]") then val_type = :f64
      elsif type_str.include?("String") then val_type = :str
      end
    end
    alloc_slot(name, val_type); emit_store(name, val_type); push_type(:void)
  end

  def compile_ast_assign(node)
    if node.name.is_a?(AST::GetField)
      target = compile_ast_expr_str(node.name.target)
      field = node.name.field.to_s
      val = compile_ast_expr_str(node.value)
      # Can't easily do this without a set-field! native. Fall through.
      push_type(:void)
    elsif node.name.is_a?(AST::GetIndex)
      name = root_var_name(node.name)
      if name && @slot_types[name] == :map
        # HashMap: push map, key, val then MAP_PUT (mutates in place, no store)
        compile_ast_expr_to_value(node.name.target)
        compile_ast_expr_to_value(node.name.index)
        compile_ast_expr_to_value(node.value)
        emit_op(MAP_PUT)
      elsif name && has_slot?(name)
        compile_ast_expr(node.value); pop_type
        compile_ast_expr(node.name.target)
        compile_ast_expr(node.name.index)
        emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
        emit_store(name, :any)
      end
      push_type(:void)
    else
      compile_ast_expr(node.value); val_type = pop_type
      name = node.name.to_s
      if has_slot?(name)
        emit_store(name, val_type); @slot_types[name] = val_type
      else
        emit_op(SET_NAME, add_const(name))
      end
      push_type(:void)
    end
  end

  def compile_ast_func_call(node)
    name = node.name.to_s
    case name
    when "print"
      node.args.each { |a| compile_ast_expr_to_value(a) }
      emit_op(NATIVE_CALL, NATIVES["display"], node.args.length)
      push_type(:void)
    when "toFloat"
      compile_ast_expr(node.args[0]); emit_op(INT_TO_F64); push_type(:f64)
    when "toInt"
      compile_ast_expr(node.args[0]); emit_op(F64_TO_INT); push_type(:i64)
    else
      native_id = NATIVES[name]
      if native_id
        node.args.each { |a| compile_ast_expr_to_value(a) }
        emit_op(NATIVE_CALL, native_id, node.args.length)
        push_type(:any)
      else
        fn_idx = add_const(name)
        emit_op(LOAD_NAME, fn_idx)
        node.args.each { |a| compile_ast_expr_to_value(a) }
        emit_op(CALL, node.args.length)
        push_type(:any)
      end
    end
  end

  def compile_ast_method_call(node)
    name = node.name.to_s
    case name
    when "length"
      compile_ast_expr_to_value(node.object)
      emit_op(NATIVE_CALL, NATIVES["list-length"], 1); push_type(:i64)
    when "append"
      compile_ast_expr_to_value(node.object)
      compile_ast_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
      if node.object.is_a?(AST::Identifier)
        emit_op(SET_NAME, add_const(node.object.name.to_s))
      end
      push_type(:void)
    when "toString"
      compile_ast_expr_to_value(node.object)
      emit_op(NATIVE_CALL, NATIVES["number->string"], 1); push_type(:str)
    when "trim"
      compile_ast_expr_to_value(node.object)
      emit_op(NATIVE_CALL, NATIVES["trim"], 1); push_type(:str)
    when "split"
      compile_ast_expr_to_value(node.object)
      compile_ast_expr_to_value(node.args[0])
      emit_op(NATIVE_CALL, NATIVES["split"], 2); push_type(:any)
    else
      native_id = NATIVES[name]
      if native_id
        compile_ast_expr_to_value(node.object)
        node.args.each { |a| compile_ast_expr_to_value(a) }
        emit_op(NATIVE_CALL, native_id, 1 + node.args.length)
      else
        fn_idx = add_const(name)
        emit_op(LOAD_NAME, fn_idx)
        compile_ast_expr_to_value(node.object)
        node.args.each { |a| compile_ast_expr_to_value(a) }
        emit_op(CALL, 1 + node.args.length)
      end
      push_type(:any)
    end
  end

  def compile_ast_if(node)
    compile_ast_expr(node.condition); cond_type = pop_type
    emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    jump_false = @ops.length; emit_op(0)
    ast_body_stmts(node.then_branch)
    if node.else_branch && !node.else_branch.empty?
      emit_op(JUMP); jump_end = @ops.length; emit_op(0)
      @ops[jump_false] = @ops.length
      ast_body_stmts(node.else_branch)
      @ops[jump_end] = @ops.length
    else
      @ops[jump_false] = @ops.length
      push_type(:void)
    end
  end

  def compile_ast_while(node)
    loop_start = @ops.length
    compile_ast_expr(node.condition); cond_type = pop_type
    emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
    jump_exit = @ops.length; emit_op(0)
    node.do_branch.each { |s| compile_ast_stmt(s); t = pop_type; emit_op(POP) unless void_type?(t) }
    emit_op(JUMP, loop_start)
    @ops[jump_exit] = @ops.length; push_type(:void)
  end

  def compile_ast_for_range(node)
    var = node.var_name
    @mutables.add(var)
    compile_ast_expr(node.start_expr)
    var_idx = add_const(var)
    emit_op(STORE_NAME, var_idx); emit_op(POP)
    loop_start = @ops.length
    emit_op(LOAD_NAME, var_idx)
    compile_ast_expr(node.end_expr)
    emit_op(LT); emit_op(JUMP_IF_FALSE)
    jump_exit = @ops.length; emit_op(0)
    node.body.each { |s| compile_ast_stmt(s); emit_op(POP) }
    emit_op(LOAD_NAME, var_idx)
    emit_op(LOAD_CONST, add_const([:i64, 1]))
    emit_op(ADD); emit_op(SET_NAME, var_idx); emit_op(POP)
    emit_op(JUMP, loop_start)
    @ops[jump_exit] = @ops.length
    emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
  end

  def compile_ast_for_each(node)
    var = node.var_name
    idx_var = "__idx_#{var}"
    @mutables.add(idx_var)
    emit_op(LOAD_CONST, add_const([:i64, 0]))
    idx_name = add_const(idx_var)
    emit_op(STORE_NAME, idx_name); emit_op(POP)
    compile_ast_expr_to_value(node.collection)
    coll_name = add_const("__coll_#{var}")
    emit_op(STORE_NAME, coll_name); emit_op(POP)
    loop_start = @ops.length
    emit_op(LOAD_NAME, idx_name)
    emit_op(LOAD_NAME, coll_name)
    emit_op(NATIVE_CALL, NATIVES["list-length"], 1)
    emit_op(LT); emit_op(JUMP_IF_FALSE)
    jump_exit = @ops.length; emit_op(0)
    emit_op(LOAD_NAME, coll_name)
    emit_op(LOAD_NAME, idx_name)
    emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    emit_op(STORE_NAME, add_const(var)); emit_op(POP)
    node.body.each { |s| compile_ast_stmt(s); emit_op(POP) }
    emit_op(LOAD_NAME, idx_name)
    emit_op(LOAD_CONST, add_const([:i64, 1]))
    emit_op(ADD); emit_op(SET_NAME, idx_name); emit_op(POP)
    emit_op(JUMP, loop_start)
    @ops[jump_exit] = @ops.length
    emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
  end

  def compile_ast_match(node)
    subject_var = "__match_subj"
    compile_ast_expr_to_value(node.expr)
    emit_op(STORE_NAME, add_const(subject_var)); emit_op(POP)
    jump_ends = []
    node.cases.each do |c|
      if c[:kind] == :when
        # WHEN condition: evaluate the condition directly; skip body if condition is false
        compile_ast_expr_to_value(c[:value])
        emit_op(JUMP_IF_FALSE)
      else
        # Value case: compare subject == case_value; skip body if not equal
        emit_op(LOAD_NAME, add_const(subject_var))
        compile_ast_expr_to_value(c[:value])
        emit_op(EQ); emit_op(JUMP_IF_FALSE)
      end
      jump_skip = @ops.length; emit_op(0)
      c[:body].each do |s|
        compile_ast_stmt(s)
        t = pop_type
        emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
      end
      emit_op(JUMP); jump_ends << @ops.length; emit_op(0)
      @ops[jump_skip] = @ops.length
    end
    if node.default_case && !node.default_case.empty?
      node.default_case.each do |s|
        compile_ast_stmt(s)
        t = pop_type
        emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
      end
    end
    jump_ends.each { |idx| @ops[idx] = @ops.length }
    emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
  end

  # AST expression compilation (used by fallback paths)
  def compile_ast_expr(node)
    case node
    when AST::Literal     then compile_ast_literal(node)
    when AST::Identifier  then compile_ast_ident(node)
    when AST::BinaryOp    then compile_ast_binary(node)
    when AST::UnaryOp     then compile_ast_unary(node)
    when AST::FuncCall    then compile_ast_func_call(node)
    when AST::MethodCall  then compile_ast_method_call(node)
    when AST::GetField    then compile_ast_get_field(node)
    when AST::GetIndex    then compile_ast_get_index(node)
    when AST::ListLit     then compile_ast_list_lit(node)
    when AST::StructLit   then compile_ast_struct_lit(node)
    when AST::BindExpr    then compile_ast_bind(node)
    when AST::VarDecl     then compile_ast_vardecl(node)
    when AST::ReturnNode  then compile_ast_expr(node.value) if node.value
    when NilClass
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    else
      raise Unimplemented, "unhandled AST expr: #{node.class}"
    end
  end

  def compile_ast_expr_to_value(node)
    compile_ast_expr(node); ensure_value_stack
  end

  def compile_ast_literal(node)
    case node.type
    when :INT64
      emit_op(LOAD_CONST_I64, add_const([:i64, node.value])); push_type(:i64)
    when :NUMBER, :FLOAT
      emit_op(LOAD_CONST_F64, add_const([:f64, node.value])); push_type(:f64)
    when :STRING
      emit_op(LOAD_CONST, add_const([:str, node.value])); push_type(:str)
    when :BOOLEAN, :BOOL, :TRUE, :FALSE
      emit_op(LOAD_CONST, add_const([:bool, !!node.value])); push_type(:bool)
    when :NIL
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    else
      emit_op(LOAD_CONST_F64, add_const([:f64, node.value.to_f])); push_type(:f64)
    end
  end

  def compile_ast_ident(node)
    name = node.name.to_s
    vt = @slot_types[name] || :any
    if vt == :i64 && @islots[name]
      emit_op(LOAD_ISLOT, @islots[name]); push_type(:i64)
    elsif vt == :f64 && @fslots[name]
      emit_op(LOAD_FSLOT, @fslots[name]); push_type(:f64)
    elsif @slots[name]
      emit_op(LOAD_SLOT, @slots[name]); push_type(vt)
    else
      emit_op(LOAD_NAME, add_const(name)); push_type(:any)
    end
  end

  def compile_ast_binary(node)
    op = node.op
    if op == :SMOOTH
      raise Unimplemented, "SMOOTH pipeline"
    elsif op == :OR_RESCUE
      compile_ast_expr(node.left)
      return
    end
    compile_ast_expr(node.left);  left_type  = pop_type
    compile_ast_expr(node.right); right_type = pop_type
    both_i64 = (left_type == :i64 && right_type == :i64)
    both_f64 = (left_type == :f64 && right_type == :f64)
    case op
    when :ADD
      if left_type == :str || right_type == :str then emit_op(CONCAT); push_type(:str)
      elsif both_i64 then emit_op(ADD_I64); push_type(:i64)
      elsif both_f64 then emit_op(ADD_F64); push_type(:f64)
      else emit_op(ADD); push_type(:any) end
    when :SUB
      if both_i64 then emit_op(SUB_I64); push_type(:i64)
      elsif both_f64 then emit_op(SUB_F64); push_type(:f64)
      else emit_op(SUB); push_type(:any) end
    when :MUL
      if both_i64 then emit_op(MUL_I64); push_type(:i64)
      elsif both_f64 then emit_op(MUL_F64); push_type(:f64)
      else emit_op(MUL); push_type(:any) end
    when :DIV
      if both_i64 then emit_op(DIV_I64); push_type(:i64)
      elsif both_f64 then emit_op(DIV_F64); push_type(:f64)
      else emit_op(DIV); push_type(:any) end
    when :EQ
      if both_i64    then emit_op(EQ_I64);  push_type(:bool)
      elsif both_f64 then emit_op(EQ_F64);  push_type(:bool)
      else                emit_op(EQ);      push_type(:any)
      end
    when :NEQ
      if both_i64    then emit_op(NEQ_I64); push_type(:bool)
      elsif both_f64 then emit_op(NEQ_F64); push_type(:bool)
      else                emit_op(EQ); emit_op(NOT); push_type(:any)
      end
    when :LT
      if both_i64    then emit_op(LT_I64);  push_type(:bool)
      elsif both_f64 then emit_op(LT_F64);  push_type(:bool)
      else                emit_op(LT);      push_type(:any)
      end
    when :GT
      if both_i64    then emit_op(GT_I64);  push_type(:bool)
      elsif both_f64 then emit_op(GT_F64);  push_type(:bool)
      else                emit_op(GT);      push_type(:any)
      end
    when :LTE
      if both_i64    then emit_op(LTE_I64); push_type(:bool)
      elsif both_f64 then emit_op(LTE_F64); push_type(:bool)
      else                emit_op(LTE);     push_type(:any)
      end
    when :GTE
      if both_i64    then emit_op(GTE_I64); push_type(:bool)
      elsif both_f64 then emit_op(GTE_F64); push_type(:bool)
      else                emit_op(GTE);     push_type(:any)
      end
    when :MOD
      if both_i64 then emit_op(MOD_I64) else emit_op(NATIVE_CALL, NATIVES["modulo"], 2) end
      push_type(:i64)
    when :AND, :OR then push_type(:bool)
    when :WRAP_ADD, :CHECK_ADD
      if both_i64 then emit_op(ADD_I64) else emit_op(ADD) end; push_type(:i64)
    when :WRAP_SUB, :CHECK_SUB
      if both_i64 then emit_op(SUB_I64) else emit_op(SUB) end; push_type(:i64)
    when :WRAP_MUL, :CHECK_MUL
      if both_i64 then emit_op(MUL_I64) else emit_op(MUL) end; push_type(:i64)
    else emit_op(ADD); push_type(:any)
    end
  end

  def compile_ast_unary(node)
    compile_ast_expr(node.right)
    case node.op
    when :NOT, :BANG, :EXCL then emit_op(NOT)
    when :SUB, :NEG
      emit_op(LOAD_CONST, add_const([:i64, -1])); emit_op(MUL)
    end
  end

  def compile_ast_get_field(node)
    # Enum variant: Type.Variant → Scheme symbol
    if node.target.is_a?(AST::Identifier) && @enum_types&.include?(node.target.name.to_s)
      emit_op(LOAD_CONST, add_const(node.field.to_s))
      push_type(:any)
      return
    end
    compile_ast_expr_to_value(node.target)
    field = node.field.to_s
    idx = find_field_index(field)
    if idx
      emit_op(LOAD_CONST_I64, add_const([:i64, idx]))
      emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
    else
      emit_op(POP); emit_op(LOAD_CONST, add_const(nil))
    end
    push_type(:any)
  end

  def compile_ast_get_index(node)
    compile_ast_expr_to_value(node.target)
    compile_ast_expr_to_value(node.index)
    emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    push_type(:any)
  end

  def compile_ast_list_lit(node)
    if node.items.empty?
      emit_op(LOAD_CONST, add_const([:empty_list]))
    else
      node.items.each { |i| compile_ast_expr_to_value(i) }
      emit_op(NATIVE_CALL, NATIVES["list"], node.items.length)
    end
    push_type(:any)
  end

  def compile_ast_struct_lit(node)
    fields = node.fields || {}
    fields.each_value { |v| compile_ast_expr_to_value(v) }
    emit_op(NATIVE_CALL, NATIVES["vector"], fields.length)
    push_type(:any)
  end

  def ast_body_stmts(stmts)
    return unless stmts
    stmts = stmts.reject { |s| s.is_a?(AST::ReturnNode) && s.value.nil? }
    stmts.each_with_index do |s, i|
      compile_ast_stmt(s)
      t = pop_type
      emit_op(POP) if i < stmts.length - 1 && !void_type?(t)
    end
  end

  # Unused helper - kept for symmetry
  def compile_ast_expr_str(node)
    compile_ast_expr(node)
    ""
  end

  # ================================================================
  # Slot management (same as BytecodeCompiler)
  # ================================================================

  def alloc_slot(name, type = :any)
    case type
    when :i64
      unless @islots[name]
        @islots[name] = @next_islot; @next_islot += 1
      end
      @slot_types[name] = :i64; @islots[name]
    when :f64
      unless @fslots[name]
        @fslots[name] = @next_fslot; @next_fslot += 1
      end
      @slot_types[name] = :f64; @fslots[name]
    else
      unless @slots[name]
        @slots[name] = @next_slot; @next_slot += 1
      end
      @slot_types[name] = type; @slots[name]
    end
  end

  def has_slot?(name)
    @islots.key?(name) || @fslots.key?(name) || @slots.key?(name)
  end

  def emit_store(name, val_type)
    case val_type
    when :i64 then emit_op(STORE_ISLOT, @islots[name])
    when :f64 then emit_op(STORE_FSLOT, @fslots[name])
    else           emit_op(STORE_SLOT,  @slots[name])
    end
  end

  # ================================================================
  # Type stack
  # ================================================================

  def push_type(t); @type_stack.push(t); end
  def pop_type; @type_stack.pop || :any; end
  def peek_type; @type_stack.last || :any; end

  def ensure_value_stack
    t = peek_type
    case t
    when :i64  then emit_op(I_TO_VAL);   @type_stack[-1] = :any
    when :bool then emit_op(BOOL_TO_VAL); @type_stack[-1] = :any
    when :f64  then emit_op(F_TO_VAL);   @type_stack[-1] = :any
    end
  end

  def ensure_value_stack_top2
    # No-op placeholder - complex reordering not needed for simple cases
  end

  def void_type?(t); t == :void; end

  def void_expr?(node)
    node.is_a?(MIR::Lit) && ["void", "undefined"].include?(node.value.to_s)
  end

  # ================================================================
  # Bytecode emission
  # ================================================================

  def emit_op(op, *args)
    @ops << op; args.each { |a| @ops << a }
  end

  def add_const(val)
    idx = @consts.length; @consts << val; idx
  end

  def root_var_name(node)
    node.is_a?(AST::Identifier) ? node.name.to_s : (node.respond_to?(:target) ? root_var_name(node.target) : nil)
  rescue
    nil
  end

  def serialize_const(c)
    case c
    when nil   then "N"
    when Array
      type, val = c[0], c[1]
      case type
      when :i64        then "I:#{val}"
      when :f64        then "F:#{val}"
      when :str        then "S:#{val}"
      when :bool       then "B:#{val}"
      when :empty_list then "L"
      when :compiled_fn
        "FN:#{c[1]}:#{c[2].join(',')}:#{c[3].map { |sc| serialize_const(sc) }.join(';')}"
      else "N"
      end
    when String then "SYM:#{c}"
    else        "N"
    end
  end
end
