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

  # IF x AS y [&& z AS a] THEN ... [ELSE ...] END
  # Single binding: if (expr) |y| { then_body } else { else_body }
  # Multi binding:  blk: { const y = expr1 orelse break :blk; ... then_body } if (!ok) { else_body }
  # bindings: Array of { expr: MIR node, capture: String }
  IfBindStmt = Struct.new(:bindings, :then_body, :else_body) do
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

  # Panic with a literal message. Never returns (control-flow terminator).
  # Used for compiler-emitted preconditions where the only sensible
  # response is to crash (e.g. MIN/MAX on empty list, INDEX allocation
  # failure). Both backends terminate execution.
  # Zig: @panic("message");
  Panic = Struct.new(:message) do
    include Stmt
  end

  # In-place sort.
  # Borrows `items_expr`; mutates the underlying slice. The comparator is
  # encoded as two key extraction expressions (key_a, key_b) — both are MIR
  # expression trees referring to placeholder identifiers `a` and `b`. The
  # emitter wraps them in the appropriate Zig closure / VM comparator.
  # No allocation; ownership of items unchanged.
  # Zig: std.mem.sort(T, items, {}, struct { fn lessThan(_, a, b) {...} });
  Sort = Struct.new(:elem_type, :items_expr, :key_a, :key_b) do
    include Stmt
  end

  # Typed-slice extraction from a Struct-of-Arrays container.
  # Borrows the SoA container; returns a slice view of one field.
  # Zig: container.data.items(.fieldname)
  SoaFieldAccess = Struct.new(:soa_expr, :field_name) do
    include Expr
  end

  # Fallible expression with literal-message panic on error. Replaces
  # `try X catch @panic("message")` patterns where the catch is purely
  # for "this can't legitimately fail at runtime, but the API is fallible".
  # Used by INDEX op (HashMap getOrPut, value_ptr.append) and similar.
  # Zig: <expr> catch @panic("message")
  TryOrPanic = Struct.new(:expr, :panic_msg) do
    include Expr
  end

  # INDEX-bucket insert: append `value` to the list bucket of `map` at `key`,
  # creating the bucket if missing. The Zig backend lowers this to the
  # getOrPut + value_ptr.append pattern with key dup/free; the VM lowers it
  # to MAP_GET + (Nil ? new_list : append) + MAP_PUT, which has matching
  # semantics for HashMap<K, []V> indexing.
  # `key_zig_type` is the comptime element type used by alloc.dupe in the
  # Zig backend (e.g. "u8"); ignored by the VM.
  # `elem_zig_type` is the comptime list-element type used by the empty-list
  # initializer in the Zig backend; ignored by the VM.
  IndexInsert = Struct.new(:map, :key_expr, :value_expr,
                           :key_zig_type, :elem_zig_type, :alloc) do
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
  CatchWrapper = Struct.new(:code, :error_reassigns, :clause_bodies, :clause_meta, :has_default) do
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
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  HeapCreate = Struct.new(:zig_type, :init, :alloc, :label) do
    include Expr
  end

  # Byte slice duplication.
  # Zig: try alloc.dupe(u8, source)
  # Used for: string copies, HPT return dupes, BG captures.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  DupeSlice = Struct.new(:source, :alloc) do
    include Expr
  end

  # Typed slice allocation (uninitialized).
  # Zig: try alloc.alloc(elem_type, len)
  # Used for: COPY list deep-copy buffer.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  AllocSlice = Struct.new(:elem_type, :len, :alloc) do
    include Expr
  end

  # Free a slice.
  # Zig: alloc.free(slice)
  # Used for: errdefer cleanup of AllocSlice.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
  FreeSlice = Struct.new(:slice, :alloc) do
    include Expr
  end

  # Destroy a heap pointer.
  # Zig: alloc.destroy(ptr)
  # Used for: errdefer cleanup of HeapCreate, intermediate cap wrap cleanup.
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
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
  #   :generic_deep -> try CheatLib.promoteDeep(zig_type, rt, &name);
  # `name` may be a dotted path (e.g. "__ret.field") for per-field
  # promotion in a return-with-promotion pattern; the emitter takes &name
  # verbatim.
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
  #   :full_value  -> try CheatLib.dupeValue(@TypeOf(source), source, alloc)
  #                   (Used when the destination type matches source: ArrayList ->
  #                    ArrayList, struct -> struct. Comptime branches in
  #                    dupeValue dispatch to the right deep-copy.)
  #   :passthrough  -> source (no copy needed, value type)
  # alloc: Symbol (:heap, :frame, :cleanup) resolved via rt, OR a MIR
  # expression node (e.g. Ident("alloc")) used directly as the allocator.
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

  # Compact an @multiowned tree into a single contiguous buffer.
  # Zig: try CheatLib.freeze(T, alloc, inner_ptr)
  # inner: MIR expr for the Rc data pointer (*const T)
  # zig_base: Zig type name for T
  FreezeExpr = Struct.new(:inner, :zig_base) do
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
  AllocMark = Struct.new(:name, :alloc, :type_info) do
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

  # Optional-unwrap conditional expression.
  # Zig: (if (optional) |capture| then_expr else else_expr)
  # capture is the name bound to the unwrapped value inside then_expr.
  IfOptional = Struct.new(:optional, :capture, :then_expr, :else_expr) do
    include Expr
  end

  # Comptime-qualified expression.
  # Zig: comptime expr
  # Forces expr to be evaluated at compile time.
  Comptime = Struct.new(:expr) do
    include Expr
  end

  # Semantic union-variant payload access.
  # Zig: union_value.Variant
  # zig_type: the union's Zig type name (for checker cross-reference and
  # for bc_emitter dispatch). Distinguishes variant access from struct-field
  # access so bc_emitter can route to native `cdr` (or equivalent) without
  # scanning variant name tables.
  UnionVariantGet = Struct.new(:object, :variant, :zig_type) do
    include Expr
  end

  # Semantic list-backing-slice access.
  # Zig: list.items
  # Used by lowering to mark list-specific accesses (vs arbitrary struct
  # fields). The checker and bc_emitter can dispatch on node class rather
  # than name-matching "items".
  ListItems = Struct.new(:list) do
    include Expr
  end

  # Semantic list length access.
  # Zig: expr.len
  # Wrap in ListItems first for ArrayList-shaped containers whose length
  # lives at list.items.len (compose as ListLength(ListItems(list))).
  ListLength = Struct.new(:expr) do
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

  # Allocator reference. Zig-side: rt.heapAlloc() / rt.frameAlloc() /
  # rt.cleanupAlloc(). VM-side: no-op (VM is GC'd); strip_alloc_args drops
  # these at call sites. kind: :heap | :frame | :cleanup.
  AllocatorRef = Struct.new(:kind) do
    include Expr
  end

  # Uninitialized-memory sentinel. Zig: `undefined`. VM: nil (the slot is
  # about to be written before use).
  Undef = Struct.new(:zig_type) do
    include Expr
    # zig_type is optional — used by the Zig emitter when it needs a typed
    # undefined like `@as(T, undefined)`.
  end

  # Type sentinel — floatMax/floatMin/intMax/intMin style bootstrap value.
  # Zig: std.math.floatMax(T), -std.math.floatMax(T), std.math.maxInt(T), etc.
  # VM: a large concrete literal sufficient for accumulator-seed purposes.
  # kind: :max | :min      extreme: which end of the type range.
  # zig_type: the Zig type string (e.g. "f64", "i64").
  TypeSentinel = Struct.new(:extreme, :zig_type) do
    include Expr
  end

  # Bare integer range for Zig `for (0..N) |i| { ... }` loops. Distinct from
  # RangeLit which wraps as CheatLib.IntRange{...}. IterRange emits literal
  # `start..end` and is legal only inside ForStmt iterables.
  IterRange = Struct.new(:start, :end_val) do
    include Expr
  end

  # Optional unwrap.
  # Zig: expr.?
  OptionalUnwrap = Struct.new(:expr) do
    include Expr
  end

  # Range literal.
  # Zig: CheatLib.IntRange{ .start = s, .end = e } or CheatLib.Range{ .start = s, .end = e }
  RangeLit = Struct.new(:start, :end_val, :elem_type) do
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
  LambdaExpr = Struct.new(:fn_def, :captures) do
    include Expr
    # fn_def: MIR::FnDef with the lambda's implementation
    # captures: optional Array<String> — USE-captured variable names
    # from the AST. The Zig backend ignores these (the synthesized
    # struct's `fn` accesses outer scope); the BC backend uses them
    # to emit STORE_NAME at lambda creation and LOAD_NAME inside the
    # body so the values survive across the BC_CALL boundary.
  end

  # Pipeline IR node. Wraps the pre-computed MIR output of a s> chain.
  # Phase 1: inner carries old-path MIR (RawZig or MIR tree); all other fields nil.
  # Future phases: source_type, stages, sink, sink_alloc encode streaming structure.
  #
  # ast_node:    original s> BinaryOp AST node
  # inner:       pre-computed MIR from existing paths (Phase 1), nil in Phase 2+
  # source_type: :range/:slice/:list/:pool/:sharded/:inf_stream (Phase 2+)
  # stages:      Array of stage descriptors (Phase 3+)
  # sink:        sink descriptor (Phase 4+)
  # sink_alloc:  :frame/:heap for sink output (Phase 4+)
  Pipeline = Struct.new(:ast_node, :inner, :source_type, :stages, :sink, :sink_alloc) do
    include Stmt
    def expr?; true; end  # can appear in both expression and statement position
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

  # Inline bytecode. Sibling to InlineZig, consumed only by bc_emitter (the
  # VM backend). Emitted by MIR lowering when target == :bc AND the stdlib
  # registry entry opts into bc (entry[:bc] == true). Carries the op symbol
  # (same key used in BUILTIN_OPS) + arg expressions.
  #
  # op:    Symbol — the registry key (e.g. :intAdd, :assert, :eql).
  # args:  Array<MIR::Expr> — the argument expressions (unlowered).
  # stdlib_def: the registry hash (ownership semantics).
  #
  # bc_emitter has a case-per-op dispatch. It evaluates args (via compile_expr)
  # in declared order, then emits the corresponding opcode sequence. The Zig
  # backend must never see this node.
  InlineBc = Struct.new(:op, :args, :stdlib_def) do
    include Expr
  end

  # Raw bytecode. Sibling to RawZig for the :bc target. Nothing in
  # mir_lowering emits this yet — Phase 0 scaffolding only (see
  # examples/minivm/MIR_MIGRATION.md). Phase 3 will start emitting it
  # by target-aware rewriting of RawZig sites that have a :bc_raw
  # registry mapping.
  #
  # template: Array of Symbol | String | Array. bc_emitter walks the
  #   template: a Symbol is an opcode name (emit_op(OPCODE)), a String
  #   is a placeholder like "{0}" that substitutes with the compiled
  #   value of args[0], an Array is [opcode_symbol, *inline_args] for
  #   opcodes that take immediate args (e.g. [:NATIVE_CALL, :list_push, 2]).
  # args:     Array<MIR::Expr> — the argument expressions (unlowered).
  # stdlib_def: the registry hash the template came from (ownership
  #   semantics so the checker can reason about it).
  #
  # Same invisibility rule as RawZig applies: the checker cannot see
  # inside the template. When Phase 3 lands, every bc_raw template should
  # come from a registry entry whose ownership effects are declared in
  # stdlib_def, making INV-5 enforceable uniformly.
  RawBc = Struct.new(:template, :args, :stdlib_def) do
    include Stmt
    def expr?; true; end  # can appear in expression position too
  end

  # Sharded HashMap put / get -- structural representation of a write/read
  # against a (possibly sharded, possibly Arc-wrapped) HashMap. Replaces
  # the InlineZig template substitution path so the checker has visibility
  # into key allocation, value transfer, and shard-direct vs routed
  # dispatch.
  #
  # Fields:
  #   target:      MIR node for the container being read/written.
  #   key:         MIR node for the lookup key (string or numeric).
  #   value:       MIR node for the value being written (Put only).
  #   shard_idx:   MIR node (typically Ident) for the shard index var
  #                when emitted inside a SHARD pipeline body. nil ->
  #                routed dispatch (target.put / target.get computes
  #                the shard internally).
  #   shard_key:   MIR node for the shard-keyed lookup string (only set
  #                when shard_idx is non-nil and the shard_direct
  #                template uses it).
  #   map_kind:    :string_map | :numeric_map -- chooses key encoding.
  #   stdlib_def:  the INDEX_OPS entry (with :zig, :shard_direct_zig,
  #                :sharded_zig, allocator keys, value_transforms,
  #                bc_op). The Zig emitter reads this to pick the
  #                template; the checker reads it to validate
  #                ownership effects.
  #   key_zig:     Optional Zig type string for numeric_map key (for
  #                CheatLib.numericMapGet template). Set when relevant.
  #   val_zig:     Same, for value type.
  # resolved_allocs: Hash of allocator placeholder name (:alloc, :key_alloc,
  #   :val_alloc, :shard_alloc) to a resolved allocator symbol (:heap |
  #   :frame). The lowering pre-resolves :receiver_storage / :node_storage
  #   to a concrete kind based on the receiver/target context, so the
  #   emitter only needs to map symbol -> Zig string.
  # template_kind: :zig | :sharded_zig | :shard_direct_zig -- which
  #   INDEX_OPS template the lowering chose. The emitter uses this to
  #   pick the same template without re-running the lowering's
  #   shard-context inspection.
  ShardedMapPut = Struct.new(:target, :key, :value, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_zig, :val_zig,
                              :resolved_allocs, :template_kind) do
    include Stmt
    def expr?; true; end
  end

  ShardedMapGet = Struct.new(:target, :key, :shard_idx, :shard_key,
                              :map_kind, :stdlib_def, :key_zig, :val_zig,
                              :resolved_allocs, :template_kind) do
    include Expr
  end
end
