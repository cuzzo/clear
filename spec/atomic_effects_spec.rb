require "rspec"
require "set"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/annotator/helpers/effects" unless defined?(EffectTracker::EffectState)

# Atomics M1.6.5 — :CONTENTION / :BLOCKING effect axis for sync capabilities.
#
# Verifies:
#   1. Concrete capabilities stamp the right concrete effects:
#      - @shared:atomic   -> :CONTENTION
#      - @shared:versioned -> :CONTENTION (via SNAPSHOT WITH)
#      - @shared:locked   -> :CONTENTION + :BLOCKING (via EXCLUSIVE WITH)
#   2. Polymorphic REQUIRES (WITH MATCH with LOCKED + ATOMIC arms) stamps
#      the ?-form variants correctly: concrete in every arm + ?-form for
#      effects that fire in some arms but not all.
#   3. Call-site resolution narrows ?-form to concrete based on actual
#      arg families: LOCKED arg upgrades BLOCKING_MAYBE -> BLOCKING;
#      lock-free arg drops BLOCKING_MAYBE; concrete sync of any kind
#      upgrades CONTENTION_MAYBE -> CONTENTION.
#   4. Transitive propagation through a 3-deep call chain.
#   5. Polymorphic caller passing its own polymorphic param keeps ?-form
#      alive (caller still depends on caller's caller).
RSpec.describe "Atomics M1.6.5: contention/blocking effect axis" do
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

  describe "concrete capability stamping" do
    it "stamps :CONTENTION on @shared:atomic load" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            x = c;
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).not_to include(:BLOCKING)
    end

    it "stamps :CONTENTION on @shared:atomic store" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            c = 5;
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).not_to include(:BLOCKING)
    end

    it "stamps :CONTENTION on @shared:atomic compound op" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            c += 1;
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).not_to include(:BLOCKING)
    end

    it "stamps :CONTENTION + :BLOCKING on WITH EXCLUSIVE @locked" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @locked;
            WITH EXCLUSIVE c AS inner { inner.value; }
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).to include(:BLOCKING)
    end

    it "stamps :CONTENTION + :BLOCKING on WITH EXCLUSIVE @writeLocked" do
      effs = effects_of(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @writeLocked;
            WITH EXCLUSIVE c AS inner { inner.value; }
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).to include(:BLOCKING)
    end

    it "is absent for pure stack code" do
      effs = effects_of(<<~CLEAR)
        FN main() RETURNS Void ->
            x = 42;
            RETURN;
        END
      CLEAR
      expect(effs).not_to include(:CONTENTION)
      expect(effs).not_to include(:BLOCKING)
      expect(effs).not_to include(:CONTENTION_MAYBE)
      expect(effs).not_to include(:BLOCKING_MAYBE)
    end
  end

  describe "polymorphic REQUIRES + WITH MATCH ?-form" do
    it "stamps CONTENTION concretely + BLOCKING_MAYBE for LOCKED | ATOMIC" do
      effs = effects_of(<<~CLEAR, "incr!")
        STRUCT Counter { value: Int64 }
        FN incr!(MUTABLE c: Counter) RETURNS Void REQUIRES c: ATOMIC | LOCKED ->
            WITH c AS va MATCH
              WHEN ATOMIC   -> { x = 0; }
              WHEN LOCKED -> { va.value = va.value + 1; }
            END
            RETURN;
        END

        FN main() RETURNS Void ->
            RETURN;
        END
      CLEAR
      expect(effs).to include(:CONTENTION)        # both arms add CONTENTION
      expect(effs).to include(:BLOCKING_MAYBE)    # only LOCKED arm prelude blocks
      expect(effs).not_to include(:BLOCKING)      # not concrete because ATOMIC arm doesn't block
      expect(effs).not_to include(:CONTENTION_MAYBE) # both arms have it -> concrete
    end

    it "stamps CONTENTION concrete (no MAYBE) for LOCKED | VERSIONED" do
      effs = effects_of(<<~CLEAR, "incr!")
        STRUCT Counter { value: Int64 }
        FN incr!(MUTABLE c: Counter) RETURNS Void REQUIRES c: VERSIONED | LOCKED ->
            WITH c AS va MATCH
              WHEN VERSIONED -> { x = va.value; }
              WHEN LOCKED  -> { x = va.value; }
            END
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      # Both arms record CONTENTION in their prelude.
      expect(effs).to include(:CONTENTION)
      # Only LOCKED arm records BLOCKING -> ?-form.
      expect(effs).to include(:BLOCKING_MAYBE)
      expect(effs).not_to include(:BLOCKING)
    end
  end

  describe "call-site ?-form resolution" do
    it "upgrades BLOCKING_MAYBE -> BLOCKING when caller passes a concrete @locked binding" do
      effs = effects_of(<<~CLEAR, "caller")
        STRUCT Counter { value: Int64 }
        FN bump!(MUTABLE c: Counter) RETURNS Void REQUIRES c: ATOMIC | LOCKED ->
            WITH c AS va MATCH
              WHEN ATOMIC   -> { x = 0; }
              WHEN LOCKED -> { va.value = va.value + 1; }
            END
            RETURN;
        END

        FN caller() RETURNS !Void ->
            MUTABLE c = Counter{ value: 0 } @locked;
            bump!(c);
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).to include(:BLOCKING)
      # ?-form should NOT propagate up — the call-site pinned LOCKED.
      expect(effs).not_to include(:BLOCKING_MAYBE)
    end

    it "keeps BLOCKING_MAYBE when caller is itself polymorphic (passes its own polymorphic param)" do
      effs = effects_of(<<~CLEAR, "wrapper!")
        STRUCT Counter { value: Int64 }
        FN bump!(MUTABLE c: Counter) RETURNS Void REQUIRES c: ATOMIC | LOCKED ->
            WITH c AS va MATCH
              WHEN ATOMIC   -> { x = 0; }
              WHEN LOCKED -> { va.value = va.value + 1; }
            END
            RETURN;
        END

        FN wrapper!(MUTABLE c: Counter) RETURNS Void REQUIRES c: ATOMIC | LOCKED ->
            bump!(c);
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      # wrapper!'s param is itself polymorphic, so the ?-form should propagate.
      expect(effs).to include(:BLOCKING_MAYBE)
      expect(effs).not_to include(:BLOCKING)
    end
  end

  describe "transitive propagation" do
    it "propagates :CONTENTION through a call chain" do
      effs = effects_of(<<~CLEAR, "outer")
        FN bump() RETURNS !Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            c += 1;
            RETURN;
        END

        FN middle() RETURNS !Void ->
            bump();
            RETURN;
        END

        FN outer() RETURNS !Void ->
            middle();
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).not_to include(:BLOCKING)
    end

    it "propagates :BLOCKING through a call chain" do
      effs = effects_of(<<~CLEAR, "outer")
        STRUCT Counter { value: Int64 }
        FN locked_op() RETURNS !Void ->
            c = Counter{ value: 0 } @locked;
            WITH EXCLUSIVE c AS inner { inner.value; }
            RETURN;
        END

        FN middle() RETURNS !Void ->
            locked_op();
            RETURN;
        END

        FN outer() RETURNS !Void ->
            middle();
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      expect(effs).to include(:CONTENTION)
      expect(effs).to include(:BLOCKING)
    end
  end

  describe "EffectSet projection (lowercase ?-form)" do
    it "projects BLOCKING_MAYBE to :\"blocking?\" in EffectSet" do
      ast = run(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN incr!(MUTABLE c: Counter) RETURNS Void REQUIRES c: ATOMIC | LOCKED ->
            WITH c AS va MATCH
              WHEN ATOMIC   -> { x = 0; }
              WHEN LOCKED -> { va.value = va.value + 1; }
            END
            RETURN;
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "incr!" }
      es = fn.effect_set
      expect(es).not_to be_nil
      expect(es.include?(:contention)).to eq(true)
      expect(es.include?(:blocks_maybe)).to eq(true)
      expect(es.include?(:blocking)).to eq(false)
    end

    it "projects concrete BLOCKING + CONTENTION in EffectSet" do
      ast = run(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @locked;
            WITH EXCLUSIVE c AS inner { inner.value; }
            RETURN;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      es = fn.effect_set
      expect(es.include?(:contention)).to eq(true)
      expect(es.include?(:blocking)).to eq(true)
      expect(es.include?(:contends_maybe)).to eq(false)
      expect(es.include?(:blocks_maybe)).to eq(false)
    end
  end

  describe "WithMatchCheck.family_of_arg_set" do
    it "returns a singleton Set for a concrete sync" do
      sym = Object.new
      def sym.sync; :atomic; end
      def sym.sync_families; nil; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg_set(arg)).to eq(Set[:ATOMIC])
    end

    it "returns the disjunction Set for a polymorphic param" do
      sym = Object.new
      def sym.sync; :locked; end
      def sym.sync_families; Set[:ATOMIC, :LOCKED]; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg_set(arg)).to eq(Set[:ATOMIC, :LOCKED])
    end

    it "returns Set[:LOCAL] for a sync-less binding (#336)" do
      # Pre-#336 this returned an empty set; now non-sync bindings
      # are in the LOCAL family.
      sym = SymbolEntry.new(reg: "x", type: :Int64, mutable: false, storage: :stack, sync: nil)
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg_set(arg)).to eq(Set[:LOCAL])
    end
  end
end
