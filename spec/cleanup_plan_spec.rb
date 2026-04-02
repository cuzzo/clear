require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/promotion_plan"

# Tests CleanupPlan — decides which bindings in a function need
# defer cleanup, and with what allocator. The ownership generator
# reads this plan and emits Zig mechanically.
#
# Each test covers a specific class of leak bug found in the codebase.

RSpec.describe CleanupPlan do
  def cleanup_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }

    CleanupPlan.compute(
      fn_node,
      fn_nodes: fn_nodes,
      schema_lookup: ->(name) { annotator.lookup_type_schema(name) },
    )
  end

  # =========================================================================
  # Case 1: Direct binding of returns_promoted list function
  # =========================================================================
  describe "direct binding of promoted list return" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN makeList() RETURNS Int64[] ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN items;
        END
        FN main() RETURNS Void ->
            list1 = makeList();
            ASSERT list1.length() == 1;
            RETURN;
        END
      CLEAR
    end

    it "marks list1 for heap cleanup" do
      expect(plan.bindings).to have_key("list1")
      expect(plan.bindings["list1"][:alloc]).to eq(:heap)
    end
  end

  # =========================================================================
  # Case 2: Reassignment inside IF branch
  # =========================================================================
  describe "reassignment inside IF branch" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN makeList() RETURNS Int64[] ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN items;
        END
        FN main() RETURNS Void ->
            MUTABLE result: Int64[] = [];
            IF TRUE THEN
                result = makeList();
            END
            ASSERT result.length() == 1;
            RETURN;
        END
      CLEAR
    end

    it "marks result for heap cleanup" do
      expect(plan.bindings).to have_key("result")
      expect(plan.bindings["result"][:alloc]).to eq(:heap)
    end
  end

  # =========================================================================
  # Case 3: Passthrough — no promoted calls, no cleanup needed
  # =========================================================================
  describe "no promoted calls" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN add(a: Int64, b: Int64) RETURNS Int64 ->
            RETURN a + b;
        END
        FN main() RETURNS Void ->
            x = add(1_i64, 2_i64);
            RETURN;
        END
      CLEAR
    end

    it "has no bindings needing cleanup" do
      expect(plan.bindings).to be_empty
    end
  end

  # =========================================================================
  # Case 4: Union binding from returns_promoted function
  # (the scheme interpreter pattern)
  # =========================================================================
  describe "union binding from promoted function" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        UNION Value { Num: Float64, Items: Int64[] }
        FN makeValue() RETURNS Value ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN Value{ Items: items };
        END
        FN main() RETURNS Void ->
            v = makeValue();
            RETURN;
        END
      CLEAR
    end

    it "marks v for heap cleanup (union may contain promoted slice)" do
      expect(plan.bindings).to have_key("v")
      expect(plan.bindings["v"][:alloc]).to eq(:heap)
    end
  end

  # =========================================================================
  # Case 5: Chained call — fn A returns promoted, fn B returns A's result
  # =========================================================================
  describe "chained promoted return" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN makeList() RETURNS Int64[] ->
            MUTABLE items: Int64[]@list = List[];
            items.append(1_i64);
            RETURN items;
        END
        FN wrapper() RETURNS Int64[] ->
            RETURN makeList();
        END
        FN main() RETURNS Void ->
            result = wrapper();
            RETURN;
        END
      CLEAR
    end

    it "marks result for heap cleanup (transitively promoted)" do
      expect(plan.bindings).to have_key("result")
      expect(plan.bindings["result"][:alloc]).to eq(:heap)
    end
  end

  # =========================================================================
  # Case 6: HashMap local — not from promoted call, uses own allocator
  # =========================================================================
  describe "local HashMap (not promoted)" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            RETURN;
        END
      CLEAR
    end

    it "marks m for cleanup (HashMap owns heap data)" do
      expect(plan.bindings).to have_key("m")
    end
  end

  # =========================================================================
  # Case 7: @list local — uses frame allocator
  # =========================================================================
  describe "local @list" do
    let(:plan) do
      cleanup_for(<<~CLEAR, "main")
        FN main() RETURNS Void ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            RETURN;
        END
      CLEAR
    end

    it "marks vals for frame cleanup" do
      expect(plan.bindings).to have_key("vals")
      expect(plan.bindings["vals"][:alloc]).to eq(:frame)
    end
  end
end
