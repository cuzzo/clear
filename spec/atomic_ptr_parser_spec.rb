require "rspec"

require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"

# AtomicPtr M3.2 -- Capability sigil parsing for `@indirect:atomic`.
#
# Verifies the parser recognizes the `@indirect:atomic` sigil chain
# at type-level (`T@indirect:atomic`), composes correctly with
# `@shared`, participates in the `:` join chain, and rejects
# combinations that conflict with M2's already-established sync
# duplication / primitive carve-out rules. End-to-end annotator
# behavior (no @local / @multiowned, struct-only) is M3.4.
RSpec.describe "@indirect:atomic parser (M3.2)" do
  def parse_type(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).send(:parse_type_annotation)
  end

  describe "type-level `T@indirect:atomic`" do
    it "parses Counter@indirect:atomic with sync == :atomic and layout == :indirect" do
      t = parse_type("Counter@indirect:atomic")
      expect(t.sync).to eq(:atomic)
      expect(t.layout).to eq(:indirect)
    end

    it "atomic? AND indirect? both true on the produced Type" do
      t = parse_type("Counter@indirect:atomic")
      expect(t.atomic?).to be true
      expect(t.indirect?).to be true
    end

    it "is recognized as any_sync? (participates in capability machinery)" do
      t = parse_type("Counter@indirect:atomic")
      expect(t.any_sync?).to be true
    end

    it "lowers Counter@indirect:atomic to *CheatLib.AtomicPtr(Counter)" do
      t = parse_type("Counter@indirect:atomic")
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "@indirect:atomic forces :heap provenance" do
      t = parse_type("Counter@indirect:atomic")
      expect(t.provenance).to eq(:heap)
    end
  end

  describe "order independence in the sigil chain" do
    it "@atomic:indirect parses identically to @indirect:atomic" do
      a = parse_type("Counter@indirect:atomic")
      b = parse_type("Counter@atomic:indirect")
      expect(a.sync).to eq(b.sync)
      expect(a.layout).to eq(b.layout)
      expect(a.zig_type).to eq(b.zig_type)
    end
  end

  describe "composition with @shared" do
    it "@shared:indirect:atomic preserves the bare *AtomicPtr(T) form (no double Arc)" do
      t = parse_type("Counter@shared:indirect:atomic")
      expect(t.shared?).to be true
      expect(t.atomic?).to be true
      expect(t.indirect?).to be true
      expect(t.zig_type).to eq("*CheatLib.AtomicPtr(Counter)")
    end

    it "all three orderings of @shared:indirect:atomic produce equivalent Types" do
      a = parse_type("Counter@shared:indirect:atomic")
      b = parse_type("Counter@indirect:shared:atomic")
      c = parse_type("Counter@atomic:indirect:shared")
      expect(a.zig_type).to eq(b.zig_type)
      expect(b.zig_type).to eq(c.zig_type)
      expect(a.sync).to eq(b.sync)
      expect(a.layout).to eq(b.layout)
      expect(a.ownership).to eq(b.ownership)
    end
  end

  describe "duplicate / illegal joins" do
    it "rejects `@indirect:atomic:locked` (atomic + lock-sync collision)" do
      expect {
        parse_type("Counter@indirect:atomic:locked")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@indirect:atomic:versioned` (atomic + versioned-sync collision)" do
      expect {
        parse_type("Counter@indirect:atomic:versioned")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@indirect:indirect` (duplicate layout)" do
      expect {
        parse_type("Counter@indirect:indirect")
      }.to raise_error(/Duplicate layout/i)
    end
  end
end
