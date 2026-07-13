require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/annotator/helpers/effects" unless defined?(EffectTracker::EffectState)

RSpec.describe "Effect Tracking" do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
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
    it "does not treat non-escaping HashMap creation as heap placement" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64> = {"alice": 1_i64, "bob": 2_i64};
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:HEAP)
    end

    it "detects @pool collection" do
      effs = effects_of(<<~CLEAR)
        STRUCT Item { value: Float64 }
        FN main() RETURNS Void ->
          MUTABLE items: Item[100]@pool = [];
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
        FN factorial(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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
        FN allocates() RETURNS !Void ->
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

        FN lock_it(c: Counter) RETURNS !Void ->
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
        FN recurse(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
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

  # --- SUSPENDS family ---

  describe "SUSPENDS effect" do
    it "is recorded for NEXT on a BG promise" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { 42; };
          x = NEXT p;
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
    end

    it "is recorded for IO intrinsics (readFile)" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          content = readFile("foo.txt");
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
    end

    it "is recorded for TCP read" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          server = TCPServer::listen(8080);
          client = accept(server);
          data = tcpRead(client);
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
    end

    it "is absent for pure code" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 1 + 2;
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:SUSPENDS)
      expect(effs).not_to include(:SUSPENDS_CONDITIONAL)
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end

    it "BLOCKING implies SUSPENDS (lock wait may yield)" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner { inner.value; }
          RETURN;
        END
      CLEAR
      expect(effs).to include(:BLOCKING)
      expect(effs).to include(:SUSPENDS)
    end
  end

  describe "SUSPENDS:CONDITIONAL effect" do
    it "is set when suspension is inside an IF branch" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 1;
          IF x > 0 THEN
            content = readFile("foo.txt");
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_CONDITIONAL)
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end

    it "is set when suspension is inside a MATCH arm" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Int64 = 1;
          PARTIAL MATCH x START
            1 -> y = readFile("a.txt");,
            DEFAULT -> y = "";
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_CONDITIONAL)
    end

    it "is NOT set when the suspension is linear (outside any IF)" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          content = readFile("foo.txt");
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
      expect(effs).not_to include(:SUSPENDS_CONDITIONAL)
    end
  end

  describe "SUSPENDS:LOOP effect" do
    it "is set when suspension is inside a WHILE loop" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = 10;
          WHILE x > 0 DO
            content = readFile("foo.txt");
            x = x - 1;
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
    end

    it "is set when suspension is inside a FOR loop" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          FOR i IN (0 ..< 3) DO
            content = readFile("foo.txt");
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
    end

    it "is NOT set when the loop contains no suspension" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE sum = 0;
          FOR i IN (0 ..< 10) DO
            sum = sum + i;
          END
          RETURN;
        END
      CLEAR
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end
  end

  describe "SUSPENDS propagation through call graph" do
    it "linear caller inherits callee's plain SUSPENDS" do
      effs = effects_of(<<~CLEAR)
        FN load() RETURNS !String ->
          RETURN readFile("foo.txt");
        END

        FN main() RETURNS Void ->
          x = load();
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
      expect(effs).not_to include(:SUSPENDS_CONDITIONAL)
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end

    it "caller calling a SUSPENDS fn inside a loop gets SUSPENDS:LOOP" do
      effs = effects_of(<<~CLEAR)
        FN load() RETURNS !String ->
          RETURN readFile("foo.txt");
        END

        FN main() RETURNS Void ->
          FOR i IN (0 ..< 3) DO
            x = load();
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
    end

    it "caller calling a SUSPENDS fn inside IF gets SUSPENDS:CONDITIONAL" do
      effs = effects_of(<<~CLEAR)
        FN load() RETURNS !String ->
          RETURN readFile("foo.txt");
        END

        FN main() RETURNS Void ->
          MUTABLE gate = 1;
          IF gate > 0 THEN
            x = load();
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_CONDITIONAL)
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end

    it "intrinsic callee with SUSPENDS:LOOP still promotes to LOOP at linear site" do
      # If 'process' has SUSPENDS:LOOP internally, any caller that calls it
      # linearly must still see SUSPENDS:LOOP — loop-ness is intrinsic to callee.
      effs = effects_of(<<~CLEAR)
        FN process() RETURNS !Void ->
          FOR i IN (0 ..< 3) DO
            x = readFile("foo.txt");
          END
          RETURN;
        END

        FN main() RETURNS Void ->
          process();
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
    end

    it "loop-wrapping a SUSPENDS:CONDITIONAL fn yields both LOOP and CONDITIONAL" do
      effs = effects_of(<<~CLEAR)
        FN maybe_load() RETURNS !Void ->
          MUTABLE gate = 1;
          IF gate > 0 THEN
            x = readFile("foo.txt");
          END
          RETURN;
        END

        FN main() RETURNS Void ->
          FOR i IN (0 ..< 3) DO
            maybe_load();
          END
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
      expect(effs).to include(:SUSPENDS_CONDITIONAL)
    end

    it "multi-level propagation keeps worst-case LOOP tag" do
      effs = effects_of(<<~CLEAR)
        FN inner() RETURNS !String ->
          RETURN readFile("foo.txt");
        END

        FN middle() RETURNS !Void ->
          FOR i IN (0 ..< 3) DO
            x = inner();
          END
          RETURN;
        END

        FN main() RETURNS Void ->
          middle();
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS_LOOP)
    end

    it "propagates across pure wrapper functions" do
      effs = effects_of(<<~CLEAR)
        FN inner() RETURNS !String ->
          RETURN readFile("foo.txt");
        END

        FN wrap() RETURNS !String ->
          RETURN inner();
        END

        FN main() RETURNS Void ->
          x = wrap();
          RETURN;
        END
      CLEAR
      expect(effs).to include(:SUSPENDS)
      expect(effs).not_to include(:SUSPENDS_LOOP)
    end
  end

  describe "EffectTracker.display" do
    it "renders SUSPENDS family with colon syntax" do
      expect(EffectTracker.display(:SUSPENDS)).to eq("SUSPENDS")
      expect(EffectTracker.display(:SUSPENDS_CONDITIONAL)).to eq("SUSPENDS:CONDITIONAL")
      expect(EffectTracker.display(:SUSPENDS_LOOP)).to eq("SUSPENDS:LOOP")
    end

    it "passes non-SUSPENDS effects through" do
      expect(EffectTracker.display(:HEAP)).to eq("HEAP")
      expect(EffectTracker.display(:BLOCKING)).to eq("BLOCKING")
    end
  end
end
