require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/annotator/helpers/with_match_check" unless defined?(WithMatchCheck)

# True-Sync-Polymorphism step 5 (#327): polymorphic-warning surface
# + the new effect names `contends_maybe` / `blocks_maybe`.
#
# For every WITH POLYMORPHIC block, the annotator projects the
# admissible-family error set (LockTimeout / MvccConflict /
# AtomicConflict per axis), subtracts per-WITH `ON ...` handlers and
# the program-level SYNC POLICY, and warns on the remainder.
#
# In normal usage with the baked-in SYNC POLICY (the default that's
# always stamped when the user doesn't write one), every axis-error
# is covered, so the remainder is empty and no warning fires. This
# spec exercises the helper directly to pin the projection contract,
# and then exercises the warn path via a synthetic empty policy.
RSpec.describe "Polymorphic-warning surface (#327)" do
  describe "errors_for_requires" do
    it "LOCKED admits {LockTimeout}" do
      expect(WithMatchCheck.errors_for_requires(Set[:LOCKED])).to eq(Set[:LockTimeout])
    end

    it "SNAPSHOTTED admits {MvccConflict, AtomicConflict}" do
      expect(WithMatchCheck.errors_for_requires(Set[:SNAPSHOTTED]))
        .to eq(Set[:MvccConflict, :AtomicConflict])
    end

    it "VERSIONED admits {MvccConflict}" do
      expect(WithMatchCheck.errors_for_requires(Set[:VERSIONED])).to eq(Set[:MvccConflict])
    end

    it "ATOMIC admits {AtomicConflict}" do
      expect(WithMatchCheck.errors_for_requires(Set[:ATOMIC])).to eq(Set[:AtomicConflict])
    end

    it "LOCKED | SNAPSHOTTED unions to {LockTimeout, MvccConflict, AtomicConflict}" do
      expect(WithMatchCheck.errors_for_requires(Set[:LOCKED, :SNAPSHOTTED]))
        .to eq(Set[:LockTimeout, :MvccConflict, :AtomicConflict])
    end

    it "Deadlock and LockCycle are NEVER in the projection (inline-only)" do
      Set[:LOCKED, :SNAPSHOTTED, :VERSIONED, :ATOMIC].each do |fam|
        errors = WithMatchCheck.errors_for_requires(Set[fam])
        expect(errors).not_to include(:Deadlock)
        expect(errors).not_to include(:LockCycle)
      end
    end

    it "empty / nil REQUIRES projects empty error set" do
      expect(WithMatchCheck.errors_for_requires(Set.new)).to eq(Set.new)
      expect(WithMatchCheck.errors_for_requires(nil)).to eq(Set.new)
    end
  end

  describe "handled_error_set" do
    let(:type_clause) {
      ->(name) {
        AST::ErrorClause.new(
          selectors: [AST::ErrorSelector.new(form: :type, name: name, token: nil)],
          retries: nil,
          action: AST::ErrorActionKind::Raise,
          token: nil,
        )
      }
    }

    it "extracts type-form selectors from the clause + policy" do
      node = AST::WithBlock.new(nil, [], [], nil)
      node.lock_error_clause = type_clause.call(:MvccConflict)
      policy = [type_clause.call(:LockTimeout), type_clause.call(:AtomicConflict)]
      handled = WithMatchCheck.handled_error_set(node, policy)
      expect(handled).to eq(Set[:MvccConflict, :LockTimeout, :AtomicConflict])
    end

    it "expands kind-form selectors via AST.types_for_kind" do
      node = AST::WithBlock.new(nil, [], [], nil)
      node.lock_error_clause = AST::ErrorClause.new(
        selectors: [AST::ErrorSelector.new(form: :kind, name: :Transient, token: nil)],
        retries: nil,
        action: AST::ErrorActionKind::Raise,
        token: nil,
      )
      handled = WithMatchCheck.handled_error_set(node, [])
      # :Transient expands to LockTimeout, LockCycle, MvccConflict,
      # AtomicConflict (all stdlib Transient types).
      expect(handled).to include(:LockTimeout, :MvccConflict, :AtomicConflict)
    end

    it "returns an empty set when no clause and no policy" do
      node = AST::WithBlock.new(nil, [], [], nil)
      expect(WithMatchCheck.handled_error_set(node, [])).to eq(Set.new)
    end
  end

  describe "warn integration in the annotator" do
    def annotate_capturing_notes(src)
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      capture = StringIO.new
      orig = $stderr
      $stderr = capture
      begin
        SemanticAnnotator.new.annotate!(ast)
      ensure
        $stderr = orig
      end
      [ast, capture.string]
    end

    it "fires no warning when the baked-in SYNC POLICY covers everything" do
      _ast, notes = annotate_capturing_notes(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN bump!(c: Counter) RETURNS Void
          REQUIRES c: SNAPSHOTTED
        ->
          WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @versioned;
          bump!(c);
          RETURN;
        END
      CLEAR
      expect(notes).not_to include("Polymorphic error")
    end

    it "fires no warning when REQUIRES LOCKED is covered by the baked-in policy" do
      _ast, notes = annotate_capturing_notes(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN bump!(c: Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @shared:locked;
          bump!(c);
          RETURN;
        END
      CLEAR
      expect(notes).not_to include("Polymorphic error")
    end
  end

  describe "EffectSet accepts the new contends_maybe / blocks_maybe names" do
    it "accepts both new spellings" do
      expect { EffectSet.new([:contends_maybe, :blocks_maybe]) }.not_to raise_error
    end

    it "still accepts the legacy ?-suffix names for backward compatibility" do
      expect { EffectSet.new([:"contention?", :"blocking?"]) }.not_to raise_error
    end

    it "EFFECT_ORDER places the new names alongside their concrete counterparts" do
      order = EffectSet::EFFECT_ORDER
      expect(order.index(:contends_maybe)).to be < order.index(:blocking)
      expect(order.index(:blocks_maybe)).to be > order.index(:blocking)
    end
  end
end
