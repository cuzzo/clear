# typed: true
# fsm_ops.rb -- Structured MIR operations for FSM stdlib templates.
#
# Replaces the Zig-text :fsm_setup / :fsm_finish_block /
# :fsm_finish_value / :fsm_state_decls / :fsm_state_finalize templates
# with a typed op tree the FSM lowering and MIR checker can both walk.
#
# The motivating problem: the previous templates were raw Zig strings.
# That meant every memory-safety decision baked into them (which step
# a `defer` lives in, which captures cleanup at finalize, whether an
# alloc has a matching errdefer, whether the buffer slice escapes via
# inner.result) was invisible to the MIR checker. Two real bugs
# shipped through that hole: a cross-step UAF on captures, and a leak
# of the readFile heap buffer.
#
# After this refactor every byte of FSM-emitted Zig comes from
# walking these op nodes via FsmOpEmitter. No template substitution,
# no string interpolation, no InlineZig escape hatch on the FSM path.
# The checker receives an FsmStructure derived directly from the op
# tree (not from a textual scan of rendered Zig) so its invariants
# hold structurally rather than syntactically.
#
# All op types are immutable Structs. Statement ops carry one
# statement's worth of side effects; expression ops carry one
# value-producing fragment. The emitter dispatches on Struct class.

module FsmOps
  # =====================================================================
  # Statement ops
  # =====================================================================

  # ctx.<target_field> = <value_expr>;
  # Used to store the result of a setup call into a state struct field
  # (e.g. `ctx.rf_fd = try fsmOpenForRead(path);`).
  AssignField = Struct.new(:field, :value)

  # const <name>: <zig_type> = <value_expr>;
  # Step-local binding. value may use `try` (the surrounding step
  # function returns anyerror!void).
  LetConst = Struct.new(:name, :zig_type, :value)

  # errdefer <fn>(<args>);
  # Step-0 cleanup that fires only on error before suspension.
  ErrDeferCall = Struct.new(:fn, :args)

  # errdefer ctx.alloc.free(ctx.<field>);
  # Pairs with an alloc on the same field; the matching success-path
  # cleanup goes in DeferFreeField (placed in finalize).
  ErrDeferFreeField = Struct.new(:field)

  # defer ctx.alloc.free(ctx.<field>);
  # Used in :fsm_state_finalize to clean a heap-alloc'd state field
  # at FSM end (after the last step's body runs).
  DeferFreeField = Struct.new(:field)

  # [try] <fn>(<args>);
  # Bare statement call. is_try == true emits `try fn(...)`.
  StmtCall = Struct.new(:fn, :args, :is_try)

  # try ctx.rt.getSched().submit<Verb>ForFsm(&<waiter>, <extra_args...>);
  # The verbs map 1:1 to runtime helpers (submitReadForFsm,
  # submitWriteForFsm, submitRecvForFsm, ...). waiter is a StateField
  # expression so the structure-derivation walker sees it as a read
  # of that field (matching how the emitter actually renders it).
  IoSubmit = Struct.new(:verb, :waiter, :extra_args)

  IO_SUBMIT_VERBS = {
    read:  "submitReadForFsm",
    write: "submitWriteForFsm",
    recv:  "submitRecvForFsm",
    send:  "submitSendForFsm",
  }.freeze

  # if (ctx.<field>.<sub> < 0) return <return_fn>(<return_args>);
  # Models the io_uring CQE error-propagation idiom. Specialized
  # rather than a general `if` because every FSM IO finish has the
  # same shape (`waiter.result` is i32; negative == -errno).
  IfFieldSubLtZeroReturnCall = Struct.new(:field, :sub, :return_fn, :return_args)

  # =====================================================================
  # Expression ops
  # =====================================================================

  # Template arg `{0}`, `{1}`, ... — substituted with the lowered
  # arg expressions at emit time.
  ArgRef = Struct.new(:idx)

  # __ctx_<id>.<name>  (state struct field on the FSM ctx).
  StateField = Struct.new(:name)

  # <base>.<name>  (sub-field access; e.g. waiter.result).
  SubField = Struct.new(:base, :name)

  # Step-local binding name (e.g. __rf_size).
  LocalRef = Struct.new(:name)

  # &<expr>
  AddrOf = Struct.new(:expr)

  # Raw Zig literal for things that don't need structure (numbers,
  # `undefined`, `&[_]u8{}`, etc.). Kept as a small escape hatch for
  # init expressions; the checker treats it as opaque.
  ZigLit = Struct.new(:zig)

  # @intCast(<zig_type>, <expr>) — Zig's type-coercion builtin.
  IntCast = Struct.new(:zig_type, :expr)

  # <fn>(<args>) — call expression. is_try wraps in `try`.
  CallExpr = Struct.new(:fn, :args, :is_try)

  # try ctx.alloc.alloc(<elem_type>, <count_expr>)
  # Modeled separately from CallExpr because the allocator (ctx.alloc)
  # is a fixed reference and the checker validates it against the
  # matching ErrDeferFreeField / DeferFreeField on the same field.
  AllocExpr = Struct.new(:elem_type, :count)

  # <base>[0..@intCast(usize, <end_expr>)]
  # The slice-up-to-intcast idiom used to bound a read buffer to the
  # bytes returned by io_uring.
  SliceUntilIntCast = Struct.new(:base, :end_expr)

  # Binary infix operator: <left> <op> <right> rendered with parens.
  # op is a Zig operator string, e.g. "+", "-", "<", "==". Used for
  # wake-time arithmetic and other small expressions that don't
  # warrant a dedicated node.
  BinOp = Struct.new(:op, :left, :right)

  # =====================================================================
  # Convenience constructors (terser to write in std_lib.rb)
  # =====================================================================
  module DSL
    extend self

    def assign_field(field, value);          AssignField.new(field, value); end
    def let_const(name, zig_type, value);    LetConst.new(name, zig_type, value); end
    def err_defer_call(fn, args);            ErrDeferCall.new(fn, args); end
    def err_defer_free_field(field);         ErrDeferFreeField.new(field); end
    def defer_free_field(field);             DeferFreeField.new(field); end
    def stmt_call(fn, args, is_try: false);  StmtCall.new(fn, args, is_try); end
    def io_submit(verb, waiter, extra_args)
      # Accept a bare string for caller convenience and lift it to a
      # StateField op so the walker / emitter both see structure.
      waiter_op = waiter.is_a?(String) ? StateField.new(waiter) : waiter
      IoSubmit.new(verb, waiter_op, extra_args)
    end
    def if_neg_return_call(field, sub, return_fn, return_args)
      IfFieldSubLtZeroReturnCall.new(field, sub, return_fn, return_args)
    end

    def arg(idx);                            ArgRef.new(idx); end
    def state(name);                         StateField.new(name); end
    def subf(base, name);                    SubField.new(base, name); end
    def local(name);                         LocalRef.new(name); end
    def addr(expr);                          AddrOf.new(expr); end
    def lit(zig);                            ZigLit.new(zig); end
    def intcast(zig_type, expr);             IntCast.new(zig_type, expr); end
    def call(fn, args, is_try: false);       CallExpr.new(fn, args, is_try); end
    def alloc_expr(elem_type, count);        AllocExpr.new(elem_type, count); end
    def slice_intcast(base, end_expr);       SliceUntilIntCast.new(base, end_expr); end
    def binop(op, left, right);              BinOp.new(op, left, right); end
  end

  # =====================================================================
  # State-field declarations
  #
  # Replaces `:fsm_state_decls` Zig text lines with structured
  # records. Each describes one field of the FSM ctx struct:
  #
  #   name      String — e.g. "rf_fd"
  #   zig_type  String — e.g. "i32" or "CheatHeader.FsmIoWaiter"
  #   init_zig  String — Zig initializer, e.g. "-1" or "undefined"
  # =====================================================================
  StateFieldDecl = Struct.new(:name, :zig_type, :init_zig) do
    def render
      "#{name}: #{zig_type} = #{init_zig},"
    end
  end

  # =====================================================================
  # Emitter
  # =====================================================================
  #
  # Renders an op tree to Zig text. Single dispatch on op class —
  # no decisions, no allocator choices, no template substitution
  # surprises. Every Zig fragment in an FSM body comes from one of
  # these methods, including the trailing semicolons and newlines.
  #
  # Context required:
  #
  #   ctx_id     Integer — the FSM ctx id (renders __ctx_<id>.X)
  #   bg_rt      String  — the BG runtime variable name (e.g. __rt_bg0)
  #   arg_codes  [String] — pre-rendered arg expressions (template {N})
  #
  # The emitter is stateless; create one per FSM body or reuse safely.
  class Emitter
    def initialize(ctx_id:, bg_rt:, arg_codes:)
      @ctx_id = ctx_id
      @bg_rt = bg_rt
      @arg_codes = arg_codes
    end

    # Render a list of statement ops into newline-joined Zig text
    # with each statement properly terminated. Empty list -> "".
    def emit_stmts(ops)
      return "" if ops.nil? || ops.empty?
      ops.map { |op| emit_stmt(op) }.join("\n")
    end

    def emit_stmt(op)
      case op
      when AssignField
        "#{ctx}.#{op.field} = #{emit_expr(op.value)};"
      when LetConst
        "const #{op.name}: #{op.zig_type} = #{emit_expr(op.value)};"
      when ErrDeferCall
        "errdefer #{resolve_fn(op.fn)}(#{emit_args(op.args)});"
      when ErrDeferFreeField
        "errdefer #{ctx}.alloc.free(#{ctx}.#{op.field});"
      when DeferFreeField
        "defer #{ctx}.alloc.free(#{ctx}.#{op.field});"
      when StmtCall
        prefix = op.is_try ? "try " : ""
        "#{prefix}#{resolve_fn(op.fn)}(#{emit_args(op.args)});"
      when IoSubmit
        verb_fn = IO_SUBMIT_VERBS[op.verb] or
          raise ArgumentError, "FsmOps::IoSubmit unknown verb #{op.verb.inspect}"
        all_args = [AddrOf.new(op.waiter)] + (op.extra_args || [])
        "try #{ctx}.rt.getSched().#{verb_fn}(#{emit_args(all_args)});"
      when IfFieldSubLtZeroReturnCall
        cond = "#{ctx}.#{op.field}.#{op.sub} < 0"
        "if (#{cond}) {\n    return #{resolve_fn(op.return_fn)}(#{emit_args(op.return_args)});\n}"
      else
        raise ArgumentError, "FsmOps::Emitter unknown statement op #{op.class}"
      end
    end

    # Function path resolution. Function references are static text
    # (Zig identifiers and method paths) — but a few stable
    # placeholders must be substituted: __FSM_CTX -> __ctx_<id> for
    # method paths rooted at the FSM ctx (e.g.
    # `__FSM_CTX.rt.getSched().fsmSleepTask`). Limited to the fn
    # field; expression args use structured ops, not placeholders.
    def resolve_fn(fn_str)
      fn_str.gsub("__FSM_CTX", ctx)
    end

    def emit_expr(expr)
      case expr
      when ArgRef
        idx = expr.idx
        unless @arg_codes && idx < @arg_codes.length
          raise ArgumentError, "FsmOps arg index #{idx} out of range (#{@arg_codes&.length || 0} args)"
        end
        @arg_codes[idx]
      when StateField
        "#{ctx}.#{expr.name}"
      when SubField
        "#{emit_expr(expr.base)}.#{expr.name}"
      when LocalRef
        expr.name
      when AddrOf
        "&#{emit_expr(expr.expr)}"
      when ZigLit
        expr.zig
      when IntCast
        "@as(#{expr.zig_type}, @intCast(#{emit_expr(expr.expr)}))"
      when CallExpr
        prefix = expr.is_try ? "try " : ""
        "#{prefix}#{resolve_fn(expr.fn)}(#{emit_args(expr.args)})"
      when AllocExpr
        "try #{ctx}.alloc.alloc(#{expr.elem_type}, #{emit_expr(expr.count)})"
      when SliceUntilIntCast
        "#{emit_expr(expr.base)}[0..@as(usize, @intCast(#{emit_expr(expr.end_expr)}))]"
      when BinOp
        "(#{emit_expr(expr.left)} #{expr.op} #{emit_expr(expr.right)})"
      when String
        # Allow plain strings as opaque expression literals for
        # backward compat / convenience. Treated like ZigLit.
        expr
      else
        raise ArgumentError, "FsmOps::Emitter unknown expression op #{expr.class}"
      end
    end

    private

    def emit_args(args)
      (args || []).map { |a| emit_expr(a) }.join(", ")
    end

    def ctx
      "__ctx_#{@ctx_id}"
    end
  end

  # =====================================================================
  # Lowerer — convert FsmOps op trees to MIR statements/expressions.
  # =====================================================================
  #
  # Sibling of Emitter. Emitter produces Zig text (legacy path);
  # Lowerer produces typed MIR nodes that the wrapper renders via
  # MIREmitter. The structural goal: every FSM body fragment is a
  # real MIR statement, not a RawZig blob carrying Zig text.
  #
  # Constructor takes the same context as Emitter:
  #   ctx_id     Integer — for __ctx_<id>.X field references
  #   bg_rt      String  — current BG runtime variable name
  #   arg_mirs   [MIR::*] — MIR expressions for the {N} template
  #                         arg slots; produced by lowering the
  #                         AST args (not their rendered Zig).
  #
  # Each FsmOps op kind maps to a fixed MIR node shape:
  #   AssignField              -> MIR::Set(target=ctx.field, value)
  #   LetConst                 -> MIR::Let
  #   ErrDeferCall             -> MIR::ErrDeferStmt(MIR::Call)
  #   ErrDeferFreeField        -> MIR::ErrDeferStmt(MIR::MethodCall(ctx.alloc, free, [field]))
  #   DeferFreeField           -> MIR::DeferStmt(MIR::MethodCall(ctx.alloc, free, [field]))
  #   StmtCall                 -> MIR::ExprStmt(MIR::Call, discard=false)
  #   IoSubmit                 -> MIR::ExprStmt(MIR::MethodCall(ctx.rt.getSched(), submitVForFsm, [&waiter, *extras], try=true))
  #   IfFieldSubLtZeroReturnCall -> MIR::IfStmt(BinOp("<", FieldGet(FieldGet(ctx, F), Sub), Lit("0")), [ReturnStmt(Call)], [])
  #
  # Each FsmOps expression kind maps to a MIR expression:
  #   ArgRef             -> arg_mirs[idx] (already MIR)
  #   StateField         -> MIR::FieldGet(MIR::Ident("__ctx_<id>"), name)
  #   SubField           -> MIR::FieldGet(lower(base), name)
  #   LocalRef           -> MIR::Ident(name)
  #   AddrOf             -> MIR::UnaryOp("&", lower(expr))
  #   ZigLit             -> MIR::Lit(zig)
  #   IntCast            -> MIR::Call("@as", [Ident(zig_type), Call("@intCast", [expr])])
  #   CallExpr           -> MIR::Call(resolve_fn(fn), args.map(&lower), is_try)
  #   AllocExpr          -> MIR::MethodCall(ctx.alloc, "alloc", [Ident(elem_type), count], try=true)
  #   SliceUntilIntCast  -> MIR::SliceExpr(base, Lit("0"), IntCast(usize, end_expr))
  #   BinOp              -> MIR::BinOp
  #
  # All function paths starting with "__FSM_CTX." are resolved to
  # the literal "__ctx_<id>." prefix at lowering time -- the MIR
  # node's callee field is the resolved string. Nothing in the MIR
  # tree carries unsubstituted placeholders.

  class Lowerer
    def initialize(ctx_id:, bg_rt:, arg_mirs:)
      @ctx_id = ctx_id
      @bg_rt = bg_rt
      @arg_mirs = arg_mirs
    end

    # Lower a list of FsmOps statement nodes -> [MIR::Stmt].
    def lower_stmts(ops)
      return [] if ops.nil? || ops.empty?
      ops.map { |op| lower_stmt(op) }
    end

    def lower_stmt(op)
      case op
      when AssignField
        MIR::Set.new(state_ref(op.field), lower_expr(op.value), false)
      when LetConst
        MIR::Let.new(op.name, lower_expr(op.value), false, op.zig_type, nil)
      when ErrDeferCall
        MIR::ErrDeferStmt.new(
          MIR::Call.new(resolve_fn(op.fn), op.args.map { |a| lower_expr(a) }, false),
        )
      when ErrDeferFreeField
        MIR::ErrDeferStmt.new(free_call(op.field))
      when DeferFreeField
        MIR::DeferStmt.new(free_call(op.field))
      when StmtCall
        MIR::ExprStmt.new(
          MIR::Call.new(resolve_fn(op.fn), op.args.map { |a| lower_expr(a) }, op.is_try),
          false,
        )
      when IoSubmit
        verb_fn = IO_SUBMIT_VERBS[op.verb] or
          raise ArgumentError, "FsmOps::IoSubmit unknown verb #{op.verb.inspect}"
        all_args = [MIR::UnaryOp.new("&", lower_expr(op.waiter))] +
          (op.extra_args || []).map { |a| lower_expr(a) }
        receiver = MIR::MethodCall.new(
          MIR::FieldGet.new(ctx_ident, "rt"),
          "getSched", [], false,
        )
        MIR::ExprStmt.new(
          MIR::MethodCall.new(receiver, verb_fn, all_args, true),
          false,
        )
      when IfFieldSubLtZeroReturnCall
        cond = MIR::BinOp.new(
          "<",
          MIR::FieldGet.new(state_ref(op.field), op.sub),
          MIR::Lit.new("0"),
        )
        ret = MIR::ReturnStmt.new(
          MIR::Call.new(resolve_fn(op.return_fn), op.return_args.map { |a| lower_expr(a) }, false),
        )
        MIR::IfStmt.new(cond, [ret], [])
      else
        raise ArgumentError, "FsmOps::Lowerer unknown statement op #{op.class}"
      end
    end

    def lower_expr(expr)
      case expr
      when ArgRef
        idx = expr.idx
        unless @arg_mirs && idx < @arg_mirs.length
          raise ArgumentError, "FsmOps arg index #{idx} out of range (#{@arg_mirs&.length || 0} args)"
        end
        @arg_mirs[idx]
      when StateField
        state_ref(expr.name)
      when SubField
        MIR::FieldGet.new(lower_expr(expr.base), expr.name)
      when LocalRef
        MIR::Ident.new(expr.name)
      when AddrOf
        MIR::UnaryOp.new("&", lower_expr(expr.expr))
      when ZigLit
        MIR::Lit.new(expr.zig)
      when IntCast
        # Zig: @as(<type>, @intCast(<expr>))
        MIR::Call.new(
          "@as",
          [MIR::Ident.new(expr.zig_type),
           MIR::Call.new("@intCast", [lower_expr(expr.expr)], false)],
          false,
        )
      when CallExpr
        MIR::Call.new(
          resolve_fn(expr.fn),
          expr.args.map { |a| lower_expr(a) },
          expr.is_try,
        )
      when AllocExpr
        MIR::MethodCall.new(
          MIR::FieldGet.new(ctx_ident, "alloc"),
          "alloc",
          [MIR::Ident.new(expr.elem_type), lower_expr(expr.count)],
          true,
        )
      when SliceUntilIntCast
        MIR::SliceExpr.new(
          lower_expr(expr.base),
          MIR::Lit.new("0"),
          lower_expr(IntCast.new("usize", expr.end_expr)),
          nil,
        )
      when BinOp
        MIR::BinOp.new(expr.op, lower_expr(expr.left), lower_expr(expr.right))
      when String
        # Already-rendered Zig; keep as a literal so the MIR
        # emitter passes it through. Should be rare -- prefer
        # structured ops.
        MIR::Lit.new(expr)
      else
        raise ArgumentError, "FsmOps::Lowerer unknown expression op #{expr.class}"
      end
    end

    private

    # ctx.<field> — used as both the assignment target on the LHS
    # of MIR::Set and as a value expression in arg lists.
    def state_ref(name)
      MIR::FieldGet.new(ctx_ident, name)
    end

    def ctx_ident
      MIR::Ident.new("__ctx_#{@ctx_id}")
    end

    # ctx.alloc.free(ctx.<field>) as a MIR expression.
    def free_call(field)
      MIR::MethodCall.new(
        MIR::FieldGet.new(ctx_ident, "alloc"),
        "free",
        [state_ref(field)],
        false,
      )
    end

    def resolve_fn(fn_str)
      fn_str.gsub("__FSM_CTX", "__ctx_#{@ctx_id}")
    end
  end

  # =====================================================================
  # Structure-derivation helpers
  # =====================================================================
  #
  # Walk an op tree and answer questions the FSM checker asks:
  #   - which state fields are read (referenced) in this list of ops?
  #   - which state fields are alloc'd here?
  #   - which state fields are freed here?
  # The lowering composes these per step to populate FsmStructure
  # without a textual scan of the rendered Zig.

  def self.referenced_state_fields(ops_or_expr)
    out = []
    walk(ops_or_expr) do |node|
      out << node.name if node.is_a?(StateField)
    end
    out.uniq
  end

  def self.alloc_state_fields(ops)
    out = []
    Array(ops).each do |op|
      if op.is_a?(AssignField) && op.value.is_a?(AllocExpr)
        out << op.field
      end
    end
    out.uniq
  end

  def self.free_state_fields(ops)
    out = []
    Array(ops).each do |op|
      case op
      when ErrDeferFreeField, DeferFreeField
        out << op.field
      end
    end
    out.uniq
  end

  def self.walk(node, &block)
    return unless node
    if node.is_a?(Array)
      node.each { |n| walk(n, &block) }
      return
    end
    yield node
    node.each_pair do |_, v|
      walk(v, &block)
    end if node.respond_to?(:each_pair)
  end
end
