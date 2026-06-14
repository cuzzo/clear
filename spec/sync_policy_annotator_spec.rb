require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# True-Sync-Polymorphism step 2 (#325): annotator validation for the
# top-level `SYNC POLICY START ... END` block.
#
# Rules verified here:
#   1. Single-instance: more than one SYNC POLICY in the program → error.
#   2. Main-file-only: SYNC POLICY in a module without `FN main` → error.
#   3. Completeness: must handle exactly LockTimeout, MvccConflict,
#      AtomicConflict. Missing any → error (with the missing list).
#   4. Inline-only-error guard: `ON Deadlock` / `ON LockCycle` in a
#      SYNC POLICY → error with "must be handled in-line".
#   5. No kind selectors / no RETRY-sugar → error (each handler must
#      name a specific error type so completeness is checkable).
#   6. Resolved policy is stamped on Program#sync_policy. Absent → the
#      baked-in default applies.
RSpec.describe "SYNC POLICY annotator validation (#325)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # ── 1. Single-instance ────────────────────────────────────────

  describe "single-instance rule" do
    it "rejects two SYNC POLICY blocks in the same file" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          SYNC POLICY START
              ON LockTimeout RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/Only one SYNC POLICY block is allowed/)
    end
  end

  # ── 2. Main-file-only ─────────────────────────────────────────

  describe "main-file-only rule" do
    it "rejects SYNC POLICY in a module without FN main" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN helper() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/SYNC POLICY may only be declared in the file containing `FN main`/)
    end

    it "accepts SYNC POLICY when FN main is present" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.not_to raise_error
    end
  end

  # ── 3. Completeness ───────────────────────────────────────────

  describe "completeness rule" do
    it "errors when LockTimeout is missing" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/SYNC POLICY must handle every required error.*Missing: LockTimeout/)
    end

    it "errors when MvccConflict is missing" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/Missing: MvccConflict/)
    end

    it "errors when AtomicConflict is missing" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON MvccConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/Missing: AtomicConflict/)
    end

    it "errors when multiple are missing (lists all in the message)" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/Missing: MvccConflict, AtomicConflict|Missing: AtomicConflict, MvccConflict/)
    end
  end

  # ── 4. Inline-only error guard ────────────────────────────────

  describe "inline-only error guard (Deadlock, LockCycle)" do
    it "rejects ON Deadlock in SYNC POLICY" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON Deadlock RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/Deadlock.*must be handled in-line.*SYNC POLICY defaults are not allowed/)
    end

    it "rejects ON LockCycle in SYNC POLICY" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON LockCycle RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/LockCycle.*must be handled in-line/)
    end

    it "the Deadlock error message points at the WITH POLYMORPHIC POSSIBLE_DEADLOCK opt-out" do
      begin
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON Deadlock RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
        fail "expected error"
      rescue => e
        expect(e.message).to match(/WITH POLYMORPHIC POSSIBLE_DEADLOCK/)
      end
    end
  end

  # ── 5. Kind selectors + RETRY sugar are rejected ──────────────

  describe "selector-shape rule" do
    it "rejects ON Transient (kind selector instead of type)" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON Transient RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/SYNC POLICY handlers must name a specific error type, not a kind/)
    end

    it "rejects RETRY(N) THEN sugar (desugars to ON Transient)" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              RETRY(3) THEN RAISE
              ON LockTimeout RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/SYNC POLICY handlers must name a specific error type/)
    end

    it "rejects an unknown error name" do
      expect {
        annotate(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
              ON Whatever RAISE
              ON MvccConflict RAISE
              ON AtomicConflict RAISE
          END

          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(/`Whatever` is not a valid SYNC POLICY error/)
    end
  end

  # ── 6. Resolved policy is stamped on the Program ──────────────

  describe "policy resolution + stamping" do
    it "stamps the user-written policy on Program#sync_policy" do
      ast = annotate(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RETRY(2) THEN RAISE
            ON MvccConflict RAISE
            ON AtomicConflict RAISE
        END

        FN main() RETURNS Void -> RETURN; END
      CLEAR

      handlers = ast.sync_policy
      expect(handlers).to be_an(Array)
      expect(handlers.size).to eq(3)
      lt = handlers.find { |h| h.selectors.first.name == :LockTimeout }
      expect(lt.retries).to eq(2)
      expect(lt.action).to eq(:raise)
    end

    it "stamps the baked-in default when no SYNC POLICY is present" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      handlers = ast.sync_policy
      expect(handlers).to be_an(Array)
      names = handlers.flat_map { |h| h.selectors.map { |s| s.name } }.to_set
      expect(names).to eq(Set[:LockTimeout, :MvccConflict, :AtomicConflict])
    end

    it "the baked-in LockTimeout default has RETRY(3) THEN RAISE" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      lt = ast.sync_policy.find { |h| h.selectors.first.name == :LockTimeout }
      expect(lt.retries).to eq(3)
      expect(lt.action).to eq(:raise)
    end

    it "the baked-in MvccConflict / AtomicConflict defaults are RAISE (no retry)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      %i[MvccConflict AtomicConflict].each do |name|
        h = ast.sync_policy.find { |hh| hh.selectors.first.name == name }
        expect(h.retries).to be_nil
        expect(h.action).to eq(:raise)
      end
    end
  end
end
