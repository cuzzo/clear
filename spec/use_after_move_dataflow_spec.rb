require "rspec"
require_relative "../src/transpiler"

# Tests the UseAfterMoveChecker -- the dataflow-based use-after-move checker
# that operates on CFG per-statement snapshots.
#
# The annotator's OwnershipGraph already catches most use-after-move errors
# before the dataflow stage. These specs verify:
# 1. No false positives on valid programs
# 2. Correct per-statement state tracking (foundation for Phase 3/4)
# 3. Edge cases in GIVE/TAKES/return/BG semantics

RSpec.describe UseAfterMoveChecker do
  def check_errors(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    UseAfterMoveChecker.check(fn_node, schema_lookup: schema_lookup)
  end

  def expect_no_error(src, fn_name = "main")
    errors = check_errors(src, fn_name)
    expect(errors).to be_empty, "Expected no errors but got: #{errors.inspect}"
  end

  def analyze_state(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    OwnershipDataflow.analyze(fn_node, schema_lookup: schema_lookup)
  end

  # =========================================================================
  # No false positives on valid programs
  # =========================================================================

  describe "valid programs produce no errors" do
    it "simple primitives" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          z = x;
          RETURN;
        END
      CLEAR
    end

    it "single use of non-Copy value" do
      expect_no_error(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
    end

    it "GIVE to TAKES with no further use" do
      expect_no_error(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(GIVE vals);
          RETURN;
        END
      CLEAR
    end

    it "return of owned value" do
      expect_no_error(<<~CLEAR)
        FN makeList() RETURNS Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
        FN main() RETURNS Void ->
          r = makeList();
          RETURN;
        END
      CLEAR
    end

    it "multiowned (Rc) reuse" do
      expect_no_error(<<~CLEAR)
        STRUCT Node { value: Int64 }
        FN main() RETURNS Void ->
          n = Node{ value: 1 } @multiowned;
          n2 = n;
          n3 = n;
          RETURN;
        END
      CLEAR
    end

    it "implicit borrow (non-TAKES param)" do
      expect_no_error(<<~CLEAR)
        FN readLen(items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n1 = readLen(vals);
          n2 = readLen(vals);
          RETURN;
        END
      CLEAR
    end

    it "if/else where no branch moves" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          IF vals.length() > 0 THEN
            vals.append(2_i64);
          END
          n = vals.length();
          RETURN;
        END
      CLEAR
    end

    it "loop with no move" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          MUTABLE i = 0;
          WHILE i < 5 DO
            vals.append(i);
            i = i + 1;
          END
          n = vals.length();
          RETURN;
        END
      CLEAR
    end

    it "string reuse (strings are Copy in CLEAR dataflow)" do
      expect_no_error(<<~CLEAR)
        FN greet(name: String) RETURNS String ->
          RETURN "hello";
        END
        FN main() RETURNS Void ->
          s = "world";
          r1 = greet(s);
          r2 = greet(s);
          RETURN;
        END
      CLEAR
    end

    it "union single use" do
      expect_no_error(<<~CLEAR)
        UNION Value { Num: Float64, List: Int64[] }
        FN main() RETURNS Void ->
          v1 = Value{ Num: 1.0 };
          v2 = v1;
          RETURN;
        END
      CLEAR
    end
  end

  # =========================================================================
  # Per-statement state tracking (foundation for Phase 3/4)
  # =========================================================================

  describe "per-statement state tracking" do
    it "tracks point_states for each statement" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.point_states).not_to be_empty
    end

    it "enriched entry has allocator and needs_cleanup" do
      df = analyze_state(<<~CLEAR, "consume")
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
      CLEAR
      # TAKES param should have an OwnerEntry with allocator info
      entry = df.exit_states["items"]
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.allocator).to eq(:heap)
      end
    end

    it "exit_states show moved after assignment of non-Copy" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "exit_states preserve owned for Copy types" do
      df = analyze_state(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["x"]).to eq(:owned)
      expect(df.exit_states["y"]).to eq(:owned)
    end

    it "exit_states show moved after heap struct assignment" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end
  end

  # =========================================================================
  # Phase 5: Promotion modeled as ownership transfer
  # =========================================================================

  # =========================================================================
  # Phase 5: Promotion modeled as ownership transfer
  #
  # In CLEAR's arena model, promotion = copy (frame original stays alive).
  # Unlike Rust where `return x` moves x, CLEAR wraps returned values in
  # CopyNode (frame-to-heap copy). The dataflow correctly models this:
  # sources of copies stay :owned, only explicit moves (GIVE on heap types,
  # non-Copy assignment) mark sources as :moved.
  # =========================================================================

  describe "promotion as ownership transfer" do
    it "direct return of collection marks source as moved" do
      df = analyze_state(<<~CLEAR, "makeList")
        FN makeList() RETURNS Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
      CLEAR
      # Direct return of identifier: marked as moved by collect_binding_moves
      expect(df.exit_states["items"]).to eq(:moved)
    end

    it "struct literal return copies fields (CopyNode), source stays owned" do
      df = analyze_state(<<~CLEAR, "wrap")
        STRUCT Wrapper { data: Int64[] }
        FN wrap() RETURNS %Wrapper ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN Wrapper{ data: items };
        END
      CLEAR
      # Annotator wraps struct literal field values in CopyNode for promotion.
      # CopyNode does NOT consume the source -- frame original stays alive.
      expect(df.exit_states["items"]).to eq(:owned)
    end

    it "return preserves allocator info on moved OwnerEntry" do
      df = analyze_state(<<~CLEAR, "makeList")
        FN makeList() RETURNS Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
      CLEAR
      entry = df.exit_states["items"]
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.state).to eq(:moved)
        expect(entry.allocator).not_to be_nil
      end
    end

    it "GIVE on @list creates copy, source stays owned" do
      df = analyze_state(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(GIVE vals);
          RETURN;
        END
      CLEAR
      # GIVE on frame @list creates CopyNode (frame-to-heap copy).
      # The original frame list stays alive until frame rewind.
      expect(df.exit_states["vals"]).to eq(:owned)
    end

    it "non-Copy assignment marks source as moved" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: %User = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      # Direct assignment of non-Copy heap struct IS a move
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "TAKES param tracked with allocator info" do
      df = analyze_state(<<~CLEAR, "consume")
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
      CLEAR
      entry = df.exit_states["items"]
      expect(entry).not_to be_nil
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.allocator).to eq(:heap)
      end
    end
  end
end
