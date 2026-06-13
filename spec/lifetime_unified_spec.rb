require "rspec"
require_relative "../src/ast/symbol_entry" unless defined?(SymbolEntry::BindingLifecycleFacts)

# Atomics M2.1: SymbolEntry.lifetime is the single mechanism for
# "where can this binding escape to". One shape:
#
#   []                — no constraint
#   [self]            — locked to declaring scope (replaces
#                        non_escaping = true)
#   [source, ...]     — intersection of source lifetimes
#
# `non_escaping` is preserved as a back-compat alias on top of
# `lifetime == [self]`.
RSpec.describe SymbolEntry, "lifetime unification (M2.1)" do
  def fresh
    SymbolEntry.new(reg: nil, type: :Int64, mutable: false, storage: :stack)
  end

  describe "default state" do
    it "lifetime is empty and non_escaping is false" do
      sym = fresh
      expect(sym.lifetime).to eq([])
      expect(sym.non_escaping).to be(false)
      expect(sym.lifetime_sources).to eq([])
    end
  end

  describe "[self] current-scope lifetime (replaces non_escaping = true)" do
    it "non_escaping = true sets lifetime to [self]" do
      sym = fresh
      sym.mark_non_escaping!
      expect(sym.lifetime).to eq([sym])
      expect(sym.non_escaping).to be(true)
    end

    it "non_escaping = false clears the current-scope lifetime" do
      sym = fresh
      sym.mark_non_escaping!
      sym.clear_non_escaping!
      expect(sym.lifetime).to eq([])
      expect(sym.non_escaping).to be(false)
    end

    it "lifetime = :current_scope is observed by non_escaping" do
      sym = fresh
      sym.lifetime = :current_scope
      expect(sym.non_escaping).to be(true)
    end

    it "lifetime_sources returns [self] for current-scope lifetime" do
      sym = fresh
      sym.lifetime = :current_scope
      expect(sym.lifetime_sources).to eq([sym])
    end

    it "dups binding flow facts independently for branch scopes" do
      parent = fresh
      child = parent.dup

      child.mark_borrowed_alias!

      expect(child.borrowed_alias).to be(true)
      expect(child.non_escaping).to be(false)
      expect(parent.borrowed_alias).to be(false)
      expect(parent.non_escaping).to be(false)
    end
  end

  describe "tied lifetime sources" do
    it "single-source form (RETURNS foo:T)" do
      # FN identity(foo: T) RETURNS foo:T -> RETURN foo; END
      # The returned value's lifetime points at `foo`. Whatever foo's
      # lifetime is, the returned value inherits it.
      foo = fresh
      retval = fresh
      retval.lifetime = SymbolEntry.tied_lifetime([foo])
      expect(retval.lifetime).to eq([foo])
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
      expect(bg.lifetime).to eq([x, y, z])
      expect(bg.lifetime_sources).to eq([x, y, z])
      expect(bg.non_escaping).to be(false)
    end

    it "tied_lifetime de-duplicates sources" do
      a = fresh
      b = fresh
      result = SymbolEntry.tied_lifetime([a, b, a])
      expect(result).to eq([a, b])
    end

    it "tied_lifetime returns an empty array for empty input (unconstrained)" do
      expect(SymbolEntry.tied_lifetime([])).to eq([])
    end

    it "non_escaping = false does NOT clobber a tied lifetime" do
      # The clear-current-scope semantic of non_escaping = false must
      # not leak into the richer tied form. Otherwise the v0.1 alias
      # would silently downgrade an M2.3-tagged BG handle to
      # unconstrained at the next non_escaping = false write.
      sym = fresh
      other = fresh
      sym.lifetime = SymbolEntry.tied_lifetime([other])
      sym.clear_non_escaping!
      expect(sym.lifetime).to eq([other])
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
