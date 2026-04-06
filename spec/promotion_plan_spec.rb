require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/promotion_plan"

# Tests PromotionPlan (Pass C) — the single object that decides what
# promotion to emit for each function. Maps 1:1 to bugs found today.

RSpec.describe PromotionPlan do
  # Helper: parse + annotate CLEAR code, return PromotionPlan for named function.
  def plan_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    PromotionPlan.compute(fn_node, schema_lookup: ->(name) { annotator.lookup_type_schema(name) })
  end

  # =========================================================================
  # Bug case 1: Struct with ArrayList field
  # ArrayList must be promoted BEFORE struct construction so .items is heap.
  # =========================================================================
  describe "struct with @list field" do
    let(:plan) do
      plan_for(<<~CLEAR, "build")
        STRUCT Pair { items: Int64[], count: Int64 }
        FN build() RETURNS Pair ->
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            vals.append(2_i64);
            RETURN Pair{ items: vals, count: 2 };
        END
        FN main() RETURNS Void -> p = build(); RETURN; END
      CLEAR
    end

    it "is empty (implicit COPY in struct field handles promotion)" do
      # @list fields are now implicit-copied by the annotator, so
      # PromotionPlan no longer needs to promote them on return.
      expect(plan).to be_empty
    end
  end

  # =========================================================================
  # Bug case 2: Struct with HashMap + string literal
  # HashMap promoted per-variable. String literal needs struct-level promote.
  # =========================================================================
  describe "struct with HashMap and string literal" do
    let(:plan) do
      plan_for(<<~CLEAR, "build")
        STRUCT MapHolder { data: HashMap<Int64>, label: String }
        FN build() RETURNS MapHolder ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            RETURN MapHolder{ data: m, label: "direct" };
        END
        FN main() RETURNS Void -> h = build(); RETURN; END
      CLEAR
    end

    it "promotes the HashMap variable" do
      expect(plan.var_promotes.map { |vp| vp[:var] }).to include("m")
    end

    it "does NOT need struct-level promote (CopyNode already owns string)" do
      # The string literal is wrapped in CopyNode by ensure_owned_value!,
      # which heap-dupes it. promoteFields would double-dupe. So struct_promote
      # should be nil when all promotable fields are already CopyNode-handled.
      expect(plan.struct_promote).to be_nil
    end

    it "suppresses defer for the HashMap" do
      expect(plan.suppress_defers).to include("m")
    end
  end

  # =========================================================================
  # Bug case 3: Passthrough function (TAKES, no allocation)
  # =========================================================================
  describe "passthrough function with TAKES" do
    let(:plan) do
      plan_for(<<~CLEAR, "wrap")
        STRUCT Pair { items: Int64[], count: Int64 }
        FN wrap(TAKES items: Int64[]) RETURNS Pair ->
            RETURN Pair{ items: items, count: 1 };
        END
        FN main() RETURNS Void ->
            vals: Int64[] = [1_i64];
            p = wrap(vals);
            RETURN;
        END
      CLEAR
    end

    it "produces an empty plan" do
      expect(plan).to be_empty
    end
  end

  # =========================================================================
  # Bug case 4: Direct @list return
  # =========================================================================
  describe "direct @list return" do
    let(:plan) do
      plan_for(<<~CLEAR, "build")
        FN build() RETURNS Float64[] ->
            MUTABLE vals: Float64[]@list = List[];
            vals.append(1.0);
            RETURN vals;
        END
        FN main() RETURNS Void -> x = build(); RETURN; END
      CLEAR
    end

    it "promotes the list variable" do
      expect(plan.var_promotes.map { |vp| vp[:var] }).to eq(["vals"])
    end

    it "no struct-level promote needed" do
      expect(plan.struct_promote).to be_nil
    end

    it "suppresses defer" do
      expect(plan.suppress_defers).to include("vals")
    end
  end

  # =========================================================================
  # Bug case 5: Direct HashMap return
  # =========================================================================
  describe "direct HashMap return" do
    let(:plan) do
      plan_for(<<~CLEAR, "build")
        FN build() RETURNS HashMap<Int64> ->
            MUTABLE m: HashMap<Int64> = {};
            m["x"] = 1_i64;
            RETURN m;
        END
        FN main() RETURNS Void -> x = build(); RETURN; END
      CLEAR
    end

    it "promotes the map variable" do
      expect(plan.var_promotes.map { |vp| vp[:var] }).to eq(["m"])
    end

    it "suppresses defer" do
      expect(plan.suppress_defers).to include("m")
    end
  end

  # =========================================================================
  # Bug case 6: Already-heap data — no allocation, no promotion
  # =========================================================================
  describe "function with no allocations" do
    let(:plan) do
      plan_for(<<~CLEAR, "identity")
        FN identity(x: Int64) RETURNS Int64 ->
            RETURN x;
        END
        FN main() RETURNS Void -> y = identity(42_i64); RETURN; END
      CLEAR
    end

    it "produces an empty plan" do
      expect(plan).to be_empty
    end
  end

  # =========================================================================
  # Bug case 7: Pure numeric struct — no promotable fields
  # =========================================================================
  describe "struct with only numeric fields" do
    let(:plan) do
      plan_for(<<~CLEAR, "origin")
        STRUCT Point { x: Float64, y: Float64 }
        FN origin() RETURNS Point ->
            RETURN Point{ x: 0.0, y: 0.0 };
        END
        FN main() RETURNS Void -> p = origin(); RETURN; END
      CLEAR
    end

    it "produces an empty plan" do
      expect(plan).to be_empty
    end
  end

  # =========================================================================
  # String concat in struct — expression return with frame-allocated string
  # =========================================================================
  # String concat results: the concat string lives in the caller's frame
  # arena (frame mark is NOT restored for string-returning functions).
  # No promotion needed — this matches HEAD behavior.
  describe "struct with string from concat" do
    let(:plan) do
      plan_for(<<~CLEAR, "build")
        STRUCT User { name: String, age: Int64 }
        FN build(first: String, last: String) RETURNS User ->
            name = first + " " + last;
            RETURN User{ name: COPY name, age: 42 };
        END
        FN main() RETURNS Void -> u = build("a", "b"); RETURN; END
      CLEAR
    end

    it "does NOT need struct_promote (COPY already owns the string)" do
      # COPY name heap-dupes the string. No further promotion needed.
      # promoteFields would double-dupe.
      expect(plan.struct_promote).to be_nil
    end
  end
end
