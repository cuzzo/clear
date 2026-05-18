require "rspec"
require_relative "../src/backends/transpiler"

# Tests for LoopFrameAnalysis (Pass 2.5) -- the module that sets mark_per_iter
# and promotes outer containers/fields to heap.
#
# Groups:
#   A  mark_per_iter = true  (loop-local frame collections)
#   B  mark_per_iter = false (no frame locals, or locals that escape)
#   C  heap carry var promotion (outer string reassignment upgraded to heap)
#   D  outer container heap promotion (promote_outer_mutations!)
#   E  outer struct/map field promotion (promote_outer_field_assigns!)
#   F  Zig output: saveLoopMark/restoreLoopMark emitted

RSpec.describe LoopFrameAnalysis do

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
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: ->(n) { annotator.lookup_type_schema(n) })
    mir.transform!(ast)
    ast
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def main_fn(ast)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" } ||
      ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
  end

  # ===========================================================================
  # Group A: mark_per_iter = true
  # ===========================================================================
  describe "Group A: mark_per_iter = true for loop-local frame collections" do

    it "WhileLoop: local @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be true
    end

    it "ForRange: local @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          FOR i IN (0_i64 ..< 5) DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::ForRange) }
      expect(loop.mark_per_iter).to be true
    end

    it "ForEach: local @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [1_i64, 2_i64];
          FOR x IN xs DO
            MUTABLE parts: String[]@list = [];
            parts.append(x.toString());
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::ForEach) }
      expect(loop.mark_per_iter).to be true
    end

    it "WhileLoop: local @list (not HashMap) → mark_per_iter = true, HashMap alone → false" do
      # HashMaps are always heap-allocated; they are not frame collections.
      # mark_per_iter requires a loop-local FRAME collection (@list or similar).
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE m: HashMap<Int64> = {};
            m["k"] = i;
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be false
    end

    it "inner loop gets mark_per_iter, outer loop does not (no outer-scope frame locals)" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            MUTABLE j = 0_i64;
            WHILE j < 3 DO
              MUTABLE parts: String[]@list = [];
              parts.append(j.toString());
              j = j + 1_i64;
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      outer = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
      inner = outer.do_branch.find { |s| s.is_a?(AST::WhileLoop) }
      expect(outer.mark_per_iter).to be false
      expect(inner.mark_per_iter).to be true
    end

  end

  # ===========================================================================
  # Group B: mark_per_iter = false
  # ===========================================================================
  describe "Group B: mark_per_iter = false" do

    it "no frame allocs in body → false" do
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
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be false
    end

    it "outer list append with literal value → false (accumulation pattern)" do
      # append(outer, literal): backing-store extension of the outer container.
      # Per-iteration rewind would corrupt the accumulated data.
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE all: Float64[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            append(all, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be false
    end

    it "local list escapes to outer via append → false" do
      # The local 'val' escapes into outer 'keys' — can't rewind and keep the pointer.
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE keys: String[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            keys.append(i.toString());
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be false
    end

    it "TIGHT WHILE: suppresses mark_per_iter even with local frame list" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be_falsey
    end

  end

  # ===========================================================================
  # Group C: heap carry var promotion (outer string reassigned in mark_per_iter loop)
  # ===========================================================================
  # Previously used loopPreserveAndRewind (frame-copy before rewind).
  # Now: carry vars are promoted to heap so they survive the per-iter rewind.
  describe "Group C: heap carry var promotion for outer string reassignment" do

    it "outer string reassigned with frame concat → declaration promoted to heap" do
      # resp = resp + i.toString(): resp is outer, i.toString() is loop-local frame string.
      # Phase 1.5c promotes resp's declaration to heap so it survives the per-iter rewind.
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE resp = "";
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE part: String[]@list = [];
            part.append(i.toString());
            resp = resp + i.toString();
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      loop = fn.body.find { |s| s.is_a?(AST::WhileLoop) }
      resp_decl = fn.body.find { |s| (s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr)) && s.name.to_s == "resp" }
      expect(loop.mark_per_iter).to be true
            expect(resp_decl.type_info.heap_provenance?).to be true
    end

    it "no heap carry promotion when no outer string reassignment occurs" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be true
          end

    it "Zig output uses heap concat (not loopPreserveAndRewind) for outer string variable" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE resp = "";
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
            resp = resp + i.toString();
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("loopPreserveAndRewind")
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("defer rt.restoreLoopMark")
      expect(zig).to include("rt.heapAlloc()")
    end

    it "outer string reassigned with user function call result → declaration promoted to heap" do
      # last = makePrefix(i): the loop has mark_per_iter=true (tmp forces it).
      # Phase 1.5c promotes last's declaration to heap so it survives the rewind.
      ast = run_mir(<<~CLEAR)
        FN makePrefix(i: Int64) RETURNS !String ->
          RETURN "entry-" + i.toString();
        END
        FN main() RETURNS Void ->
          MUTABLE last = "";
          FOR i IN (1_i64 ..= 5) DO
            tmp = i.toString();
            last = makePrefix(i);
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      loop = fn.body.find { |s| s.is_a?(AST::ForRange) }
      last_decl = fn.body.find { |s| (s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr)) && s.name.to_s == "last" }
      expect(loop.mark_per_iter).to be true
            expect(last_decl.type_info.heap_provenance?).to be true
    end

    it "outer string reassigned with method call result → declaration promoted to heap" do
      # last = i.toString(): loop has mark_per_iter=true (tmp forces it).
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE last = "";
          FOR i IN (1_i64 ..= 5) DO
            tmp = i.toString();
            last = i.toString();
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      loop = fn.body.find { |s| s.is_a?(AST::ForRange) }
      last_decl = fn.body.find { |s| (s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr)) && s.name.to_s == "last" }
      expect(loop.mark_per_iter).to be true
            expect(last_decl.type_info.heap_provenance?).to be true
    end

    it "outer string reassigned with concat of outer (non-local) vars → declaration promoted to heap" do
      # result = prefix + "-" + suffix: ALL parts are outer vars, not frame locals.
      # The concat is still frame-allocated by default and corrupted by the rewind.
      # Phase 1.5c promotes result's declaration to heap.
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE prefix = "hello";
          MUTABLE suffix = "world";
          MUTABLE result = "";
          FOR i IN (1_i64 ..= 5) DO
            tmp = i.toString();
            result = prefix + "-" + suffix;
          END
          RETURN;
        END
      CLEAR
      fn = main_fn(ast)
      loop = fn.body.find { |s| s.is_a?(AST::ForRange) }
      result_decl = fn.body.find { |s| (s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr)) && s.name.to_s == "result" }
      expect(loop.mark_per_iter).to be true
            expect(result_decl.type_info.heap_provenance?).to be true
    end

  end

  # ===========================================================================
  # Group D: outer container heap promotion (promote_outer_mutations!)
  # ===========================================================================
  describe "Group D: outer container promoted to heap when loop rewinds" do

    it "outer @list that receives append of loop-local value gets promoted to heap" do
      # outer_list.append(local_frame_val): when mark_per_iter=true and the
      # escapes_to_outer? check fires, the outer container is promoted.
      # However if the local val escapes via append, mark_per_iter=false -- so
      # this test covers the case where a SEPARATE local list exists AND there is
      # also a mutation of an outer list via a different path.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE outer: Float64[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            append(outer, i.toString().length());
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Outer list is frame-allocated (append with frame-allocated backing extension)
      # Per-iteration rewind is false: no local frame collections.
      expect(zig).not_to include("saveLoopMark")
    end

    it "loop with local frame list AND outer append: outer promoted to heap, loop rewound" do
      # A loop with BOTH a loop-local frame list AND an outer container that gets
      # its backing-store extended (append of a non-local value).
      # The outer must be heap-promoted so the rewind doesn't corrupt its backing.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE log: String[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
            log.append("done");
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      # log must be heap-allocated because it's extended inside a rewinding loop
      expect(zig).to include("heapAlloc")
    end

    # Regression for the bc_runner UAF family (#76, #89, #115, #121, #156, #174,
    # #271, #78). When a rewinding loop has the outer-mutation buried inside a
    # nested loop / nested control-flow, scan_direct stops at the inner loop
    # boundary and never sees the mutation. The outer container then keeps its
    # frame allocator and the per-iteration rewind frees its growth buffer mid-run.
    it "outer @list mutated inside a nested loop INSIDE a rewinding loop is heap-promoted" do
      src = <<~CLEAR
        UNION Val { Nil, Number: Float64 }
        FN main() RETURNS Void ->
          MUTABLE outer: Val[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            # frame-alloc in WHILE's direct body drives mark_per_iter=true
            MUTABLE buf: Val[]@list = [];
            buf.append(Val.Nil);
            FOR k IN (0_i64 ..< 4_i64) DO
              # Mutation buried inside a nested FOR; transitively in a
              # rewinding loop's body.
              outer.append(Val.Nil);
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      # outer.append must use heapAlloc — anything else is a UAF when the
      # WHILE rewinds.
      expect(zig).to match(/outer\.append\(rt\.heapAlloc\(\)/)
    end

    # Same pattern but the nested control-flow is a MATCH instead of a FOR.
    # MATCH is currently included in scan_direct's recursion, so this passes
    # today — keep the invariant explicit so a future scan_direct refactor
    # doesn't quietly drop coverage.
    it "outer @list mutated inside a MATCH branch INSIDE a rewinding loop is heap-promoted" do
      src = <<~CLEAR
        UNION Val { Nil, Number: Float64 }
        FN main() RETURNS Void ->
          MUTABLE outer: Val[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE buf: Val[]@list = [];
            buf.append(Val.Nil);
            PARTIAL MATCH i START
              DEFAULT -> outer.append(Val.Nil);
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to match(/outer\.append\(rt\.heapAlloc\(\)/)
    end

  end

  # ===========================================================================
  # Group E: outer struct/map field promotion
  # ===========================================================================
  describe "Group E: outer struct field assignment promotes RHS to heap" do

    it "outer struct field assigned frame string uses heapAlloc in Zig output" do
      src = <<~CLEAR
        STRUCT State { label: String, count: Int64 }
        FN main() RETURNS Void ->
          MUTABLE s: State = State{ label: "init", count: 0 };
          FOR i IN (1_i64 ..= 3) DO
            s.count = s.count + 1;
            s.label = "step-" + i.toString();
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The concat result must be heap-allocated to match the field's cleanup allocator
      expect(zig).to include("heapAlloc")
      # Should NOT crash (allocator mismatch would cause double-free segfault)
    end

    it "multiple iterations of outer struct field assignment stay correct" do
      # Verifies that the test 204 scenario passes end-to-end.
      src = <<~CLEAR
        STRUCT State { label: String, count: Int64 }
        FN main() RETURNS Void ->
          MUTABLE s: State = State{ label: "init", count: 0 };
          FOR i IN (1_i64 ..= 5) DO
            s.count = s.count + 1;
            s.label = "step-" + i.toString();
          END
          ASSERT s.count == 5;
          ASSERT s.label == "step-5";
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

  end

  # ===========================================================================
  # Group F: Zig saveLoopMark / restoreLoopMark emitted for all loop constructs
  # ===========================================================================
  describe "Group F: saveLoopMark / restoreLoopMark emitted for all constructs" do

    it "WhileLoop emits saveLoopMark + defer restoreLoopMark for loop-local list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "WhileLoop heap-promotes a loop-local string that escapes into an outer list" do
      src = <<~CLEAR
        FN isCommand(ch: String) RETURNS Bool ->
          RETURN ch == ">" || ch == "<";
        END

        FN commands(program: String) RETURNS !String ->
          MUTABLE parts: String[]@list = [];
          MUTABLE i = 0;
          WHILE i < program.length() DO
            ch = program.charAt(i);
            IF isCommand(ch) THEN
              parts.append(ch);
            END
            i += 1;
          END
          RETURN parts.join("");
        END
      CLEAR

      zig = nil
      expect { zig = transpile(src) }.not_to raise_error
      expect(zig).to include("charAtCodepoint(rt.heapAlloc()")
      expect(zig).not_to include("saveLoopMark")
    end

    it "WhileLoop heap-promotes a loop-local list that escapes into an outer list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE outer: Int64[][]@list = [];
          MUTABLE i = 0;
          WHILE i < 1 DO
            MUTABLE inner: Int64[]@list = [];
            inner.append(i);
            outer.append(inner);
            i += 1;
          END
          RETURN;
        END
      CLEAR

      zig = nil
      expect { zig = transpile(src) }.not_to raise_error
      expect(zig).to include("inner.append(rt.heapAlloc()")
      expect(zig).to include("inner_moved = true")
      expect(zig).not_to include("saveLoopMark")
    end

    it "WhileLoop heap-promotes a loop-local dynamic array that escapes into an outer list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE outer: Int64[][]@list = [];
          MUTABLE i = 0;
          WHILE i < 1 DO
            inner: Int64[] = [i, i + 1];
            outer.append(inner);
            i += 1;
          END
          RETURN;
        END
      CLEAR

      zig = nil
      expect { zig = transpile(src) }.not_to raise_error
      expect(zig).to include("rt.heapAlloc()")
      expect(zig).not_to include("saveLoopMark")
    end

    it "WhileLoop keeps an escaping loop-local map on heap without loop marks" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE outer: HashMap<Int64>[]@list = [];
          MUTABLE i = 0;
          WHILE i < 1 DO
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = i;
            outer.append(m);
            i += 1;
          END
          RETURN;
        END
      CLEAR

      zig = nil
      expect { zig = transpile(src) }.not_to raise_error
      expect(zig).to include("StringMap")
      expect(zig).to include("rt.heapAlloc()")
      expect(zig).not_to include("saveLoopMark")
    end

    it "ForRange emits saveLoopMark + defer restoreLoopMark for loop-local list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          FOR i IN (0_i64 ..< 5) DO
            MUTABLE parts: String[]@list = [];
            parts.append(i.toString());
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "ForEach emits saveLoopMark + defer restoreLoopMark for loop-local list" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [1_i64, 2_i64, 3_i64];
          FOR x IN xs DO
            MUTABLE parts: String[]@list = [];
            parts.append(x.toString());
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "TIGHT WHILE does NOT emit saveLoopMark even with frame allocs" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          TIGHT WHILE i < 100 DO
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("saveLoopMark")
    end

    it "outer-only append loop does NOT emit saveLoopMark" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE all: Float64[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 10 DO
            append(all, 1.0);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).not_to include("saveLoopMark")
    end

    it "nested loops: inner saveLoopMark appears once, outer does not" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            MUTABLE j = 0_i64;
            WHILE j < 3 DO
              MUTABLE parts: String[]@list = [];
              parts.append(j.toString());
              j = j + 1_i64;
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig.scan("saveLoopMark").length).to eq(1)
    end

    # --- heap carry string in doubly-nested loops (server pattern) ---
    # The outer loop is mark_per_iter (frame-local prefix string).
    # The inner loop is mark_per_iter (frame-local parts list).
    # resp is a heap carry var: outer-scoped string reassigned in the inner loop.
    # Both outer and inner emit saveLoopMark/restoreLoopMark.
    it "doubly-nested loops both emit saveLoopMark when both have frame-locals" do
      # Outer loop: prefix is a frame-local string -> outer loop gets mark_per_iter.
      # Inner loop: parts is a frame-local list -> inner loop gets mark_per_iter.
      # Both loops must emit saveLoopMark / restoreLoopMark.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE outer = 0_i64;
          WHILE outer < 3 DO
            prefix = "O" + outer.toString();
            MUTABLE resp = "";
            MUTABLE i = 0_i64;
            WHILE i < 5 DO
              MUTABLE parts: String[]@list = [];
              parts.append(i.toString());
              resp = resp + i.toString() + ";" + prefix.length().toString();
              i = i + 1_i64;
            END
            outer = outer + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Both outer (prefix is frame-local) and inner (parts is frame-local) get marks
      expect(zig.scan("saveLoopMark").length).to eq(2)
      expect(zig.scan("restoreLoopMark").length).to eq(2)
    end

    it "heap carry string in nested loop: initial value heap-duped, not comptime literal" do
      # When resp is promoted to heap (carry var), its initial value "" must be
      # heap-duped so defer heapAlloc().free(resp) does not free a comptime literal.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            prefix = "O" + i.toString();
            MUTABLE resp = "";
            MUTABLE j = 0_i64;
            WHILE j < 5 DO
              MUTABLE parts: String[]@list = [];
              parts.append(j.toString());
              resp = resp + j.toString() + ";" + prefix.length().toString();
              j = j + 1_i64;
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # resp's initial value must be a heap dupe, not the comptime literal ""
      expect(zig).to include('heapAlloc().dupe(u8, "")')
      expect(zig).not_to match(/var resp.*=\s*""\s*;/)
    end

    it "heap carry string in nested loop: reassignment uses ReassignWithCleanup" do
      # resp = resp + ... must free the old resp before assigning new.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            prefix = "O" + i.toString();
            MUTABLE resp = "";
            MUTABLE j = 0_i64;
            WHILE j < 5 DO
              MUTABLE parts: String[]@list = [];
              parts.append(j.toString());
              resp = resp + j.toString() + ";" + prefix.length().toString();
              j = j + 1_i64;
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # The pattern is: allocate __new_resp, cleanup old resp, assign new
      expect(zig).to include("__new_resp")
      expect(zig).to include("CheatLib.cleanup([]const u8")
      # And the final defer must free resp
      expect(zig).to include("defer rt.heapAlloc().free(resp)")
    end

  end

  # ===========================================================================
  # Group G: AST invariant -- IfStatement#else_branch is ALWAYS an Array
  #
  # Root cause of the 2026-05-18 compiler bug: PipelineRewriter constructed
  # AST::IfStatement.new(..., nil) for an absent else, violating the parser
  # invariant (parser uses `[]`, never nil). scan_direct then correctly
  # received a contract-violating nil. The architecturally-correct fix is
  # to keep scan_direct's contract strictly non-nil and stop nil at the
  # source (PipelineRewriter -> []; MatchStatement#default_case, which IS
  # `[ASTNode] or nil` by AST design, is guarded at the one recurse site).
  # scan_direct is NEVER called with nil; its sig must stay non-nilable.
  # These lock the invariant + the end-to-end paths.
  # ===========================================================================
  describe "Group G: IfStatement#else_branch invariant (never nil) + scan_direct strict contract" do
    # Walk every IfStatement in the (pipeline-rewritten) tree.
    def each_if_statement(node, &blk)
      return unless node
      blk.call(node) if node.is_a?(AST::IfStatement)
      if node.respond_to?(:to_a)
        node.to_a.each { |c| [c].flatten.each { |x| each_if_statement(x, &blk) if x.is_a?(Struct) } }
      end
    end

    it "PipelineRewriter never produces a nil else_branch (parser invariant upheld)" do
      # A pipeline that exercises PipelineRewriter's synthesized
      # IfStatements (WHERE predicate, FIND, AVG, limit/skip, ANY/ALL).
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64, 3_i64, 4_i64];
          s = xs |> WHERE _ > 1_i64 |> SUM _;
          ASSERT s == 9_i64, "where+sum";
          RETURN;
        END
      CLEAR
      offenders = []
      ast.statements.each { |st| each_if_statement(st) { |iff| offenders << iff if iff.else_branch.nil? } }
      expect(offenders).to be_empty,
        "PipelineRewriter must use [] (not nil) for an absent else_branch; " \
        "#{offenders.size} IfStatement(s) violated the AST invariant"
    end

    it "collect_local_names runs on IF without ELSE (no nil reaches scan_direct)" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE a = 1_i64;
          IF a > 0_i64 THEN
            MUTABLE b = 2_i64;
            a = a + b;
          END
          RETURN;
        END
      CLEAR
      names = nil
      expect { names = LoopFrameAnalysis.collect_local_names(main_fn(ast).body) }.not_to raise_error
      expect(names).to include("a")
    end

    it "collect_local_names runs on PARTIAL MATCH without DEFAULT (default_case nil guarded at recurse site)" do
      ast = run_mir(<<~CLEAR)
        UNION V { Nil, IntV: Int64 }
        FN main() RETURNS Void ->
          MUTABLE v: V = V{ IntV: 7 };
          MUTABLE acc = 0_i64;
          PARTIAL MATCH v START
            V.IntV AS i -> acc = acc + i;
          END
          RETURN;
        END
      CLEAR
      expect { LoopFrameAnalysis.collect_local_names(main_fn(ast).body) }.not_to raise_error
    end

    it "scan_direct's contract is strictly non-nil (passing nil is a type error, not a no-op)" do
      # Encodes the CORRECT contract: scan_direct walks a statement body,
      # which is always an Array. nil must NOT be silently accepted --
      # that was the band-aid. Callers must never pass nil.
      expect { LoopFrameAnalysis.scan_direct(nil) { |_| } }.to raise_error(TypeError)
    end
  end

end
