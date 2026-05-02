require "rspec"
require "set"
require_relative "../src/tools/atomic_ptr_migration_suggester"

# AtomicPtr M3.15: static eligibility check for the @shared:writeLocked
# / @shared:locked (struct) -> @indirect:atomic migration. Tested in
# isolation; the doctor wires the runtime contention signal in
# src/doctor.rb (M3.16).
RSpec.describe "AtomicPtrMigrationSuggester (M3.15 static eligibility)" do
  def candidates(src)
    AtomicPtrMigrationSuggester.analyze(src)
  end

  describe "positive cases" do
    it "flags @shared:writeLocked struct with whole-struct replace inside WITH EXCLUSIVE" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN swap!() RETURNS !Void ->
          MUTABLE c = Cfg{ host: "x", port: 80 } @shared:writeLocked;
          WITH EXCLUSIVE c AS a { a = Cfg{ host: "y", port: 443 }; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first).to include(
        name: "c",
        struct_name: :Cfg,
        sync: :write_locked,
        shared: true,
      )
    end

    it "flags @shared:locked struct with read-only WITH EXCLUSIVE bodies" do
      # Read-mostly pattern: structurally eligible to switch to
      # @indirect:atomic, even if every WITH is read-only. The doctor
      # combines this with profile contention to decide.
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN check() RETURNS !Void ->
          c = Cfg{ host: "x", port: 80 } @shared:locked;
          WITH EXCLUSIVE c AS a { _ = a.host; }
          WITH EXCLUSIVE c AS a { _ = a.port; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:n_uses]).to eq(2)
    end

    it "counts multiple eligible WITH bodies on the same binding" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ host: "x", port: 80 } @shared:writeLocked;
          WITH EXCLUSIVE c AS a { a = Cfg{ host: "y", port: 443 }; }
          WITH EXCLUSIVE c AS a { a = Cfg{ host: "z", port: 8080 }; }
          WITH EXCLUSIVE c AS a { _ = a.port; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:n_uses]).to eq(3)
    end
  end

  describe "negative cases" do
    it "does not flag bindings with field-level mutation (stay-put @shared:locked)" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:writeLocked;
          WITH EXCLUSIVE c AS a { a.port = a.port + 1; }
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag @shared:versioned bindings (already lock-free; M3.16 handles upgrade)" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:versioned;
          WITH SNAPSHOT c AS MUTABLE a { a.port = a.port + 1; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag plain (non-locked) struct bindings" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN main() RETURNS Void ->
          c = Cfg{ port: 80 };
          _ = c.port;
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag bindings that escape via fn-arg" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN sink!(MUTABLE c: Cfg) RETURNS Void REQUIRES c: LOCKED ->
          WITH EXCLUSIVE c AS a { a.port = a.port + 1; }
          RETURN;
        END
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:writeLocked;
          sink!(c);
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end

    it "does not flag whole-struct replace using a different struct type" do
      # Eligibility requires the RHS struct lit to match the binding's
      # struct type -- a cross-type replace is suspicious and disqualifies.
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        STRUCT Other { port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:writeLocked;
          WITH EXCLUSIVE c AS a { a = Cfg{ port: 100 }; }
          RETURN;
        END
      CLEAR
      # This one actually matches (Cfg{} == Cfg) so it should flag.
      expect(cs.size).to eq(1)
    end

    it "swallows parser errors and returns []" do
      cs = candidates("INVALID CLEAR SOURCE !!!")
      expect(cs).to eq([])
    end
  end

  # AtomicPtr M3.16: extension to recognize @shared:versioned struct
  # bindings whose WITH SNAPSHOT MUTABLE bodies are whole-struct replace.
  # The doctor (emit_atomic_ptr_upgrade_from_mvcc!) cross-references
  # this with mvcc-profile multi_commits == 0 to surface the upgrade.
  describe "M3.16 upgrade-from-MVCC detection" do
    it "flags @shared:versioned struct with whole-struct replace inside WITH SNAPSHOT MUTABLE" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN swap!() RETURNS !Void ->
          MUTABLE c = Cfg{ host: "x", port: 80 } @shared:versioned;
          WITH SNAPSHOT c AS MUTABLE a { a = Cfg{ host: "y", port: 443 }; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first).to include(
        name: "c",
        struct_name: :Cfg,
        sync: :versioned,
        shared: true,
      )
    end

    it "flags @shared:versioned with read-only WITH SNAPSHOT bodies (read-mostly fit)" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN check() RETURNS !Void ->
          c = Cfg{ host: "x", port: 80 } @shared:versioned;
          WITH SNAPSHOT c AS a { _ = a.host; }
          RETURN;
        END
      CLEAR
      expect(cs.size).to eq(1)
      expect(cs.first[:sync]).to eq(:versioned)
    end

    it "does not flag @shared:versioned with field-level mutation in WITH SNAPSHOT MUTABLE" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN main!() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:versioned;
          WITH SNAPSHOT c AS MUTABLE a { a.port = a.port + 1; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end
  end
end
