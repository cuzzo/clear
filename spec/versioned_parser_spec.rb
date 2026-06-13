require "rspec"

require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# Phase L3 -- Capability sigil parsing for `@versioned`.
#
# Verifies the parser recognizes `@versioned` as a sync sigil at
# both type-level (`T@versioned`) and expression-level
# (`expr @versioned`), composes correctly with `@shared` (giving
# Arc<Versioned(T)>), participates in the `:` join chain, and rejects
# duplicate sync joins.
RSpec.describe "@versioned parser" do
  def parse_type(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).send(:parse_type_annotation)
  end

  def parse_full(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  describe "type-level `T@versioned`" do
    it "parses Counter@versioned with sync == :versioned" do
      t = parse_type("Counter@versioned")
      expect(t.sync).to eq(:versioned)
      expect(t.versioned?).to be true
    end

    it "is a separate sync from :locked / :write_locked" do
      t = parse_type("Counter@versioned")
      expect(t.locked?).to be false
      expect(t.write_locked?).to be false
    end

    it "is recognized as any_sync? (participates in capability machinery)" do
      t = parse_type("Counter@versioned")
      expect(t.any_sync?).to be true
    end

    it "lowers to *CheatLib.Versioned(Counter)" do
      t = parse_type("Counter@versioned")
      expect(t.zig_type).to eq("*CheatLib.Versioned(Counter)")
    end
  end

  describe "join chain `@shared:versioned`" do
    it "composes Arc<Versioned(T)>" do
      t = parse_type("Counter@shared:versioned")
      expect(t.shared?).to be true
      expect(t.versioned?).to be true
      expect(t.zig_type).to eq("CheatLib.Arc(CheatLib.Versioned(Counter))")
    end

    it "is order-independent: `@versioned:shared` parses identically" do
      a = parse_type("Counter@shared:versioned")
      b = parse_type("Counter@versioned:shared")
      expect(a.shared?).to eq(b.shared?)
      expect(a.versioned?).to eq(b.versioned?)
      expect(a.zig_type).to eq(b.zig_type)
    end
  end

  describe "duplicate-sync rejection" do
    it "rejects `@versioned:locked` (two sync wrappers in one chain)" do
      expect { parse_type("Counter@versioned:locked") }
        .to raise_error(/Duplicate sync/i)
    end

    it "rejects `@locked:versioned` (the symmetric case)" do
      expect { parse_type("Counter@locked:versioned") }
        .to raise_error(/Duplicate sync/i)
    end

    it "rejects `@versioned:writeLocked`" do
      expect { parse_type("Counter@versioned:writeLocked") }
        .to raise_error(/Duplicate sync/i)
    end

  end

  describe "primitive @versioned" do
    it "parses Int64@versioned" do
      t = parse_type("Int64@versioned")
      expect(t.versioned?).to be true
      expect(t.zig_type).to eq("*CheatLib.Versioned(i64)")
    end

    it "parses Float64@versioned" do
      t = parse_type("Float64@versioned")
      expect(t.versioned?).to be true
      expect(t.zig_type).to eq("*CheatLib.Versioned(f64)")
    end
  end

  describe "REQUIRES VERSIONED parsing (already in REQUIRES_VALID_FAMILIES)" do
    it "accepts `REQUIRES x: VERSIONED`" do
      src = <<~CLEAR
        FN tx(x: Counter@versioned) RETURNS Void REQUIRES x: VERSIONED -> RETURN; END
      CLEAR
      ast = parse_full(src)
      fn = ast.statements.first
      expect(fn.requires["x"]).to include(:VERSIONED)
    end

    it "accepts `REQUIRES x: VERSIONED | LOCKED` (polymorphic)" do
      src = <<~CLEAR
        FN poly(x: Counter@versioned) RETURNS Void REQUIRES x: VERSIONED | LOCKED -> RETURN; END
      CLEAR
      ast = parse_full(src)
      fn = ast.statements.first
      expect(fn.requires["x"]).to include(:VERSIONED, :LOCKED)
    end
  end
end
