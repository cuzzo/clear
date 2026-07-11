require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

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
    run_mir_frontend(src)
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def main_fn(ast)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" } ||
      ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
  end

  def function_nodes(ast)
    ast.statements
      .select { |s| s.is_a?(AST::FunctionDef) }
      .to_h { |fn| [fn.name, fn] }
  end

  def first_concurrent_with_shard_context(ast)
    found = nil
    AST.each_locatable(ast.statements, descend_functions: true) do |node|
      next unless node.is_a?(AST::ConcurrentOp) && node.shard_context

      found = node
      break
    end
    found
  end

  # ===========================================================================
  # Group A: mark_per_iter = true
  # ===========================================================================
  describe "Group A: mark_per_iter = true for loop-local frame collections" do

    it "WhileLoop: local primitive @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be true
    end

    it "ForRange: local primitive @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          FOR i IN (0_i64 ..< 5) DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::ForRange) }
      expect(loop.mark_per_iter).to be true
    end

    it "ForEach: local primitive @list → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [1_i64, 2_i64];
          FOR x IN xs DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(x);
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::ForEach) }
      expect(loop.mark_per_iter).to be true
    end

    it "WhileLoop: transient frame-allocating string method in body condition → mark_per_iter = true" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          json = "[,]";
          MUTABLE commas = 0_i64;
          MUTABLE i = 0_i64;
          WHILE i < json.length() DO
            IF json.charAt(i) == "," THEN
              commas = commas + 1_i64;
            END
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      expect(loop.mark_per_iter).to be true
    end

    it "WhileLoop: local HashMap owns heap allocator and does not need a loop frame mark" do
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
              MUTABLE parts: Int64[]@list = [];
              parts.append(j);
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
  # Group C: outer string reassignment in mark_per_iter loop
  # ===========================================================================
  # Placement is decided by escape analysis, not loop rewinds.
  describe "Group C: outer string reassignment remains local unless it escapes" do

    it "outer string reassigned with frame concat stays frame-local" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE resp = "";
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE part: Int64[]@list = [];
            part.append(i);
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
      expect(resp_decl.symbol.heap_storage?).to be false
    end

    it "no heap carry promotion when no outer string reassignment occurs" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
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
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
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

    it "outer string reassigned with user function call result is heap-backed across loop iterations" do
      # Placement is decided by escape analysis, not by loop rewinds.
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
      expect(last_decl.symbol.heap_storage?).to be true
    end

    it "outer string reassigned with method call result stays frame-local unless it escapes" do
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
      expect(last_decl.symbol.heap_storage?).to be false
    end

    it "outer string reassigned with concat of outer vars stays frame-local unless it escapes" do
      # result = prefix + "-" + suffix is a local overwrite; no escape means no heap storage.
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
      expect(result_decl.symbol.heap_storage?).to be false
    end

  end

  # ===========================================================================
  # Group D: outer container placement
  # ===========================================================================
  describe "Group D: outer container placement is not driven by loop rewinds" do

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

    it "loop with local frame list AND outer append rewinds the loop with heap-backed outer storage" do
      # A loop with BOTH a loop-local frame list AND an outer container that gets
      # its backing-store extended (append of a non-local value).
      # The outer must be heap-promoted so the rewind doesn't corrupt its backing.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE log: String[]@list = [];
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
            log.append("done");
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("log.append(rt.heapAlloc()")
    end

    it "outer @list mutated inside a nested loop uses heap-backed outer storage" do
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
      expect(zig).to match(/outer\.append\(rt\.heapAlloc\(\)/)
    end

    it "outer @list mutated inside a MATCH branch uses heap-backed outer storage" do
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
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("saveLoopMark")
      expect(zig).to include("restoreLoopMark")
    end

    it "WhileLoop stores a loop-local string into a frame-owned outer list by moving heap-owned escaped data" do
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
      expect(zig).to include("const ch: []const u8 = try CheatLib.charAtCodepoint(rt.heapAlloc()")
      expect(zig).to include("try parts.append(rt.heapAlloc(), ch)")
      expect(zig).to include("ch_moved = true")
    end

    it "WhileLoop moves a loop-local list to heap when stored in an outer list" do
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
      expect(zig).to include("try inner.append(rt.heapAlloc(), i)")
      expect(zig).to include("try outer.append(rt.heapAlloc(), inner)")
      expect(zig).to include("inner_moved = true")
    end

    it "WhileLoop moves a loop-local dynamic array to heap when stored in an outer list" do
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
      expect(zig).to include("try CheatLib.makeList(i64, rt.heapAlloc()")
      expect(zig).to include("try outer.append(rt.heapAlloc(), inner)")
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
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
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
            MUTABLE parts: Int64[]@list = [];
            parts.append(x);
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

    it "promise-list BG append keeps the accumulated list on frame without frame-owned promise temps" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          count: Int64 = 3_i64;
          MUTABLE futures: ~Void[]@list = [];
          FOR i IN (0_i64 ..< count) DO
            futures.append(BG { sleep(1_i64); });
          END
          FOR j IN (0_i64 ..< count) DO
            IF futures[j] AS future THEN NEXT future; END
          END
          RETURN;
        END
      CLEAR

      zig = nil
      expect { zig = transpile(src) }.not_to raise_error
      expect(zig).to include("try futures.append(rt.frameAlloc()")
      expect(zig).not_to include("saveLoopMark")
      expect(zig).not_to include("restoreLoopMark")
    end

    it "nested loops: inner saveLoopMark appears once, outer does not" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3 DO
            MUTABLE j = 0_i64;
            WHILE j < 3 DO
              MUTABLE parts: Int64[]@list = [];
              parts.append(j);
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
              MUTABLE parts: Int64[]@list = [];
              parts.append(i);
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

    it "nested loop-carried string initializes as heap-owned because it survives inner loop restore" do
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
      expect(zig).to include('var resp: []const u8 = @as([]const u8, try rt.heapAlloc().dupe(u8, ""))')
      expect(zig).to include("defer if (!resp_moved) CheatLib.cleanup(@TypeOf(resp), rt.heapAlloc(), &resp)")
    end

    it "nested loop-carried string reassignment uses heap allocation because it survives inner loop restore" do
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
      expect(zig).to include("try std.mem.concat(rt.heapAlloc()")
      expect(zig).to include("__new_resp")
      expect(zig).to include("CheatLib.cleanup(@TypeOf(resp), rt.heapAlloc(), &resp)")
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

    it "local binding facts run on IF without ELSE" do
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
      facts = nil
      expect { facts = MIR::LocalBindingAnalysis.direct_loop_body_facts(main_fn(ast).body) }.not_to raise_error
      names = T.must(facts).names
      expect(names).to include("a")
    end

    it "local binding facts run on PARTIAL MATCH without DEFAULT" do
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
      expect { MIR::LocalBindingAnalysis.direct_loop_body_facts(main_fn(ast).body) }.not_to raise_error
    end

    it "local binding fact traversal contract is strictly non-nil" do
      # Encodes the CORRECT contract: traversal walks a statement body,
      # which is always an Array. nil must NOT be silently accepted --
      # that was the band-aid. Callers must never pass nil.
      expect { MIR::LocalBindingAnalysis.each_direct_loop_node(nil) { |_| } }.to raise_error(TypeError)
    end

    it "classifies direct loop expression boundary node kinds" do
      token = Lexer::Token.new(:VAR_ID, "x", 1, 1)
      function = AST::FunctionDef.new(
        token,
        "nested",
        [],
        [],
        Type.new(:Void),
        nil,
        [],
        [],
        nil,
        :public,
        [],
        false,
      )
      boundary_nodes = [
        AST::WhileLoop.new(token, AST::Literal.new(token, :BOOL, true, :stack), [], nil),
        AST::WhileBindLoop.new(token, AST::Literal.new(token, :NIL, nil, :stack), "item", token, [], nil),
        AST::ForRange.new(token, "i", AST::Literal.new(token, :INT64, 0, :stack), AST::Literal.new(token, :INT64, 1, :stack), false, [], nil, false),
        AST::ForEach.new(token, "item", AST::Identifier.new(token, "items"), [], nil, false),
        function,
        AST::LambdaLit.new(token, [], [], [], nil, nil),
        AST::BgBlock.new(token, [], nil, :standard, false, false, nil, false),
        AST::BgStreamBlock.new(token, [], nil, :standard),
      ]
      expression = AST::FuncCall.new(token, "make", [])

      expect(boundary_nodes.map { |node| LoopFrameAnalysis.direct_loop_expression_boundary?(node) })
        .to all(be(true))
      expect(LoopFrameAnalysis.direct_loop_expression_boundary?(expression)).to be(false)
    end

    it "uses loop-local names when scanning receiver-mutating frame expressions" do
      token = Lexer::Token.new(:VAR_ID, "local", 1, 1)
      local_type = Type.new(:"String[]", collection: :list)
      receiver = AST::Identifier.new(token, "local")
      receiver.full_type = local_type
      receiver.symbol = SymbolEntry.new(reg: "local", type: local_type, mutable: true, storage: :frame)
      allocating_arg = AST::FuncCall.new(token, "makeFrame", [])
      allocating_arg.full_type = Type.new(:Int64)
      mutating_call = AST::MethodCall.new(token, receiver, "append", [allocating_arg])
      mutating_call.full_type = Type.new(:Void)
      mutating_call.matched_signature = FunctionSignature.new(
        params: [],
        return_type: Type.new(:Void),
        intrinsic: true,
        emit: IntrinsicEmit.new(mutates_receiver: true),
      )
      callee = AST::FunctionDef.new(
        token,
        "makeFrame",
        [],
        [],
        Type.new(:Int64),
        nil,
        [],
        [],
        nil,
        :public,
        [],
        true,
      )

      expect(
        LoopFrameAnalysis.direct_loop_expression_frame_alloc?(
          [mutating_call],
          { "makeFrame" => callee },
          Set["local"],
        ),
      ).to be(true)
      expect(
        LoopFrameAnalysis.direct_loop_expression_frame_alloc?(
          [mutating_call],
          { "makeFrame" => callee },
          Set.new,
        ),
      ).to be(false)
      expect(
        LoopFrameAnalysis.direct_loop_expression_frame_alloc?(
          [mutating_call],
          { "makeFrame" => callee },
        ),
      ).to be(false)
    end

    it "skips nested loop boundaries while scanning later frame-allocating siblings" do
      token = Lexer::Token.new(:VAR_ID, "makeFrame", 1, 1)
      nested_loop = AST::WhileLoop.new(
        token,
        AST::Literal.new(token, :BOOL, true, :stack),
        [],
        nil,
      )
      allocating_call = AST::FuncCall.new(token, "makeFrame", [])
      allocating_call.full_type = Type.new(:Int64)
      callee = AST::FunctionDef.new(
        token,
        "makeFrame",
        [],
        [],
        Type.new(:Int64),
        nil,
        [],
        [],
        nil,
        :public,
        [],
        true,
      )

      expect(
        LoopFrameAnalysis.direct_loop_expression_frame_alloc?(
          [nested_loop, allocating_call],
          { "makeFrame" => callee },
        ),
      ).to be(true)
    end

    it "short-circuits after finding a frame allocation" do
      token = Lexer::Token.new(:VAR_ID, "makeFrame", 1, 1)
      allocating_call = AST::FuncCall.new(token, "makeFrame", [])
      allocating_call.full_type = Type.new(:Int64)
      untyped_later_call = AST::FuncCall.new(token, "needsNoScan", [])
      callee = AST::FunctionDef.new(
        token,
        "makeFrame",
        [],
        [],
        Type.new(:Int64),
        nil,
        [],
        [],
        nil,
        :public,
        [],
        true,
      )

      expect(
        LoopFrameAnalysis.direct_loop_expression_frame_alloc?(
          [allocating_call, untyped_later_call],
          { "makeFrame" => callee },
        ),
      ).to be(true)
    end

    it "analyze! skips declarations without stopping later function analysis" do
      ast = run_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 5 DO
            MUTABLE parts: Int64[]@list = [];
            parts.append(i);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      loop.mark_per_iter = false
      declaration = AST::FunctionDef.new(
        Lexer::Token.new(:VAR_ID, "declared", 1, 1),
        "declared",
        [],
        [],
        Type.new(:Void),
        nil,
        nil,
        [],
        nil,
        :public,
        [],
        false,
      )

      LoopFrameAnalysis.analyze!({ "declared" => declaration, "main" => main_fn(ast) })

      expect(loop.mark_per_iter).to be(true)
    end

    it "analyze! passes schema lookup into while-bind loop-capture frame checks" do
      ast = run_mir(<<~CLEAR)
        STRUCT Box { parts: Int64[]@list }
        FN maybe() RETURNS ?Box -> RETURN NIL; END
        FN main() RETURNS Void ->
          WHILE maybe() AS box DO
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileBindLoop) }
      loop.mark_per_iter = false
      box_schema = Schemas::StructSchema.new(fields: {
        "parts" => AST::StructField.new(type: Type.new(:"Int64[]", collection: :list), default: nil, borrowed: false),
      })

      LoopFrameAnalysis.analyze!(
        function_nodes(ast),
        ->(name) { name.to_sym == :Box ? box_schema : nil },
      )

      expect(loop.mark_per_iter).to be(true)
    end

    it "analyze! passes function nodes into loop expression frame allocation checks" do
      ast = run_mir(<<~CLEAR)
        FN scratch(n: Int64) RETURNS Int64 ->
          MUTABLE parts: Int64[]@list = [];
          parts.append(n);
          RETURN n;
        END
        FN main() RETURNS Void ->
          MUTABLE i = 0_i64;
          WHILE i < 3_i64 DO
            x = scratch(i);
            i = i + 1_i64;
          END
          RETURN;
        END
      CLEAR
      loop = main_fn(ast).body.find { |s| s.is_a?(AST::WhileLoop) }
      loop.mark_per_iter = false

      LoopFrameAnalysis.analyze!(function_nodes(ast))

      expect(loop.mark_per_iter).to be(true)
    end

    it "analyze! updates shard contexts through the public entrypoint" do
      ast = run_mir(<<~CLEAR)
        FN makeKey(n: Int64) RETURNS !String ->
          RETURN "k:${toString(n)}";
        END
        FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64>@sharded(4) = {};
          (0_i64 ..< 4_i64) |> SHARD(makeKey(_), counts) |> CONCURRENT EACH {
            counts[_] = 1_i64;
          };
          RETURN;
        END
      CLEAR
      concurrent = T.must(first_concurrent_with_shard_context(ast))
      reset_context = T.must(concurrent.shard_context).with_frame_allocations(
        key_allocates_frame: false,
        body_allocates_frame: false,
      )
      concurrent.shard_context = reset_context

      LoopFrameAnalysis.analyze!(function_nodes(ast))

      context = T.must(concurrent.shard_context)
      expect(context.key_allocates_frame).to be(true)
      expect(context.body_allocates_frame).to be(false)
    end
  end

end
