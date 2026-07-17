require "rspec"
require "set"
require_relative "../ruby/tools/atomic_ptr_migration_suggester" unless defined?(AtomicPtrMigrationSuggester)

# AtomicPtr M3.15: static eligibility check for the @shared:writeLocked
# / @shared:locked (struct) -> @boxed:atomic migration. Tested in
# isolation; the doctor wires the runtime contention signal in
# src/tools/doctor.rb (M3.16).
RSpec.describe "AtomicPtrMigrationSuggester (M3.15 static eligibility)" do
  def candidates(src)
    AtomicPtrMigrationSuggester.analyze(src)
  end

  describe "positive cases" do
    it "flags @shared:writeLocked struct with whole-struct replace inside WITH EXCLUSIVE" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN swap() RETURNS !Void ->
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
      # @boxed:atomic, even if every WITH is read-only. The doctor
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
        FN main() RETURNS !Void ->
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
        FN main() RETURNS !Void ->
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
        FN main() RETURNS !Void ->
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
        FN sink(MUTABLE c: Cfg) RETURNS Void REQUIRES c: LOCKED ->
          WITH EXCLUSIVE c AS a { a.port = a.port + 1; }
          RETURN;
        END
        FN main() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:writeLocked;
          sink(&c);
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
        FN main() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:writeLocked;
          WITH EXCLUSIVE c AS a { a = Other{ port: 100 }; }
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

  # AtomicPtr M3.16: extension to recognize @shared:versioned struct
  # bindings whose WITH SNAPSHOT MUTABLE bodies are whole-struct replace.
  # The doctor (emit_atomic_ptr_upgrade_from_mvcc!) cross-references
  # this with mvcc-profile multi_commits == 0 to surface the upgrade.
  describe "M3.16 upgrade-from-MVCC detection" do
    it "flags @shared:versioned struct with whole-struct replace inside WITH SNAPSHOT MUTABLE" do
      cs = candidates(<<~CLEAR)
        STRUCT Cfg { host: String, port: Int64 }
        FN swap() RETURNS !Void ->
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
        FN main() RETURNS !Void ->
          MUTABLE c = Cfg{ port: 80 } @shared:versioned;
          WITH SNAPSHOT c AS MUTABLE a { a.port = a.port + 1; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      expect(cs).to be_empty
    end
  end

  describe "defensive AST-level branch behavior" do
    it "accepts inferred read captures for write-locked candidates" do
      candidates_by_name = {
        "c" => { sync: :write_locked, struct_name: :Cfg, n_uses: 0, disqualified: false },
      }
      cap = AST::Capability.new(
        capability: :infer,
        var_node: AST::Identifier.new(nil, "c"),
        alias: "a",
      )
      body = [
        AST::BindExpr.new(nil, "_", nil, AST::GetField.new(nil, AST::Identifier.new(nil, "a"), "port")),
      ]
      with_node = AST::WithBlock.new(nil, [cap], body)

      AtomicPtrMigrationSuggester.send(:classify_with_block!, with_node, candidates_by_name)

      expect(candidates_by_name["c"]).to include(n_uses: 1, disqualified: false)
    end

    it "disqualifies unacceptable capabilities" do
      candidates_by_name = {
        "c" => { sync: :locked, struct_name: :Cfg, n_uses: 0, disqualified: false },
      }
      cap = AST::Capability.new(
        capability: :SNAPSHOT,
        var_node: AST::Identifier.new(nil, "c"),
      )

      AtomicPtrMigrationSuggester.send(:classify_with_block!,
        AST::WithBlock.new(nil, [cap], []),
        candidates_by_name,
      )

      expect(candidates_by_name["c"][:disqualified]).to eq(true)
    end

    it "disqualifies acceptable captures with ineligible bodies" do
      candidates_by_name = {
        "c" => { sync: :locked, struct_name: :Cfg, n_uses: 0, disqualified: false },
      }
      cap = AST::Capability.new(
        capability: :EXCLUSIVE,
        var_node: AST::Identifier.new(nil, "c"),
        alias: "a",
      )

      AtomicPtrMigrationSuggester.send(:classify_with_block!,
        AST::WithBlock.new(nil, [cap], []),
        candidates_by_name,
      )

      expect(candidates_by_name["c"][:disqualified]).to eq(true)
    end

    it "handles assignment-node field writes, root replacements, and other targets" do
      alias_id = AST::Identifier.new(nil, "a")
      field_write = AST::Assignment.new(nil, AST::GetField.new(nil, alias_id, "port"), AST::Literal.new(nil, :INT64, 81, :stack))
      matching_replace = AST::Assignment.new(nil, AST::Identifier.new(nil, "a"), AST::StructLit.new(nil, "Cfg", {}, :stack, nil))
      mismatched_replace = AST::Assignment.new(nil, AST::Identifier.new(nil, "a"), AST::StructLit.new(nil, "Other", {}, :stack, nil))
      other_target = AST::Assignment.new(nil, AST::GetField.new(nil, AST::Identifier.new(nil, "other"), "port"), AST::Literal.new(nil, :INT64, 81, :stack))
      call_stmt = AST::FuncCall.new(nil, "print", [AST::GetField.new(nil, alias_id, "port")])

      expect(AtomicPtrMigrationSuggester.send(:stmt_eligible?, field_write, "a", :Cfg)).to eq(false)
      expect(AtomicPtrMigrationSuggester.send(:stmt_eligible?, matching_replace, "a", :Cfg)).to eq(true)
      expect(AtomicPtrMigrationSuggester.send(:stmt_eligible?, mismatched_replace, "a", :Cfg)).to eq(false)
      expect(AtomicPtrMigrationSuggester.send(:stmt_eligible?, other_target, "a", :Cfg)).to eq(true)
      expect(AtomicPtrMigrationSuggester.send(:stmt_eligible?, call_stmt, "a", :Cfg)).to eq(true)
    end
  end
end
