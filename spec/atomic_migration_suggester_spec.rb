require "rspec"
require "set"
require_relative "../src/tools/atomic_migration_suggester"

# Atomics M1.9 / M1.10: static eligibility check for the
# @shared:locked -> @shared:atomic migration. Tested in isolation;
# the doctor wires the runtime contention signal in src/tools/doctor.rb.
RSpec.describe "AtomicMigrationSuggester (M1.9/M1.10 static eligibility)" do
  def candidates(src)
    AtomicMigrationSuggester.analyze(src)
  end

  describe "positive cases" do
    it "flags @shared:locked single-Int64 counter with `+=`-shaped body" do
      cs = candidates(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN bumpIt() RETURNS !Void ->
          c = Counter{ value: 0 } @shared:locked;
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first).to include(
        name: "c",
        struct_name: :Counter,
        field_name: "value",
        field_type: :Int64,
        shared: true,
        n_uses: 1,
      )
    end

    it "flags plain @locked with `-=`-shaped body" do
      cs = candidates(<<~CLEAR)
        STRUCT G { v: Int64 }
        FN dec() RETURNS !Void ->
          g = G{ v: 0 } @locked;
          WITH EXCLUSIVE g AS a { a.v = a.v - 5; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:shared]).to eq(false)
    end

    it "flags Float64 single-field counter" do
      cs = candidates(<<~CLEAR)
        STRUCT G { gauge: Float64 }
        FN tick() RETURNS !Void ->
          g = G{ gauge: 0.0 } @shared:locked;
          WITH EXCLUSIVE g AS a { a.gauge = a.gauge + 1.5_f64; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:field_type]).to eq(:Float64)
    end

    it "flags Bool flag" do
      cs = candidates(<<~CLEAR)
        STRUCT F { flag: Bool }
        FN setIt() RETURNS !Void ->
          f = F{ flag: FALSE } @shared:locked;
          WITH EXCLUSIVE f AS a { a.flag = TRUE; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:field_type]).to eq(:Bool)
    end

    it "counts multiple eligible WITH bodies" do
      cs = candidates(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @shared:locked;
          WITH EXCLUSIVE c AS a { a.v = a.v + 1; }
          WITH EXCLUSIVE c AS a { a.v = a.v + 1; }
          WITH EXCLUSIVE c AS a { a.v = 42; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:n_uses]).to eq(3)
    end
  end

  describe "negative cases" do
    it "does not flag @writeLocked (RWLock has no atomic equivalent)" do
      cs = candidates(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @writeLocked;
          WITH EXCLUSIVE c AS a { a.v = a.v + 1; }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag two-field structs" do
      cs = candidates(<<~CLEAR)
        STRUCT C { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          c = C{ x: 0, y: 0 } @shared:locked;
          WITH EXCLUSIVE c AS a { a.x = a.x + 1; }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag non-primitive single-field structs" do
      cs = candidates(<<~CLEAR)
        STRUCT N { name: String }
        FN main() RETURNS Void ->
          n = N{ name: "x" } @shared:locked;
          WITH EXCLUSIVE n AS a { a.name = "y"; }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag bindings that escape via fn-arg" do
      cs = candidates(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN sink!(MUTABLE c: C) RETURNS Void REQUIRES c: LOCKED ->
          WITH EXCLUSIVE c AS a { a.v = a.v + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          c = C{ v: 0 } @shared:locked;
          sink!(c);
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag bodies with multiplication (not atomic-rewriteable)" do
      cs = candidates(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 1 } @shared:locked;
          WITH EXCLUSIVE c AS a { a.v = a.v * 2; }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag bodies with control flow" do
      cs = candidates(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @shared:locked;
          WITH EXCLUSIVE c AS a {
            IF a.v > 10 THEN a.v = 0; END
          }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "swallows parser errors and returns []" do
      cs = candidates("INVALID CLEAR SOURCE !!!")
      expect(cs).to eq([])
    end
  end
end
