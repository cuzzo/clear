require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# AtomicPtr M3.8 -- annotator per-arm conflict-clause validation
# for `WITH SNAPSHOT ... AS [MUTABLE] alias MATCH ... END`.
#
# - VERSIONED arm + MUTABLE: REQUIRES `ON MvccConflict` (mirrors the
#   single-cell M5 contract).
# - ATOMIC arm + MUTABLE: FORBIDS conflict handlers (rcu retries until
#   success; design contract docs/agents/atomicptr.md §6.2). Once
#   #330 bounds AtomicPtr.update at 256, the right handler will be
#   `ON AtomicConflict`, but for now no inline handler is permitted.
# - read-mode SNAPSHOT MATCH (no MUTABLE on any cell): no per-arm
#   conflict-clause requirement at all (read paths can't fail).
# - The legacy M2/G1 rejection of "WITH c AS MUTABLE va MATCH ...
#   WHEN VERSIONED" was a generic-MATCH guard against writes through
#   the read snapshot; SNAPSHOT MATCH dispatches to Versioned.update
#   per arm so the rejection should NOT fire.
RSpec.describe "WITH SNAPSHOT MATCH annotator validation (M3.8)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "MUTABLE SNAPSHOT MATCH" do
    def with_arms(arms)
      <<~CLEAR
        STRUCT Cfg { port: Int64 }
        FN bumpPort(MUTABLE c: Cfg) RETURNS !Void
          REQUIRES c: VERSIONED | ATOMIC
        ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
        #{arms}
          END
          RETURN;
        END
      CLEAR
    end

    it "accepts VERSIONED arm with ON MvccConflict + ATOMIC arm without" do
      arms = <<~ARMS.rstrip
            WHEN VERSIONED -> { x.port = x.port + 1; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { x.port = x.port + 1; }
      ARMS
      expect { annotate(with_arms(arms)) }.not_to raise_error
    end

    it "VERSIONED arm without ON MvccConflict falls back to the program SYNC POLICY (#328)" do
      # True-Sync-Polymorphism (#328): the per-arm `ON MvccConflict`
      # is no longer mandatory on the VERSIONED arm of a SNAPSHOT
      # MATCH MUTABLE; the program-level SYNC POLICY (baked-in default
      # raises) provides the fallback handler. Inline arm-level handler
      # is still accepted (it would override the policy).
      arms = <<~ARMS.rstrip
            WHEN VERSIONED -> { x.port = x.port + 1; }
            WHEN ATOMIC    -> { x.port = x.port + 1; }
      ARMS
      expect { annotate(with_arms(arms)) }.not_to raise_error
    end

    it "rejects when the ATOMIC arm has a conflict handler (forbidden by rcu contract)" do
      arms = <<~ARMS.rstrip
            WHEN VERSIONED -> { x.port = x.port + 1; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { x.port = x.port + 1; } ON MvccConflict RAISE
      ARMS
      expect { annotate(with_arms(arms)) }
        .to raise_error(/ATOMIC.*forbids.*conflict|ATOMIC.*rcu/i)
    end
  end

  describe "read-mode SNAPSHOT MATCH (no MUTABLE)" do
    it "accepts read-only arms with no ON MvccConflict on either arm" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN dump(c: Cfg) RETURNS Void
            REQUIRES c: VERSIONED | ATOMIC
          ->
            WITH SNAPSHOT c AS x MATCH
              WHEN VERSIONED -> { _ = x.port; }
              WHEN ATOMIC    -> { _ = x.port; }
            END
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
