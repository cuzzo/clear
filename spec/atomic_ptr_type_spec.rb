require "rspec"

require_relative "../src/ast/type" unless defined?(Type)

# AtomicPtr M3.1 -- Type axis for `@indirect:atomic` (atomic pointer to
# a refcounted struct payload).
#
# Where M1.3's `:atomic` covers the primitive-as-cell case (Int64@atomic
# -> *CheatLib.Atomic(i64)), M3.1 adds the struct case via the new
# `:indirect` layout axis: Counter@indirect:atomic -> *CheatLib.AtomicPtr
# (Counter). The two combinations are distinct: bare Atomic(T) is single
# CAS-able machine word; AtomicPtr(T) is atomic pointer swap on a
# refcounted heap-allocated T.
#
# ClearParser sigil work (M3.2) wires `@indirect:atomic` from source through
# CapabilityWrap. Annotator combo validation (M3.4) rejects @local /
# @multiowned with @indirect:atomic, and rejects @indirect:atomic on
# primitives (use @shared:atomic instead). Runtime AtomicPtr(T) is M3.3.
RSpec.describe "Type @indirect:atomic axis (AtomicPtr M3.1)" do
  describe "predicates" do
    it "indirect? is true when layout == :indirect" do
      t = Type.new(:Counter, sync: :atomic, layout: :indirect)
      expect(t.indirect?).to be true
    end

    it "atomic? is still true when sync == :atomic + layout :indirect" do
      t = Type.new(:Counter, sync: :atomic, layout: :indirect)
      expect(t.atomic?).to be true
    end

    it "any_sync? is true for indirect:atomic (sync capability is engaged)" do
      t = Type.new(:Counter, sync: :atomic, layout: :indirect)
      expect(t.any_sync?).to be true
    end

    it "indirect? is false on a plain @atomic primitive (no layout)" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.indirect?).to be false
    end

    it "indirect? is false on plain types (no layout)" do
      expect(Type.new(:Int64).indirect?).to be false
      expect(Type.new("Counter").indirect?).to be false
    end
  end

  describe "zig_type mapping" do
    it "wraps a struct as `*CheatLib.AtomicPtr(<bare>)`" do
      t = Type.new("Counter", sync: :atomic, layout: :indirect)
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "drops the Arc wrap in @shared:indirect:atomic — same `*AtomicPtr(T)` form" do
      # `@indirect:atomic` is already heap-pinned + Arc-managed under the
      # hood. An explicit `:shared` ownership doesn't add a second Arc;
      # the AtomicPtr cell itself owns the Arc.
      t = Type.new("Counter", sync: :atomic, ownership: :shared, layout: :indirect)
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "primitive @atomic does NOT pick up the AtomicPtr lowering" do
      t = Type.new(:Int64, sync: :atomic)
      expect(t.zig_type).to eq("*CheatLib.Atomic(i64)")
    end
  end

  describe "Group 1 / Group 2 separation" do
    it "bare_data_type strips :indirect layout" do
      t = Type.new("Counter", sync: :atomic, layout: :indirect)
      bare = t.bare_data_type
      expect(bare.indirect?).to be false
      expect(bare.atomic?).to be false
      expect(bare.any_sync?).to be false
    end

    it "@shared:indirect:atomic bare_data_type strips all three axes" do
      t = Type.new("Counter", sync: :atomic, ownership: :shared, layout: :indirect)
      bare = t.bare_data_type
      expect(bare.indirect?).to be false
      expect(bare.atomic?).to be false
      expect(bare.shared?).to be false
    end
  end

  describe "provenance" do
    it "@indirect:atomic forces :heap provenance (atomic-ptr cell is heap-pinned)" do
      t = Type.new("Counter", sync: :atomic, layout: :indirect)
      expect(t.provenance).to eq(:heap)
    end

    it "preserves heap provenance after @shared added on top" do
      t = Type.new("Counter", sync: :atomic, ownership: :shared, layout: :indirect)
      expect(t.provenance).to eq(:heap)
    end
  end

  describe "copy constructor" do
    it "copies the :layout axis when constructing Type.new(other_type)" do
      orig = Type.new("Counter", sync: :atomic, layout: :indirect)
      copy = Type.new(orig)
      expect(copy.indirect?).to be true
      expect(copy.atomic?).to be true
    end
  end
end
