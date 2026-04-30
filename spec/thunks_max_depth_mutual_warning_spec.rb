require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"

# F4 (Tranche 5): EFFECTS REENTRANT:MAX_DEPTH(N) on a function whose
# name appears in a @call_graph cycle silently demotes the cycle to
# `:unbounded` stack tier (2 MB :service OS thread per fiber). The
# user picked `:MAX_DEPTH` precisely to avoid that cost; the silent
# demotion defeats the choice.
#
# The compiler can't compute a precise SCC product bound today
# (Phase 5+ work), but it CAN warn the user and offer the auto-fix
# they actually have: drop the `:MAX_DEPTH(N)` and accept the
# `:service` tier explicitly. (The interactive option -- refactor
# to direct self-recursion -- is in the message text.)

RSpec.describe "EFFECTS REENTRANT:MAX_DEPTH(N) mutual-cycle warning" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate_collecting(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast) rescue nil
    FixCollector.drain.select { |f| f.category == :reentrance }
  end

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "emits a fixable warning when a :MAX_DEPTH fn is part of a mutual cycle" do
    finds = annotate_collecting(<<~CLEAR)
      FN ping(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(64) ->
        RETURN pong(n - 1_i64);
      END
      FN pong(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(64) ->
        RETURN ping(n - 1_i64);
      END
      FN main() RETURNS Void -> _ = ping(5_i64) OR EXIT "boom"; RETURN; END
    CLEAR
    relevant = finds.select { |f| f.message =~ /MAX_DEPTH.*mutual cycle/i }
    expect(relevant).not_to be_empty
    f = relevant.first
    expect(f.message).to match(/silently demoted to ':unbounded'/i)
    expect(f.message).to match(/ping.*pong|pong.*ping/i)
    expect(f.fixes.map(&:description)).to include(match(/Drop ':MAX_DEPTH\(64\)'/))
  end

  it "does NOT warn for a :MAX_DEPTH fn that is non-recursive" do
    finds = annotate_collecting(<<~CLEAR)
      FN bounded(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(64) ->
        RETURN n + 1_i64;
      END
      FN main() RETURNS Void -> _ = bounded(5_i64) OR EXIT "boom"; RETURN; END
    CLEAR
    expect(finds.select { |f| f.message =~ /MAX_DEPTH.*mutual cycle/i }).to be_empty
  end

  it "does NOT warn for a :MAX_DEPTH fn that is directly self-recursive (counter handles it)" do
    finds = annotate_collecting(<<~CLEAR)
      FN dec(n: Int64) RETURNS !Int64
        EFFECTS REENTRANT:MAX_DEPTH(64) ->
        RETURN dec(n - 1_i64);
      END
      FN main() RETURNS Void -> _ = dec(5_i64) OR EXIT "boom"; RETURN; END
    CLEAR
    expect(finds.select { |f| f.message =~ /MAX_DEPTH.*mutual cycle/i }).to be_empty
  end

  it "compiles a directly-self-recursive :MAX_DEPTH fn without firing any error" do
    # The pre-Tranche-5 annotator's `directly_recursive + :non_reentrant`
    # branch fired a stale `Use @reentrant` message for MAX_DEPTH; that
    # branch now skips reentrant_max_depth so the runtime counter path
    # is the actual source of truth.
    expect {
      annotate(<<~CLEAR)
        FN dec(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(64) ->
          RETURN dec(n - 1_i64);
        END
        FN main() RETURNS Void -> _ = dec(5_i64) OR EXIT "boom"; RETURN; END
      CLEAR
    }.not_to raise_error
  end
end
