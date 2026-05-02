require "rspec"
require_relative "../src/ast/symbol_entry"

# Atomics M2.1: SymbolEntry.lifetime is the single mechanism for
# "where can this binding escape to". Three shapes:
#
#   nil               — no constraint
#   :current_scope    — locked to declaring scope (replaces
#                        non_escaping = true)
#   { sources: [...] } — intersection of source lifetimes (used for
#                        `RETURNS foo:T` returns AND BG handles whose
#                        lifetime is the intersection of all captured
#                        atomic / borrow bindings)
#
# `non_escaping` is preserved as a back-compat alias on top of
# `lifetime == :current_scope`.
RSpec.describe SymbolEntry, "lifetime unification (M2.1)" do
  def fresh
    SymbolEntry.new(reg: nil, type: :Int64, mutable: false, storage: :stack)
  end

  describe "default state" do
    it "lifetime is nil and non_escaping is false" do
      sym = fresh
      expect(sym.lifetime).to be_nil
      expect(sym.non_escaping).to be(false)
      expect(sym.lifetime_sources).to eq([])
    end
  end

  describe ":current_scope (replaces non_escaping = true)" do
    it "non_escaping = true sets lifetime to :current_scope" do
      sym = fresh
      sym.non_escaping = true
      expect(sym.lifetime).to eq(:current_scope)
      expect(sym.non_escaping).to be(true)
    end

    it "non_escaping = false clears the :current_scope lifetime" do
      sym = fresh
      sym.non_escaping = true
      sym.non_escaping = false
      expect(sym.lifetime).to be_nil
      expect(sym.non_escaping).to be(false)
    end

    it "lifetime = :current_scope is observed by non_escaping" do
      sym = fresh
      sym.lifetime = :current_scope
      expect(sym.non_escaping).to be(true)
    end

    it "lifetime_sources returns [self] for :current_scope" do
      sym = fresh
      sym.lifetime = :current_scope
      expect(sym.lifetime_sources).to eq([sym])
    end
  end

  describe "tied lifetime ({ sources: [...] })" do
    it "single-source form (RETURNS foo:T)" do
      # FN identity(foo: T) RETURNS foo:T -> RETURN foo; END
      # The returned value's lifetime points at `foo`. Whatever foo's
      # lifetime is, the returned value inherits it.
      foo = fresh
      retval = fresh
      retval.lifetime = SymbolEntry.tied_lifetime([foo])
      expect(retval.lifetime).to eq(sources: [foo])
      expect(retval.lifetime_sources).to eq([foo])
      # NOT non_escaping in the v0.1 sense — the binding CAN leave its
      # declaring scope, just not past foo's scope.
      expect(retval.non_escaping).to be(false)
    end

    it "multi-source form (BG capturing multiple atomics / borrows)" do
      # bg = BG { x; y; z; }
      # bg's lifetime is the INTERSECTION of x, y, z.
      x, y, z = fresh, fresh, fresh
      bg = fresh
      bg.lifetime = SymbolEntry.tied_lifetime([x, y, z])
      expect(bg.lifetime).to eq(sources: [x, y, z])
      expect(bg.lifetime_sources).to eq([x, y, z])
      expect(bg.non_escaping).to be(false)
    end

    it "tied_lifetime de-duplicates sources" do
      a = fresh
      b = fresh
      result = SymbolEntry.tied_lifetime([a, b, a])
      expect(result).to eq(sources: [a, b])
    end

    it "tied_lifetime returns nil for empty / nil input (unconstrained)" do
      expect(SymbolEntry.tied_lifetime(nil)).to be_nil
      expect(SymbolEntry.tied_lifetime([])).to be_nil
    end

    it "non_escaping = false does NOT clobber a tied lifetime" do
      # The clear-current-scope semantic of non_escaping = false must
      # not leak into the richer tied form. Otherwise the v0.1 alias
      # would silently downgrade an M2.3-tagged BG handle to
      # unconstrained at the next non_escaping = false write.
      sym = fresh
      other = fresh
      sym.lifetime = SymbolEntry.tied_lifetime([other])
      sym.non_escaping = false
      expect(sym.lifetime).to eq(sources: [other])
    end

    it "non_escaping reads false for a tied lifetime" do
      # Tied lifetimes ARE allowed to escape (just bounded by the
      # source's lifetime). The v0.1 `non_escaping = true` semantic
      # was strictly stronger ("cannot escape anywhere"); a tied
      # lifetime would be a false positive there.
      sym = fresh
      other = fresh
      sym.lifetime = SymbolEntry.tied_lifetime([other])
      expect(sym.non_escaping).to be(false)
    end
  end
end
