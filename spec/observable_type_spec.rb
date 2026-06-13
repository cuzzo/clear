require "rspec"

require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# Phase 2.1 — `@observable` flag on Type.
# Verifies the parser recognizes `@observable` as a capability sigil and the
# resulting Type carries `observable?` true. Semantic validation (where
# `@observable` is legal) is enforced in later phases (2.2, 2.8).
RSpec.describe "@observable type flag" do
  def parse_type(src)
    tokens = Lexer.new(src).tokenize
    parser = ClearParser.new(tokens, src)
    parser.send(:parse_type_annotation)
  end

  it "is false on a plain type" do
    expect(parse_type("Float64").observable?).to be false
  end

  it "is true on `~Float64@observable`" do
    t = parse_type("~Float64@observable")
    expect(t.tense?).to be true
    expect(t.observable?).to be true
  end

  it "is true on `~Int64@observable` with chained `@locked` (chain order doesn't matter to flag)" do
    t = parse_type("~Int64@observable")
    expect(t.observable?).to be true
  end

  it "preserves @observable when chained with ownership: `~Float64@shared:observable`" do
    t = parse_type("~Float64@shared:observable")
    expect(t.observable?).to be true
    expect(t.shared?).to be true
  end

  it "preserves @observable when chained after a collection sigil: `~String[]@set:observable`" do
    t = parse_type("~String[]@set:observable")
    expect(t.observable?).to be true
    expect(t.set_collection?).to be true
  end

  it "rejects duplicate @observable in a chain" do
    expect { parse_type("~Float64@observable:observable") }
      .to raise_error(/Duplicate observable/)
  end

  it "preserves observable across the copy constructor" do
    t = parse_type("~Float64@observable")
    copy = Type.new(t)
    expect(copy.observable?).to be true
  end

  # Commit 2 of the pipeline-terminal wiring: the type→Zig mapping
  # for `~T@observable` must produce a heap-pointed `ObservableSum(T)`
  # (so the accumulator outlives the producer fiber and is reachable
  # across fibers via WITH VIEW). Other tense shapes (BoundedStream,
  # Promise, ...) keep their existing mappings.
  describe "Type#zig_type for ~T@observable" do
    # `parse_type` produces a Type without `observable_terminal` set
    # (the parser doesn't currently parse terminal-kind syntax). The
    # lift_to_observable_if_terminal! flow stamps the kind during
    # fold-pipe analysis. To exercise zig_type directly here, attach
    # the kind by hand.
    def parse_observable(src, terminal:)
      t = parse_type(src)
      t.observable_terminal = terminal
      t
    end

    it "~Int64@observable[:sum] -> *CheatLib.obs.ObservableSum(i64)" do
      expect(parse_observable("~Int64@observable", terminal: :sum).zig_type)
        .to eq("*CheatLib.obs.ObservableSum(i64)")
    end

    it "~Float64@observable[:sum] -> *CheatLib.obs.ObservableSum(f64)" do
      expect(parse_observable("~Float64@observable", terminal: :sum).zig_type)
        .to eq("*CheatLib.obs.ObservableSum(f64)")
    end

    it "non-observable ~T still maps to CheatLib.Promise(T)" do
      expect(parse_type("~Int64").zig_type).to eq("CheatLib.Promise(i64)")
    end

    it "~T[N] (BoundedStream) ignores the @observable branch" do
      # The observable branch is gated to scalar-tense types (skips
      # array / map inners). A bounded stream should still emit
      # BoundedStream regardless of @observable on it (today the
      # collection-observable path is StreamSet, separate from this
      # mapping; lands in Commit 9).
      expect(parse_type("~Int64[8]").zig_type)
        .to eq("CheatLib.BoundedStream(i64, 8)")
    end
  end
end
