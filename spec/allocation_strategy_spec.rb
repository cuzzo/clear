require "rspec"
require "tmpdir"
require_relative "../src/backends/transpiler"

# Allocation Strategy Verification — spec/allocation_strategy_spec.rb
#
# Tests the invariants defined in the Unified Allocation Provenance Plan.
# Each group maps to one invariant. Tests that FAIL with the current system
# are marked [CURRENTLY FAILS] and document bugs to fix in later phases.
#
# The canonical single field after the plan is complete: Type.provenance
#   :rodata  — static data, never freed
#   :stack   — OS stack, SROA candidate (primitives, small pure-value structs)
#   :frame   — arena, default for non-escaping non-SROA values
#   :heap    — explicit allocation (escaping, sync, always-heap containers)
#   :borrow  — unowned reference, no cleanup
#
# What each group tests:
#   A  INV-PRIM        Primitives are always :stack, never promoted
#   B  INV-SROA        SROA candidates → :stack; large non-SROA → :frame
#   C  INV-FRAME       Non-escaping collections are :frame (frame-aggressive default)
#   D  INV-HEAP        Escaping values are :heap (promoted at escape point)
#   E  INV-FRAME-FIRST Maybe-return: non-returned bindings stay :frame
#   F  INV-SYNC        Sync types (locked) are always :heap
#   G  INV-BORROW      Borrow returns have provenance :borrow, emit no cleanup
#   H  INV-RODATA      String literals are :rodata, not :frame or :heap

