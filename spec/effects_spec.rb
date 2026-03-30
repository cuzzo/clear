require "rspec"
require_relative "../src/transpiler"
require_relative "../src/ast"
require_relative "../src/effects"

RSpec.describe "Effect Tracking" do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  def effects_of(source, fn_name = "main")
    ast = run(source)
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    fn&.effects || Set.new
  end

  # --- HEAP ---

  describe "HEAP effect" do
    it "detects HashMap creation" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64> = {"alice": 1_i64, "bob": 2_i64};
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
    end

    it "detects @pool collection" do
      effs = effects_of(<<~CLEAR)
        STRUCT Item { value: Float64 }
        FN main() RETURNS Void ->
          MUTABLE items: Item[]@pool = [];
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
    end

    it "detects List[] constructor" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE items = List[];
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
    end

    it "detects capability wrap (@shared)" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @shared;
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
    end

    it "is absent for pure stack code" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x + 1;
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:HEAP)
    end
  end

  # --- BLOCKING ---

  describe "BLOCKING effect" do
    it "detects WITH EXCLUSIVE" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner { inner.value; }
          RETURN;
        END
      CLEAR
      expect(effs).to include(:BLOCKING)
    end

    it "is absent without WITH EXCLUSIVE" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:BLOCKING)
    end
  end

  # --- LOOP_UNBOUND ---

  describe "LOOP_UNBOUND effect" do
    it "detects WHILE TRUE" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          WHILE TRUE DO
            BREAK;
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:LOOP_UNBOUND)
    end

    it "is absent for bounded WHILE" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 10;
          WHILE x > 0 DO
            x = x - 1;
          END
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:LOOP_UNBOUND)
    end
  end

  # --- REENTRANT ---

  describe "REENTRANT effect" do
    it "detects direct recursion" do
      effs = effects_of(<<~CLEAR, "factorial")
        FN factorial(n: Int64) RETURNS Int64 @reentrant ->
          IF n <= 1 THEN RETURN 1; END
          RETURN n * factorial(n - 1);
        END

        FN main() RETURNS Void ->
          x = factorial(5);
          RETURN;
        END
      CLEAR
      expect(effs).to include(:REENTRANT)
    end

    it "is absent for non-recursive functions" do
      effs = effects_of(<<~CLEAR, "double")
        FN double(n: Int64) RETURNS Int64 ->
          RETURN n * 2;
        END

        FN main() RETURNS Void ->
          x = double(5);
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:REENTRANT)
    end
  end

  # --- Transitive propagation ---

  describe "transitive propagation" do
    it "propagates HEAP through call graph" do
      effs = effects_of(<<~CLEAR)
        FN allocates() RETURNS Void ->
          MUTABLE items = List[];
          RETURN;
        END

        FN main() RETURNS Void ->
          allocates();
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
    end

    it "propagates BLOCKING through call graph" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN lock_it(c: Counter) RETURNS Void ->
          d = c @locked;
          WITH EXCLUSIVE d AS inner { inner.value; }
          RETURN;
        END

        FN main() RETURNS Void ->
          c = Counter{ value: 0 };
          lock_it(c);
          RETURN;
        END
      CLEAR
      expect(effs).to include(:BLOCKING)
    end

    it "propagates REENTRANT through call graph" do
      effs = effects_of(<<~CLEAR)
        FN recurse(n: Int64) RETURNS Int64 @reentrant ->
          IF n <= 0 THEN RETURN 0; END
          RETURN recurse(n - 1);
        END

        FN main() RETURNS Void ->
          x = recurse(5);
          RETURN;
        END
      CLEAR
      expect(effs).to include(:REENTRANT)
    end

    it "accumulates multiple effects" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE items = List[];
          WHILE TRUE DO
            BREAK;
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:HEAP)
      expect(effs).to include(:LOOP_UNBOUND)
    end
  end

  # --- Effect-free functions ---

  describe "effect-free functions" do
    it "pure arithmetic has no effects" do
      effs = effects_of(<<~CLEAR, "add")
        FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END

        FN main() RETURNS Void ->
          x = add(1, 2);
          RETURN;
        END
      CLEAR
      expect(effs).to be_empty
    end
  end
end
