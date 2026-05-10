require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Atomics M2.3: a BG / BG STREAM handle's lifetime is the
# intersection of every lifetime-bounded capture (atomic + locked +
# Rc + local). Plain @shared (Arc-only, no inner sync) does NOT
# contribute — Arc is refcounted, so the inner data lives as long
# as any reference exists.
#
# This spec verifies the LIFETIME STAMP itself: after annotation,
# the BG handle binding's SymbolEntry.lifetime is `{ sources: [...] }`
# with the right SymbolEntries. The downstream escape checks
# (RETURN / struct field / list append / nested-BG capture) are M2.6
# audit-matrix work and are tested separately.
RSpec.describe "BG handle tied lifetime (M2.3)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def main_fn(ast)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
  end

  def find_binding_symbol(fn, name)
    # The annotator stamps `node.symbol` on declaration BindExprs.
    # Walk fn body and pick the binding whose name matches.
    target = nil
    AST.walk_body(fn.body) do |n|
      if (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.respond_to?(:name) && n.name == name && n.respond_to?(:symbol)
        target ||= n.symbol
      end
    end
    target
  end

  describe "@shared:atomic captures" do
    it "BG capturing one atomic gets a one-source tied lifetime" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE c: Int64 = 0 @shared:atomic;
          bg = BG { v = c; print(v.toString()); };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime).to be_a(Hash)
      expect(sym.lifetime[:sources].size).to eq(1)
      # Source is the SymbolEntry of the captured atomic. Identity
      # check via name on the SymbolEntry's reg / scope.
      atomic_sym = find_binding_symbol(main_fn(ast), "c")
      expect(sym.lifetime_sources).to include(atomic_sym)
    end

    it "BG capturing two atomics gets a two-source tied lifetime (intersection)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x: Int64 = 0 @shared:atomic;
          MUTABLE y: Int64 = 0 @shared:atomic;
          bg = BG { print(x.toString()); print(y.toString()); };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime[:sources].size).to eq(2)
      expect(sym.lifetime_sources.map { |s| s.equal?(find_binding_symbol(main_fn(ast), "x")) || s.equal?(find_binding_symbol(main_fn(ast), "y")) }.all?).to be(true)
    end

    it "non_escaping is FALSE for a tied BG handle (it CAN escape, just bounded)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE c: Int64 = 0 @shared:atomic;
          bg = BG { v = c; print(v.toString()); };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      # Tied lifetime = the binding can leave its scope as long as
      # the destination is inside the source's scope. That's NOT the
      # v0.1 :current_scope semantic. Reporting non_escaping = true
      # would re-introduce the false-positive class M2.1 set out to
      # fix.
      expect(sym.non_escaping).to be(false)
    end
  end

  describe "@locked / @writeLocked / @multiowned captures" do
    it "BG capturing @locked gets the lock binding as a source" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          bg = BG { WITH EXCLUSIVE c AS inner { inner.v = inner.v + 1; } };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime).to be_a(Hash)
      expect(sym.lifetime[:sources].first).to equal(find_binding_symbol(main_fn(ast), "c"))
    end

    it "BG capturing @writeLocked also gets a tied lifetime" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @writeLocked;
          bg = BG { WITH EXCLUSIVE c AS inner { inner.v = inner.v + 1; } };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime[:sources].size).to eq(1)
    end
  end

  describe "@shared (Arc-only, no inner sync) — NOT a source" do
    it "BG capturing @shared without inner sync does NOT tie the lifetime" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @shared;
          bg = BG { x = c.v; };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      # Arc is refcounted; lifetime extension comes from the refcount,
      # not from the originating binding's scope.
      expect(sym.lifetime).to be_nil
    end
  end

  describe "mixed captures" do
    it "atomic + plain shared = only atomic contributes a source" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE counter: Int64 = 0 @shared:atomic;
          shared = C{ v: 0 } @shared;
          bg = BG { print(counter.toString()); print(shared.v.toString()); };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime).to be_a(Hash)
      expect(sym.lifetime[:sources].size).to eq(1)
      counter_sym = find_binding_symbol(main_fn(ast), "counter")
      expect(sym.lifetime[:sources]).to include(counter_sym)
    end

    it "atomic + locked = both contribute (intersection of two scopes)" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE a: Int64 = 0 @shared:atomic;
          b = C{ v: 0 } @locked;
          bg = BG {
            print(a.toString());
            WITH EXCLUSIVE b AS inner { inner.v = inner.v + 1; }
          };
          NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      expect(sym.lifetime[:sources].size).to eq(2)
    end
  end

  describe "BG buried in struct literal" do
    # Real fuzz finding (`tools/fuzz/run.rb --matrix --templates
    # lifetimed_return`, store_in_field cell): a BG block embedded
    # inside a struct literal field must propagate its tied lifetime
    # to the surrounding binding. Otherwise `RETURN h` (where h's bg
    # field captures a function-local source) escapes the source's
    # scope unrejected — confirmed UAF (assertion read garbage from
    # freed Counter.value).
    it "h = Holder{ bg: BG { @local }} ties h's lifetime to the BG's captures" do
      ast = annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        STRUCT Holder { bg: ~Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 0_i64 } @local;
          h = Holder{ bg: BG { c.value; } };
          r: Int64 = NEXT h.bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "h")
      expect(sym.lifetime).to be_a(Hash)
      expect(sym.lifetime[:sources].size).to eq(1)
      counter_sym = find_binding_symbol(main_fn(ast), "c")
      expect(sym.lifetime_sources).to include(counter_sym)
    end
  end

  describe "BG buried in union variant literal" do
    # Without recursing into union variant fields the BG handle escapes
    # silently when wrapped in a union (same UAF class as the StructLit
    # case). `Wrap.Single{ handle: BG{...} }` is the AST::UnionVariantLit
    # shape that this case must cover.
    it "`Wrap.Single{ handle: BG{...} }` ties w's lifetime to the captures" do
      ast = annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        UNION Wrap { Single { handle: ~Int64 } }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 0_i64 } @local;
          w = Wrap.Single{ handle: BG { c.value; } };
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "w")
      expect(sym.lifetime).to be_a(Hash)
      counter_sym = find_binding_symbol(main_fn(ast), "c")
      expect(sym.lifetime_sources).to include(counter_sym)
    end
  end

  describe "no captures" do
    it "BG with pure-compute body gets nil lifetime (no constraint)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          bg: ~Int64 = BG { 2 + 2; };
          x = NEXT bg;
          RETURN;
        END
      CLEAR
      sym = find_binding_symbol(main_fn(ast), "bg")
      # No captures = no lifetime to inherit from. The handle can
      # flow freely (subject to existing single-receiver / spawn
      # constraints).
      expect(sym.lifetime).to be_nil
    end
  end
end
