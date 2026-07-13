require "rspec"

require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# Atomics M1.2 -- Capability sigil parsing for `@atomic`.
#
# Verifies the parser recognizes `@atomic` as a sync sigil at type-level
# (`T@shared:atomic`), composes correctly with `@shared`, participates in
# the `:` join chain, and rejects duplicate-sync joins. Type-axis +
# zig_type wiring is M1.3; lift-the-primitive-restriction is verified
# via end-to-end annotator tests (separate spec) once M1.3 lands the
# zig_type lowering.
RSpec.describe "@atomic parser" do
  def parse_type(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).send(:parse_type_annotation)
  end

  describe "type-level `T@atomic`" do
    it "parses Int64@atomic with sync == :atomic" do
      t = parse_type("Int64@atomic")
      expect(t.sync).to eq(:atomic)
      expect(t.atomic?).to be true
    end

    it "is a separate sync from :locked / :write_locked / :versioned" do
      t = parse_type("Int64@atomic")
      expect(t.locked?).to be false
      expect(t.write_locked?).to be false
      expect(t.versioned?).to be false
    end

    it "is recognized as any_sync? (participates in capability machinery)" do
      t = parse_type("Int64@atomic")
      expect(t.any_sync?).to be true
    end

    it "lowers Int64@atomic to *CheatLib.Atomic(i64)" do
      t = parse_type("Int64@atomic")
      expect(t.zig_type).to eq("*CheatLib.Atomic(i64)")
    end
  end

  describe "join chain `@shared:atomic`" do
    it "drops the Arc wrap — bare `*Atomic(Int64)` (M2.2)" do
      t = parse_type("Int64@shared:atomic")
      expect(t.shared?).to be true
      expect(t.atomic?).to be true
      expect(t.zig_type).to eq("*CheatLib.Atomic(i64)")
    end

    it "is order-independent: `@atomic:shared` parses identically" do
      a = parse_type("Int64@shared:atomic")
      b = parse_type("Int64@atomic:shared")
      expect(a.shared?).to eq(b.shared?)
      expect(a.sync).to eq(b.sync)
      expect(a.zig_type).to eq(b.zig_type)
    end
  end

  describe "duplicate / illegal joins" do
    it "rejects `@atomic:locked` (two sync capabilities)" do
      expect {
        parse_type("Counter@atomic:locked")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@atomic:versioned` (two sync capabilities)" do
      expect {
        parse_type("Counter@atomic:versioned")
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects `@locked:atomic` (two sync capabilities, reverse order)" do
      expect {
        parse_type("Counter@locked:atomic")
      }.to raise_error(/Duplicate sync/i)
    end
  end

  describe "primitive cells" do
    # The whole point of @atomic is the primitive-as-cell case. The parser
    # accepts primitive-bound atomic; the annotator's no-cap-on-primitives
    # check carves out atomic specifically. End-to-end (annotator pass)
    # behavior is covered by a separate atomic_annotator_spec once M1.3
    # lands the zig_type lowering.
    it "parser accepts Int64@shared:atomic" do
      t = parse_type("Int64@shared:atomic")
      expect(t.sync).to eq(:atomic)
      expect(t.shared?).to be true
    end

    it "parser accepts Float64@shared:atomic" do
      t = parse_type("Float64@shared:atomic")
      expect(t.sync).to eq(:atomic)
    end

    it "parser accepts Bool@shared:atomic" do
      t = parse_type("Bool@shared:atomic")
      expect(t.sync).to eq(:atomic)
    end
  end
end
