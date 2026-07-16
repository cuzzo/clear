require "rspec"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# AtomicPtr M3.2 -- Capability sigil parsing for `@boxed:atomic`.
#
# Verifies the parser recognizes the `@boxed:atomic` sigil chain
# at type-level (`T@boxed:atomic`), composes correctly with
# `@shared`, participates in the `:` join chain, and rejects
# combinations that conflict with M2's already-established sync
# duplication / primitive carve-out rules. End-to-end annotator
# behavior (no @local / @multiowned, struct-only) is M3.4.
RSpec.describe "@boxed:atomic parser (M3.2)" do
  def parse_type(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).send(:parse_type_annotation)
  end

  describe "type-level `T@boxed:atomic`" do
    it "parses Counter@boxed:atomic with sync == :atomic and layout == :indirect" do
      t = parse_type("Counter@boxed:atomic")
      expect(t.sync).to eq(:atomic)
      expect(t.layout).to eq(:indirect)
    end

    it "atomic? AND indirect? both true on the produced Type" do
      t = parse_type("Counter@boxed:atomic")
      expect(t.atomic?).to be true
      expect(t.indirect?).to be true
    end

    it "is recognized as any_sync? (participates in capability machinery)" do
      t = parse_type("Counter@boxed:atomic")
      expect(t.any_sync?).to be true
    end

    it "lowers Counter@boxed:atomic to *CheatLib.AtomicPtr(Counter)" do
      t = parse_type("Counter@boxed:atomic")
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "@boxed:atomic forces :heap provenance" do
      t = parse_type("Counter@boxed:atomic")
      expect(t.provenance).to eq(:heap)
    end
  end

  describe "order independence in the sigil chain" do
    it "@atomic:boxed parses identically to @boxed:atomic" do
      a = parse_type("Counter@boxed:atomic")
      b = parse_type("Counter@atomic:boxed")
      expect(a.sync).to eq(b.sync)
      expect(a.layout).to eq(b.layout)
      expect(a.zig_type).to eq(b.zig_type)
    end
  end

  describe "composition with @shared" do
    it "@shared:boxed:atomic preserves the bare *AtomicPtr(T) form (no double Arc)" do
      t = parse_type("Counter@shared:boxed:atomic")
      expect(t.shared?).to be true
      expect(t.atomic?).to be true
      expect(t.indirect?).to be true
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "all three orderings of @shared:boxed:atomic produce equivalent Types" do
      a = parse_type("Counter@shared:boxed:atomic")
      b = parse_type("Counter@boxed:shared:atomic")
      c = parse_type("Counter@atomic:boxed:shared")
      expect(a.zig_type).to eq(b.zig_type)
      expect(b.zig_type).to eq(c.zig_type)
      expect(a.sync).to eq(b.sync)
      expect(a.layout).to eq(b.layout)
      expect(a.ownership).to eq(b.ownership)
    end
  end

  describe "duplicate / illegal joins" do
    it "rejects `@boxed:atomic:locked` (atomic + lock-sync collision)" do
      expect {
        parse_type("Counter@boxed:atomic:locked")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@boxed:atomic:versioned` (atomic + versioned-sync collision)" do
      expect {
        parse_type("Counter@boxed:atomic:versioned")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@boxed:boxed` (duplicate layout)" do
      expect {
        parse_type("Counter@boxed:boxed")
      }.to raise_error(/Duplicate layout/i)
    end
  end
end
