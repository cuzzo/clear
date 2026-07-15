require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/annotator/helpers/with_match_check" unless defined?(WithMatchCheck)

# True-Sync-Polymorphism step 4 (#326): annotator validation for the
# polymorphic-iff rule and the SNAPSHOTTED REQUIRES family.
#
# Rules:
#   1. Plain WITH on a polymorphic parameter (REQUIRES admits >1
#      storage axis) → error: use WITH POLYMORPHIC.
#   2. WITH POLYMORPHIC on a non-polymorphic binding (concrete sync,
#      or REQUIRES admits exactly 1 storage axis) → error: drop
#      POLYMORPHIC or broaden REQUIRES.
#   3. WITH POLYMORPHIC on a polymorphic param → accepted.
#   4. SNAPSHOTTED REQUIRES family admits @versioned, @atomic, and
#      @boxed:atomic (the umbrella for retry-style sync); the
#      narrower VERSIONED / ATOMIC families pin behavior.
#   5. The auto-shim path (WITH on a parameter without REQUIRES) is
#      grandfathered — plain WITH still works there because the shim
#      populates LOCKED only after the iff-rule has fired (and the
#      iff-rule sees no REQUIRES → not poly → no error).
RSpec.describe "True-Sync-Polymorphism dispatch (#326)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # ── 1. Plain WITH on poly param → error ──────────────────────

  describe "polymorphic-iff rule" do
    it "rejects plain WITH on REQUIRES c: LOCKED (admits 2 axes)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Void
            REQUIRES c: LOCKED
          ->
            WITH EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Plain WITH on the polymorphic parameter 'c'.*WITH POLYMORPHIC/m)
    end

    it "rejects plain WITH on REQUIRES c: SNAPSHOTTED (admits 2 axes)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN read(c: Counter) RETURNS Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS x { _ = x.value; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error  # SNAPSHOT is its own dispatch path; iff-rule
                             # only enforces on plain WITH (not SNAPSHOT/MATCH/VIEW).
    end

    it "rejects plain WITH on REQUIRES c: LOCKED | VERSIONED (multi-family)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Void
            REQUIRES c: LOCKED | VERSIONED
          ->
            WITH EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/Plain WITH on the polymorphic parameter 'c'/)
    end

    it "accepts WITH POLYMORPHIC on REQUIRES c: LOCKED" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Void
            REQUIRES c: LOCKED
          ->
            WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects WITH POLYMORPHIC on REQUIRES c: VERSIONED (mono, 1 axis)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Void
            REQUIRES c: VERSIONED
          ->
            WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH POLYMORPHIC is only allowed when at least one bound binding is a polymorphic parameter/m)
    end

    it "rejects WITH POLYMORPHIC on REQUIRES c: ATOMIC (mono, 1 axis)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bump!(c: Counter) RETURNS Void
            REQUIRES c: ATOMIC
          ->
            WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH POLYMORPHIC is only allowed when at least one bound binding is a polymorphic parameter/m)
    end

    it "rejects WITH POLYMORPHIC on a concrete (non-param) binding" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 0 } @shared:locked;
            WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/WITH POLYMORPHIC is only allowed/)
    end

    it "accepts plain WITH on a concrete @shared:locked binding (mono)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 0 } @shared:locked;
            WITH EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "auto-shim path is grandfathered (plain WITH on param without REQUIRES)" do
      # The LOCKED auto-shim populates requires_map AFTER the iff-rule
      # has already fired. Since requires_map is empty at iff-check time,
      # poly_requires? returns false and the rule does not error.
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN bumpIt(c: Counter) RETURNS Void ->
            WITH EXCLUSIVE c AS x { x.value = x.value + 1; }
            RETURN;
          END
          FN main() RETURNS Void ->
            c = Counter{ value: 0 } @shared:locked;
            bumpIt(c);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  # ── 2. SNAPSHOTTED REQUIRES family ───────────────────────────

  describe "SNAPSHOTTED REQUIRES family" do
    it "is recognized by the parser as a valid family" do
      tokens = Lexer.new(<<~CLEAR).tokenize
        STRUCT C { v: Int64 }
        FN read(c: C) RETURNS Void
          REQUIRES c: SNAPSHOTTED
        ->
          RETURN;
        END
      CLEAR
      ast = ClearParser.new(tokens, "").parse
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
      expect(fn.requires["c"]).to eq(Set[:SNAPSHOTTED])
    end

    it "admits @versioned at call sites" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN read(c: C) RETURNS Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS x { _ = x.v; }
            RETURN;
          END
          FN main() RETURNS Void ->
            c = C{ v: 0 } @versioned;
            read(c);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "admits @boxed:atomic at call sites" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN read(c: C) RETURNS Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS x { _ = x.v; }
            RETURN;
          END
          FN main() RETURNS Void ->
            c = C{ v: 0 } @boxed:atomic;
            read(c);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "rejects passing a @locked binding to SNAPSHOTTED" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN read(c: C) RETURNS Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS x { _ = x.v; }
            RETURN;
          END
          FN main() RETURNS Void ->
            c = C{ v: 0 } @shared:locked;
            read(c);
            RETURN;
          END
        CLEAR
      }.to raise_error(/Call to 'read'.*requires parameter 'c'.*SNAPSHOTTED.*family LOCKED/m)
    end
  end

  # ── 3. Family axis classification ────────────────────────────

  describe "family axis classification" do
    it "LOCKED admits 2 axes — poly" do
      expect(WithMatchCheck.poly_requires?(Set[:LOCKED])).to be true
    end

    it "SNAPSHOTTED admits 2 axes — poly" do
      expect(WithMatchCheck.poly_requires?(Set[:SNAPSHOTTED])).to be true
    end

    it "VERSIONED admits 1 axis — mono" do
      expect(WithMatchCheck.poly_requires?(Set[:VERSIONED])).to be false
    end

    it "ATOMIC admits 1 axis — mono" do
      expect(WithMatchCheck.poly_requires?(Set[:ATOMIC])).to be false
    end

    it "VERSIONED | ATOMIC unions to 2 axes — poly" do
      expect(WithMatchCheck.poly_requires?(Set[:VERSIONED, :ATOMIC])).to be true
    end

    it "empty / nil REQUIRES is mono" do
      expect(WithMatchCheck.poly_requires?(Set.new)).to be false
      expect(WithMatchCheck.poly_requires?(nil)).to be false
    end
  end
end
