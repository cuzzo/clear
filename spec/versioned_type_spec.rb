require "rspec"

require_relative "../src/ast/type"

# Phase L2 -- Type axis for `:versioned` (MVCC).
#
# Verifies the Type machinery accepts `:versioned` as a sync value
# and maps it to `CheatLib.Versioned(T)` in zig_type. ClearParser sigil
# support (parsing `@versioned` from source) comes in L3.
RSpec.describe "Type @versioned axis" do
  describe "predicates" do
    it "versioned? is true when sync == :versioned" do
      t = Type.new("Counter", sync: :versioned)
      expect(t.versioned?).to be true
    end

    it "any_sync? is true for :versioned (treated as a sync capability)" do
      t = Type.new("Counter", sync: :versioned)
      expect(t.any_sync?).to be true
    end

    it "is mutually exclusive with :locked / :write_locked / :always_mutable" do
      t = Type.new("Counter", sync: :versioned)
      expect(t.locked?).to be false
      expect(t.write_locked?).to be false
      # Type#always_mutable? was deleted as dead code on master; check
      # the underlying sync field directly.
      expect(t.sync).not_to eq(:always_mutable)
    end

    it "is false on plain types (no sync)" do
      expect(Type.new("Counter").versioned?).to be false
      expect(Type.new(:Int64).versioned?).to be false
    end
  end

  describe "zig_type mapping" do
    it "wraps a struct in `*CheatLib.Versioned(T)` at @ownership :affine" do
      t = Type.new("Counter", sync: :versioned)
      expect(t.zig_type).to eq("*CheatLib.Versioned(Counter)")
    end

    it "wraps a primitive (Int64) in `*CheatLib.Versioned(i64)`" do
      t = Type.new(:Int64, sync: :versioned)
      expect(t.zig_type).to eq("*CheatLib.Versioned(i64)")
    end

    it "wraps a primitive (Float64) in `*CheatLib.Versioned(f64)`" do
      t = Type.new(:Float64, sync: :versioned)
      expect(t.zig_type).to eq("*CheatLib.Versioned(f64)")
    end

    it "composes Arc<Versioned(T)> at @shared:versioned" do
      t = Type.new("Counter", sync: :versioned, ownership: :shared)
      expect(t.zig_type).to eq("CheatLib.Arc(CheatLib.Versioned(Counter))")
    end
  end

  describe "Group 1 / Group 2 separation" do
    it "bare_data_type strips :versioned (sync wrapper is composed AROUND the bare shape)" do
      t = Type.new("Counter", sync: :versioned)
      bare = t.bare_data_type
      expect(bare.versioned?).to be false
      expect(bare.any_sync?).to be false
    end

    it "@shared:versioned bare_data_type strips both axes" do
      t = Type.new("Counter", sync: :versioned, ownership: :shared)
      bare = t.bare_data_type
      expect(bare.versioned?).to be false
      expect(bare.shared?).to be false
    end
  end

  describe "provenance" do
    it "@versioned forces :heap provenance (Versioned cell needs a stable address)" do
      t = Type.new("Counter", sync: :versioned)
      expect(t.provenance).to eq(:heap)
    end
  end
end
