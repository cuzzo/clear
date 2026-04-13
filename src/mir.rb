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
    def has_own_frame? = true
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
  Let = Struct.new(:name, :init, :mutable, :annotation, :suppression) do
    include Stmt
  end

  # Assignment.
  # Zig: target = value;
  # target is an MIR expression (Ident, FieldGet, IndexGet, Deref)
  # needs_field_cleanup: true if this is a field assignment where the old
  #   value needs cleanup but no pre-cleanup was emitted (FIELD_LEAK).
  Set = Struct.new(:target, :value, :needs_field_cleanup) do
    include Stmt
  end

  # Reassignment with old-value cleanup.
  # Zig: { const __new = value; CheatLib.cleanup(T, alloc, &old); old = __new; }
  # alloc: symbol (:heap, :frame, :cleanup) -- resolved to Zig by emitter.
  ReassignWithCleanup = Struct.new(:name, :value, :zig_type, :alloc) do
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
  #
  # WARNING: RawZig BYPASSES ownership verification. The MIR checker cannot
  # see inside raw Zig code. Any allocation, deallocation, or ownership
  # transfer inside a RawZig block is INVISIBLE to the checker.
  #
  # SAFETY RULES:
  #   - NEVER allocate heap memory inside RawZig without a matching
  #     MIR::AllocMark + MIR::Cleanup outside it (leak).
  #   - NEVER free/deinit a binding inside RawZig that has a Cleanup
  #     outside it (double-free).
  #   - NEVER move ownership of a binding into RawZig without a
  #     MIR::MoveMark + guarded Cleanup outside it (double-free or leak).
  #   - NEVER return a frame-allocated value from RawZig without
  #     MIR::EscapePromote outside it (use-after-free).
  #   - ALWAYS declare ownership_contract so the checker can cross-reference.
  #
  # ownership_contract: { consumes: [name, ...], produces: [name, ...], borrows: [name, ...] }
  #   consumes: bindings whose ownership transfers into the raw block (must have SuppressCleanup)
  #   produces: bindings the raw block creates (must have MIR::Alloc + MIR::Drop)
  #   borrows:  bindings read but not moved/freed (must not be moved during raw block)
  #   nil = unaudited (legacy; to be eliminated)
  RawZig = Struct.new(:code, :reason, :ownership_contract, :stdlib_def) do
    include Stmt
    def expr?; true; end  # can appear in expression position too
  end

  # Background block. Wraps raw Zig code for a fiber spawn but exposes
  # capture_analysis for ownership verification (BG_ESCAPE check).
  # captures: { name => Type-like object } from capture_analysis.captures
  # run_body: [MIR::Stmt] — lowered MIR for the fiber run function body.
  #   Carries the MIR so the checker can see allocations inside the fiber.
  #   Emission still uses code (raw Zig). nil for legacy callers; checker skips.
  BgBlock = Struct.new(:code, :captures, :run_body) do
    include Stmt
    def expr?; true; end
  end

  # Catch wrapper. Wraps raw Zig code for try/catch but exposes
  # error-path reassignment metadata for allocator consistency (INV-9).
  # error_reassigns: [{ name: String, alloc: :heap/:frame, line: int }]
  # clause_bodies: Array<Array<MIR::Stmt>> — one per catch clause + default.
  #   Carries the lowered MIR so the checker can see allocations inside each
  #   catch body. Emission still uses code (raw Zig). nil for legacy callers.
  CatchWrapper = Struct.new(:code, :error_reassigns, :clause_bodies) do
    include Stmt
  end

  # DO block. Wraps raw Zig code for fork-join parallel branches.
  # branch_bodies: Array<Array<MIR::Stmt>> — one per branch, lowered MIR.
  #   Carries the MIR so the checker can see allocations inside DO branches.
  #   Emission still uses code (raw Zig).
  DoBlock = Struct.new(:code, :branch_bodies) do
    include Stmt
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
  #     const __p = try alloc.create(zig_type);
  #     errdefer alloc.destroy(__p);
  #     __p.* = init;
  #     break :blk __p;
  # }
  # Used for: @indirect fields, heap struct literals, capability boxing.
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  HeapCreate = Struct.new(:zig_type, :init, :alloc, :label) do
    include Expr
  end

  # Byte slice duplication.
  # Zig: try alloc.dupe(u8, source)
  # Used for: string copies, HPT return dupes, BG captures.
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  DupeSlice = Struct.new(:source, :alloc) do
    include Expr
  end

  # Typed slice allocation (uninitialized).
  # Zig: try alloc.alloc(elem_type, len)
  # Used for: COPY list deep-copy buffer.
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  AllocSlice = Struct.new(:elem_type, :len, :alloc) do
    include Expr
  end

  # Free a slice.
  # Zig: alloc.free(slice)
  # Used for: errdefer cleanup of AllocSlice.
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  FreeSlice = Struct.new(:slice, :alloc) do
    include Expr
  end

  # Destroy a heap pointer.
  # Zig: alloc.destroy(ptr)
  # Used for: errdefer cleanup of HeapCreate, intermediate cap wrap cleanup.
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  DestroyPtr = Struct.new(:ptr, :alloc) do
    include Expr
  end

  # --- Cleanup / Lifecycle ---

  # Deferred cleanup for a binding. Always emits `defer` (with optional moved
  # guard). cleanup_entry carries all pre-computed data: kind, zig_type,
  # elem_zig_type, alloc, has_moved_guard, rc_* fields, etc.
  # The emitter applies templates mechanically from the entry.
  #
  # cleanup_entry keys: :kind, :zig_type, :elem_zig_type, :alloc,
  #   :has_moved_guard, :resource_close_zig, :is_fixed,
  #   :rc_variant, :rc_alloc, :rc_release_func, :base_zig,
  #   :needs_release_fields
  #
  # Use ErrCleanup instead when ownership transfers to a callee or container
  # and cleanup is only needed on the error path.
  Cleanup = Struct.new(:name, :cleanup_entry) do
    include Stmt
  end

  # Error-path-only cleanup for a binding. Always emits `errdefer`.
  # Used when ownership transfers out of this scope on the success path
  # (TAKES arg, struct/union field) -- the callee/container owns on success,
  # but the binding must be freed if an error occurs after allocation.
  # The emitter emits `errdefer cleanup(name)` unconditionally (no guard).
  ErrCleanup = Struct.new(:name, :cleanup_entry) do
    include Stmt
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
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  DeepCopy = Struct.new(:source, :zig_type, :elem_type, :strategy,
                        :alloc) do
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
  # alloc: symbol (:heap, :frame, nil) -- resolved to Zig by emitter.
  ContainerInit = Struct.new(:zig_type, :strategy, :alloc,
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
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  CapWrap = Struct.new(:inner, :zig_base, :strategy,
                       :sync_fn,   # "lockedCreate", "rwLockedCreate", "refCellCreate", nil
                       :sync_type, # "CheatLib.Locked(T)", nil
                       :own_fn,    # "arcCreate", "rcCreate", nil
                       :alloc) do
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
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  MakeList = Struct.new(:elem_type, :items, :alloc) do
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

  # ================================================================
  # Verification-Only Nodes (no codegen, for MIRChecker)
  # ================================================================

  # Marks an allocation point. Subsumes old MIR::Alloc.
  AllocMark = Struct.new(:name, :alloc) do
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
  # heap_provenance: true if return type is heap-allocated (for HPT_LEAK check).
  Call = Struct.new(:callee, :args, :try_wrap, :heap_provenance) do
    include Expr
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
  # Zig: try std.mem.concat(alloc, u8, &.{ parts })
  # alloc: symbol (:heap, :frame) -- resolved to Zig by emitter.
  # rt_expr: Zig expression for runtime (e.g. "rt") -- used for rt-dependent calls.
  ConcatStr = Struct.new(:parts, :alloc, :rt_expr) do
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

  # Inline Zig expression. Tracked escape hatch for expression-level Zig code.
  #
  # WARNING: InlineZig BYPASSES ownership verification unless stdlib_def is set.
  # The MIR checker cannot see inside inline Zig expressions. Any function call
  # that allocates, deallocates, or transfers ownership is INVISIBLE to the
  # checker unless the stdlib_def field declares it.
  #
  # SAFETY RULES:
  #   - NEVER call a function that allocates (append, getOrPut, dupe, concat)
  #     without setting stdlib_def = { allocates: true }.
  #   - NEVER call a function that frees memory without a corresponding
  #     MIR::Cleanup marker outside the InlineZig.
  #   - NEVER embed multi-statement code -- InlineZig is for expressions only.
  #     Use RawZig (with ownership_contract) for statement-level escape hatches.
  #   - All CheatLib.* calls MUST go through BUILTIN_OPS or STD_LIB registries,
  #     not be emitted as raw InlineZig strings.
  #   - Pure expressions (casts, ranges, field access, Zig builtins) are safe
  #     without stdlib_def.
  #
  # stdlib_def: hash from BUILTIN_OPS/STD_LIB with ownership metadata
  #   { allocates: true }  -- call allocates; checker uses for HPT_LEAK
  #   { borrows: :all }    -- call borrows all args; no ownership transfer
  #   nil = unaudited or pure expression (safe if no allocation/deallocation)
  # ownership_contract: same as RawZig (for RawZig-converted nodes).
  #
  # allocs: resolved allocator symbols for placeholders left in code.
  #   { key_alloc: :heap, val_alloc: :frame, alloc: :heap }
  #   Emitter substitutes {key_alloc} -> "rt.heapAlloc()" etc.
  #   Checker inspects symbols directly (same as DupeSlice.alloc, etc.)
  #   nil = no allocator placeholders (pure expression).
  #
  # target_var: CLEAR variable name of the container being operated on.
  #   Used by the checker to cross-reference with AllocMark for consistency.
  #   nil = no target (intrinsic call, not a container operation).
  InlineZig = Struct.new(:code, :reason, :ownership_contract, :stdlib_def, :allocs, :target_var) do
    include Expr
  end
end
