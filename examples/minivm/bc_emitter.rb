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
  FIBER_RET   = 81
  BG_SPAWN    = 82
  AWAIT       = 83
  VAL_TO_I64  = 84  # vstack Value → istack Int64 (via getInt)
  VAL_TO_F64  = 85  # vstack Value → fstack Float64 (via getNum)
  IS_ERR      = 86  # pop vstack Value, push Value.TrueVal if Value.Error else FalseVal
  PUSH_ERR    = 87  # push a Value.Error{errMsg:"", errKind:"runtime"} sentinel
  RAISE_ERR   = 88  # pop msg+kind strings, push Value.Error{errMsg=msg, errKind=kind}
  GET_ERR_KIND = 89 # peek top Value.Error, push Value.Str(errKind)
  # Wrapping i64 arithmetic for `%+`, `%-`, `%*` (RNGs / hashes that
  # intentionally overflow). Distinct from the panicking ADD_I64/SUB_I64/MUL_I64.
  WRAP_ADD_I64 = 90
  WRAP_SUB_I64 = 91
  WRAP_MUL_I64 = 92
  # LIST_REMOVE_AT: pop list + idx, rebuild list without that index, push
  # both the new list AND the removed element. Caller stores the new list
  # back to the source binding and keeps the element on the stack as the
  # expression's value. This is what `xs.remove(i)` should do — the VM's
  # Value.List is value-typed so a non-rebuilding list-ref couldn't model
  # the side effect.
  LIST_REMOVE_AT = 93
  # LIST_POP_LAST: pop list, push (shrunk_list, popped_elem). If list is
  # empty, popped_elem is Value.Nil. Used by `xs.pop()` so callers can
  # store the shrunk list back through the same chain-set machinery as
  # remove(idx).
  LIST_POP_LAST = 94
  # MAP_VALUES: pop map, push List of Value (the map's values in iteration
  # order). Used by HashMap.values() in BC mode.
  MAP_VALUES = 95

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
    "list-pop" => 107, "iota" => 108, "slice" => 109, "slice-from" => 110,
    "intMin" => 111,
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
    @block_break_patches = nil   # Array of op indices for MIR::BreakStmt(value) -> block-expr exit
    @block_break_types   = nil   # Parallel array of typed-stack residencies for each break value
  end

  def compile(program)
    # Build struct field list from result schemas (field order matters for
    # vector-ref index). Schema shape varies: Hash{name=>{type,...}} from the
    # annotator, or Array of field specs from older paths. Normalize both.
    @struct_defaults = {}  # { "Name" => [default_ast_or_nil, ...] in field order }
    (@result.struct_schemas || {}).each do |name, fields|
      sname = name.to_s
      case fields
      when Hash
        @struct_fields[sname]   = fields.keys.map(&:to_s)
        @struct_defaults[sname] = fields.values.map { |spec| spec.is_a?(Hash) ? spec[:default] : nil }
      when Array
        @struct_fields[sname] = fields.map { |f| f.is_a?(Hash) ? f[:name].to_s : f.to_s }
        @struct_defaults[sname] = fields.map { |f| f.is_a?(Hash) ? f[:default] : nil }
      else
        @struct_fields[sname] = []
        @struct_defaults[sname] = []
      end
    end

    # Track enum type names so field access emits symbols (not nil)
    @enum_types = Set.new((@result.enum_schemas || {}).keys.map(&:to_s))
    @union_types = Set.new((@result.union_schemas || {}).keys.map(&:to_s))

    # All union-variant tag names across every UNION. The VM represents a
    # union value as Pair(car=Symbol("Variant"), cdr=payload). MATCH-capture
    # binds the payload via FieldGet(union, "Variant"), which must lower to
    # cdr(obj). Without this set, FieldGet falls through to vector-ref(obj,
    # find_field_index("Variant")), which returns Nil for non-inline-struct
    # variants (the payload Pair has no field named "Variant"). Building
    # the set up front gives an O(1) check inside compile_field_get.
    @union_variant_names = Set.new
    (@result.union_schemas || {}).each do |_uname, variants|
      (variants || {}).each_key { |vname| @union_variant_names << vname.to_s }
    end
    # Don't shadow any registered struct field names (a non-inline-struct
    # union variant doesn't put fields into @struct_fields, so the only
    # collision is between two ad-hoc names — keep struct semantics in
    # that case).
    flat_struct_fields = Set.new
    @struct_fields.each_value { |fs| fs.each { |f| flat_struct_fields << f.to_s } }
    @union_variant_names -= flat_struct_fields

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

    # Build a `name -> comptime_params count` map so call sites can strip
    # the leading type-arg Idents that the lowering injects for generic
    # functions (`identity<f64>(42.0)` -> Call("identity", [Ident("f64"), 42.0])).
    # The VM is dynamically typed, so type args are dead weight; without
    # stripping, `identity` would receive "f64" in slot 0 and the actual
    # value in slot 1.
    @fn_comptime_arity = {}
    fns.each do |f|
      n = (f.respond_to?(:comptime_params) ? (f.comptime_params || []) : []).length
      next if n == 0
      @fn_comptime_arity[f.name.to_s] = n
    end

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

  # Separate accessors for the two output files. bc_run.rb writes ops and
  # consts to distinct paths; previously it split serialize()'s output by
  # `\n`, which corrupted any S: const containing a newline byte. The
  # const blob may now embed real newlines inside S:LEN:BYTES records,
  # so callers MUST NOT split it by line.
  def serialize_ops_blob; @ops.join(","); end
  def serialize_consts_blob; @consts.map { |c| serialize_const(c) }.join("\n"); end

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
    direct = @fn_nodes[name.to_sym] || @fn_nodes[name] ||
             @fn_nodes["#{name}!".to_sym] || @fn_nodes["#{name}!"]
    return direct if direct
    # `__<X>_body` is the inner half of the CATCH-grammar pair; the AST is
    # the user-facing fn `X`. Strip the wrapper prefix/suffix so the
    # paired-walk lookup finds the real body.
    if name.to_s =~ /\A__(.+)_body\z/
      base = $1
      direct = @fn_nodes[base.to_sym] || @fn_nodes[base] ||
               @fn_nodes["#{base}!".to_sym] || @fn_nodes["#{base}!"]
      return direct if direct
    end
    if MAIN_NAMES.include?(name)
      return @fn_nodes[:main] || @fn_nodes["main"] ||
             @fn_nodes[:cheatMain] || @fn_nodes["cheatMain"] ||
             @fn_nodes[:clearMain] || @fn_nodes["clearMain"]
    end
    nil
  end

  # Compile a non-main helper function into the shared op stream, isolated
  # from main's slot tables. Records @fn_start_ips[name] so call sites can
  # emit BC_CALL with a fixed target IP.
  def compile_helper_fn_mir(mir_fn)
    name   = mir_fn.name.to_s
    # Comptime-instantiated MIR::FnDef nodes have no AST counterpart and
    # no runtime equivalent: they're Zig's "fn returning a type" pattern
    # for generic structs/unions/fns (e.g. `Pair(T)`, `Option(T)`) and
    # the synthesized closure helpers the lowering generates around
    # try/catch and union-arm handlers (`__caseA_body`, `__processUser_body`,
    # `__handleWithCatch_body`, etc.). The Zig backend specializes them at
    # call sites; the VM has no comptime, so just drop them — call sites
    # that try to BC_CALL them won't find an entry in @fn_start_ips and
    # fall through to the LOAD_NAME slow path (which is also dead because
    # these names don't exist at runtime). Tests that *actually* call the
    # generic at runtime will fail later with a clear error.
    ast_fn = mir_fn.instance_variable_get(:@ast_fn) if mir_fn.respond_to?(:instance_variable_get)
    ast_fn ||= lookup_ast_fn(name)
    if ast_fn.nil?
      return
    end
    # User-defined generic functions like `FN identity<T>(x: T) RETURNS T`
    # have non-empty comptime_params but DO have a real AST body that we
    # can compile type-erased -- the VM is dynamically typed so the type
    # parameter T is irrelevant at runtime. Type-returning generators
    # (`Pair(T)` -> Zig type) have no AST body and should still be skipped;
    # detect them by their body shape (single InlineZig "type emit" or
    # single ReturnStmt with a type expression).
    if mir_fn.respond_to?(:comptime_params) && mir_fn.comptime_params &&
       !mir_fn.comptime_params.empty?
      body = mir_fn.respond_to?(:body) ? (mir_fn.body || []) : []
      type_generator = body.empty? || (body.length == 1 && body.first.is_a?(MIR::InlineZig))
      return if type_generator
    end
    # MIR::CatchWrapper-only bodies are the user-facing wrappers around a
    # `__<name>_body` inner helper. The wrapper's body parses the inner
    # call + per-clause kind matchers from the embedded Zig source.
    # We compile this entry directly without AST pairing (the AST has the
    # full CATCH-grammar source, but the wrapper's MIR is structural).
    body = mir_fn.respond_to?(:body) ? (mir_fn.body || []) : []
    if body.length == 1 && body.first.is_a?(MIR::CatchWrapper)
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
      ast_param_types = ast_param_vm_types(ast_fn)
      (mir_fn.params || []).each do |p|
        pname = p.respond_to?(:name) ? p.name.to_s : p.to_s
        next if pname == "rt"
        base_name = pname.start_with?("_m_") ? pname[3..] : pname
        alloc_slot(pname, ast_param_types[base_name] || :any)
      end
      compile_catch_wrapper(body.first); pop_type
      emit_op(BC_RET_VOID) unless @helper_fn_returned
      @slots = saved[:slots]; @islots = saved[:islots]; @fslots = saved[:fslots]
      @slot_types = saved[:slot_types]; @mutables = saved[:mutables]
      @next_slot = saved[:next_slot]; @next_islot = saved[:next_islot]
      @next_fslot = saved[:next_fslot]; @type_stack = saved[:type_stack]
      @in_helper_fn = false
      @helper_fn_returned = false
      return
    end
    # Synthesized closure helpers (`__caseA_body`, `__handleWithCatch_body`,
    # `__processUser_body`, ...) likewise have no AST counterpart -- the
    # lowering generates them around try/catch / OR-fallback / union-arm
    # bodies. lookup_ast_fn typically resolves them to an unrelated user
    # fn, which causes MIR/AST length mismatches when compiled. The exception
    # is `__<userFn>_body` which carries the real CATCH-grammar logic --
    # the AST that lookup_ast_fn finds for it (the wrapper's user-fn) IS
    # the right body. Detect that case by checking if the AST shape pairs.
    if name.start_with?("__") && name.end_with?("_body")
      # Allow it through; the MIR body shape should pair with the AST.
    elsif name.start_with?("__")
      return
    end

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
    #
    # Stamp the slot type from the AST param's declared type when known
    # (HashMap -> :map, Set -> :set). MIR drops the user-facing type into
    # `zig_type = "anytype"` for comptime-polymorphic params, so we'd lose
    # the dispatch hint without consulting the AST. Without the stamp,
    # `map[key] = val` inside a `MUTABLE map: HashMap<...>` callee would
    # fall through to list-set! (default :any path) and corrupt the map.
    ast_param_types = ast_param_vm_types(ast_fn)
    (mir_fn.params || []).each do |p|
      pname = p.respond_to?(:name) ? p.name.to_s : p.to_s
      next if pname == "rt"
      base_name = pname.start_with?("_m_") ? pname[3..] : pname
      alloc_slot(pname, ast_param_types[base_name] || :any)
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

    # Pre-pass: harvest `name -> struct_base` from MIR::AllocMark nodes so
    # compile_let can stamp `:struct_<Base>` on slots whose initializer is
    # a function call (which otherwise pushes :any and loses dispatch
    # info). Without this, `h1.items` against a struct returned from a
    # helper would fall through the .items short-circuit (treating it as
    # the Zig ArrayList wrapper identity) and assertion-side counts would
    # see h1 instead of h1.items.
    @alloc_struct_hints ||= {}
    walk_for_alloc_marks(mir_body)

    # Ownership-only MIR nodes (MoveMark) and synthetic hoisted temps
    # (__hpt_N / __tmp_N Lets) have no AST counterpart -- the lowering
    # inserts them for HPT lifting and ownership tracking. Compile them
    # without consuming an AST stmt so the remaining MIR stmts still
    # pair 1:1 with AST stmts.
    synthetic_only = ->(n) {
      n.is_a?(MIR::MoveMark) ||
      (n.is_a?(MIR::Let) && n.name.to_s =~ /\A__(hpt|tmp)_\d+\z/) ||
      # Lowering inserts `MIR::Let name=X init=Ident("_m_X")` at the top of
      # any helper fn body that has a MUTABLE param: it renames the param to
      # `_m_X` and then re-binds `X = _m_X` so the user-visible name is the
      # mutable handle. The Let is real (allocates a slot + copies), but
      # has no AST counterpart -- the param name is `X` in the source.
      (n.is_a?(MIR::Let) && n.init.is_a?(MIR::Ident) &&
       n.init.name.to_s == "_m_#{n.name}") ||
      # @nonReentrant / @reentrant lowering injects a StackGuard at fn entry:
      #   Let _guard = safety.StackGuard.enter(@src)
      #   _guard.push()
      # The matching pop is in a DeferStmt (already skipped). The VM has
      # no StackGuard machinery; treat all three as synthetic so they
      # don't break the MIR/AST pairing.
      (n.is_a?(MIR::Let) && n.name.to_s == "_guard") ||
      (n.is_a?(MIR::ExprStmt) && n.expr.is_a?(MIR::MethodCall) &&
       n.expr.receiver.is_a?(MIR::Ident) &&
       n.expr.receiver.name.to_s == "_guard")
    }
    mir_paired = mir_stmts.reject(&synthetic_only)
    if mir_paired.length != ast_stmts.length
      raise Unimplemented, "MIR/AST length mismatch (#{mir_paired.length} vs #{ast_stmts.length})"
    end

    ast_cursor = 0
    mir_stmts.each do |mir_node|
      if synthetic_only.call(mir_node)
        compile_stmt(mir_node, nil)
        t = pop_type
        emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
        next
      end
      ast_node = ast_stmts[ast_cursor]; ast_cursor += 1
      compile_stmt(mir_node, ast_node)
      # Every top-level stmt should leave the vstack balanced. compile_stmt
      # leaves a type-stack entry per stmt; pop it and emit POP if the value
      # is on the (untyped) value stack. This catches stmt-position InlineBc
      # (e.g. `:assert` pushes :any nil) as well as Let/ExprStmt.
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
    end
  end

  # Strip memory/housekeeping nodes.
  def semantic_mir_nodes(body)
    # Keep hoisted temps (__hpt_N / __tmp_N) -- they receive real slots and
    # subsequent uses resolve via LOAD_SLOT. The previous "inline at use"
    # strategy never materialized: the InlineBc walker emits LOAD_NAME for
    # bare Idents, which is a slow-path symbol lookup that returns Nil for
    # these synthetic names.
    body.reject { |n| skip_mir?(n) }
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
    @current_ast_stmt = ast_node
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
      emit_store(name, val_type)  # authoritative @slot_types update
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
      # `RETURN error.CheatError` is the lowering's RAISE-out-of-fn shape
      # (mir_lowering emits setError + return error.CheatError for any
      # !T-returning function's raise). The VM has no Zig error union;
      # surface a Value.Error sentinel so callers using TryCatch / OR
      # can detect the failure via IS_ERR.
      if has_value && mir_node.value.is_a?(MIR::Ident) &&
         mir_node.value.name.to_s == "error.CheatError"
        emit_op(PUSH_ERR); push_type(:any)
      elsif has_value
        compile_expr(mir_node.value)
      end
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
      # MoveMark is a Zig-codegen artifact: it pairs with a guarded `defer
      # cleanup(x) if (!x_moved)` so that the deferred free is suppressed
      # when ownership has been transferred out (return, TAKES callee).
      # The VM has no Zig defer — slot lifetimes are managed by Value's
      # tagged-union semantics, and BC_RET slot-restore drops the callee's
      # slot copies cleanly. Emitting MARK_MOVED would clear the slot
      # *before* the value-load that consumes it (e.g. the LOAD_SLOT for
      # the very return that this MoveMark precedes), corrupting the
      # returned value. So MoveMark is a structural no-op in the VM.
      push_type(:void)
      return
    when MIR::Call, MIR::MethodCall
      # Statement-position bare call — compile as an expression and discard
      # the result (mirrors how ExprStmt handles it). Happens for side-effect
      # calls emitted directly into MATCH arms and similar scopes.
      compile_expr(mir_node)
      t = pop_type
      emit_op(POP) unless t == :i64 || t == :f64 || t == :bool || t == :void
      push_type(:void)
    when MIR::ScopeBlock
      # RAISE detection: lower_raise produces
      #   ScopeBlock([
      #     ExprStmt(MethodCall(rt, "setError", [.Kind, name_id, msg, line])),
      #     ReturnStmt(Ident("error.CheatError"))
      #   ])
      # The VM has no rt.__error infrastructure; lift the kind+msg into
      # a Value.Error sentinel via RAISE_ERR + BC_RET instead.
      if (raise_info = detect_raise_scope(mir_node))
        kind, msg_expr = raise_info
        emit_op(LOAD_CONST, add_const([:str, kind]))
        compile_expr_to_value(msg_expr); pop_type
        emit_op(RAISE_ERR)
        emit_op(BC_RET) if @in_helper_fn
        @helper_fn_returned = true if @in_helper_fn
        push_type(:void)
        return
      end

      # WITH blocks lower to ScopeBlock with an InlineZig binding-prologue
      # at the head. The prologue's alias_to_source records the source for
      # each alias in @with_aliases. After the body, write each alias back
      # to its source so in-block mutations (`c.value = c.value + 1`) are
      # visible after the WITH (Zig backend does this via guard pointer
      # aliasing; VM uses by-value slots).
      inner = semantic_mir_nodes(mir_node.body)
      @with_aliases ||= {}
      saved_keys = @with_aliases.keys
      inner.each { |n| compile_stmt(n, nil) }
      new_aliases = @with_aliases.keys - saved_keys
      new_aliases.each { |a| alias_writeback(a) }
      new_aliases.each { |a| @with_aliases.delete(a) }
    when MIR::Pipeline
      # See compile_expr's MIR::Pipeline branch.
      compile_stmt(mir_node.inner, nil)
    when MIR::ContinueStmt
      if @loop_continue_target == :deferred_for
        emit_op(JUMP)
        @loop_for_continue_patches << @ops.length
        emit_op(0)
        push_type(:void)
      elsif @loop_continue_target == :deferred_while_update
        emit_op(JUMP)
        @loop_while_update_patches << @ops.length
        emit_op(0)
        push_type(:void)
      elsif @loop_continue_target
        emit_op(JUMP, @loop_continue_target)
        push_type(:void)
      else
        raise Unimplemented, "ContinueStmt outside of a known loop target"
      end
    when MIR::BreakStmt
      if mir_node.value && @block_break_patches
        # Block-expression escape: BreakStmt(label, value) inside an IfStmt
        # body that is itself inside a BlockExpr. Push the value to vstack
        # and JUMP to the block-expr exit; compile_block_expr patches.
        compile_expr(mir_node.value)
        # Record the break value's typed-stack residency so the enclosing
        # compile_block_expr knows where the value lives at the join. The
        # statement-position `push_type(:void)` below is for the local
        # control-flow sense (this statement doesn't yield to its enclosing
        # statement list); it's separate from the block-expression result.
        @block_break_types << pop_type if @block_break_types
        emit_op(JUMP)
        @block_break_patches << @ops.length
        emit_op(0)
        push_type(:void)
      elsif @loop_break_patches
        emit_op(JUMP)
        @loop_break_patches << @ops.length
        emit_op(0)
        push_type(:void)
      else
        raise Unimplemented, "MIR::BreakStmt outside of a known loop"
      end
    when MIR::InlineZig
      # Reason-based pass-throughs for Zig-specific statement leaves the VM
      # can safely ignore (no-op semantics). 'with_block_bindings' unwraps
      # Rc/Arc/locked wrappers into aliases — VM has no sync distinction so
      # the binding is inert. 'suppress_unused_inner_capture' is a Zig
      # unused-var suppressor. Others still raise.
      case mir_node.reason.to_s
      when "with_block_bindings"
        # Compiler-emitted WITH-block binding patterns:
        #   const __X_unwrap = X.ctrl.data.*;        (Arc/multiowned unwrap)
        #   const c = __X_guard_N.get();              (locked sync acquire)
        # In both cases, bind the alias to the same slot value as the source.
        # The VM has no Arc/lock indirection — alias and source share storage.
        # The source is named in stdlib_def[:borrows].
        sources = (mir_node.stdlib_def && mir_node.stdlib_def[:borrows]) || []
        # First pattern: Arc unwrap via .ctrl.data.*
        mir_node.code.to_s.scan(/const\s+(__\w+_unwrap)\s*=\s*(\w+)\.ctrl\.data\.\*/).each do |alias_name, src_name|
          alias_to_source(alias_name, src_name)
        end
        # Second pattern: locked guard.get() — alias source is in borrows[].
        # Each `const NAME = __VAR_guard_N.get();` introduces NAME aliased to
        # the corresponding borrows entry (1:1, in order).
        guard_aliases = mir_node.code.to_s.scan(/const\s+(\w+)\s*=\s*__\w+_guard_\d+\.get\(\)/).flatten
        guard_aliases.each_with_index do |alias_name, i|
          src_name = sources[i] || sources.last
          alias_to_source(alias_name, src_name) if src_name
        end
        # Third pattern: plain WITH BORROWED / RESTRICT — emits Zig-side
        #   const ref = greeting;       (immutable borrow)
        #   const ref = &greeting;      (mutable borrow, Zig pointer)
        # The VM has no borrow indirection; alias and source share storage
        # via alias_to_source. The mutable case still copies (writeback
        # below) so reassigning through the alias is visible on the source.
        mir_node.code.to_s.scan(/const\s+(\w+)\s*=\s*&?(\w+)(?:\.\w+)*\s*;/).each do |alias_name, src_name|
          # Skip the patterns already handled above (Arc unwrap, guard.get()).
          next if alias_name.start_with?("__") && alias_name.end_with?("_unwrap")
          next if mir_node.code.to_s.match?(/const\s+#{Regexp.escape(alias_name)}\s*=\s*__\w+_guard_\d+\.get\(\)/)
          alias_to_source(alias_name, src_name) if has_slot?(src_name)
        end
        push_type(:void)
      when "suppress_unused_inner_capture", "item_cleanup"
        push_type(:void)
      else
        raise Unimplemented, "InlineZig not supported in VM path"
      end
    when MIR::RawZig
      raise Unimplemented, "RawZig not supported in VM path"
    when MIR::BgBlock
      # Expression-position handler does the real work (emit deferred body
      # + BG_SPAWN). At stmt position we just evaluate and discard.
      compile_expr(mir_node); t = pop_type
      emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
      push_type(:void)
    when MIR::DoBlock
      # The Zig backend hands each DO branch to fp.run_concurrent for
      # true parallelism. The VM has no parallel scheduler in exec!
      # itself; running the branches sequentially preserves semantics
      # for the common pattern (mutex-protected counter increment, etc.)
      # since each branch's WITH EXCLUSIVE serializes against the lock
      # anyway. Emit each branch's MIR stmts in order.
      (mir_node.branch_bodies || []).each do |branch|
        branch.each { |s| compile_stmt(s, nil); pop_type }
      end
      push_type(:void)
    when MIR::CatchWrapper
      compile_catch_wrapper(mir_node)
    when MIR::Panic
      # Print message + halt. The VM has no @panic equivalent; surfacing the
      # message via display() and emitting HALT is the closest analogue.
      emit_op(LOAD_CONST, add_const([:str, "PANIC: #{mir_node.message}"]))
      emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      emit_op(HALT)
      push_type(:void)
    when MIR::Sort
      compile_sort(mir_node)
      push_type(:void)
    when MIR::IndexInsert
      compile_index_insert(mir_node)
      push_type(:void)
    when MIR::SoaFieldAccess
      # The VM uses Value.List uniformly; SoA layout (separate slice per
      # field) has no equivalent. Defer until VM models multi-array shape.
      raise Unimplemented, "MIR::SoaFieldAccess not yet supported in VM path"
    when MIR::TryOrPanic
      # The VM treats fallible operations as infallible (no error union
      # propagation). Compile the expr; the @panic-on-error path is dead
      # in this backend since the expr never raises in the VM model.
      compile_expr(mir_node.expr)
    when MIR::Lit, MIR::Ident, MIR::ConcatStr, MIR::BinOp, MIR::BlockExpr
      # Bare expression in statement position (e.g. the last value of a
      # bg-block body, used as the fiber's return). Evaluate for side
      # effects and drop the result.
      compile_expr(mir_node); t = pop_type
      emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
      push_type(:void)
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
    saved_ast = @current_ast_stmt
    @current_ast_stmt = ast_node
    case expr
    when MIR::Call
      compile_call_expr(expr)
    when MIR::MethodCall
      compile_method_call_expr(expr)
    when MIR::InlineZig, MIR::RawZig
      # Reason-based no-ops: OR EXIT writes rt.__error.{kind,error_name,
      # message,clear_line} via RawZig; the VM has no rt struct, the error
      # sentinel carries kind+message directly via RAISE_ERR. These field
      # assigns are dead in BC mode.
      reason = expr.respond_to?(:reason) ? expr.reason.to_s : ""
      if reason.start_with?("or_exit_")
        push_type(:void)
        return
      end
      raise Unimplemented, "#{expr.class.name.split('::').last} expr not supported in VM path"
    else
      compile_expr(expr)
    end
    @current_ast_stmt = saved_ast
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
    # AllocMark struct hint: compile_main pre-walked the body and
    # recorded `name -> base_struct_name` for any AllocMark with a
    # known type_info. Use it when val_type fell through as :any (e.g.
    # the init was a function call that lost type info via BC_CALL).
    if effective_type == :any && @alloc_struct_hints && @alloc_struct_hints[name]
      effective_type = :"struct_#{@alloc_struct_hints[name]}"
    end
    alloc_slot(name, effective_type)
    # Pass val_type (where the value actually lives), not effective_type
    # (where the slot lives). emit_store does the cross-stack coercion
    # itself — passing the slot type would skip the coercion and store
    # past the wrong stack.
    emit_store(name, val_type)
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

  # Build { ast_param_name => vm_slot_type } for a function's AST params.
  # The AST keeps the user-facing CLEAR type (`HashMap<...>`, `Set<...>`),
  # which is the only place to recover dispatch info for comptime-polymorphic
  # params (MIR's zig_type is "anytype" for those).
  def ast_param_vm_types(ast_fn)
    out = {}
    return out unless ast_fn.respond_to?(:params)
    (ast_fn.params || []).each do |ap|
      next unless ap.is_a?(Hash)
      pname = ap[:name].to_s
      out[pname] = vm_type_from_ast_type(ap[:type])
    end
    out
  end

  def vm_type_from_ast_type(t)
    return :any if t.nil?
    # `T[]@set` / `T[]@map` carry the collection kind on the Type object's
    # `collection` attr (the `[]` is just element-shape). Check that first
    # so `Int64[]@set` resolves to :set even though raw is "Int64[]".
    if t.respond_to?(:collection)
      case t.collection
      when :set then return :set
      when :map then return :map
      end
    end
    raw = (t.respond_to?(:raw) ? t.raw : t).to_s
    return :map if raw.start_with?("HashMap")
    return :map if raw.start_with?("StringMap") || raw.start_with?("NumericMap")
    return :map if raw.include?("ShardedStringMap") || raw.include?("StripedNumericMap")
    return :set if raw == "Set" || raw.start_with?("Set<") || raw.start_with?("HashSet")
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
        emit_store(name, val_type)  # authoritative @slot_types update
      else
        name_idx = add_const(name)
        emit_op(SET_NAME, name_idx)
      end
    when MIR::FieldGet
      # `obj.field = v`. Two cases:
      #   - obj is a direct Ident slot: vector-set!(obj, idx, v); store back.
      #   - obj is a chain (IndexGet / FieldGet / get()-unwrap): walk the
      #     full chain via compile_chain_set so each level rebuilds and
      #     the final root slot gets the rebuilt value.
      compile_chain_set(target, node.value)
    when MIR::IndexGet
      # Walk the IndexGet chain inside-out so multi-dim assigns (e.g.
      # matrix[i][j] = v) update each level functionally and store the
      # final list back to the root binding. ListItems wrappers are
      # transparent — the VM stores Value.List directly.
      chain = []
      cur = target
      while cur.is_a?(MIR::IndexGet)
        chain << cur
        cur = cur.object
        cur = cur.list if cur.is_a?(MIR::ListItems)
      end
      root_node = cur
      root_name = root_node.is_a?(MIR::Ident) ? root_node.name.to_s : nil
      if root_name && has_slot?(root_name) && chain.length >= 1
        @nested_set_counter ||= 0
        @nested_set_counter += 1
        tmp = "__nset#{@nested_set_counter}"
        compile_expr_to_value(node.value); pop_type
        alloc_slot(tmp, :any); emit_op(STORE_SLOT, @slots[tmp]); @slot_types[tmp] = :any
        # chain[0] is outermost, chain[-1] is innermost. Update inside-out:
        # tmp <- list-set!(<innermost level>, <innermost idx>, tmp)
        # ... up to the root.
        chain.reverse.each do |idx_node|
          obj = idx_node.object
          obj = obj.list if obj.is_a?(MIR::ListItems)
          compile_expr_to_value(obj); pop_type
          compile_expr_to_value(idx_node.index); pop_type
          emit_op(LOAD_SLOT, @slots[tmp])
          emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
          emit_op(STORE_SLOT, @slots[tmp])
        end
        emit_op(LOAD_SLOT, @slots[tmp])
        emit_op(STORE_SLOT, @slots[root_name])
      else
        # Fallback: original 3-arg push, callers must handle the open stack.
        compile_expr(node.value); pop_type
        compile_expr(target.object)
        compile_expr(target.index)
      end
    end
    push_type(:void)
  end

  # `target = value` where target is a (possibly nested) chain of
  # FieldGet / IndexGet / .get() rooted at an Ident slot. CLEAR's
  # collections are values, so each level must rebuild and the rebuilt
  # value at level N becomes the input at level N-1.
  #
  # Strategy: compute the new value, stash it, then walk the chain
  # outside-in collecting each level. After the walk, emit each level's
  # rebuild op (vector-set! for FieldGet, list-set! for IndexGet) inside
  # to outside, finally storing into the root slot.
  def compile_chain_set(target, value_node)
    # Unwrap .get() identity layers so the chain analysis sees through
    # @alwaysMutable accessors.
    unwrap = ->(n) {
      while n.is_a?(MIR::MethodCall) && n.method.to_s == "get" && n.args.empty?
        n = n.receiver
      end
      n.is_a?(MIR::ListItems) ? n.list : n
    }

    # Collect chain entries from outermost to innermost. Each entry is
    # either [:field, owner, field_name, struct_name] or
    # [:index, owner, index_node].
    chain = []
    cur = target
    loop do
      cur = unwrap.call(cur)
      case cur
      when MIR::FieldGet
        owner = unwrap.call(cur.object)
        receiver_struct = nil
        if owner.is_a?(MIR::Ident)
          t = @slot_types[owner.name.to_s]
          if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
            receiver_struct = t.to_s.sub(/\Astruct_/, "")
          end
        end
        chain << [:field, cur.object, cur.field, receiver_struct]
        cur = cur.object
      when MIR::IndexGet
        chain << [:index, cur.object, cur.index]
        cur = cur.object
      else
        break
      end
    end
    root = unwrap.call(cur)

    # Compute and stash the new value.
    @chain_set_counter ||= 0; @chain_set_counter += 1
    cur_tmp = "__cset_#{@chain_set_counter}_v"
    alloc_slot(cur_tmp, :any) unless has_slot?(cur_tmp)
    compile_expr_to_value(value_node); pop_type
    emit_op(STORE_SLOT, @slots[cur_tmp])
    emit_op(POP)

    # Walk outermost (first collected) to innermost. The collected order is
    # outer→inner (the FieldGet wraps the IndexGet which wraps the Ident).
    # For the rebuild we go in the same order: at each level rebuild the
    # owner using the current tmp value, then move on to the next-outer
    # owner whose substitution is the just-rebuilt value.
    chain.each do |entry|
      kind, owner, *rest = entry
      compile_expr_to_value(unwrap.call(owner)); pop_type
      case kind
      when :field
        field, struct_name = rest
        idx = find_field_index(field, struct_name: struct_name)
        if idx.nil?
          # Bail on unresolved field — leave cur_tmp as-is.
          emit_op(POP)
          next
        end
        emit_op(LOAD_CONST, add_const([:i64, idx]))
        emit_op(LOAD_SLOT, @slots[cur_tmp])
        emit_op(NATIVE_CALL, NATIVES["vector-set!"], 3)
      when :index
        index_node = rest[0]
        compile_expr_to_value(index_node); pop_type
        emit_op(LOAD_SLOT, @slots[cur_tmp])
        emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
      end
      emit_op(STORE_SLOT, @slots[cur_tmp])
      emit_op(POP)
    end

    # Final store into the root slot (if it's a known Ident).
    if root.is_a?(MIR::Ident) && has_slot?(root.name.to_s)
      emit_op(LOAD_SLOT, @slots[cur_tmp])
      emit_store(root.name.to_s, :any)
    end
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
    end
    push_type(:void)
  end

  def compile_while(node)
    loop_start = @ops.length
    capture = node.respond_to?(:capture) ? node.capture : nil
    compile_cond(node.cond); ensure_value_stack
    cond_type = pop_type
    if capture
      # WHILE-bind (`WHILE expr AS v DO ...`): on each iteration evaluate
      # `expr`; if non-nil, bind `v` to its value and run the body. The
      # cond value is the binding source — stash it before NOT/NOT
      # boolifies it, then load into the capture slot inside the live
      # branch.
      capture_name = capture.to_s
      alloc_slot(capture_name, :any) unless has_slot?(capture_name)
      @while_bind_tmp_counter ||= 0; @while_bind_tmp_counter += 1
      tmp = "__wbind_#{@while_bind_tmp_counter}"
      alloc_slot(tmp, :any) unless has_slot?(tmp)
      emit_op(STORE_SLOT, @slots[tmp]); emit_op(POP)  # tmp = cond value
      emit_op(LOAD_SLOT, @slots[tmp])
      emit_op(NOT); emit_op(NOT)
      emit_op(JUMP_IF_FALSE)
      jump_exit_idx = @ops.length
      emit_op(0)
      # Live branch: capture = tmp.
      emit_op(LOAD_SLOT, @slots[tmp])
      emit_op(STORE_SLOT, @slots[capture_name])
      emit_op(POP)
      cond_type = :any  # we already converted via NOT/NOT to bool then popped
    else
      emit_op(cond_type == :bool ? JUMP_IF_FALSE_I : JUMP_IF_FALSE)
      jump_exit_idx = @ops.length
      emit_op(0)
    end

    # Zig-style `while (cond) : (update) { body }` lowers FOR-range loops
    # to WhileStmt with a non-nil `update` (the iterator increment). The
    # update runs on every iteration after the body and BEFORE the next
    # condition check; CONTINUE must therefore jump to the update block,
    # not back to loop_start (otherwise the iterator never advances).
    has_update = node.respond_to?(:update) && node.update
    saved_continue = @loop_continue_target
    saved_breaks   = @loop_break_patches
    update_patches = []
    if has_update
      @loop_continue_target = :deferred_while_update
      @loop_while_update_patches = update_patches
    else
      @loop_continue_target = loop_start
    end
    @loop_break_patches   = []
    emit_body_stmts(node.body)
    break_patches = @loop_break_patches
    @loop_continue_target = saved_continue
    @loop_break_patches   = saved_breaks

    if has_update
      update_ip = @ops.length
      update_patches.each { |ip| @ops[ip] = update_ip }
      compile_stmt(node.update, nil)
      t = pop_type
      emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
      @loop_while_update_patches = nil
    end
    emit_op(JUMP, loop_start)
    @ops[jump_exit_idx] = @ops.length
    break_patches.each { |idx| @ops[idx] = @ops.length }
    push_type(:void)
  end

  # MIR::IndexInsert: append `value` to the list bucket of `map` at `key`,
  # creating the bucket on first hit. Lowering pattern matches the Zig
  # backend's getOrPut + value_ptr.append idiom; here we use MAP_GET +
  # list-push/MAKE_LIST + MAP_PUT.
  def compile_index_insert(node)
    @idx_insert_counter ||= 0; @idx_insert_counter += 1
    n = @idx_insert_counter
    tmp_key  = "__idx_key#{n}"
    tmp_val  = "__idx_val#{n}"
    tmp_list = "__idx_list#{n}"
    alloc_slot(tmp_key,  :any) unless has_slot?(tmp_key)
    alloc_slot(tmp_val,  :any) unless has_slot?(tmp_val)
    alloc_slot(tmp_list, :any) unless has_slot?(tmp_list)

    # Stash key and val into temp slots so we can reload them as needed
    # without re-evaluating side effects.
    compile_expr_to_value(node.key_expr); pop_type
    emit_op(STORE_SLOT, @slots[tmp_key]); emit_op(POP)
    compile_expr_to_value(node.value_expr); pop_type
    emit_op(STORE_SLOT, @slots[tmp_val]); emit_op(POP)

    # Probe map[key] -> existing list or Nil.
    compile_expr_to_value(node.map); pop_type
    emit_op(LOAD_SLOT, @slots[tmp_key])
    emit_op(MAP_GET)

    # Boolify (Nil -> false, list -> true) then dispatch.
    emit_op(NOT); emit_op(NOT)
    emit_op(JUMP_IF_FALSE)
    create_branch_idx = @ops.length; emit_op(0)

    # Existing branch: reload list, append val (list-push returns a NEW list).
    compile_expr_to_value(node.map); pop_type
    emit_op(LOAD_SLOT, @slots[tmp_key])
    emit_op(MAP_GET)
    emit_op(LOAD_SLOT, @slots[tmp_val])
    emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
    emit_op(JUMP); merge_jump_idx = @ops.length; emit_op(0)

    # Create branch: fresh single-element list [val].
    @ops[create_branch_idx] = @ops.length
    emit_op(LOAD_SLOT, @slots[tmp_val])
    emit_op(NATIVE_CALL, NATIVES["list"], 1)

    # Merge: stack top is the new list. Stash + put back into map[key].
    @ops[merge_jump_idx] = @ops.length
    emit_op(STORE_SLOT, @slots[tmp_list]); emit_op(POP)
    compile_expr_to_value(node.map); pop_type
    emit_op(LOAD_SLOT, @slots[tmp_key])
    emit_op(LOAD_SLOT, @slots[tmp_list])
    emit_op(MAP_PUT)
    emit_op(POP)  # discard the Nil pushed by MAP_PUT
  end

  # MIR::Sort lowers `items s> ORDER_BY <key>` to a comparator-as-expression
  # (key_a, key_b) over placeholder identifiers `a` and `b`. The Zig backend
  # emits `std.mem.sort` with an anonymous-struct lessThan; the VM has no
  # in-place sort native and no closures, so we expand structurally to an
  # inline bubble sort that allocates two slots `a`/`b`, populates them per
  # comparison from list[j+1] / list[j], and uses the same key expressions
  # to drive a vstack `<` test. Swap via list-set! (functional update +
  # store-back to the underlying slot).
  def compile_sort(node)
    items = node.items_expr
    while items.is_a?(MIR::FieldGet) && items.field.to_s == "items"
      items = items.object
    end
    unless items.is_a?(MIR::Ident) && has_slot?(items.name.to_s)
      raise Unimplemented, "MIR::Sort items_expr must resolve to a value-slot Ident"
    end
    list_slot = items.name.to_s

    uniq = @ops.length
    i_slot = "__sort_i_#{uniq}"
    j_slot = "__sort_j_#{uniq}"
    len_slot = "__sort_len_#{uniq}"
    [i_slot, j_slot, len_slot, "a", "b"].each { |s| alloc_slot(s, :any) unless has_slot?(s) }

    one_const = add_const([:i64, 1])
    zero_const = add_const([:i64, 0])

    store_int_slot = lambda do |slot, const_idx|
      emit_op(LOAD_CONST_I64, const_idx); emit_op(I_TO_VAL)
      emit_op(STORE_SLOT, @slots[slot]); emit_op(POP)
    end
    incr_slot = lambda do |slot|
      emit_op(LOAD_SLOT, @slots[slot])
      emit_op(LOAD_CONST_I64, one_const); emit_op(I_TO_VAL); emit_op(ADD)
      emit_op(STORE_SLOT, @slots[slot]); emit_op(POP)
    end
    load_list_idx = lambda do |idx_emitter|
      emit_op(LOAD_SLOT, @slots[list_slot])
      idx_emitter.call
      emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    end

    # len = list.length()
    emit_op(LOAD_SLOT, @slots[list_slot])
    emit_op(NATIVE_CALL, NATIVES["count"], 1)
    emit_op(STORE_SLOT, @slots[len_slot]); emit_op(POP)

    # i = 0
    store_int_slot.call(i_slot, zero_const)

    outer_start = @ops.length
    # while i < len; jump to exit when (i < len) is false
    emit_op(LOAD_SLOT, @slots[i_slot])
    emit_op(LOAD_SLOT, @slots[len_slot])
    emit_op(LT)
    emit_op(JUMP_IF_FALSE)
    outer_exit_patch = @ops.length; emit_op(0)

    # j = 0
    store_int_slot.call(j_slot, zero_const)

    inner_start = @ops.length
    # while j < len - i - 1
    emit_op(LOAD_SLOT, @slots[j_slot])
    emit_op(LOAD_SLOT, @slots[len_slot])
    emit_op(LOAD_SLOT, @slots[i_slot])
    emit_op(SUB)
    emit_op(LOAD_CONST_I64, one_const); emit_op(I_TO_VAL)
    emit_op(SUB)
    emit_op(LT)
    emit_op(JUMP_IF_FALSE)
    inner_exit_patch = @ops.length; emit_op(0)

    # b = list[j]
    load_list_idx.call(-> { emit_op(LOAD_SLOT, @slots[j_slot]) })
    emit_op(STORE_SLOT, @slots["b"]); emit_op(POP)
    # a = list[j+1]
    load_list_idx.call(lambda {
      emit_op(LOAD_SLOT, @slots[j_slot])
      emit_op(LOAD_CONST_I64, one_const); emit_op(I_TO_VAL); emit_op(ADD)
    })
    emit_op(STORE_SLOT, @slots["a"]); emit_op(POP)

    # if key_a < key_b: swap (right-of-pair < left-of-pair, so reorder)
    compile_expr_to_value(node.key_a); pop_type
    compile_expr_to_value(node.key_b); pop_type
    emit_op(LT)
    emit_op(JUMP_IF_FALSE)
    no_swap_patch = @ops.length; emit_op(0)

    # list = list-set!(list, j+1, b)
    emit_op(LOAD_SLOT, @slots[list_slot])
    emit_op(LOAD_SLOT, @slots[j_slot])
    emit_op(LOAD_CONST_I64, one_const); emit_op(I_TO_VAL); emit_op(ADD)
    emit_op(LOAD_SLOT, @slots["b"])
    emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
    emit_op(STORE_SLOT, @slots[list_slot]); emit_op(POP)
    # list = list-set!(list, j, a)
    emit_op(LOAD_SLOT, @slots[list_slot])
    emit_op(LOAD_SLOT, @slots[j_slot])
    emit_op(LOAD_SLOT, @slots["a"])
    emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
    emit_op(STORE_SLOT, @slots[list_slot]); emit_op(POP)

    @ops[no_swap_patch] = @ops.length

    # j += 1
    incr_slot.call(j_slot)
    emit_op(JUMP, inner_start)
    @ops[inner_exit_patch] = @ops.length

    # i += 1
    incr_slot.call(i_slot)
    emit_op(JUMP, outer_start)
    @ops[outer_exit_patch] = @ops.length
  end

  def compile_for(node, ast_node = nil)
    if ast_node
      compile_ast_stmt(ast_node)
      return
    end
    # Structural ForStmt: iterate a list-producing expression (iter),
    # binding each element to `capture` (and optionally index to
    # index_capture). ContinueStmt jumps to the index-increment; BreakStmt
    # patches into the loop exit.
    capture = node.capture.to_s.sub(/\A\*/, "")  # strip Zig `*` pointer sigil
    idx_name  = "__for_idx_#{@ops.length}"
    coll_name = "__for_coll_#{@ops.length}"
    alloc_slot(idx_name, :any); alloc_slot(coll_name, :any)
    alloc_slot(capture, :any) unless has_slot?(capture)
    @slot_types[capture] = :any
    if node.index_capture
      idx_cap = node.index_capture.to_s.sub(/\A\*/, "")
      alloc_slot(idx_cap, :any) unless has_slot?(idx_cap)
      @slot_types[idx_cap] = :any
    end

    # coll = iter; idx = 0
    compile_expr_to_value(node.iter); pop_type
    emit_op(STORE_SLOT, @slots[coll_name])
    emit_op(POP)
    emit_op(LOAD_CONST, add_const([:i64, 0]))
    emit_op(STORE_SLOT, @slots[idx_name])
    emit_op(POP)

    loop_start = @ops.length
    # if idx >= len(coll): jump exit
    emit_op(LOAD_SLOT, @slots[idx_name])
    emit_op(LOAD_SLOT, @slots[coll_name])
    emit_op(NATIVE_CALL, NATIVES["count"], 1)
    emit_op(LT)
    emit_op(JUMP_IF_FALSE)
    jump_exit = @ops.length; emit_op(0)

    # capture = coll[idx]
    emit_op(LOAD_SLOT, @slots[coll_name])
    emit_op(LOAD_SLOT, @slots[idx_name])
    emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    emit_op(STORE_SLOT, @slots[capture])
    emit_op(POP)
    # optional index capture
    if node.index_capture
      idx_cap = node.index_capture.to_s.sub(/\A\*/, "")
      emit_op(LOAD_SLOT, @slots[idx_name])
      emit_op(STORE_SLOT, @slots[idx_cap])
      emit_op(POP)
    end

    # body — wire break/continue targets
    saved_continue = @loop_continue_target
    saved_breaks   = @loop_break_patches
    continue_label = nil  # we'll patch after loop body
    @loop_break_patches = []
    # Continue target points to the increment block below.
    continue_patches = []
    @loop_continue_target = nil  # set after body emission via patch list
    continue_marker = -> (ip) { continue_patches << ip }
    # Replace ContinueStmt emission: use a patch list that resolves to the
    # increment block's IP. To minimize changes, set the continue target to
    # a placeholder that we rewrite once we know the increment IP.
    @loop_continue_target = :deferred_for
    @loop_for_continue_patches = continue_patches
    semantic_mir_nodes(node.body).each { |s| compile_stmt(s, nil) }
    break_patches = @loop_break_patches
    @loop_continue_target = saved_continue
    @loop_break_patches   = saved_breaks
    @loop_for_continue_patches = nil

    # Increment block
    increment_ip = @ops.length
    continue_patches.each { |ip| @ops[ip] = increment_ip }
    emit_op(LOAD_SLOT, @slots[idx_name])
    emit_op(LOAD_CONST, add_const([:i64, 1]))
    emit_op(ADD)
    emit_op(STORE_SLOT, @slots[idx_name])
    emit_op(POP)
    emit_op(JUMP, loop_start)

    @ops[jump_exit] = @ops.length
    break_patches.each { |ip| @ops[ip] = @ops.length }
    push_type(:void)
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
    push_type(:void)
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
    when AST::StructDef, AST::EnumDef, AST::UnionDef
      # Type declarations have no runtime side effect in the VM (schemas are
      # registered up-front during compile()'s top-level scan). Treat as no-op
      # so stmt-position type-decls don't blow up the AST walker.
      push_type(:void)
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
      # `try EXPR` (Zig-style): if EXPR is a Value.Error, propagate by
      # returning early from the enclosing helper fn with the error
      # sentinel still on the stack. Otherwise leave EXPR's value on
      # the stack and fall through. Without this, OR-RAISE patterns
      # like `readFile(x) OR RAISE` silently swallowed the failure.
      compile_expr(node.expr); ensure_value_stack; pop_type
      # IS_ERR pops the operand and pushes a bool, so stash the value
      # first and reload it on each path.
      @tryexpr_counter ||= 0; @tryexpr_counter += 1
      tmp = "__try_#{@tryexpr_counter}"
      alloc_slot(tmp, :any) unless has_slot?(tmp)
      emit_op(STORE_SLOT, @slots[tmp])  # STORE_SLOT keeps a copy on the vstack too
      emit_op(IS_ERR)                    # pops the on-stack copy, pushes bool
      emit_op(JUMP_IF_FALSE)              # not error -> jump to success path
      patch_ok = @ops.length; emit_op(0)
      # Error path: load the stashed Error sentinel and return early.
      emit_op(LOAD_SLOT, @slots[tmp])
      if @in_helper_fn
        emit_op(BC_RET)
        @helper_fn_returned = true
      else
        # In main, there's nothing useful to return — leave the error
        # on the stack so the surrounding TryCatch / explicit catch
        # handler (if any) can dispatch on it.
      end
      @ops[patch_ok] = @ops.length
      # Success path: reload the value from the stash so the result is
      # left on the vstack just like any other expression.
      emit_op(LOAD_SLOT, @slots[tmp])
      push_type(:any)
    when MIR::TryCatch
      # `expr OR catch_body`. compile expr; stash to a temp slot; check
      # IS_ERR; if error: discard stash, evaluate catch_body; else: load
      # the original value. Mirrors Zig's `try/catch` control flow with
      # the VM's Value.Error sentinel taking the place of error unions.
      @trycatch_counter ||= 0
      @trycatch_counter += 1
      tmp = "__tc_#{@trycatch_counter}"
      compile_expr_to_value(node.expr); pop_type
      alloc_slot(tmp, :any)
      emit_op(STORE_SLOT, @slots[tmp])
      emit_op(IS_ERR)
      emit_op(JUMP_IF_FALSE)
      keep_patch = @ops.length; emit_op(0)
      # Error path: stash already taken, fall through to catch_body
      compile_expr_to_value(node.catch_body); pop_type
      emit_op(JUMP); end_patch = @ops.length; emit_op(0)
      # Non-error path: load the original value
      @ops[keep_patch] = @ops.length
      emit_op(LOAD_SLOT, @slots[tmp])
      @ops[end_patch] = @ops.length
      push_type(:any)
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
    when MIR::TryOrPanic
      # VM has no error union propagation; the catch arm is unreachable.
      compile_expr(node.expr)
    when MIR::SoaFieldAccess
      raise Unimplemented, "MIR::SoaFieldAccess not yet supported in VM path"
    when MIR::AllocatorRef
      # VM is GC'd; strip_alloc_args removes these from arg lists. If one
      # does reach here (e.g. assigned to a local), emit nil — it's never
      # used for allocation in the VM.
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when MIR::Undef
      # Uninitialized sentinel; VM uses nil for unset slots.
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when MIR::SliceExpr
      # target[start..end] — the VM has no slice semantics separate from lists;
      # materialize [target[start], ..., target[end-1]] via a helper native.
      # For open-ended (no end_expr) the native reads to the end.
      compile_expr_to_value(node.target); pop_type
      compile_expr_to_value(node.start); pop_type
      if node.end_expr
        compile_expr_to_value(node.end_expr); pop_type
        emit_op(NATIVE_CALL, NATIVES["slice"], 3) if NATIVES.key?("slice")
      else
        emit_op(NATIVE_CALL, NATIVES["slice-from"], 2) if NATIVES.key?("slice-from")
      end
      push_type(:any); return
    when MIR::IterRange
      # 0..N — materialize as a Scheme list [0, 1, ..., N-1] since the VM's
      # ForStmt iterates any list-producing expression. Cheap enough for
      # pipeline test cases.
      compile_expr_to_value(node.start); pop_type
      compile_expr_to_value(node.end_val); pop_type
      if NATIVES.key?("iota")
        emit_op(NATIVE_CALL, NATIVES["iota"], 2); push_type(:any); return
      end
    when MIR::RangeLit
      # CheatLib.IntRange / CheatLib.Range materializes as the same flat
      # list of integers — the VM has no lazy stream type, so concrete
      # materialization is the only way to keep ForStmt / pipeline-source
      # iteration correct.
      compile_expr_to_value(node.start); pop_type
      compile_expr_to_value(node.end_val); pop_type
      emit_op(NATIVE_CALL, NATIVES["iota"], 2)
      push_type(:any); return
      # Fallback: push a 2-elem list [start, end] so the loop iterates only
      # twice — wrong semantically, but enough to avoid compile failure.
      emit_op(NATIVE_CALL, NATIVES["list"], 2); push_type(:any); return
    when MIR::TypeSentinel
      # Accumulator seed (float/int min/max). Pick a large-enough concrete
      # value; tests that use MIN/MAX sentinels to fold a collection will
      # still produce correct results as long as real inputs beat the seed.
      t = node.zig_type.to_s
      if t =~ /\Af/
        val = node.extreme == :max ? Float::MAX : -Float::MAX
        emit_op(LOAD_CONST, add_const([:f64, val])); push_type(:any); return
      else
        val = node.extreme == :max ? (2**62) : -(2**62)
        emit_op(LOAD_CONST, add_const([:i64, val])); push_type(:any); return
      end
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
    when MIR::ScopeBlock
      # ScopeBlock in expression position: walk the body with the WITH-alias
      # bookkeeping that the stmt-form uses, but leave the trailing value on
      # the stack (the last semantic-stmt's compile_expr / compile_stmt push).
      inner = semantic_mir_nodes(node.body)
      @with_aliases ||= {}
      saved_keys = @with_aliases.keys
      last_t = :any
      inner.each_with_index do |n, i|
        if i < inner.length - 1
          compile_stmt(n, nil)
          t = pop_type
          emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
        else
          compile_stmt(n, nil)
          last_t = pop_type
        end
      end
      new_aliases = @with_aliases.keys - saved_keys
      new_aliases.each { |a| alias_writeback(a) }
      new_aliases.each { |a| @with_aliases.delete(a) }
      push_type(last_t)
      return
    when MIR::Pipeline
      # Migrated pipeline operators produce a real MIR tree via
      # pipeline_host.lower_pipeline — compile that directly. Legacy operators
      # leave inner as MIR::RawZig which the VM can't compile; the inner
      # RawZig dispatch raises with a better error than a silent passthrough.
      compile_expr(node.inner)
    when MIR::BgBlock
      # Phase 1: emit the body as a separate bytecode chunk with its own
      # entry_ip + FIBER_RET at the end, then emit BG_SPAWN to invoke it
      # in a recursive exec! call. The pushed value is a Future-like Pair.
      # Captures come from node.captures (name => type). Push each capture
      # onto the stack, then BG_SPAWN argc = len(captures).
      captures = (node.captures || {}).keys.map(&:to_s)
      # Jump over the deferred body chunk at the call site.
      emit_op(JUMP)
      skip_patch = @ops.length; emit_op(0)
      entry_ip = @ops.length

      # Emit body prologue: captures are loaded into slots 0..N-1 by exec!'s
      # initCaps handling. We need those captures bound by their CLEAR names
      # (e.g., `x`). Map slot 0..N-1 to capture names.
      saved_slots    = @slots
      saved_islots   = @islots
      saved_fslots   = @fslots
      saved_types    = @slot_types
      saved_mutables = @mutables
      saved_next     = @next_slot
      saved_nexti    = @next_islot
      saved_nextf    = @next_fslot
      saved_stack    = @type_stack
      @slots = {}; @islots = {}; @fslots = {}
      @slot_types = {}; @mutables = Set.new
      @next_slot = 0; @next_islot = 0; @next_fslot = 0
      @type_stack = []
      captures.each_with_index do |cname, idx|
        @slots[cname] = idx
        @slot_types[cname] = :any
      end
      @next_slot = captures.length

      # Compile body. Last statement's value is the fiber's return.
      stmts = semantic_mir_nodes(node.run_body || [])
      if stmts.empty?
        emit_op(LOAD_CONST, add_const(nil))
      else
        stmts[0...-1].each do |s|
          compile_stmt(s, nil); t = pop_type
          emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
        end
        last = stmts[-1]
        # FIBER_RET pops from the value stack, so the fiber's result must
        # land there (not on the typed istack/fstack). compile_expr_to_value
        # boxes typed results via I_TO_VAL/F_TO_VAL.
        if last.is_a?(MIR::ExprStmt)
          compile_expr_to_value(last.expr); pop_type
        elsif last.respond_to?(:expr?) && last.expr?
          compile_expr_to_value(last); pop_type
        else
          compile_stmt(last, nil); t = pop_type
          emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
          emit_op(LOAD_CONST, add_const(nil))
        end
      end
      emit_op(FIBER_RET)

      # Restore caller's slot context.
      @slots = saved_slots
      @islots = saved_islots
      @fslots = saved_fslots
      @slot_types = saved_types
      @mutables = saved_mutables
      @next_slot = saved_next
      @next_islot = saved_nexti
      @next_fslot = saved_nextf
      @type_stack = saved_stack

      # Patch the jump-over-body target.
      @ops[skip_patch] = @ops.length

      # Push each capture as a Value onto the value stack. Typed slots
      # (:i64 / :f64) need I_TO_VAL / F_TO_VAL to box as Value because
      # initCaps in exec! is Value[]. Without boxing, LOAD_ISLOT/LOAD_FSLOT
      # would put a raw int/float on the typed stack and BG_SPAWN would
      # read garbage Values from the value stack.
      captures.each do |cname|
        if @islots.key?(cname)
          emit_op(LOAD_ISLOT, @islots[cname])
          emit_op(I_TO_VAL)
        elsif @fslots.key?(cname)
          emit_op(LOAD_FSLOT, @fslots[cname])
          emit_op(F_TO_VAL)
        elsif has_slot?(cname)
          emit_op(LOAD_SLOT, @slots[cname])
        else
          emit_op(LOAD_NAME, add_const(cname))
        end
      end
      emit_op(BG_SPAWN, entry_ip, captures.length)
      push_type(:any)
      return
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
      # LOAD_CONST puts Value.TrueVal on the value stack, not the typed
      # istack. push_type(:bool) would mislead compile_expr_to_value into
      # emitting BOOL_TO_VAL (which pops istack and panics on underflow).
      emit_op(LOAD_CONST, add_const([:bool, true])); push_type(:any)
    when "false"
      emit_op(LOAD_CONST, add_const([:bool, false])); push_type(:any)
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
      # Resolve Zig-source escape sequences here, in Ruby. The lexer
      # already interpreted the original CLEAR-source escapes; the MIR
      # lowering re-encoded them as Zig source for the Zig backend.
      # bc_emitter undoes that re-encoding so the const carries the
      # actual bytes the program intended. The serialize_const :str
      # length-prefixes the bytes; the VM never sees escape syntax.
      emit_op(LOAD_CONST, add_const([:str, unescape_zig_source_str($1)])); push_type(:str)
    else
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any)
    end
  end

  # ================================================================
  # Identifiers
  # ================================================================

  def compile_ident(node)
    name = node.name.to_s
    # BG block capture ident: MIR lowers `x` inside a bg body to `__ctx_N.x`
    # (Zig-side context unpacking). VM inlines the body, so strip the prefix
    # and read the outer slot directly.
    name = $1 if name =~ /\A__ctx_\d+\.(.*)\z/
    # Arc/Rc-unwrap path. The MIR lowers an `IF resolved AS r ... r.value`
    # to a synthetic Ident("_r.ctrl.data.value") — a Zig path expression
    # that the Zig backend would emit literally. In the VM, Value already
    # is the inner value (no Arc box), so peel `.ctrl.data.*` and treat
    # subsequent dotted segments as field accesses.
    if name.include?(".")
      head, *tail = name.split(".")
      # Strip Arc-unwrap path markers that have no VM analogue.
      tail = tail.reject { |seg| seg == "ctrl" || seg == "data" }
      compile_ident_root(head)
      tail.each do |field|
        receiver_struct = nil
        t = @slot_types[head]
        if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
          receiver_struct = t.to_s.sub(/\Astruct_/, "")
        end
        idx = find_field_index(field, struct_name: receiver_struct)
        if idx
          emit_op(LOAD_CONST, add_const([:i64, idx]))
          emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
        else
          # Unknown field — fall back to nil to keep the stack balanced.
          emit_op(POP); emit_op(LOAD_CONST, add_const(nil))
        end
      end
      pop_type if @type_stack.any?
      push_type(:any)
      return
    end
    compile_ident_root(name)
  end

  # Load a single (un-dotted) name onto the stack and tag the type stack.
  def compile_ident_root(name)
    if @islots[name]
      emit_op(LOAD_ISLOT, @islots[name]); push_type(:i64)
    elsif @fslots[name]
      emit_op(LOAD_FSLOT, @fslots[name]); push_type(:f64)
    elsif @slots[name]
      emit_op(LOAD_SLOT, @slots[name]); push_type(@slot_types[name] || :any)
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
    # Use distinct synthetic ops for wrapping arithmetic — compile_binop
    # routes them to WRAP_*_I64 opcodes so `%+` / `%* `wrap in Zig
    # (Debug-mode `*` panics on overflow; user code intentionally
    # overflows for hashes/RNGs).
    wrapAdd:  "wrap+", wrapSub: "wrap-", wrapMul: "wrap*",
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
    when :map_get
      # m[k] for both string_map and numeric_map. Runner's keyAsStr
      # stringifies numeric keys so the same MAP_GET handles both.
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      emit_op(MAP_GET); push_type(:any); return
    when :map_set
      # m[k] = v for both string_map and numeric_map. MAP_PUT mutates the
      # MapRef in-place; the trailing Nil is consumed by the surrounding
      # ExprStmt's POP.
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      compile_expr_to_value(node.args[2]); pop_type
      emit_op(MAP_PUT); push_type(:any); return
    when :numericMapGet
      # emit_builtin(:numericMapGet, [key_zig_ident, val_zig_ident, target, index])
      # The first two are comptime type hints (Zig-only); skip them.
      compile_expr_to_value(node.args[2]); pop_type
      compile_expr_to_value(node.args[3]); pop_type
      emit_op(MAP_GET); push_type(:any); return
    when :put
      # MAP_METHODS["put"] -> map.put(key, value). Same VM op for string/numeric maps.
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      compile_expr_to_value(node.args[2]); pop_type
      emit_op(MAP_PUT); push_type(:any); return
    when :delete
      # MAP_METHODS["delete"] -> map.delete(key).
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      emit_op(MAP_DELETE); push_type(:any); return
    when :keys
      # MAP_METHODS["keys"] -> map.keys() returns String[].
      compile_expr_to_value(node.args[0]); pop_type
      emit_op(MAP_KEYS); push_type(:any); return
    when :values
      # MAP_METHODS["values"] -> map.values() returns V[]. The runner walks
      # the env vars and collects them; needs a MAP_VALUES opcode.
      compile_expr_to_value(node.args[0]); pop_type
      emit_op(MAP_VALUES); push_type(:any); return
    when :append, :insert, :push
      # `set.insert(x)` and `list.{append,insert,push}(x)` collide on op name.
      # Dispatch on receiver shape: sets live in the env pool as MapRef and
      # need SET_INSERT; lists go through the list-push native.
      tag = node.stdlib_def && node.stdlib_def[:tag]
      arg_hint = expr_type_hint(node.args[0])
      if tag == :set_method || arg_hint == :set
        compile_expr_to_value(node.args[0])
        compile_expr_to_value(node.args[1])
        emit_op(SET_INSERT)
        # SET_INSERT pushes Value.Nil as its result; mark :any so callers
        # in statement position emit POP instead of leaking it on vstack.
        push_type(:any); return
      end
      if tag == :pool_method
        # pool.insert(item) -> Id<T> = current length. VM models pool as a
        # list: insert appends, the returned Id is the index where the item
        # landed. Cleanup uses STORE_SLOT then list-length on the stored
        # list to compute the index, then leave the index on top.
        compile_expr_to_value(node.args[0]); pop_type
        compile_expr_to_value(node.args[1]); pop_type
        emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
        # Stack now has new_list. Need to: store back to slot, push id.
        recv = node.args[0]
        recv = recv.list if recv.is_a?(MIR::ListItems)
        if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
          emit_store(recv.name.to_s, :any)
          emit_op(POP)  # consume the new_list copy STORE_SLOT left
          # Return the id = (length - 1). Reload, count, sub 1.
          emit_op(LOAD_SLOT, @slots[recv.name.to_s])
          emit_op(NATIVE_CALL, NATIVES["count"], 1)
          emit_op(LOAD_CONST, add_const([:i64, 1]))
          emit_op(SUB)
          push_type(:any); return
        else
          # Non-Ident receiver: best-effort -- push Nil id (caller usually
          # assigns to a fresh variable so this only matters when the id is
          # used; rare for non-Ident pool receivers).
          emit_op(POP)
          emit_op(LOAD_CONST, add_const([:i64, 0]))
          push_type(:any); return
        end
      end
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
      # Storeback strategy: append builds a NEW list value (CLEAR semantics
      # — collections are values). The new list lives on top of vstack;
      # without storing it back, the receiver still references the OLD
      # empty list and the mutation is lost.
      recv = node.args[0]
      recv = recv.list if recv.is_a?(MIR::ListItems)
      if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
        emit_store(recv.name.to_s, :any)
      elsif recv.is_a?(MIR::FieldGet) || recv.is_a?(MIR::IndexGet)
        # Nested target: stash the new list and synthesize a Set so
        # compile_set's existing FieldGet / IndexGet chain handler walks
        # back through the levels (vector-set! through fields, list-set!
        # through indices) and stores the final root value.
        @chain_append_counter ||= 0; @chain_append_counter += 1
        tmp = "__chappend_#{@chain_append_counter}"
        alloc_slot(tmp, :any) unless has_slot?(tmp)
        emit_op(STORE_SLOT, @slots[tmp])  # STORE_SLOT keeps a copy on stack
        emit_op(POP)                        # discard the redundant copy
        synth = MIR::Set.new(recv, MIR::Ident.new(tmp), nil)
        compile_set(synth); pop_type
      end
      push_type(:void); return
    when :reserve
      # list.reserve(n) — no-op in VM (lists are growable per-mutation)
      compile_expr_to_value(node.args[0]); pop_type; emit_op(POP)
      compile_expr_to_value(node.args[1]); pop_type; emit_op(POP)
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    when :pop
      # list.pop() -> ?T. LIST_POP_LAST mutates: pushes (shrunk_list, popped).
      # Storeback: shrunk_list goes back to receiver; popped is the
      # expression value. Same chain-set pattern as :remove.
      compile_expr_to_value(node.args[0])
      emit_op(LIST_POP_LAST)
      recv = node.args[0]
      recv = recv.list if recv.is_a?(MIR::ListItems)
      # LIST_POP_LAST leaves [shrunk, popped] on the stack (popped on top).
      # Stash both, write shrunk back through the receiver chain, then
      # leave popped as the expression value.
      if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
        @list_pop_tmp_counter ||= 0; @list_pop_tmp_counter += 1
        ptmp = "__lpop_p#{@list_pop_tmp_counter}"
        stmp = "__lpop_s#{@list_pop_tmp_counter}"
        alloc_slot(ptmp, :any) unless has_slot?(ptmp)
        alloc_slot(stmp, :any) unless has_slot?(stmp)
        emit_op(STORE_SLOT, @slots[ptmp]); emit_op(POP)  # popped -> ptmp
        emit_op(STORE_SLOT, @slots[stmp]); emit_op(POP)  # shrunk -> stmp
        emit_op(LOAD_SLOT, @slots[stmp])
        emit_store(recv.name.to_s, :any)                  # write shrunk back
        # STORE_SLOT in the runner keeps a copy on the vstack — pop it so
        # the only value left at the end is the popped element.
        emit_op(POP)
        emit_op(LOAD_SLOT, @slots[ptmp])                  # popped as result
      elsif recv.is_a?(MIR::FieldGet) || recv.is_a?(MIR::IndexGet)
        @list_pop_tmp_counter ||= 0; @list_pop_tmp_counter += 1
        ptmp = "__lpop_p#{@list_pop_tmp_counter}"
        stmp = "__lpop_s#{@list_pop_tmp_counter}"
        alloc_slot(ptmp, :any) unless has_slot?(ptmp)
        alloc_slot(stmp, :any) unless has_slot?(stmp)
        emit_op(STORE_SLOT, @slots[ptmp]); emit_op(POP)
        emit_op(STORE_SLOT, @slots[stmp]); emit_op(POP)
        synth = MIR::Set.new(recv, MIR::Ident.new(stmp), nil)
        compile_set(synth); pop_type
        emit_op(LOAD_SLOT, @slots[ptmp])
      end
      push_type(:any); return
    when :length, :count
      # Sets/maps live in the env pool (Value.MapRef); the count native
      # (id 13) calls listLen which doesn't reach into the pool. Emit
      # MAP_LENGTH for those receivers; otherwise the count native handles
      # list/string uniformly. Result lands on vstack as Int64Val (:any).
      tag = node.stdlib_def && node.stdlib_def[:tag]
      arg_hint = expr_type_hint(node.args[0])
      compile_expr_to_value(node.args[0])
      if arg_hint == :set || arg_hint == :map
        emit_op(MAP_LENGTH)
      elsif tag == :pool_method
        # Pool length = number of non-Nil entries in the backing list.
        # Use a runtime helper that walks the list and counts non-Nil.
        emit_op(NATIVE_CALL, NATIVES["count"], 1)  # total slots
        # TODO: subtract removed (Nil) entries. For now, return raw count
        # which matches insert-only workloads.
      else
        emit_op(NATIVE_CALL, NATIVES["count"], 1)
      end
      push_type(:any); return
    when :get
      # POOL_METHODS["get"]: pool.get(id) -> ?T. Pool is modeled as a list;
      # list-ref handles in-bounds; otherwise yields Nil.
      tag = node.stdlib_def && node.stdlib_def[:tag]
      if tag == :pool_method
        compile_expr_to_value(node.args[0]); pop_type
        compile_expr_to_value(node.args[1]); pop_type
        emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
        push_type(:any); return
      end
      # No other op uses :get through InlineBc currently.
      raise Unimplemented, "InlineBc :get with tag=#{tag}"
    when :remove
      # set.remove(val) needs SET_REMOVE (MapRef-backed); list.remove(idx)
      # uses LIST_REMOVE_AT which pushes (new_list, removed_elem) so we can
      # both rebuild the receiver and produce the removed element as the
      # expression value. pool.remove(id) is in-place: set list[id] = Nil.
      tag = node.stdlib_def && node.stdlib_def[:tag]
      arg_hint = expr_type_hint(node.args[0])
      if tag == :set_method || arg_hint == :set
        compile_expr_to_value(node.args[0])
        compile_expr_to_value(node.args[1])
        emit_op(SET_REMOVE)
        # SET_REMOVE pushes Value.Nil; mark :any so stmt-position emits POP.
        push_type(:any); return
      end
      if tag == :pool_method
        # pool.remove(id): list-set!(pool, id, Nil); store back.
        compile_expr_to_value(node.args[0]); pop_type
        compile_expr_to_value(node.args[1]); pop_type
        emit_op(LOAD_CONST, add_const(nil))
        emit_op(NATIVE_CALL, NATIVES["list-set!"], 3)
        recv = node.args[0]
        if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
          emit_store(recv.name.to_s, :any)
        end
        push_type(:any); return
      end
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      emit_op(LIST_REMOVE_AT)
      # Stack: [..., new_list, removed_elem]. Store new_list back to the
      # receiver slot if it's a known binding, then leave the removed
      # element as the expression result. We need to swap-store: store the
      # second-from-top (new_list) without losing the top (removed_elem).
      recv = node.args[0]
      if recv.is_a?(MIR::Ident) && has_slot?(recv.name.to_s)
        # Stash removed elem, store new_list, push removed elem back.
        @list_remove_tmp_counter ||= 0
        @list_remove_tmp_counter += 1
        tmp = "__lrm_#{@list_remove_tmp_counter}"
        alloc_slot(tmp, :any) unless has_slot?(tmp)
        emit_op(STORE_SLOT, @slots[tmp])  # stash removed (no pop)
        emit_op(POP)                      # discard removed from vstack
        emit_store(recv.name.to_s, :any)  # store new_list, pops it
        emit_op(LOAD_SLOT, @slots[tmp])   # restore removed as expr value
      end
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
      # Sets are Value.MapRef in the VM; the string "contains?" native
      # (id 41) only handles strings. Use SET_CONTAINS / MAP_CONTAINS for
      # collection-typed receivers; pool.contains?(id) checks if the
      # backing list has a non-Nil entry at index id.
      tag = node.stdlib_def && node.stdlib_def[:tag]
      arg_hint = expr_type_hint(node.args[0])
      if tag == :pool_method
        # pool.contains?(id) -> (list-ref(pool, id) != Nil)
        compile_expr_to_value(node.args[0]); pop_type
        compile_expr_to_value(node.args[1]); pop_type
        emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
        # Boolify: non-Nil -> true, Nil -> false. NOT NOT.
        emit_op(NOT); emit_op(NOT)
        push_type(:any); return
      end
      compile_expr_to_value(node.args[0])
      compile_expr_to_value(node.args[1])
      if arg_hint == :set
        emit_op(SET_CONTAINS)
      elsif arg_hint == :map
        emit_op(MAP_CONTAINS)
      else
        emit_op(NATIVE_CALL, NATIVES["contains?"], 2)
      end
      push_type(:any); return
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
      # `toFloat(intExpr)` converts Int64 -> Float64. The arg lands on the
      # typed istack (or vstack as Int64Val); INT_TO_F64 expects istack so
      # ensure the arg is on istack first (VAL_TO_I64 wrapper for vstack).
      compile_expr(node.args[0])
      arg_t = pop_type
      case arg_t
      when :i64  then emit_op(INT_TO_F64)
      when :f64  then # already f64 — identity
      else            emit_op(VAL_TO_I64); emit_op(INT_TO_F64)
      end
      push_type(:f64); return
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
    when :random, :timestampMs, :threadCount, :peakMemoryKb, :currentMemoryKb,
         :framePeakBytes
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
    when :strcmp
      # String compare -> -1/0/+1. VM has no native; use eq? for equality
      # case and synthesize a simple lexical compare via a helper if needed.
      # For now, forward via a 2-arg native if registered, else return 0.
      compile_expr_to_value(node.args[0]); pop_type
      compile_expr_to_value(node.args[1]); pop_type
      if NATIVES.key?("strcmp")
        emit_op(NATIVE_CALL, NATIVES["strcmp"], 2)
      else
        emit_op(POP); emit_op(POP)
        emit_op(LOAD_CONST, add_const([:i64, 0]))
      end
      push_type(:any); return
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
    when MIR::UnaryOp
      # Negation/not preserves the operand's typed-stack residency.
      expr_type_hint(node.operand)
    when MIR::BinOp
      lh = expr_type_hint(node.left)
      rh = expr_type_hint(node.right)
      if lh == :i64 && rh == :i64
        case node.op.to_s
        when "==", "!=", "<", ">", "<=", ">=" then :bool
        else :i64
        end
      elsif lh == :f64 && rh == :f64
        case node.op.to_s
        when "==", "!=", "<", ">", "<=", ">=" then :bool
        else :f64
        end
      else
        :any
      end
    when MIR::InlineBc
      # Arithmetic ops route through compile_binop, which stays on the
      # istack only when BOTH operands hint as :i64. Mirror that here so
      # downstream callers don't assume typed-stack residency in mixed
      # cases. :length and :charAt always emit to the vstack via NATIVE_CALL,
      # so they remain :any.
      case node.op
      when :intAdd, :intSub, :intMul, :intDiv, :intMod,
           :wrapAdd, :wrapSub, :wrapMul
        a = node.args[0] && expr_type_hint(node.args[0])
        b = node.args[1] && expr_type_hint(node.args[1])
        (a == :i64 && b == :i64) ? :i64 : :any
      else :any
      end
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
    when "wrap+", "wrap-", "wrap*"
      wrap_op = { "wrap+" => WRAP_ADD_I64, "wrap-" => WRAP_SUB_I64, "wrap*" => WRAP_MUL_I64 }.fetch(op)
      # Wrap-arithmetic always uses two's-complement on i64. If the operand
      # type-stack tags don't already say :i64, hoist the values from vstack
      # to istack via VAL_TO_I64 (top first, then under). This preserves
      # wrap semantics regardless of where the values landed (typed stack
      # for compile-time-known i64s, vstack for runtime values from :any
      # slots / params). Falling back to the untyped MUL/ADD/SUB would
      # panic on overflow for `*` semantics — wrong for `%*`.
      coerce_top_to_istack = ->(t) {
        case t
        when :i64 then nil  # already on istack
        else
          # Move from vstack to istack. ensure_value_stack first if value
          # is on a different typed stack (:f64 / :bool).
          case t
          when :f64  then emit_op(F_TO_VAL)
          when :bool then emit_op(BOOL_TO_VAL)
          end
          emit_op(VAL_TO_I64)
        end
      }
      if both_i64 then emit_op(wrap_op); push_type(:i64)
      else
        # Coerce right (top of stack) first so left stays underneath.
        coerce_top_to_istack.call(right_type)
        # Coerce left: it's beneath right on whichever stack it landed.
        # If left is :i64 already, skip. Otherwise we need to swap before
        # coercing — but the runner has no SWAP. Easiest path: re-walk
        # via vstack with a temp slot.
        if left_type != :i64
          # Stash right on a temp val slot so we can coerce left.
          @wrap_tmp_counter ||= 0
          @wrap_tmp_counter += 1
          tmp = "__wraptmp_#{@wrap_tmp_counter}"
          alloc_slot(tmp, :i64) unless has_slot?(tmp)
          emit_op(STORE_ISLOT, @islots[tmp])  # right is on istack
          coerce_top_to_istack.call(left_type)  # now left is on top
          emit_op(LOAD_ISLOT, @islots[tmp])  # right back on top
        end
        emit_op(wrap_op); push_type(:i64)
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
      # MOD_I64 stays on the istack; NATIVE_CALL modulo pushes its result
      # onto the vstack as Value.Int64Val. Tag the type stack accordingly
      # so downstream emit_store / I_TO_VAL pick the right path. Tagging
      # both as :i64 mis-routes the vstack case through I_TO_VAL on an
      # empty istack.
      if both_i64
        emit_op(MOD_I64); push_type(:i64)
      else
        emit_op(NATIVE_CALL, NATIVES["modulo"], 2); push_type(:any)
      end
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
    # Result is Value.TrueVal/FalseVal on the value stack (compile_expr_to_value
    # + LOAD_CONST [:bool] both push to vstack). push_type(:bool) would
    # mislead callers (compile_while, compile_let) into emitting istack-only
    # opcodes (JUMP_IF_FALSE_I, etc.) → istack underflow.
    push_type(:any)
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
    push_type(:any)
  end

  def compile_unary(node)
    # Stay on the typed istack/fstack when the operand is an int/float
    # literal so subsequent typed ops (DIV_I64 et al.) preserve int
    # truncation semantics. compile_expr (not compile_expr_to_value)
    # leaves the value on its native stack.
    compile_expr(node.operand)
    t = pop_type
    case node.op
    when "!", "not"
      ensure_value_stack if respond_to?(:ensure_value_stack, true)
      emit_op(NOT); push_type(:any)
    when "-"
      case t
      when :i64
        @neg_tmp_counter ||= 0; @neg_tmp_counter += 1
        tmp = "__mneg_tmp_#{@neg_tmp_counter}"
        @islots[tmp] = (@next_islot ||= 0); @next_islot += 1
        emit_op(STORE_ISLOT, @islots[tmp])
        emit_op(LOAD_CONST_I64, add_const([:i64, 0]))
        emit_op(LOAD_ISLOT, @islots[tmp])
        emit_op(SUB_I64)
        push_type(:i64)
      when :f64
        emit_op(LOAD_CONST_F64, add_const([:f64, -1.0]))
        emit_op(MUL_F64)
        push_type(:f64)
      else
        emit_op(LOAD_CONST, add_const([:i64, -1]))
        emit_op(MUL); push_type(:any)
      end
    end
  end

  # ================================================================
  # Function calls
  # ================================================================

  def compile_call_expr(node)
    callee = node.callee.to_s.sub(/\Atry /, "")

    # Skip rt arg: always first if present. BG-fiber bodies refer to the
    # runtime via a synthetic name like `__rt_bg0` (Zig codegen scaffolding);
    # strip those too so the callee's slot layout matches.
    args = node.args.reject { |a|
      a.is_a?(MIR::Ident) && (a.name.to_s == "rt" || a.name.to_s =~ /\A__rt_bg\d+\z/)
    }
    # Skip &address-of wrapper
    args = args.map { |a| a.is_a?(MIR::AddressOf) ? a.expr : a }

    # Strip leading comptime type-arg Idents for generic fns. The MIR call
    # for `identity<f64>(42.0)` is Call("identity", [Ident("f64"), Lit(42.0)]).
    # The VM has no comptime; type arg Idents would land in the helper's
    # slot 0 (the formal type parameter) shifting all real args by one.
    if @fn_comptime_arity && (n = @fn_comptime_arity[callee])
      args = args.drop(n)
    end

    # Zig's std.debug.print is how macro_print (CLEAR's `print`) is emitted.
    # Args are: [format_string_lit, tuple_ident_like ".{a, b, c}"]. The
    # tuple Ident's name is a raw Zig snippet we can't parse; recover the
    # formatted arg list from the AST when available, or best-effort from
    # the tuple-literal string contents.
    if callee == "std.debug.print"
      # AST-first path: when we have the original print(...) AST, we can
      # compile each arg via compile_ast_expr — that handles arbitrary
      # method chains (s.length(), p.contains?(x), x.toString()) without
      # the brittle string regex parser below.
      ast_print_args = ast_print_args_from(@current_ast_stmt)
      if ast_print_args
        ast_print_args.each do |aarg|
          compile_ast_print_arg(aarg)
        end
        emit_op(LOAD_CONST, add_const([:str, "\n"]))
        emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
        emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
      end
      # Pull arg names out of the synthetic tuple Ident (name is ".{a, b}").
      tuple = args[1]
      if tuple.is_a?(MIR::Ident) && tuple.name.to_s =~ /\A\.\{(.*)\}\z/m
        inner = $1
        # Strip Zig wrappers iteratively, but only the formatting/conversion
        # ones: `try`, `@as(T, V)`, `@intFromFloat(V)`, `@floatFromInt(V)`,
        # and `CheatLib.intToString(alloc, V)` / `CheatLib.floatToString`.
        # Keep operational CheatLib calls (`CheatLib.len`, `CheatLib.getAt`,
        # `CheatLib.indexOf`, ...) intact so the printer can dispatch them
        # to the right native instead of taking their first slot-arg as
        # the value (which would print the container, not the result).
        peelable_calls = %w[
          CheatLib.intToString CheatLib.floatToString CheatLib.numberToString
        ].freeze
        unwrap = lambda do |p|
          loop do
            stripped = p.strip
            if stripped =~ /\Atry\s+(.*)\z/m
              p = $1.strip; next
            end
            # `("STR")[N..]` and `("STR")[N..M]` — Zig string-literal slice
            # produced by the lowering when materializing a const string for
            # std.debug.print. The slice is structural (always 0..), so the
            # contents are equivalent to the inner literal for VM display.
            if stripped =~ /\A\("(.*)"\)\[\d*\.\.\d*\]\z/m
              p = "\"#{$1}\""; next
            end
            # Bare parenthesized expression: `(EXPR)` -> `EXPR`.
            # Only peel when the outer parens enclose a balanced expression
            # (depth never returns to 0 mid-string).
            if stripped =~ /\A\((.+)\)\z/m
              inner_p = $1
              depth = 0; balanced = true
              inner_p.each_char do |c|
                if c == '('
                  depth += 1
                elsif c == ')'
                  depth -= 1
                  if depth < 0 then balanced = false; break end
                end
              end
              if balanced && depth == 0
                p = inner_p; next
              end
            end
            if stripped =~ /\A([@\w][\w.]*)\s*\((.*)\)\s*\z/m
              fn = $1; argstr = $2
              args_split = split_print_tuple(argstr).map(&:strip)
              if args_split.length >= 1 && (
                   fn == "@as" || fn == "@intFromFloat" || fn == "@floatFromInt" ||
                   peelable_calls.include?(fn))
                p = args_split.last; next
              end
            end
            break
          end
          p.strip
        end
        # std.mem.concat(allocator, T, &.{S1, S2, ...}) -> dispatch to each
        # array literal element. The lowering builds this for `"a" + b + "c"`
        # patterns inside print(...). Without the rewrite, the whole concat
        # call falls into the unknown-expr LOAD_NAME branch and prints "nil".
        rewritten = inner
        loop do
          stripped = rewritten.strip
          peeled = stripped.sub(/\Atry\s+/, "")
          if peeled =~ /\Astd\.mem\.concat\s*\(/
            # Find matching close paren of the outer call.
            i = peeled.index("(")
            depth = 0; close_idx = nil
            (i...peeled.length).each do |k|
              c = peeled[k]
              if c == "("
                depth += 1
              elsif c == ")"
                depth -= 1
                if depth == 0 then close_idx = k; break end
              end
            end
            break unless close_idx
            argstr = peeled[(i+1)...close_idx]
            cargs = split_print_tuple(argstr)
            # Last arg is `&.{S1, S2, ...}` (or `.{ ... }`).
            last = cargs.last&.strip
            break unless last
            arr_inner = nil
            if last =~ /\A&?\s*\.\{(.*)\}\z/m
              arr_inner = $1
            end
            break unless arr_inner
            rewritten = arr_inner
          else
            break
          end
        end
        parts = split_print_tuple(rewritten).map { |p| unwrap.call(p) }
        parts.each do |raw|
          if raw =~ /\A"(.*)"\z/m
            str = $1.gsub(/\\n/, "\n").gsub(/\\t/, "\t").gsub(/\\"/, '"').gsub(/\\\\/, '\\')
            emit_op(LOAD_CONST, add_const([:str, str]))
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          elsif raw =~ /\ACheatLib\.len\((.+)\)\z/m && (sub = $1.strip; emit_print_subexpr(sub))
            # `CheatLib.len(EXPR)` -> count(EXPR) native, leaving Value.Int64Val.
            # emit_print_subexpr loaded EXPR onto vstack; finalize with count + display.
            emit_op(NATIVE_CALL, NATIVES["count"], 1)
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          elsif raw =~ /\ACheatLib\.getAt\((.+),\s*(\d+)\)\z/m && (sub = $1.strip; idx = $2.to_i; emit_print_subexpr(sub))
            # `CheatLib.getAt(EXPR, N)` -> list-ref(EXPR, N).
            emit_op(LOAD_CONST, add_const([:i64, idx]))
            emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          elsif raw =~ /\A([a-zA-Z_]\w*)\.(length|count)\(\s*\)\z/ && has_slot?($1)
            # `obj.length()` / `obj.count()` — collection size; opcode depends on slot kind.
            obj_name = $1
            emit_load_any(obj_name)
            t = @slot_types[obj_name]
            if t == :set || t == :map
              emit_op(MAP_LENGTH)
            else
              emit_op(NATIVE_CALL, NATIVES["count"], 1)
            end
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          elsif raw =~ /\A([a-zA-Z_]\w*)\.([a-zA-Z_]\w*)\z/ && has_slot?($1)
            # `obj.field` access against a known slot — emit FieldGet via vector-ref.
            obj_name = $1; fld = $2
            emit_load_any(obj_name)
            struct_name = nil
            t = @slot_types[obj_name]
            if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
              struct_name = t.to_s.sub(/\Astruct_/, "")
            end
            idx = find_field_index(fld, struct_name: struct_name)
            if idx
              emit_op(LOAD_CONST, add_const([:i64, idx]))
              emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
            end
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          elsif has_slot?(raw)
            emit_load_any(raw)
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          else
            # Unknown expression — fall back to LOAD_NAME (likely prints nil
            # but doesn't crash).
            emit_op(LOAD_NAME, add_const(raw))
            emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
          end
        end
        # print() always ends with a newline (the {s}\n style format string).
        emit_op(LOAD_CONST, add_const([:str, "\n"]))
        emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      end
      emit_op(LOAD_CONST, add_const(nil)); push_type(:any); return
    end

    # Compiled helper function: emit direct BC_CALL with the fixed target IP
    # recorded when the helper body was laid out. Bypasses name lookup.
    # Also strip a leading namespace prefix (e.g. `require_helper.addPub`) so
    # REQUIRE-imported helpers resolve to the bare-named FnDef the lowering
    # emitted under the local helper region.
    helper_callee = callee
    helper_callee = helper_callee.split(".").last if !@fn_start_ips.key?(helper_callee) && helper_callee.include?(".")
    if @fn_start_ips.key?(helper_callee)
      args.each { |a| compile_expr_to_value(a) }
      emit_op(BC_CALL, @fn_start_ips[helper_callee], args.length)
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

    # CheatLib.makeList(T, alloc, items): produce a fresh growable list
    # initialized from `items`. In the VM, Value.List already supports
    # growth and there's no T/alloc distinction — forward `items`.
    if callee == "CheatLib.makeList"
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

  # The outer CATCH-wrapper FN is structurally:
  #   try __<inner>_body(rt, ...args) catch { ...clauses... }
  # In the VM, compile to:
  #   1. BC_CALL the inner fn with the same args we received.
  #   2. Peek the result; IS_ERR test.
  #   3. If error: parse CatchWrapper.code for `matchesKind(.X)` clauses and
  #      walk them in order, comparing GET_ERR_KIND to each kind. The matching
  #      clause's body is one of the pre-lowered clause_bodies. The `else`
  #      arm is the final clause_body (default).
  #   4. If not error: BC_RET that value.
  def compile_catch_wrapper(node)
    code = node.code.to_s
    inner_call = code[/return\s+(\w+)\s*\(\s*([^)]*)\)\s*catch/, 1]
    inner_args = code[/return\s+\w+\s*\(\s*([^)]*)\)\s*catch/, 1]
    arg_names = (inner_args || "").split(/,\s*/).map(&:strip).reject(&:empty?)
    # Each clause's match info: extract `matchesKind(.X)` (and optional
    # `matchesName(@intFromEnum(ErrorName.Y))`). The else arm has none.
    clause_kinds = []
    code.scan(/(?:if|else if)\s*\(rt\.__error\.matchesKind\(\.(\w+)\)(?:\s+and\s+rt\.__error\.matchesName\(@intFromEnum\(ErrorName\.(\w+)\)\))?\)/).each do |kind, name|
      clause_kinds << { kind: kind, name: name }
    end
    has_default = code.include?("} else {")
    # Sanity: clause_bodies length should equal clause_kinds.length + (default ? 1 : 0).

    if inner_call.nil? || !@fn_start_ips.key?(inner_call)
      raise Unimplemented, "compile_catch_wrapper: inner fn `#{inner_call}` has no entry"
    end

    # Push args matching the names parsed from the Zig call. Each name
    # should be a current parameter slot (set by compile_helper_fn_mir's
    # param prologue) or `rt` (skipped). `rt` is always first; the helper
    # at the inner_call entry expects 0 args (rt is auto-passed by the
    # interpreter via callSavedSlots), so skip rt and emit only the rest.
    user_args = arg_names.reject { |n| n == "rt" }
    user_args.each do |name|
      emit_load_any(name)
    end
    emit_op(BC_CALL, @fn_start_ips[inner_call], user_args.length)
    push_type(:any)
    # After BC_CALL the result Value is on top of vstack. Peek IS_ERR.
    # IS_ERR pops; we want to keep the value for the success path. Save
    # to a temp slot.
    @catch_tmp_counter ||= 0; @catch_tmp_counter += 1
    tmp = "__catch_res_#{@catch_tmp_counter}"
    alloc_slot(tmp, :any)
    emit_op(STORE_SLOT, @slots[tmp]); pop_type
    emit_op(LOAD_SLOT, @slots[tmp])
    emit_op(IS_ERR)
    # If NOT error: jump past clause dispatch and BC_RET the saved value.
    emit_op(JUMP_IF_FALSE)
    not_err_jump = @ops.length; emit_op(0)
    # Error path: load tmp again, GET_ERR_KIND, walk clause_kinds.
    end_jumps = []
    bodies = (node.clause_bodies || [])
    clause_kinds.each_with_index do |ck, ci|
      # GET_ERR_KIND peeks; we want it on top to compare. Load result, then GET_ERR_KIND.
      emit_op(LOAD_SLOT, @slots[tmp])
      emit_op(GET_ERR_KIND)
      # Result is now Value.Str(errKind). Move it forward so we don't keep the error under it.
      # Actually GET_ERR_KIND pushes errKind on top WITHOUT popping the error — stack is now [..., err, errKind].
      # We want to compare errKind to ck[:kind] then JUMP_IF_FALSE. EQ pops 2.
      # So we have: [..., err, errKind, "Kind"]; EQ pops 2 → bool; stack [..., err, bool].
      emit_op(LOAD_CONST, add_const([:str, ck[:kind]]))
      emit_op(EQ)
      emit_op(JUMP_IF_FALSE)
      skip_idx = @ops.length; emit_op(0)
      # Drop the error from the stack before running the clause body.
      emit_op(POP)
      # Compile the clause body.
      body = bodies[ci] || []
      semantic_mir_nodes(body).each { |s| compile_stmt(s, nil); pop_type }
      emit_op(JUMP); end_jumps << @ops.length; emit_op(0)
      @ops[skip_idx] = @ops.length
      # On non-match, we still have [..., err, bool] -- drop the bool.
      # Actually JUMP_IF_FALSE consumed the bool. So stack is [..., err]. Loop continues.
    end
    # Default body: drop the error and run.
    if has_default
      emit_op(POP)  # drop the err that's still on top
      default_body = bodies.last || []
      semantic_mir_nodes(default_body).each { |s| compile_stmt(s, nil); pop_type }
    else
      # No default and nothing matched: rethrow the error.
      emit_op(BC_RET)
    end
    # After clause body has run and BC_RET'd inside its body, this point
    # is unreachable; if a clause body fell through (no return), we land
    # here and the result is on stack. That's a no-op.
    end_jumps.each { |idx| @ops[idx] = @ops.length }
    # NOT-error path target: load saved value and BC_RET.
    @ops[not_err_jump] = @ops.length
    emit_op(LOAD_SLOT, @slots[tmp])
    emit_op(BC_RET)
    @helper_fn_returned = true
    pop_type
    push_type(:void)
  end

  # Detect the lowering shape `lower_raise` produces:
  #   ScopeBlock([ExprStmt(MethodCall(rt, "setError", [.Kind, name_id, msg, line])),
  #               ReturnStmt(Ident("error.CheatError"))])
  # Return [kind_string, msg_mir_expr] when matched, nil otherwise.
  def detect_raise_scope(node)
    return nil unless node.is_a?(MIR::ScopeBlock)
    body = node.body
    return nil unless body.is_a?(Array) && body.length == 2
    err_call, ret_stmt = body
    return nil unless err_call.is_a?(MIR::ExprStmt)
    return nil unless ret_stmt.is_a?(MIR::ReturnStmt) &&
                      ret_stmt.value.is_a?(MIR::Ident) &&
                      ret_stmt.value.name.to_s == "error.CheatError"
    call = err_call.expr
    return nil unless call.is_a?(MIR::MethodCall) &&
                      call.method.to_s == "setError"
    return nil unless call.args.length >= 3
    kind_arg = call.args[0]
    msg_arg  = call.args[2]
    return nil unless kind_arg.is_a?(MIR::Ident) && kind_arg.name.to_s.start_with?(".")
    [kind_arg.name.to_s.sub(/\A\./, ""), msg_arg]
  end

  # Strip allocator arguments: bare `rt` idents, `rt.heapAlloc()` calls,
  # MIR::AllocatorRef nodes, and pipeline_host's InlineZig("rt.heapAlloc()")
  # stand-ins (reason == "alloc").
  def strip_alloc_args(args)
    args.reject { |a|
      a.is_a?(MIR::AllocatorRef) ||
      (a.is_a?(MIR::Ident) && (a.name.to_s == "rt" || a.name.to_s == "alloc")) ||
      (a.is_a?(MIR::MethodCall) && a.method.to_s == "heapAlloc") ||
      (a.is_a?(MIR::InlineZig) && a.reason.to_s == "alloc")
    }
  end

  def compile_method_call_expr(node)
    method = node.method.to_s
    # Resolve through FieldGet so `h.data.get(k)` (where data is a HashMap
    # field on a struct) routes through MAP_GET, not the UFCS fallback.
    rtype  = expr_collection_kind(node.receiver)

    # rt.checkYield() is a fiber-cooperation hook for the Zig runtime. The VM
    # has no fiber scheduler, so the call is dead weight. Skip without emitting
    # any ops; without this, the lowering inserts a name-resolved CALL per
    # loop iteration which dominates VM hot paths (env HashMap lookup +
    # getSymName string concat) and pushes simple workloads ~60x slower than
    # Ruby. Receiver detection: `rt.checkYield()` arrives as MIR::MethodCall
    # whose receiver is the literal Ident "rt".
    if method == "checkYield" && node.receiver.is_a?(MIR::Ident) && node.receiver.name.to_s == "rt"
      push_type(:any)
      emit_op(LOAD_CONST, add_const(nil))
      return
    end

    # NEXT on a promise (future-like value). Emit AWAIT opcode which
    # unwraps a Pair(Symbol("__future__"), result) to the held result;
    # identity on non-future values.
    if method == "next" && node.args.empty?
      compile_expr(node.receiver); pop_type
      emit_op(AWAIT)
      push_type(:any)
      return
    end

    # @alwaysMutable's `.get()` accessor: in the Zig backend it unwraps a
    # RefCell-style wrapper. In the VM, values are stored directly (no
    # interior-mutability box), so `.get()` is identity. Don't fall through
    # to UFCS — there's no top-level `get` function.
    if method == "get" && node.args.empty? && rtype != :map
      compile_expr(node.receiver)
      return
    end

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

    # Pipeline-host-emitted MIR::MethodCall for `list.append(alloc, val)`
    # bypasses lower_method_call, so it doesn't carry matched_stdlib_def
    # and never reaches the InlineBc :append dispatch. Route it directly
    # to the same list-push storeback the InlineBc path uses, so pipeline
    # WINDOW/JOIN/etc. accumulators actually mutate.
    if method == "append" && args.length == 1
      compile_expr_to_value(node.receiver); pop_type
      compile_expr_to_value(args[0]); pop_type
      emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
      if node.receiver.is_a?(MIR::Ident) && has_slot?(node.receiver.name.to_s)
        emit_store(node.receiver.name.to_s, :any)
        emit_op(POP)
      end
      push_type(:any)
      return
    end

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
    # so node.fields has at most one entry here. Strip any generic suffix
    # so `Option(Float64){Some: ...}` resolves to the registered `Option`
    # union schema (otherwise the lookup misses and we fall through to the
    # plain-struct path, which constructs a vector instead of a cons-pair).
    union_lookup = zig_type
    union_lookup = $1 if zig_type =~ /\A([A-Za-z_]\w*)\(/
    if @union_types&.include?(union_lookup)
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

    # Plain struct: positional fields through `vector`. Stamp the struct
    # base name onto the type stack so compile_let can scope find_field_index
    # for accesses against the resulting slot. Without this, when two
    # structs share a field name (e.g. KeyValue<K,V>{key, value} and
    # Wrapper<T>{value}), find_field_index returns whichever is registered
    # first, which mis-routes `kv.value` to index 0 (kv.key).
    base = struct_base_name(zig_type)
    schema_names = base ? (@struct_fields[base] || []) : []
    # If the literal omits fields that have schema-level defaults, the Zig
    # backend fills them silently. Match that here so `Config{}` (all
    # defaulted) and `Config{ retries: 5 }` (timeout defaults to 1000)
    # both produce the right vector instead of an empty / partial one.
    field_values = if schema_names.any? && node.fields.length < schema_names.length
      provided = {}
      node.fields.each { |f| provided[f[:name].to_s] = f[:value] }
      defaults = base ? (@struct_defaults[base] || []) : []
      schema_names.each_with_index.map do |fname, idx|
        provided[fname] || defaults[idx]
      end
    else
      node.fields.map { |f| f[:value] }
    end
    field_values.each_with_index do |v, idx|
      if v.nil?
        # No default and no provided value — emit nil sentinel so vector-ref
        # at least returns something rather than reading past the end.
        emit_op(LOAD_CONST, add_const(nil))
      elsif v.is_a?(AST::DefaultLit)
        # DEFAULT for a struct-typed field: construct an empty struct of the
        # field's declared type. The schema knows the type — drill down for
        # nested-default-from-default support.
        compile_default_for_field(base, schema_names[idx])
      elsif v.is_a?(AST::Literal)
        # Schema-default ASTs reach us as raw AST literals; compile via the
        # AST path which already handles primitive types (Int64/Float64/
        # String/Bool/Nil).
        compile_ast_expr_to_value(v); pop_type
      else
        compile_expr_to_value(v); pop_type
      end
    end
    emit_op(NATIVE_CALL, NATIVES["vector"], field_values.length)
    push_type(base ? :"struct_#{base}" : :any)
  end

  # Emit a default value for `parent_struct.field_name`. If the field type
  # is itself a registered struct, recurse via a synthesized empty StructInit;
  # otherwise emit nil (caller hits this for fields that have no schema
  # default and no DEFAULT keyword either).
  def compile_default_for_field(parent_struct, field_name)
    fields_hash = (@result.struct_schemas || {})[parent_struct&.to_sym]
    spec = fields_hash.is_a?(Hash) ? fields_hash[field_name] : nil
    type_obj = spec.is_a?(Hash) ? spec[:type] : nil
    raw_type = type_obj.respond_to?(:raw) ? type_obj.raw.to_s : type_obj.to_s
    if @struct_fields.key?(raw_type)
      # Recursively construct the inner struct with all defaults.
      synth = MIR::StructInit.new(raw_type, [])
      compile_struct_init(synth); pop_type
    else
      emit_op(LOAD_CONST, add_const(nil))
    end
  end

  # Strip generic instantiation suffix from a zig type so we get the
  # bare struct name registered in @struct_fields. `Pair(Float64)` -> `Pair`,
  # `KeyValue(Float64, Bool)` -> `KeyValue`, `User` -> `User`. Used to
  # disambiguate same-named fields across distinct struct types.
  def struct_base_name(zig_type)
    s = zig_type.to_s
    base = s[/\A([A-Za-z_]\w*)/, 1]
    return nil unless base && @struct_fields.key?(base)
    base
  end

  # Pre-walk a body collecting MIR::AllocMark struct hints into
  # @alloc_struct_hints[name] = base_struct_name. compile_let consults
  # this when its emitted val_type is :any so function-call inits
  # (which lose type info) still produce a struct-typed slot.
  def walk_for_alloc_marks(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |s|
      next unless s.is_a?(MIR::AllocMark)
      ti = s.type_info
      raw = if ti.respond_to?(:raw) then ti.raw
            elsif ti.is_a?(Symbol) then ti
            else nil
            end
      next if raw.nil?
      base = raw.to_s[/\A([A-Za-z_]\w*)/, 1]
      next if base.nil? || base.empty?
      next unless @struct_fields.key?(base)
      @alloc_struct_hints[s.name.to_s] = base
    end
  end

  def compile_field_get(node)
    # Enum variant: Type.Variant → Scheme symbol
    if node.object.is_a?(MIR::Ident) && @enum_types&.include?(node.object.name.to_s)
      emit_op(LOAD_CONST, add_const(node.field.to_s))
      push_type(:any)
      return
    end

    # Union-variant payload access: MATCH `Value.Str AS s` lowers to
    # `Let s = FieldGet(v, "Str")`. The VM represents the union as
    # Pair(car=Symbol("Str"), cdr=payload), so emit cdr(obj). The
    # @union_variant_names set is pre-built from all union schemas
    # (and stripped of any name that also appears as a struct field
    # to avoid mis-routing struct.field accesses).
    if @union_variant_names&.include?(node.field.to_s)
      compile_expr_to_value(node.object); pop_type
      emit_op(NATIVE_CALL, NATIVES["cdr"], 1)
      push_type(:any)
      return
    end

    # Zig-specific list "decomposition" fields. In Zig, an
    # std.ArrayListUnmanaged(T) exposes `.items` (the []T slice) and the
    # slice in turn exposes `.len` (int). In the VM there's no
    # ArrayList-around-slice indirection — lists are Value.List directly,
    # strings are Value.Str. Treat `x.items` as identity and `x.len`
    # as a length() native call.
    #
    # IMPORTANT: only fire this short-circuit when the receiver is NOT a
    # user struct that defines a real `items` / `len` field. Otherwise
    # a ListHolder{ items: ..., label: ... } with a literal `items` field
    # would be passed through unchanged (h1.items === h1) and the asserts
    # downstream count h1 instead of h1.items.
    field_name = node.field.to_s
    if field_name == "items" || field_name == "len"
      receiver_struct = nil
      if node.object.is_a?(MIR::Ident)
        t = @slot_types[node.object.name.to_s]
        if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
          receiver_struct = t.to_s.sub(/\Astruct_/, "")
        end
      end
      has_real_field = receiver_struct &&
        @struct_fields[receiver_struct]&.include?(field_name)
      unless has_real_field
        if field_name == "items"
          compile_expr_to_value(node.object); pop_type
          push_type(:any)
          return
        else
          compile_expr_to_value(node.object); pop_type
          emit_op(NATIVE_CALL, NATIVES["count"], 1)
          push_type(:any)
          return
        end
      end
    end
    # Arc/Rc unwrap synthetic fields: in the Zig backend, multiowned/shared
    # values are wrapped in an Arc(T)/Rc(T) struct exposing `.ctrl.data.*` to
    # access the inner T. The VM stores the inner value directly (CapWrap is a
    # no-op on the value side — see MIR::CapWrap dispatch above), so the
    # unwrap chain must collapse to identity. Without this, `a.value` lowers
    # to `a.ctrl.data.value` and vector-ref(Nil, idx) returns 0.
    #
    # Guard against shadowing user-declared fields named `ctrl` or `data`:
    # only collapse when the receiver isn't a user struct that actually
    # defines this field (otherwise `MapHolder.data: HashMap` becomes
    # identity-h, and h2.data["x"] reads from h2's vector instead of the map).
    if node.field.to_s == "ctrl" || node.field.to_s == "data"
      receiver_struct = nil
      if node.object.is_a?(MIR::Ident)
        t = @slot_types[node.object.name.to_s]
        if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
          receiver_struct = t.to_s.sub(/\Astruct_/, "")
        end
      end
      has_real_field = receiver_struct &&
        @struct_fields[receiver_struct]&.include?(node.field.to_s)
      unless has_real_field
        compile_expr_to_value(node.object); pop_type
        push_type(:any)
        return
      end
    end

    # Receiver-typed lookup: if the receiver is an Ident slot stamped with
    # a `:struct_<Name>` type (set by compile_struct_init via push_type),
    # scope find_field_index to that struct's field list. Without this,
    # find_field_index returns the first match across ALL struct schemas,
    # which mis-routes `kv.value` (KeyValue idx 1) to whichever struct's
    # `value` field appears first in @struct_fields (e.g. Wrapper idx 0).
    receiver_struct = nil
    if node.object.is_a?(MIR::Ident)
      t = @slot_types[node.object.name.to_s]
      if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
        receiver_struct = t.to_s.sub(/\Astruct_/, "")
      end
    end
    compile_expr_to_value(node.object)
    idx = find_field_index(node.field, struct_name: receiver_struct)
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
    kind = expr_collection_kind(node.object)
    if kind == :map
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

  # Resolve whether `node` refers to a `:map`, `:set`, or other collection.
  # Direct Idents look up their slot type; FieldGet recurses through the
  # struct schema so `h.data` (where data is `HashMap<...>`) routes
  # through MAP_GET / MAP_PUT instead of list-ref / list-set!.
  def expr_collection_kind(node)
    return receiver_slot_type(node) if node.is_a?(MIR::Ident)
    if node.is_a?(MIR::FieldGet) && node.object.is_a?(MIR::Ident)
      t = @slot_types[node.object.name.to_s]
      return :any unless t.is_a?(Symbol) && t.to_s.start_with?("struct_")
      sname = t.to_s.sub(/\Astruct_/, "")
      schema = (@result.struct_schemas || {})[sname.to_sym]
      return :any unless schema.is_a?(Hash)
      spec = schema[node.field.to_s]
      return :any unless spec.is_a?(Hash)
      ftype = spec[:type]
      if ftype.respond_to?(:collection)
        case ftype.collection
        when :set then return :set
        when :map then return :map
        end
      end
      raw = ftype.respond_to?(:raw) ? ftype.raw.to_s : ftype.to_s
      return :map if raw.start_with?("HashMap") || raw.start_with?("StringMap") ||
                     raw.start_with?("NumericMap")
      return :set if raw.start_with?("Set") || raw.start_with?("HashSet")
    end
    :any
  end

  def find_field_index(field_name, struct_name: nil)
    fname = field_name.to_s
    if struct_name && @struct_fields.key?(struct_name)
      idx = @struct_fields[struct_name].index(fname)
      return idx if idx
    end
    @struct_fields.each_value do |fields|
      idx = fields.index(fname)
      return idx if idx
    end
    nil
  end

  # Split a `.{a, b, c}` tuple literal's inner text on top-level commas
  # only, respecting nested parens / braces / brackets / quoted strings.
  # The naive `inner.split(/,\s*/)` shreds calls like
  #   try CheatLib.intToString(alloc, @as(i64, @intFromFloat(p.first)))
  # into 3 pieces and breaks every print(p.field.toString()) call.
  def split_print_tuple(inner)
    out = []
    depth = 0
    in_quote = false
    cur = +""
    i = 0
    while i < inner.length
      c = inner[i]
      if in_quote
        cur << c
        if c == "\\" && i + 1 < inner.length
          cur << inner[i + 1]; i += 2; next
        end
        in_quote = false if c == '"'
      elsif c == '"'
        in_quote = true; cur << c
      elsif "([{".include?(c)
        depth += 1; cur << c
      elsif ")]}".include?(c)
        depth -= 1; cur << c
      elsif c == "," && depth == 0
        out << cur; cur = +""
      else
        cur << c
      end
      i += 1
    end
    out << cur unless cur.empty?
    out
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
    then_type = pop_type   # only one branch runs at runtime — exactly
    emit_op(JUMP); patch_end = @ops.length; emit_op(0)
    @ops[patch_false] = @ops.length
    compile_expr(node.else_val)
    else_type = pop_type   # one type-stack slot survives, pushed below
    @ops[patch_end] = @ops.length
    # Result type: prefer agreement; otherwise fall back to :any so callers
    # don't assume a specific typed-stack residency.
    push_type(then_type == else_type ? then_type : :any)
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
    # BlockExpr leaves a single value on the stack. Two break shapes show
    # up here: (1) a top-level BreakStmt as the last (or every-branch) stmt,
    # which compile_expr handles inline; (2) BreakStmt nested inside an
    # IfStmt / IfChain body for the `IF cond THEN <expr> ELSE <expr> END`
    # expression form. Case (2) needs a labeled jump out of the block,
    # so we set up @block_break_patches that compile_stmt(BreakStmt)
    # consumes -- emit value to vstack, JUMP to block exit.
    stmts = semantic_mir_nodes(node.body)
    last_break_type = :any
    saved_block_breaks = @block_break_patches
    saved_block_types  = @block_break_types
    @block_break_patches = []
    @block_break_types   = []
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
    # Patch all nested BreakStmt jumps to land here (after the trailing
    # value already on the stack from the fallthrough path).
    @block_break_patches.each { |idx| @ops[idx] = @ops.length }
    # The block's result type is the agreement across all break paths.
    # If the last stmt was a control-flow node (IfStmt etc.) that doesn't
    # itself yield a value, last_break_type is :void — that's a "no value
    # at this join" marker, not a type to agree on, so drop it from the
    # consensus (the Breaks are the only paths that actually pushed
    # something at the join). When there are no Breaks, last_break_type is
    # the only signal.
    types = @block_break_types.dup
    types << last_break_type if types.empty? || last_break_type != :void
    types.uniq!
    STDERR.puts "block_expr types: #{types.inspect}" if ENV["BC_TRACE_BLK"]
    @block_break_patches = saved_block_breaks
    @block_break_types   = saved_block_types
    push_type(types.length == 1 ? types.first : :any)
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
        emit_store(name, val_type)  # authoritative @slot_types update
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
      elsif @fn_start_ips.key?(name)
        # User-defined helper fn compiled into bytecode: use BC_CALL.
        # LOAD_NAME would do a dynamic env lookup that doesn't see helpers.
        node.args.each { |a| compile_ast_expr_to_value(a) }
        emit_op(BC_CALL, @fn_start_ips[name], node.args.length)
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
    obj_kind = ast_receiver_kind(node.object)
    case name
    when "length", "count"
      compile_ast_expr_to_value(node.object)
      if obj_kind == :set || obj_kind == :map
        emit_op(MAP_LENGTH)
      else
        emit_op(NATIVE_CALL, NATIVES["list-length"], 1)
      end
      push_type(:any)
    when "contains?"
      compile_ast_expr_to_value(node.object)
      compile_ast_expr_to_value(node.args[0])
      if obj_kind == :set
        emit_op(SET_CONTAINS)
      elsif obj_kind == :map
        emit_op(MAP_CONTAINS)
      else
        emit_op(NATIVE_CALL, NATIVES["contains?"], 2)
      end
      push_type(:any)
    when "insert"
      compile_ast_expr_to_value(node.object)
      compile_ast_expr_to_value(node.args[0])
      if obj_kind == :set
        emit_op(SET_INSERT)
        push_type(:any)
      else
        emit_op(NATIVE_CALL, NATIVES["list-push"], 2)
        if node.object.is_a?(AST::Identifier)
          emit_op(SET_NAME, add_const(node.object.name.to_s))
        end
        push_type(:void)
      end
    when "remove"
      compile_ast_expr_to_value(node.object)
      compile_ast_expr_to_value(node.args[0])
      if obj_kind == :set
        emit_op(SET_REMOVE)
      else
        emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
      end
      push_type(:any)
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
    end_t = pop_type
    case end_t
    when :i64 then emit_op(I_TO_VAL)
    when :f64 then emit_op(F_TO_VAL)
    end
    emit_op(LT); emit_op(JUMP_IF_FALSE)
    jump_exit = @ops.length; emit_op(0)
    node.body.each do |s|
      compile_ast_stmt(s)
      t = pop_type
      emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
    end
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
    node.body.each do |s|
      compile_ast_stmt(s)
      t = pop_type
      emit_op(POP) unless t == :void || t == :i64 || t == :f64 || t == :bool
    end
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
    when AST::OptionalUnwrap
      # `expr?` — safe-navigation prefix. The VM's Value union is already
      # nullable (Value.Nil is a variant), so OptionalUnwrap is identity:
      # the surrounding `OR fallback` (parser-introduced for `?.field OR x`)
      # already does the nil dispatch.
      compile_ast_expr(node.target)
    when AST::Copy
      compile_ast_expr(node.value)  # VM has uniform Value semantics; COPY is identity
    when AST::StringConcat
      # `"${a}${b}"` interpolated string. Compile each part to a value, then
      # chain CONCAT operations. Empty StringConcat → empty string literal.
      if node.parts.empty?
        emit_op(LOAD_CONST, add_const([:str, ""])); push_type(:str)
      else
        node.parts.each_with_index do |p, idx|
          compile_ast_expr_to_value(p)
          if idx > 0
            emit_op(CONCAT)
            pop_type; pop_type; push_type(:str)
          end
        end
      end
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
    # Slot tables (@islots / @fslots / @slots) are authoritative for storage
    # location; @slot_types may be unstamped (:any) for slots that were
    # allocated through paths that didn't tag the type. Always honor the
    # presence in the typed table even when vt is :any — without this,
    # `print(int_slot.toString())` falls through to LOAD_NAME and reads
    # the global env, which doesn't contain locals.
    if @islots[name]
      emit_op(LOAD_ISLOT, @islots[name]); push_type(:i64)
    elsif @fslots[name]
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
      # `expr OR fallback` — if expr evaluates to nil/falsy, replace with
      # fallback. Mirror compile_orelse's MIR-side flow: stash expr in a
      # temp slot, NOT-NOT to boolify, JUMP_IF_FALSE to the fallback path,
      # otherwise reload the original.
      @ast_orelse_counter ||= 0; @ast_orelse_counter += 1
      tmp_idx = add_const("__ast_orelse_#{@ast_orelse_counter}")
      compile_ast_expr_to_value(node.left); pop_type
      emit_op(STORE_NAME, tmp_idx)
      emit_op(NOT); emit_op(NOT)
      emit_op(JUMP_IF_FALSE)
      patch_fallback = @ops.length; emit_op(0)
      emit_op(LOAD_NAME, tmp_idx)
      emit_op(JUMP); patch_end = @ops.length; emit_op(0)
      @ops[patch_fallback] = @ops.length
      compile_ast_expr_to_value(node.right); pop_type
      @ops[patch_end] = @ops.length
      push_type(:any)
      return
    end
    compile_ast_expr(node.left);  left_type  = pop_type
    compile_ast_expr(node.right); right_type = pop_type
    both_i64 = (left_type == :i64 && right_type == :i64)
    both_f64 = (left_type == :f64 && right_type == :f64)
    # Mixed typed/untyped operands: typed ops live on istack/fstack, the
    # untyped op on vstack, so a polymorphic ADD/LT etc. would underflow
    # the wrong stack. Hoist the typed side to the value stack first; the
    # right operand is on top, so we must coerce the left BEFORE compiling
    # the right (it would already be there). Since we've already compiled
    # both, fall back to "if mismatched, coerce both": insert the right
    # coercion directly above and re-emit a coercion for the left by
    # peek-then-swap... simpler: reject the mismatch upstream by coercing
    # both at-load.
    if !both_i64 && !both_f64 && (left_type == :i64 || left_type == :f64 || right_type == :i64 || right_type == :f64)
      # right is on top of stack(s); coerce it first if typed.
      case right_type
      when :i64 then emit_op(I_TO_VAL); right_type = :any
      when :f64 then emit_op(F_TO_VAL); right_type = :any
      end
      # left is below right on its stack; we can't easily reach it without
      # a SWAP. Coerce by re-loading is not straightforward here either.
      # For now, support the common case where left was typed (LOAD_ISLOT/
      # LOAD_FSLOT); after right is on vstack, reach back via VAL_TO_I64
      # round-trip is wrong. Use the typed-stack ops if applicable.
      if left_type == :i64 || left_type == :f64
        # Promote the i64/f64 typed result to vstack via I_TO_VAL/F_TO_VAL,
        # which expects the value on top of istack/fstack. The right
        # coercion above moved right off the typed stack, so left is now
        # exposed on top and can be coerced.
        # WAIT: we already moved right via I_TO_VAL above (typed -> vstack).
        # In the i64/f64 mismatch case where ONLY one side was typed,
        # the typed side's value is at the top of its stack.
        if left_type == :i64
          # Insert I_TO_VAL but... operand order on vstack must remain
          # left, right. After right's I_TO_VAL, vstack: [..., right].
          # Now I_TO_VAL on left would push it on top: [..., right, left].
          # Swap them. The VM has no SWAP opcode; the simplest fix is to
          # store right to a tmp slot, I_TO_VAL the left, then re-load right.
          @binop_tmp_counter ||= 0; @binop_tmp_counter += 1
          tmp = "__binop_tmp_#{@binop_tmp_counter}"
          alloc_slot(tmp, :any) unless has_slot?(tmp)
          emit_op(STORE_SLOT, @slots[tmp])  # peek-store, vstack still has right
          emit_op(POP)
          emit_op(I_TO_VAL)                 # left from istack -> vstack
          emit_op(LOAD_SLOT, @slots[tmp])   # vstack: [left, right]
        elsif left_type == :f64
          @binop_tmp_counter ||= 0; @binop_tmp_counter += 1
          tmp = "__binop_tmp_#{@binop_tmp_counter}"
          alloc_slot(tmp, :any) unless has_slot?(tmp)
          emit_op(STORE_SLOT, @slots[tmp])
          emit_op(POP)
          emit_op(F_TO_VAL)
          emit_op(LOAD_SLOT, @slots[tmp])
        end
        left_type = :any
      end
    end
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
      # NATIVE_CALL puts result on vstack; MOD_I64 stays on istack.
      # Type tag must follow the actual residency.
      if both_i64
        emit_op(MOD_I64); push_type(:i64)
      else
        emit_op(NATIVE_CALL, NATIVES["modulo"], 2); push_type(:any)
      end
    when :AND, :OR then push_type(:bool)
    when :WRAP_ADD, :CHECK_ADD
      if both_i64 then emit_op(WRAP_ADD_I64); push_type(:i64)
      else emit_op(ADD); push_type(:any) end
    when :WRAP_SUB, :CHECK_SUB
      if both_i64 then emit_op(WRAP_SUB_I64); push_type(:i64)
      else emit_op(SUB); push_type(:any) end
    when :WRAP_MUL, :CHECK_MUL
      if both_i64 then emit_op(WRAP_MUL_I64); push_type(:i64)
      else emit_op(MUL); push_type(:any) end
    else emit_op(ADD); push_type(:any)
    end
  end

  def compile_ast_unary(node)
    compile_ast_expr(node.right)
    t = pop_type
    case node.op
    when :NOT, :BANG, :EXCL
      emit_op(NOT); push_type(:any)
    when :SUB, :NEG
      # Stay on the typed stack when the operand is i64/f64 so subsequent
      # typed ops (DIV_I64 et al.) see int operands (their @divTrunc /
      # truncate-toward-zero semantics rely on int division). Polymorphic
      # MUL on vstack would coerce to Float64 and break int truncation.
      case t
      when :i64
        # Emit (0 - val) on istack: load 0, swap order via STORE_ISLOT temp
        @neg_tmp_counter ||= 0; @neg_tmp_counter += 1
        tmp = "__neg_tmp_#{@neg_tmp_counter}"
        @islots[tmp] = (@next_islot ||= 0); @next_islot += 1
        emit_op(STORE_ISLOT, @islots[tmp])      # save val
        emit_op(LOAD_CONST_I64, add_const([:i64, 0]))
        emit_op(LOAD_ISLOT, @islots[tmp])
        emit_op(SUB_I64)
        push_type(:i64)
      when :f64
        emit_op(LOAD_CONST_F64, add_const([:f64, -1.0]))
        emit_op(MUL_F64)
        push_type(:f64)
      else
        emit_op(LOAD_CONST, add_const([:i64, -1])); emit_op(MUL)
        push_type(:any)
      end
    end
  end

  def compile_ast_get_field(node)
    # Enum variant: Type.Variant → Scheme symbol
    if node.target.is_a?(AST::Identifier) && @enum_types&.include?(node.target.name.to_s)
      emit_op(LOAD_CONST, add_const(node.field.to_s))
      push_type(:any)
      return
    end
    # Union unit variant: Type.Variant → cons("Variant", empty_vector).
    # Mirrors compile_struct_init's union dispatch: a union value in the VM
    # is Pair(car=Symbol(\"Variant\"), cdr=payload_or_empty_vector).
    if node.target.is_a?(AST::Identifier) && @union_types&.include?(node.target.name.to_s)
      emit_op(LOAD_CONST, add_const(node.field.to_s))
      emit_op(NATIVE_CALL, NATIVES["vector"], 0)
      emit_op(NATIVE_CALL, NATIVES["cons"], 2)
      push_type(:any)
      return
    end
    # Resolve receiver's struct hint if available so find_field_index can
    # disambiguate same-named fields across structs (e.g. `Config.retries`
    # vs `User.retries`). Without this, the global first-match wins and
    # `cfg.retries` reads the wrong slot.
    struct_name = nil
    if node.target.is_a?(AST::Identifier)
      t = @slot_types[node.target.name.to_s]
      if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
        struct_name = t.to_s.sub(/\Astruct_/, "")
      end
    end
    compile_ast_expr_to_value(node.target)
    field = node.field.to_s
    idx = find_field_index(field, struct_name: struct_name)
    if idx
      # Use LOAD_CONST (vstack), not LOAD_CONST_I64 (istack), because
      # NATIVE_CALL reads its args from vstack — same fix as compile_field_get.
      emit_op(LOAD_CONST, add_const([:i64, idx]))
      emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
    else
      emit_op(POP); emit_op(LOAD_CONST, add_const(nil))
    end
    push_type(:any)
  end

  def compile_ast_get_index(node)
    # Map indexing must dispatch through MAP_GET, not list-ref. Check the
    # target's slot tag — direct Ident hits @slot_types directly; FieldGet
    # walks through @struct_schemas via expr_collection_kind. Mirrors
    # compile_index_get on the MIR side.
    kind =
      if node.target.is_a?(AST::Identifier)
        @slot_types[node.target.name.to_s] || :any
      else
        :any
      end
    compile_ast_expr_to_value(node.target)
    compile_ast_expr_to_value(node.index)
    if kind == :map
      emit_op(MAP_GET)
    else
      emit_op(NATIVE_CALL, NATIVES["list-ref"], 2)
    end
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

  # Bind an alias slot to the same value the source slot currently holds.
  # Used for WITH-block bindings (Arc unwrap, locked-guard get) — the VM
  # has no indirection, so alias-and-source share storage by copy. The
  # corresponding writeback (alias_writeback) reverses this so mutations
  # to the alias are reflected in the source after the block.
  def alias_to_source(alias_name, src_name)
    return unless has_slot?(src_name)
    t = if @islots[src_name] then :i64
        elsif @fslots[src_name] then :f64
        else (@slot_types[src_name] || :any)
        end
    alloc_slot(alias_name, t)
    case t
    when :i64 then emit_op(LOAD_ISLOT, @islots[src_name])
    when :f64 then emit_op(LOAD_FSLOT, @fslots[src_name])
    else           emit_op(LOAD_SLOT,  @slots[src_name])
    end
    emit_store(alias_name, t)
    @slot_types[alias_name] = t
    @with_aliases ||= {}
    @with_aliases[alias_name] = src_name
  end

  # Reverse of alias_to_source: write the alias's current value back to the
  # source slot. Emitted after a WITH body so any in-block mutation to the
  # alias persists. The Zig backend gets this for free via pointer aliasing
  # through the lock guard; the VM uses by-value slots.
  def alias_writeback(alias_name)
    return unless @with_aliases && @with_aliases.key?(alias_name)
    src_name = @with_aliases[alias_name]
    return unless has_slot?(alias_name) && has_slot?(src_name)
    t = if @islots[alias_name] then :i64
        elsif @fslots[alias_name] then :f64
        else (@slot_types[alias_name] || :any)
        end
    case t
    when :i64 then emit_op(LOAD_ISLOT, @islots[alias_name])
    when :f64 then emit_op(LOAD_FSLOT, @fslots[alias_name])
    else           emit_op(LOAD_SLOT,  @slots[alias_name])
    end
    emit_store(src_name, t)
  end

  def has_slot?(name)
    @islots.key?(name) || @fslots.key?(name) || @slots.key?(name)
  end

  # Emit code to evaluate a small print-template subexpression (a slot
  # name, or `obj.field` against a known slot). Returns true on emit, or
  # false to signal the caller to fall through to a different branch.
  # Supports recursive nesting so `CheatLib.len(h1.items)` can compose.
  # Resolve the slot kind (:set, :map, :any) for a method-call receiver
  # AST node. Identifiers use the slot table directly; other shapes don't
  # (yet) propagate type info, so they fall back to :any.
  def ast_receiver_kind(node)
    return :any unless node.is_a?(AST::Identifier)
    @slot_types[node.name.to_s] || :any
  end

  # Find the AST args of the original CLEAR `print(...)` call corresponding
  # to a MIR `std.debug.print(...)` call. Returns an Array<AST node> or nil
  # if the AST lookup fails (synthetic stmt, lookup mismatch). When non-nil,
  # callers can compile each via compile_ast_print_arg without going through
  # the Zig-template string parser.
  def ast_print_args_from(ast_stmt)
    return nil unless ast_stmt
    node = ast_stmt
    node = node.expression if node.respond_to?(:expression) && node.expression
    node = node.value      if node.respond_to?(:value)      && node.value && !node.respond_to?(:args)
    return nil unless node.respond_to?(:args)
    name = if node.respond_to?(:name)
      node.name.is_a?(AST::Identifier) ? node.name.name.to_s : node.name.to_s
    end
    return nil unless name == "print"
    node.args
  end

  # Compile one AST arg of a `print(...)` and emit display+POP. Each arg
  # produces one rendered chunk on stdout; the trailing newline is emitted
  # once by the caller.
  def compile_ast_print_arg(arg)
    if arg.is_a?(AST::Literal) && arg.type == :string
      emit_op(LOAD_CONST, add_const([:str, arg.value.to_s]))
      emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
      return
    end
    compile_ast_expr_to_value(arg)
    pop_type if @type_stack.any?
    emit_op(NATIVE_CALL, NATIVES["display"], 1); emit_op(POP)
  end

  def emit_print_subexpr(expr)
    expr = expr.strip
    if expr =~ /\A[a-zA-Z_]\w*\z/ && has_slot?(expr)
      emit_load_any(expr); return true
    end
    if expr =~ /\A([a-zA-Z_]\w*)\.([a-zA-Z_]\w*)\z/ && has_slot?($1)
      obj_name = $1; fld = $2
      emit_load_any(obj_name)
      struct_name = nil
      t = @slot_types[obj_name]
      struct_name = t.to_s.sub(/\Astruct_/, "") if t.is_a?(Symbol) && t.to_s.start_with?("struct_")
      idx = find_field_index(fld, struct_name: struct_name)
      if idx
        emit_op(LOAD_CONST, add_const([:i64, idx]))
        emit_op(NATIVE_CALL, NATIVES["vector-ref"], 2)
      end
      return true
    end
    false
  end

  # Emit a load that lands on the value stack regardless of where the slot
  # actually lives. For typed slots, follow the load with I_TO_VAL / F_TO_VAL.
  # Used by the print-template path so `print(x)` works whether x is :i64,
  # :f64, or :any.
  def emit_load_any(name)
    if @islots.key?(name)
      emit_op(LOAD_ISLOT, @islots[name]); emit_op(I_TO_VAL)
    elsif @fslots.key?(name)
      emit_op(LOAD_FSLOT, @fslots[name]); emit_op(F_TO_VAL)
    elsif @slots.key?(name)
      emit_op(LOAD_SLOT, @slots[name])
    else
      emit_op(LOAD_NAME, add_const(name))
    end
  end

  def emit_store(name, val_type)
    # The slot was allocated in exactly one of @islots / @fslots / @slots
    # by alloc_slot, based on the original allocation type. Subsequent
    # stores must use the same table, so coerce val_type → slot table.
    #
    # Also writes @slot_types[name] to the slot's RESIDENCY tag (:i64 for
    # @islots, :f64 for @fslots, value-stack tag for @slots), not the
    # value's incoming type. compile_ident + expr_type_hint use this tag
    # to decide whether subsequent loads land on the typed stack — so a
    # vstack-resident slot must never be tagged :i64/:f64/:bool, even
    # right after an i64 was stored into it (the i64 was wrapped to
    # Value.Int64Val on the way in).
    if @islots.key?(name)
      case val_type
      when :i64, :bool then emit_op(STORE_ISLOT, @islots[name])
      when :f64        then emit_op(F64_TO_INT); emit_op(STORE_ISLOT, @islots[name])
      else                  emit_op(VAL_TO_I64); emit_op(STORE_ISLOT, @islots[name])
      end
      @slot_types[name] = :i64
    elsif @fslots.key?(name)
      case val_type
      when :f64 then emit_op(STORE_FSLOT, @fslots[name])
      when :i64 then emit_op(INT_TO_F64); emit_op(STORE_FSLOT, @fslots[name])
      else           emit_op(VAL_TO_F64); emit_op(STORE_FSLOT, @fslots[name])
      end
      @slot_types[name] = :f64
    else
      case val_type
      when :i64  then emit_op(I_TO_VAL);    emit_op(STORE_SLOT, @slots[name])
      when :f64  then emit_op(F_TO_VAL);    emit_op(STORE_SLOT, @slots[name])
      when :bool then emit_op(BOOL_TO_VAL); emit_op(STORE_SLOT, @slots[name])
      else            emit_op(STORE_SLOT,   @slots[name])
      end
      # Typed-stack tags would falsely imply istack/fstack residency.
      # When val_type carries no useful tag (:any), preserve whatever
      # alloc_slot stamped (e.g. :struct_<Name>) — that's where the
      # structural hint came from.
      new_tag = case val_type
                when :i64, :f64, :bool then :any
                else                        val_type
                end
      if new_tag == :any && @slot_types[name] && @slot_types[name] != :any
        # Keep existing tag (:struct_X / :map / :set) — emit_store has no
        # better information than alloc_slot did.
      else
        @slot_types[name] = new_tag
      end
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

  # Reverse the Zig-source string escaping that mir_lowering applies in
  # lower_literal. Compile-time only; runs in Ruby.
  def unescape_zig_source_str(raw)
    raw.gsub(/\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)/m) { |_|
      esc = $1
      if esc.start_with?("x")
        esc[1..].to_i(16).chr
      elsif esc.start_with?("u{")
        esc[2..-2].to_i(16).chr(Encoding::UTF_8)
      else
        case esc
        when "n"  then "\n"
        when "t"  then "\t"
        when "r"  then "\r"
        when "\\" then "\\"
        when '"'  then '"'
        when "'"  then "'"
        when "0"  then "\0"
        else "\\#{esc}"
        end
      end
    }
  end

  def serialize_const(c)
    case c
    when nil   then "N"
    when Array
      type, val = c[0], c[1]
      case type
      when :i64        then "I:#{val}"
      when :f64        then "F:#{val}"
      # Length-prefixed: `S:<bytesize>:<exactly bytesize bytes>`. The
      # bytes are written verbatim — they may contain any byte value,
      # including `\n`. The VM's loadBytecodeConsts! reads exactly
      # bytesize bytes after the second `:`, so no line-splitting or
      # escape parsing is needed at load time.
      when :str        then "S:#{val.bytesize}:#{val}"
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