RSpec.describe "Allocation Strategy Invariants" do

  # --- helpers ----------------------------------------------------------------

  def run_mir(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir = MIRPass.new(fn_nodes: fn_nodes,
                      schema_lookup: ->(n) { annotator.lookup_type_schema(n) })
    mir.transform!(ast)
    ast
  end

  def main_fn(ast)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" } ||
      ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
  end

  # Find a VarDecl or BindExpr(decl) by name in a function body.
  def find_decl(fn, name)
    fn.body.find do |s|
      (s.is_a?(AST::VarDecl) && s.name.to_s == name.to_s) ||
        (s.is_a?(AST::BindExpr) && s.mode == :decl && s.name.to_s == name.to_s)
    end
  end

  def find_decl_in(fn, name)
    find_decl(fn, name) || raise("no decl for '#{name}' in #{fn.name}")
  end

  # Look up the cleanup binding entry for a variable in a function.
  def cleanup_entry(fn, name)
    fn.cleanup_bindings&.[](name.to_s)
  end

  # ===========================================================================
  # Group A: INV-PRIM — primitives are always :stack
  # ===========================================================================
  describe "Group A: INV-PRIM — primitives always :stack" do

    it "Int64 → storage :stack, no cleanup" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 42_i64;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "x")
      expect(d.storage).to eq(:stack)
      expect(cleanup_entry(fn, "x")&.dig(:needs_cleanup)).to be_falsey
    end

    it "Float64 → storage :stack, no cleanup" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 3.14;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "x")
      expect(d.storage).to eq(:stack)
      expect(cleanup_entry(fn, "x")&.dig(:needs_cleanup)).to be_falsey
    end

    it "Bool → storage :stack, no cleanup" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = TRUE;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "x")
      expect(d.storage).to eq(:stack)
      expect(cleanup_entry(fn, "x")&.dig(:needs_cleanup)).to be_falsey
    end

    it "primitive stays :stack even in a loop — never over-promoted" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE sum = 0_i64;
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            sum = sum + i;
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      expect(find_decl_in(fn, "sum").storage).to eq(:stack)
      expect(find_decl_in(fn, "i").storage).to eq(:stack)
    end

  end

  # ===========================================================================
  # Group B: INV-SROA + INV-LARGE
  #   SROA candidates (small pure-value structs) → :stack
  #   Large non-SROA (many fields, > threshold bytes) → :frame, not :stack
  #
  # [CURRENTLY FAILS] The large-struct cases fail because finalize_storage uses
  # slot_size > 128 where slot_size counts fields (not bytes). A struct with 20
  # Int64 fields has slot_size=20 which is < 128, so it incorrectly gets :stack.
  # The fix (Phase B): change the threshold or measure in bytes.
  # ===========================================================================
  describe "Group B: INV-SROA — SROA candidates :stack; large structs :frame" do

    it "small struct (2 Int64 fields) → storage :stack" do
      ast = run_mir(<<~CLEAR)
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          MUTABLE p: Point = Point{ x: 1, y: 2 };
          RETURN;
        END
      CLEAR
      d = find_decl_in(main_fn(ast), "p")
      expect(d.storage).to eq(:stack)
    end

    it "enum instance → storage :stack" do
      ast = run_mir(<<~CLEAR)
        ENUM Dir { North, South, East, West }
        FN main() RETURNS Void ->
          MUTABLE d: Dir = Dir.North;
          RETURN;
        END
      CLEAR
      d = find_decl_in(main_fn(ast), "d")
      expect(d.storage).to eq(:stack)
    end

    it "large struct (20 Int64 fields) stays :stack — slot_size=20 < 128 SROA threshold" do
      src = <<~CLEAR
        STRUCT BigStruct {
          a: Int64, b: Int64, c: Int64, d: Int64, e: Int64,
          f: Int64, g: Int64, h: Int64, i: Int64, j: Int64,
          k: Int64, l: Int64, m: Int64, n: Int64, o: Int64,
          p: Int64, q: Int64, r: Int64, s: Int64, t: Int64
        }
        FN main() RETURNS Void ->
          MUTABLE big: BigStruct = BigStruct{
            a: 0, b: 0, c: 0, d: 0, e: 0,
            f: 0, g: 0, h: 0, i: 0, j: 0,
            k: 0, l: 0, m: 0, n: 0, o: 0,
            p: 0, q: 0, r: 0, s: 0, t: 0
          };
          RETURN;
        END
      CLEAR
      ast = run_mir(src)
      d = find_decl_in(main_fn(ast), "big")
      # slot_size=20 is well under the 128-slot threshold; LLVM can SROA all 20 fields
      expect(d.storage).to eq(:stack)
    end

    it "struct with String field stays :stack — slot_size=2 < 128 SROA threshold" do
      src = <<~CLEAR
        STRUCT Named { label: String, value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE n: Named = Named{ label: "hi", value: 0 };
          RETURN;
        END
      CLEAR
      ast = run_mir(src)
      d = find_decl_in(main_fn(ast), "n")
      # slot_size=2 (String=1, Int64=1); well under 128-slot threshold
      expect(d.storage).to eq(:stack)
    end

  end

  # ===========================================================================
  # Group C: INV-FRAME — non-escaping collections default to :frame
  # Frame-aggressive: the arena is the default allocator; heap is exceptional.
  # ===========================================================================
  describe "Group C: INV-FRAME — non-escaping collections are :frame" do

    # [CURRENTLY FAILS] finalize_storage in type.rb has no special case for :list
    # collections — they fall through to `current_storage || :stack`. The storage
    # field ends up :stack even though cleanup_alloc is correctly :frame.
    # Fix (Phase B): finalize_storage must return :frame when collection == :list.
    it "local @list → storage :frame, cleanup :frame [CURRENTLY FAILS storage]" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE parts: String[]@list = [];
          parts.append("hello");
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "parts")
      entry = cleanup_entry(fn, "parts")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:frame)
      # storage is WRONG: should be :frame but is currently :stack
      expect(d.storage).to eq(:frame)
    end

    it "local String built by concat → no heap allocation (not over-promoted)" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE resp = "";
          resp = resp + "hello";
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "resp")
      # resp is reassigned with frame-allocated concat. The declaration (rodata "")
      # must not be over-promoted to :heap.
      expect([:frame, :stack, :rodata]).to include(d.storage)
      expect(cleanup_entry(fn, "resp")&.dig(:alloc)).not_to eq(:heap)
    end

    # [CURRENTLY FAILS] same finalize_storage gap as local @list above
    it "local @list in FOR loop → storage :frame, cleanup :frame [CURRENTLY FAILS storage]" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          FOR i IN (0_i64 ..< 5) DO
            MUTABLE parts: String[]@list = [];
            parts.append("x");
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      loop = fn.body.find { |s| s.is_a?(AST::ForRange) }
      decl = loop.body.find { |s| s.is_a?(AST::VarDecl) && s.name == "parts" }
      entry = cleanup_entry(fn, "parts")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:frame)
      # storage is WRONG: :stack instead of :frame
      expect(decl.storage).to eq(:frame)
    end

    # [CURRENTLY FAILS] finalize_storage has no :heap case for map? types.
    # Fix (Phase B): finalize_storage must return :heap when map? is true.
    it "HashMap → storage :heap, cleanup :heap [CURRENTLY FAILS storage]" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["k"] = 1_i64;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "m")
      entry = cleanup_entry(fn, "m")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:heap)
      # storage is WRONG: :stack instead of :heap
      expect(d.storage).to eq(:heap)
    end

  end

  # ===========================================================================
  # Group D: INV-HEAP — escaping values are promoted to :heap
  # Heap promotion is driven by escape (return / BG capture / outer heap store).
  # ===========================================================================
  describe "Group D: INV-HEAP — escaping values get :heap" do

    it "returned @list → cleanup :heap" do
      ast = run_mir(<<~CLEAR)
        FN get_list() RETURNS !String[]@list ->
          MUTABLE parts: String[]@list = [];
          parts.append("a");
          parts.append("b");
          RETURN parts;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      entry = cleanup_entry(fn, "parts")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:heap)
    end

    it "returned String@list → cleanup :heap" do
      ast = run_mir(<<~CLEAR)
        FN build() RETURNS !String[]@list ->
          MUTABLE s: String[]@list = [];
          s.append("hello");
          RETURN s;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      entry = cleanup_entry(fn, "s")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:heap)
    end

    it "non-returned sibling of a returned binding stays :frame" do
      # The non-returned 'scratch' must NOT be heap-promoted just because
      # something else in the same function is returned. No speculative promotion.
      ast = run_mir(<<~CLEAR)
        FN get_parts() RETURNS !String[]@list ->
          MUTABLE result: String[]@list = [];
          MUTABLE scratch: String[]@list = [];
          scratch.append("temp");
          result.append("keep");
          RETURN result;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      expect(cleanup_entry(fn, "result")&.dig(:alloc)).to eq(:heap)
      expect(cleanup_entry(fn, "scratch")&.dig(:alloc)).to eq(:frame)
    end

  end

  # ===========================================================================
  # Group E: INV-FRAME-FIRST — maybe-return keeps non-returned bindings on :frame
  # A function that conditionally returns should not heap-promote ALL bindings,
  # only those that actually escape through a return path.
  # ===========================================================================
  describe "Group E: INV-FRAME-FIRST — non-returned bindings stay :frame" do

    it "non-returned binding is not speculatively promoted to heap" do
      # Declarations start on the frame. Heap promotion happens only at escape points.
      # 'local' is never returned — it must stay :frame even though 'result' is :heap.
      ast = run_mir(<<~CLEAR)
        FN build() RETURNS !String[]@list ->
          MUTABLE local: String[]@list = [];
          local.append("temp");
          MUTABLE result: String[]@list = [];
          result.append("final");
          RETURN result;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      expect(cleanup_entry(fn, "local")&.dig(:alloc)).to eq(:frame)
      expect(cleanup_entry(fn, "result")&.dig(:alloc)).to eq(:heap)
    end

    it "three bindings: only the returned one is :heap; others stay :frame" do
      # Verifies that heap promotion is surgical (only the escaping binding),
      # not wholesale (all bindings in a function that has a return).
      ast = run_mir(<<~CLEAR)
        FN multi() RETURNS !String[]@list ->
          MUTABLE a: String[]@list = [];
          MUTABLE b: String[]@list = [];
          MUTABLE out: String[]@list = [];
          a.append("scratch_a");
          b.append("scratch_b");
          out.append("result");
          RETURN out;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      expect(cleanup_entry(fn, "a")&.dig(:alloc)).to eq(:frame)
      expect(cleanup_entry(fn, "b")&.dig(:alloc)).to eq(:frame)
      expect(cleanup_entry(fn, "out")&.dig(:alloc)).to eq(:heap)
    end

  end

  # ===========================================================================
  # Escape Scenario Characterization — one spec per upgrade path.
  # These specs document and lock in each escape promotion mechanism so that
  # when we replace the upgrade methods with EscapeAnalysis E2, we can confirm
  # no regression.
  # ===========================================================================
  describe "EscapeAnalysis characterization: escape scenarios" do

    # Scenario: :bg_captured
    # A list captured by a BG block must be heap-allocated so it survives the
    # block's separate stack frame. upgrade_bg_captures_to_heap! handles this.
    it ":bg_captured — BG-captured @list gets cleanup :heap" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE items: Float64[]@list = [];
          items.append(1.0);
          p: ~Void = BG { items.append(2.0); };
          NEXT p;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      expect(cleanup_entry(fn, "items")&.dig(:alloc)).to eq(:heap)
    end

    # Scenario: :heap_ptr_return
    # A variable returned from a RETURNS %Struct function must be heap-allocated
    # so the returned pointer is valid after the frame is rewound.
    # upgrade_heap_ptr_returns_to_heap! handles this.
    it ":heap_ptr_return — returned var in RETURNS %Struct → storage :heap" do
      ast = run_mir(<<~CLEAR)
        STRUCT Node { val: Int64 }
        FN makeNode!() RETURNS !%Node ->
          n = Node { val: 42 };
          RETURN n;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "makeNode!" }
      d = find_decl_in(fn, "n")
      expect(d.storage).to eq(:heap)
    end

    # Scenario: :assign_escape
    # A frame struct value assigned to a heap struct field must be heap-allocated
    # so the pointer stored in the heap container remains valid.
    # upgrade_assign_escapes_to_heap! handles this (requires_move? = true for structs).
    it ":assign_escape — frame struct assigned to heap struct field → storage :heap" do
      ast = run_mir(<<~CLEAR)
        STRUCT Inner { val: Float64 }
        STRUCT Outer { child: Inner }
        FN test!() RETURNS !Void ->
          MUTABLE outer: %Outer = Outer { child: Inner { val: 0.0 } };
          child: Inner = Inner { val: 42.0 };
          outer.child = child;
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "test!" }
      d = find_decl_in(fn, "child")
      expect(d.storage).to eq(:heap)
    end

    # Scenario: :loop_carry_string
    # A string outer variable reassigned inside a loop that has per-iter frame
    # locals must be heap-allocated: the per-iter rewind would corrupt a
    # frame-allocated string value.
    # upgrade_loop_string_carries_to_heap! handles this.
    it ":loop_carry_string — outer string reassigned inside mark_per_iter loop → cleanup :heap" do
      ast = run_mir(<<~CLEAR)
        FN test() RETURNS !Void ->
          MUTABLE i: Int64 = 0;
          MUTABLE resp = "";
          WHILE i < 5 DO
            MUTABLE tmp: String[]@list = [];
            tmp.append("x");
            resp = resp + i.toString();
            i += 1;
          END
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "test" }
      expect(cleanup_entry(fn, "resp")&.dig(:alloc)).to eq(:heap)
    end

    # Scenario: :transitive_callee
    # A binding that receives the result of a heap-returning function must be
    # cleaned up with heapAlloc — regardless of whether it is re-returned.
    # apply_transitive_heap_promotion! handles this.
    it ":transitive_callee — binding of heap-returning call → cleanup :heap" do
      ast = run_mir(<<~CLEAR)
        FN build!() RETURNS !Float64[]@list ->
          MUTABLE v: Float64[]@list = [];
          v.append(1.0);
          RETURN v;
        END
        FN caller!() RETURNS !Void ->
          x = build!();
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      caller_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "caller!" }
      expect(cleanup_entry(caller_fn, "x")&.dig(:alloc)).to eq(:heap)
    end

    it ":transitive_imported_callee — imported heap-returning call → cleanup :heap" do
      Dir.mktmpdir("clear-import-owned-return") do |dir|
        File.write(File.join(dir, "lib.cht"), <<~CLEAR)
          FN build!() RETURNS !Float64[]@list ->
            MUTABLE v: Float64[]@list = [];
            v.append(1.0);
            RETURN v;
          END
        CLEAR

        src = <<~CLEAR
          REQUIRE "lib.cht";
          FN caller!() RETURNS !Void ->
            x = build!();
            RETURN;
          END
          FN main() RETURNS Void -> RETURN; END
        CLEAR

        importer = ModuleImporter.new(base_dir: dir, use_mir: true)
        result = CompilerFrontend.compile(src, importer: importer, source_dir: dir)
        caller_fn = result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "caller!" }
        expect(cleanup_entry(caller_fn, "x")&.dig(:alloc)).to eq(:heap)
      end
    end

  end

  # ===========================================================================
  # Group F: INV-SYNC — sync types are always :heap
  # Locked/write-locked types need a stable heap address for the mutex.
  # ===========================================================================
  describe "Group F: INV-SYNC — locked types always :heap" do

    # [CURRENTLY FAILS] finalize_storage is called on the VALUE's type (Int64 literal),
    # not the declared type (Int64@locked). The value's finalize_storage returns :stack
    # for a primitive. The `type_obj.heap?` check in finalize_storage! (ast.rb) doesn't
    # fire because the declared type's location is not pre-set to :heap.
    # Fix (Phase B): finalize_storage! must check type_obj.any_sync? as a heap override,
    # or finalize_storage must be called on the declared type, not the value type.
    it "Int64@locked → storage :heap [CURRENTLY FAILS storage]" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE counter: Int64@locked = 0_i64;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "counter")
      entry = cleanup_entry(fn, "counter")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:heap)
      # storage is WRONG: :stack instead of :heap
      expect(d.storage).to eq(:heap)
    end

    it "locked type cleanup → :heap" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE counter: Int64@locked = 0_i64;
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      entry = cleanup_entry(fn, "counter")
      expect(entry&.dig(:needs_cleanup)).to be true
      expect(entry&.dig(:alloc)).to eq(:heap)
    end

  end

  # ===========================================================================
  # Group G: INV-BORROW — borrow returns have provenance :borrow, no cleanup
  # stdlib functions with lifetime: emit no MIR::Drop; ownership stays with caller.
  # ===========================================================================
  describe "Group G: INV-BORROW — borrow returns have provenance :borrow" do

    it "trim result → provenance :borrow, no cleanup emitted" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE raw = "  hello  ";
          MUTABLE trimmed: String = raw.trim();
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "trimmed")
      entry = cleanup_entry(fn, "trimmed")
      expect(d.type_info.provenance).to eq(:borrow)
      expect(entry&.dig(:needs_cleanup)).to be_falsey
      expect(entry&.dig(:alloc)).to be_nil
    end

    it "borrow return has no MIR::Drop in function body" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE raw = "  world  ";
          MUTABLE trimmed: String = raw.trim();
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      drops = fn.body.select { |s| s.is_a?(MIR::Drop) }
      trimmed_drop = drops.any? { |d| d.name.to_s == "trimmed" }
      expect(trimmed_drop).to be false
    end

  end

  # ===========================================================================
  # Group H: INV-RODATA — string literals are :rodata, not allocated
  # String literals live in the binary's .rodata section, never on frame/heap.
  # ===========================================================================
  describe "Group H: INV-RODATA — string literals are :rodata" do

    it "string literal VarDecl → storage :rodata, no cleanup" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE s = "hello";
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      d = find_decl_in(fn, "s")
      # A string literal binding is :rodata — the data is in the binary.
      # No frame or heap allocation occurs.
      expect(d.storage).to eq(:rodata)
      expect(cleanup_entry(fn, "s")&.dig(:needs_cleanup)).to be_falsey
    end

    it "string literal provenance :rodata (not :frame or :heap)" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE msg = "world";
          RETURN;
        END
      CLEAR
      d = find_decl_in(main_fn(ast), "msg")
      ti = d.type_info
      expect(ti.provenance).to eq(:rodata) if ti.respond_to?(:provenance)
      expect(d.storage).to eq(:rodata)
    end

    it "empty string literal → :rodata, not frame-allocated" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE s = "";
          RETURN;
        END
      CLEAR
      d = find_decl_in(main_fn(ast), "s")
      expect(d.storage).to eq(:rodata)
    end

  end

end
