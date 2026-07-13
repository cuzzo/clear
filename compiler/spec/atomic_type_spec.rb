require "rspec"

require_relative "../ruby/ast/type" unless defined?(Type)

# Atomics M1.3 -- Type axis for `:atomic`.
#
# Verifies the Type machinery accepts `:atomic` as a sync value and
# maps it to `CheatLib.Atomic(T)` in zig_type. Mirrors the Type-level
# coverage versioned_type_spec.rb provides for `:versioned`. ClearParser
# sigil support (parsing `@atomic` from source) is M1.2; annotator
# validation that the inner T is one of {Int64, Float64, Bool} is M1.4.
RSpec.describe Type, "@atomic axis" do
  describe "predicates" do
    it "atomic? is true when sync == :atomic" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.atomic?).to be true
    end

    it "any_sync? is true for :atomic (treated as a sync capability)" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.any_sync?).to be true
    end

    it "is mutually exclusive with :locked / :write_locked / :versioned / :always_mutable" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.locked?).to be false
      expect(t.write_locked?).to be false
      expect(t.versioned?).to be false
      expect(t.sync).not_to eq(:always_mutable)
    end

    it "is false on plain types (no sync)" do
      expect(Type.new(:Int64).atomic?).to be false
      expect(Type.new("Counter").atomic?).to be false
    end
  end

  describe "zig_type mapping" do
    it "wraps Int64 in `*CheatLib.Atomic(i64)` at @ownership :affine" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.zig_type).to eq("*CheatLib.Atomic(i64)")
    end

    it "wraps Float64 in `*CheatLib.Atomic(f64)` at @ownership :affine" do
      t = Type.new(:Float64, sync: :atomic)
      expect(t.zig_type).to eq("*CheatLib.Atomic(f64)")
    end

    it "wraps Bool in `*CheatLib.Atomic(bool)` at @ownership :affine" do
      t = Type.new(:Bool, sync: :atomic)
      expect(t.zig_type).to eq("*CheatLib.Atomic(bool)")
    end

    # Atomics M2.2: dropped the Arc/Rc wrap. The M1 layout was
    # `CheatLib.Arc(CheatLib.Atomic(T))`; M2.2 collapses it to a bare
    # `*CheatLib.Atomic(T)` (heap-allocated cell, plain pointer).
    # The lifetime checker (M2.6) prevents cross-scope escape, so the
    # refcount that Arc was carrying is no longer needed.
    it "drops the Arc wrap for @shared:atomic — bare `*Atomic(Int64)` (M2.2)" do
      t = Type.new(:Int64, sync: :atomic, ownership: :shared)
      expect(t.zig_type).to eq("*CheatLib.Atomic(i64)")
    end

    it "drops the Arc wrap for @shared:atomic — bare `*Atomic(Float64)`" do
      t = Type.new(:Float64, sync: :atomic, ownership: :shared)
      expect(t.zig_type).to eq("*CheatLib.Atomic(f64)")
    end

    it "drops the Arc wrap for @shared:atomic — bare `*Atomic(Bool)`" do
      t = Type.new(:Bool, sync: :atomic, ownership: :shared)
      expect(t.zig_type).to eq("*CheatLib.Atomic(bool)")
    end
  end

  describe "Group 1 / Group 2 separation" do
    it "bare_data_type strips :atomic (sync wrapper is composed AROUND the bare shape)" do
      t = Type.new(:Int64, sync: :atomic)
      bare = t.bare_data_type
      expect(bare.atomic?).to be false
      expect(bare.any_sync?).to be false
    end

    it "@shared:atomic bare_data_type strips both axes" do
      t = Type.new(:Int64, sync: :atomic, ownership: :shared)
      bare = t.bare_data_type
      expect(bare.atomic?).to be false
      expect(bare.shared?).to be false
    end
  end

  describe "provenance" do
    it "@atomic forces :heap provenance (cache-line-aligned, stable address)" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.provenance).to eq(:heap)
    end
  end
end
