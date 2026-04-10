# src/mir.rb - Comprehensive MIR (Mid-level IR) for CLEAR -> Zig compilation
#
# Every program construct is represented as an MIR node. The emitter
# (MIREmitter) maps each node to a Zig code template. The emitter makes
# ZERO type decisions, ZERO allocator decisions, ZERO schema lookups.
#
# Design principles:
# 1. Zig-targeted: each node maps 1:1 to a Zig code pattern
# 2. All memory explicit: every alloc/dealloc/copy/move is a node
# 3. Structured control flow: preserves if/while/for/block (Zig requires it)
# 4. No Type objects: nodes carry Zig type strings, never Type instances
# 5. Recursive expressions: expression nodes contain sub-expression nodes
#
# Old MIR nodes (Drop, Promote, SuppressCleanup, Alloc, Return,
# ReassignCleanup, FieldCleanup) in ast.rb remain for the existing pipeline.
# New nodes here use distinct names to coexist during migration.

module MIR
  # Common interface for all MIR nodes.
  module Emittable
    def mir?; true; end
    def stmt?; false; end
    def expr?; false; end
  end

  module Stmt
    include Emittable
    def stmt?; true; end
  end

  module Expr
    include Emittable
    def expr?; true; end
  end

  # ================================================================
  # Top-Level Definitions
  # ================================================================

  # Program: root container. items is a flat array of top-level nodes.
  # Zig: sequence of const/fn/test declarations separated by blank lines.
  Program = Struct.new(:items) do
    include Emittable
  end

  # Function definition.
  # Zig: [pub] fn name(params) [!]ret_type { body }
  #
  # body includes prologue statements (frame save, param shadows, etc.)
  # as leading MIR nodes -- emitter just processes them in order.
  # For catch-wrapping functions, the lowering produces the inner/outer
  # pair as two FnDefs.
  FnDef = Struct.new(:name, :params, :ret_type, :body,
                     :visibility,     # :pub or :private
                     :can_fail,       # bool: emit !RetType vs RetType
                     :comptime_params # ["comptime T: type", ...]
                    ) do
    include Stmt
  end

  # Function parameter.
  # Zig: name: zig_type
  Param = Struct.new(:name, :zig_type) do
    include Emittable
  end

  # Struct type definition.
  # Zig: const Name = struct { fields; methods };
  StructDef = Struct.new(:name, :fields, :methods, :visibility) do
    include Stmt
  end

  # Struct field definition.
  # Zig: name: zig_type [= default]
  FieldDef = Struct.new(:name, :zig_type, :default) do
    include Emittable
  end

  # Enum type definition.
  # Zig: const Name = enum { A, B, C };
  EnumDef = Struct.new(:name, :variants, :visibility) do
    include Stmt
  end

  # Tagged union type definition.
  # Zig: const Name = union(enum) { A: type, B: void };
  UnionTypeDef = Struct.new(:name, :variants, :visibility) do
    include Stmt
    # variants: [{ name: String, zig_type: String }]
    # unit variants have zig_type "void"
  end

  # Import statement.
  # Zig: const alias = @import("module")[.member];
  Import = Struct.new(:alias_name, :module_path, :member) do
    include Stmt
  end

  # Type alias.
  # Zig: const Name = target;
  TypeAlias = Struct.new(:name, :target) do
    include Stmt
  end

  # Test block.
  # Zig: test "name" { body }
  TestDef = Struct.new(:name, :body) do
    include Stmt
  end

  # ================================================================
  # Statements
  # ================================================================

  # Variable declaration.
  # Zig: const/var name[: type] = init;
  #
  # mutable: false -> const, true -> var
  # annotation: optional explicit type string (nil -> Zig infers)
  # suppression: optional "_ = &name;" or "_ = name;" for Zig warnings
  Let = Struct.new(:name, :init, :mutable, :annotation, :suppression, :needs_cleanup) do
    include Stmt
  end

  # Assignment.
  # Zig: target = value;
  # target is an MIR expression (Ident, FieldGet, IndexGet, Deref)
  Set = Struct.new(:target, :value) do
    include Stmt
  end

  # Reassignment with old-value cleanup.
  # Zig: { const __new = value; CheatLib.cleanup(T, alloc, &old); old = __new; }
  ReassignWithCleanup = Struct.new(:name, :value, :zig_type, :alloc_expr) do
    include Stmt
  end

  # If statement (not expression).
  # Zig: if (cond) { then_body } [else { else_body }]
  IfStmt = Struct.new(:cond, :then_body, :else_body) do
    include Stmt
  end

  # While loop.
  # Zig: while (cond) [: (update)] [|capture|] { body }
  WhileStmt = Struct.new(:cond, :body, :capture, :update, :mark_per_iter, :tight) do
    include Stmt
  end

  # For loop over slice/range.
  # Zig: for (iter) |item[, idx]| { body }
  ForStmt = Struct.new(:iter, :capture, :body, :index_capture, :mark_per_iter, :tight) do
    include Stmt
  end

  # Scoped block.
  # Zig: { stmts }
  ScopeBlock = Struct.new(:body) do
    include Stmt
  end

  # Switch statement (for int/enum MATCH).
  # Zig: switch (subject) { arms }
  SwitchStmt = Struct.new(:subject, :arms, :default_body) do
    include Stmt
    # arms: [{ pattern: String, body: [MIR stmt] }]
  end

  # If-chain statement (for union/string MATCH).
  # Zig: if (cond1) { ... } else if (cond2) { ... } else { ... }
  IfChain = Struct.new(:branches, :default_body) do
    include Stmt
    # branches: [{ cond: MIR expr, body: [MIR stmt] }]
  end

  # Return statement.
  # Zig: return [value];
  ReturnStmt = Struct.new(:value) do
    include Stmt
  end

  # Break statement.
  # Zig: break [:label] [value];
  BreakStmt = Struct.new(:label, :value) do
    include Stmt
  end

  # Continue statement.
  # Zig: continue;
  ContinueStmt = Struct.new(:unused) do
    include Stmt
  end

  # Defer statement.
  # Zig: defer { body };  or  defer expr;
  DeferStmt = Struct.new(:body) do
    include Stmt
    # body: single MIR stmt, or a RawZig for inline defer
  end

  # Errdefer statement.
  # Zig: errdefer |_| { body };
  ErrDeferStmt = Struct.new(:body) do
    include Stmt
  end

  # Expression used as statement.
  # Zig: expr;  or  _ = expr;
  ExprStmt = Struct.new(:expr, :discard) do
    include Stmt
    # discard: true -> emit `_ = expr;`
  end

  # Raw Zig code. Escape hatch for patterns not yet modeled in MIR.
  # Every use is tracked by `reason` for auditing. Goal: zero RawZig nodes.
  # ownership_contract: { consumes: [name, ...], produces: [name, ...], borrows: [name, ...] }
  #   consumes: bindings whose ownership transfers into the raw block (must have SuppressCleanup)
  #   produces: bindings the raw block creates (must have MIR::Alloc + MIR::Drop)
  #   borrows:  bindings read but not moved/freed (must not be moved during raw block)
  #   nil = unaudited (legacy; verifier warns about unaudited RawZig nodes)
  RawZig = Struct.new(:code, :reason, :ownership_contract) do
    include Stmt
    def expr?; true; end  # can appear in expression position too
  end

  # No-op. Emits nothing. Used as placeholder for verification-only nodes.
  Noop = Struct.new(:reason) do
    include Stmt
  end

  # Source line comment.
  # Zig: // CLR:42
  Comment = Struct.new(:text) do
    include Stmt
  end

  # Variable/param suppression.
  # Zig: _ = &name;
  Suppress = Struct.new(:name) do
    include Stmt
  end

  # Public const declaration.
  # Zig: pub const NAME = VALUE;
  PubConst = Struct.new(:name, :value) do
    include Stmt
  end

  # ================================================================
  # Memory Operations (the point of the entire MIR system)
  # ================================================================

  # --- Allocation ---

  # Heap pointer allocation + initialization.
  # Zig: blk: {
  #     const __p = try alloc_expr.create(zig_type);
  #     errdefer alloc_expr.destroy(__p);
  #     __p.* = init;
  #     break :blk __p;
  # }
  # Used for: @indirect fields, heap struct literals, capability boxing.
  HeapCreate = Struct.new(:zig_type, :init, :alloc_expr, :label) do
    include Expr
  end

  # Byte slice duplication.
  # Zig: try alloc_expr.dupe(u8, source)
  # Used for: string copies, HPT return dupes, BG captures.
  DupeSlice = Struct.new(:source, :alloc_expr) do
    include Expr
  end

  # Typed slice allocation (uninitialized).
  # Zig: try alloc_expr.alloc(elem_type, len)
  # Used for: COPY list deep-copy buffer.
  AllocSlice = Struct.new(:elem_type, :len, :alloc_expr) do
    include Expr
  end

  # Free a slice.
  # Zig: alloc_expr.free(slice)
  # Used for: errdefer cleanup of AllocSlice.
  FreeSlice = Struct.new(:slice, :alloc_expr) do
    include Expr
  end

  # Destroy a heap pointer.
  # Zig: alloc_expr.destroy(ptr)
  # Used for: errdefer cleanup of HeapCreate, intermediate cap wrap cleanup.
  DestroyPtr = Struct.new(:ptr, :alloc_expr) do
    include Expr
  end

  # --- Cleanup / Lifecycle ---

  # Deferred cleanup for a binding. Subsumes old MIR::Drop.
  # Emits a defer (or guarded defer) block using the cleanup_entry hash.
  # The cleanup_entry carries ALL pre-computed data: kind, zig_type,
  # elem_zig_type, alloc, has_moved_guard, rc_* fields, etc.
  # The emitter applies templates mechanically from the entry.
  Cleanup = Struct.new(:name, :cleanup_entry) do
    include Stmt
    # cleanup_entry: Hash with :kind, :zig_type, :elem_zig_type, :alloc,
    #   :has_moved_guard, :resource_close_zig, :is_fixed,
    #   :rc_variant, :rc_alloc, :rc_release_func, :base_zig,
    #   :needs_release_fields
  end

  # Move mark: suppress cleanup for a transferred binding.
  # Zig: name_moved = true;
  # Subsumes old MIR::SuppressCleanup.
  MoveMark = Struct.new(:name) do
    include Stmt
  end

  # --- Escape Promotion ---

  # Escape promotion. Subsumes old MIR::Promote.
  # Strategy determines the Zig pattern:
  #   :list         -> try CheatLib.promoteList(elem, rt, &name);
  #   :string_map   -> name.alloc = rt.heapAlloc();
  #   :generic      -> try CheatLib.promote(zig_type, rt, &name);
  #   :ret_fields   -> (pending flag for ReturnStmt to consume)
  #   :container_store -> (pending flag for next assignment)
  #   :bg_string    -> (pending flag for BG block)
  #   :catch_string_dupe -> (pending flag for ReturnStmt)
  #   :or_fallback_dupe  -> (pending flag for OrRescue)
  #   :hpt_string_dupe   -> (consumed by ReturnStmt with HPT)
  #   :hpt_promote       -> (consumed by ReturnStmt with HPT)
  EscapePromote = Struct.new(:name, :zig_type, :strategy, :data, :rt_expr) do
    include Stmt
    # data: strategy-specific payload (field set, alloc symbol, etc.)
    # rt_expr: Zig expression for runtime (e.g. "rt", "do_rt")
  end

  # --- Deep Copy ---

  # Explicit deep copy (COPY keyword). Strategy determines the pattern:
  #   :string      -> try alloc.dupe(u8, source)
  #   :union       -> try CheatLib.dupeUnionValue(T, source, alloc)
  #   :list_shallow -> blk: { alloc + memcpy }
  #   :list_deep    -> blk: { alloc + per-element dupeUnionValue }
  #   :passthrough  -> source (no copy needed, value type)
  DeepCopy = Struct.new(:source, :zig_type, :elem_type, :strategy,
                        :alloc_expr) do
    include Expr
  end

  # --- Collection Initialization ---

  # Collection init with explicit allocator.
  # Strategy determines the Zig pattern:
  #   :pool           -> try T.initCapacity(alloc, cap)
  #   :list_capacity  -> try T.initCapacity(alloc, cap)
  #   :list_empty     -> T{}
  #   :set_empty      -> T{}
  #   :map_bare       -> T{ .alloc = alloc }
  #   :map_empty      -> T{}
  ContainerInit = Struct.new(:zig_type, :strategy, :alloc_expr,
                             :capacity) do
    include Expr
  end

  # --- Capability Wrapping ---

  # Capability wrap: applies sync and/or ownership layers.
  # Zig patterns:
  #   :local     -> try CheatLib.localCreate(T, alloc, inner)
  #   :sync_only -> try CheatLib.lockedCreate(T, alloc, inner)
  #   :own_only  -> try CheatLib.arcCreate(T, alloc, inner)
  #   :both      -> blk: { sync_create; deref; destroy_inner; own_create; }
  CapWrap = Struct.new(:inner, :zig_base, :strategy,
                       :sync_fn,   # "lockedCreate", "rwLockedCreate", "refCellCreate", nil
                       :sync_type, # "CheatLib.Locked(T)", nil
                       :own_fn,    # "arcCreate", "rcCreate", nil
                       :alloc_expr) do
    include Expr
  end

  # Rc/Arc retain (reference count increment).
  # Zig: CheatLib.arcRetain(T, name)  or  CheatLib.rcRetain(T, name)
  RcRetain = Struct.new(:source, :zig_base, :func) do
    include Expr
    # func: "arcRetain" or "rcRetain"
  end

  # Rc/Arc downgrade to weak ref.
  # Zig: CheatLib.arcDowngrade(T, source) or CheatLib.rcDowngrade(T, source)
  RcDowngrade = Struct.new(:source, :zig_base, :func) do
    include Expr
  end

  # Weak ref upgrade to strong ref.
  # Zig: CheatLib.weakArcUpgrade(T, source) or CheatLib.weakRcUpgrade(T, source)
  WeakUpgrade = Struct.new(:source, :zig_base, :func) do
    include Expr
  end

  # Make a list from items.
  # Zig: try CheatLib.makeList(elem_type, alloc, &.{ items })
  MakeList = Struct.new(:elem_type, :items, :alloc_expr) do
    include Expr
  end

  # Frame mark save.
  # Zig: const frame_mark = rt.saveFrameMark();
  FrameSave = Struct.new(:rt_expr) do
    include Stmt
  end

  # Frame mark restore (as defer).
  # Zig: defer rt.restoreFrameMark(frame_mark);
  FrameRestore = Struct.new(:rt_expr) do
    include Stmt
  end

  # Preserve and rewind (for string-returning functions).
  # Zig: return try rt.preserveAndRewind(frame_mark, value);
  PreserveAndRewind = Struct.new(:value, :rt_expr) do
    include Expr
  end

  # ================================================================
  # Verification-Only Nodes (no codegen, for StaticLeakChecker)
  # ================================================================

  # Marks an allocation point. Subsumes old MIR::Alloc.
  AllocMark = Struct.new(:name, :kind, :alloc) do
    include Stmt
    def stmt?; true; end
  end

  # Marks function exit with escaped vars. Subsumes old MIR::Return.
  ReturnMark = Struct.new(:escaped_vars) do
    include Stmt
    def stmt?; true; end
  end

  # Marks reassignment needing pre-cleanup. Subsumes old MIR::ReassignCleanup.
  ReassignMark = Struct.new(:name, :alloc) do
    include Stmt
    def stmt?; true; end
  end

  # Marks field overwrite needing pre-cleanup. Subsumes old MIR::FieldCleanup.
  FieldCleanupMark = Struct.new(:target_name, :field, :alloc) do
    include Stmt
    def stmt?; true; end
  end

  # ================================================================
  # Expressions
  # ================================================================

  # Function call.
  # Zig: [try] callee(args)
  Call = Struct.new(:callee, :args, :try_wrap) do
    include Expr
    # callee: String (Zig function name, possibly qualified)
    # args: [MIR expr]
    # try_wrap: bool
  end

  # Tail call (emits @call(.always_tail, callee, .{args})).
  TailCall = Struct.new(:callee, :args) do
    include Expr
  end

  # Method call.
  # Zig: receiver.method(args)
  MethodCall = Struct.new(:receiver, :method, :args, :try_wrap) do
    include Expr
  end

  # Field access.
  # Zig: object.field
  FieldGet = Struct.new(:object, :field) do
    include Expr
  end

  # Index access.
  # Zig: object[index]  or  specialized patterns (charAt, numericMapGet, etc.)
  IndexGet = Struct.new(:object, :index) do
    include Expr
  end

  # Binary operation.
  # Zig: left op right
  # op is the Zig operator string: "+", "-", "==", "and", "or", etc.
  BinOp = Struct.new(:op, :left, :right) do
    include Expr
  end

  # Unary operation.
  # Zig: op operand
  UnaryOp = Struct.new(:op, :operand) do
    include Expr
  end

  # Literal value. Carries pre-formatted Zig literal string.
  # Zig: 42, 3.14, "hello", true, null, etc.
  Lit = Struct.new(:value) do
    include Expr
  end

  # Variable / name reference.
  # Zig: name
  Ident = Struct.new(:name) do
    include Expr
  end

  # Function pointer reference.
  # Zig: &name
  FnRef = Struct.new(:name) do
    include Expr
  end

  # Struct initialization.
  # Zig: TypeName{ .a = x, .b = y }  or  .{ .a = x }
  StructInit = Struct.new(:zig_type, :fields) do
    include Expr
    # zig_type: String or nil (nil -> anonymous .{})
    # fields: [{ name: String, value: MIR expr }]
  end

  # Fixed-size array initialization.
  # Zig: [N]T{ item1, item2, ... }
  ArrayInit = Struct.new(:elem_type, :count, :items) do
    include Expr
  end

  # Slice expression.
  # Zig: @as([]const T, target[start..end])
  SliceExpr = Struct.new(:target, :start, :end_expr, :elem_type) do
    include Expr
  end

  # Labeled block expression.
  # Zig: label: { body; break :label result; }
  BlockExpr = Struct.new(:label, :body) do
    include Expr
    # body: [MIR stmt] -- last stmt should be BreakStmt with matching label
  end

  # String concatenation.
  # Zig: try CheatLib.concat(rt, alloc, &.{ parts })
  # or   try rt.frameConcat(&.{ parts })
  ConcatStr = Struct.new(:parts, :alloc_expr, :rt_expr) do
    include Expr
  end

  # Type cast.
  # Zig: @as(target_type, expr)  or  @intCast(expr)  etc.
  Cast = Struct.new(:expr, :target_type, :method) do
    include Expr
    # method: :as, :intCast, :floatCast, :ptrCast, :intFromFloat,
    #         :floatFromInt, :truncate, :enumFromInt
  end

  # Try expression (wraps a failable expression).
  # Zig: try expr
  TryExpr = Struct.new(:expr) do
    include Expr
  end

  # Try-catch expression.
  # Zig: expr catch |err| fallback
  # or   (expr catch fallback)
  TryCatch = Struct.new(:expr, :catch_body, :capture) do
    include Expr
    # capture: error variable name or nil
  end

  # Optional orelse expression.
  # Zig: (expr orelse fallback)
  Orelse = Struct.new(:expr, :fallback) do
    include Expr
  end

  # Conditional expression (Zig if-expression).
  # Zig: if (cond) then_val else else_val
  Conditional = Struct.new(:cond, :then_val, :else_val) do
    include Expr
  end

  # Address-of.
  # Zig: &expr
  AddressOf = Struct.new(:expr) do
    include Expr
  end

  # Dereference.
  # Zig: expr.*
  Deref = Struct.new(:expr) do
    include Expr
  end

  # Optional unwrap.
  # Zig: expr.?
  OptionalUnwrap = Struct.new(:expr) do
    include Expr
  end

  # Range literal.
  # Zig: CheatLib.Range{ .start = s, .end = e }
  RangeLit = Struct.new(:start, :end_val) do
    include Expr
  end

  # Comptime has-field check.
  # Zig: @hasField(@TypeOf(expr), "field")
  HasField = Struct.new(:expr, :field) do
    include Expr
  end

  # Items accessor (ArrayList -> slice).
  # Zig: expr.items  or  (if (@hasField(...)) expr.items else expr)
  ItemsAccess = Struct.new(:expr, :safe) do
    include Expr
    # safe: true -> emit @hasField guard, false -> direct .items
  end

  # Lambda expression (anonymous function pointer via struct trick).
  # Zig: &(struct { fn name(params) ret { body } }).name
  LambdaExpr = Struct.new(:fn_def) do
    include Expr
    # fn_def: MIR::FnDef with the lambda's implementation
  end

  # Inline Zig expression. Tracked escape hatch.
  # ownership_contract: same as RawZig. nil = unaudited.
  InlineZig = Struct.new(:code, :reason, :ownership_contract) do
    include Expr
  end
end
