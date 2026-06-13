require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# True-Sync-Polymorphism step 7 (#329): call-site error collapsing.
#
# At each call site of a polymorphic function, the caller's effective
# !T collapses to only the errors the actually-passed binding can
# surface. The compiler stamps `FuncCall#collapsed_errors` with the
# projected Set<Symbol> per call.
#
# Forwarding semantics: when a polymorphic fn `a` (narrower REQUIRES)
# forwards its parameter to a broader callee `c`, the inner call's
# collapsed_errors reflects `a`'s narrower constraint -- NOT `c`'s
# full !T union. This is the practical "zero-blast-radius" promise:
# narrow the constraint at one boundary, the projection narrows
# automatically at every downstream call.
RSpec.describe "Call-site error collapsing (#329)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def first_call(ast, callee_name)
    found = nil
    AST.walk_body(ast.statements) do |n|
      if n.is_a?(AST::FuncCall) && n.name == callee_name
        found ||= n
      end
    end
    found
  end

  # ── 1. Concrete-binding call sites ──────────────────────────────

  describe "concrete bindings narrow to a single axis" do
    it "passing @versioned to REQUIRES SNAPSHOTTED → {MvccConflict}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN tick!(MUTABLE c: C) RETURNS !Void
          REQUIRES c: SNAPSHOTTED
        ->
          WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @versioned;
          tick!(c);
          RETURN;
        END
      CLEAR
      call = first_call(ast, "tick!")
      expect(call.collapsed_errors).to eq(Set[:MvccConflict])
    end

    it "passing @indirect:atomic to REQUIRES SNAPSHOTTED → {AtomicConflict}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN tick!(MUTABLE c: C) RETURNS !Void
          REQUIRES c: SNAPSHOTTED
        ->
          WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @indirect:atomic;
          tick!(c);
          RETURN;
        END
      CLEAR
      call = first_call(ast, "tick!")
      expect(call.collapsed_errors).to eq(Set[:AtomicConflict])
    end

    it "passing @shared:locked to REQUIRES LOCKED → {LockTimeout}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN tick!(MUTABLE c: C) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH POLYMORPHIC EXCLUSIVE c AS x { x.v = x.v + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @shared:locked;
          tick!(c);
          RETURN;
        END
      CLEAR
      call = first_call(ast, "tick!")
      expect(call.collapsed_errors).to eq(Set[:LockTimeout])
    end
  end

  # ── 2. Polymorphic forwarding ────────────────────────────────────

  describe "forwarding: narrower outer REQUIRES limits the projection" do
    # The user's exact ask: FN a (narrower REQUIRES) forwards its
    # param to FN c (broader REQUIRES). The inner call site reflects
    # a's narrower constraint, automatically reduced from c's full !T.
    it "outer REQUIRES VERSIONED, inner REQUIRES SNAPSHOTTED → call site sees {MvccConflict}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }

        FN c!(MUTABLE x: C) RETURNS !Void
          REQUIRES x: SNAPSHOTTED
        ->
          WITH SNAPSHOT x AS MUTABLE xa { xa.v = xa.v + 1; }
          RETURN;
        END

        FN a!(MUTABLE b: C) RETURNS !Void
          REQUIRES b: VERSIONED
        ->
          c!(b);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE v = C{ v: 0 } @versioned;
          a!(v);
          RETURN;
        END
      CLEAR

      # Inside a's body, the call to c! projects only MvccConflict
      # because a's REQUIRES narrows the param to VERSIONED.
      a_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "a!" }
      inner_call = a_fn.body.find { |s| s.is_a?(AST::FuncCall) && s.name == "c!" }
      expect(inner_call.collapsed_errors).to eq(Set[:MvccConflict])

      # And the outer call from main to a: a's full !T is
      # {MvccConflict} (since REQUIRES VERSIONED), and the actual
      # binding is @versioned, so the projection is the same.
      outer_call = first_call(ast, "a!")
      expect(outer_call.collapsed_errors).to eq(Set[:MvccConflict])
    end

    it "outer REQUIRES ATOMIC, inner REQUIRES SNAPSHOTTED → call site sees {AtomicConflict}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }

        FN c!(MUTABLE x: C) RETURNS !Void
          REQUIRES x: SNAPSHOTTED
        ->
          WITH SNAPSHOT x AS MUTABLE xa { xa.v = xa.v + 1; }
          RETURN;
        END

        FN a!(MUTABLE b: C) RETURNS !Void
          REQUIRES b: ATOMIC
        ->
          c!(b);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE v = C{ v: 0 } @indirect:atomic;
          a!(v);
          RETURN;
        END
      CLEAR

      a_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "a!" }
      inner_call = a_fn.body.find { |s| s.is_a?(AST::FuncCall) && s.name == "c!" }
      expect(inner_call.collapsed_errors).to eq(Set[:AtomicConflict])
    end

    it "outer REQUIRES SNAPSHOTTED → forwards full {MvccConflict, AtomicConflict}" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }

        FN c!(MUTABLE x: C) RETURNS !Void
          REQUIRES x: SNAPSHOTTED
        ->
          WITH SNAPSHOT x AS MUTABLE xa { xa.v = xa.v + 1; }
          RETURN;
        END

        FN a!(MUTABLE b: C) RETURNS !Void
          REQUIRES b: SNAPSHOTTED
        ->
          c!(b);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE v = C{ v: 0 } @versioned;
          a!(v);
          RETURN;
        END
      CLEAR

      # Forwarding a polymorphic param directly: the inner call sees
      # the full union (the binding is still polymorphic at this point;
      # the actual-family pin only happens when a concrete binding is
      # passed to a from the outside).
      a_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "a!" }
      inner_call = a_fn.body.find { |s| s.is_a?(AST::FuncCall) && s.name == "c!" }
      expect(inner_call.collapsed_errors).to eq(Set[:MvccConflict, :AtomicConflict])
    end
  end

  # ── 3. Non-polymorphic calls have no collapsed_errors ────────────

  describe "calls to non-polymorphic functions" do
    it "no REQUIRES on callee → collapsed_errors is nil" do
      ast = annotate(<<~CLEAR)
        FN bare(x: Int64) RETURNS Void -> _ = x; RETURN; END
        FN main() RETURNS Void ->
          bare(42);
          RETURN;
        END
      CLEAR
      call = first_call(ast, "bare")
      expect(call).not_to be_nil
      expect(call.collapsed_errors).to be_nil
    end
  end
end
