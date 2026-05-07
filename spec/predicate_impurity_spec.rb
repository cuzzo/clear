require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

# Coverage for the impurity-rejection paths in WITH GUARD / PRE / POST
# predicates (capabilities.rb#predicate_impurity_reason). Predicates
# must be pure: predicate-time evaluation that allocates, mutates,
# fails, suspends, or has user-fn effects could either (a) silently
# invalidate the guard (a mutating predicate races itself) or (b)
# panic / suspend at a point where the runtime can't recover.
RSpec.describe "predicate-impurity rejection" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "stdlib-call impurity inside WITH GUARD" do
    it "rejects a guard whose call allocates (e.g. `split`)" do
      # `split` returns a fresh String[] and is flagged
      # `allocates: true`. Whether the dispatch path also marks the
      # call `can_fail` (string ops with `try CheatLib.split(...)` in
      # their zig pattern do propagate `try`-ability), the impurity
      # check fires either way — the test pins behavior, not which
      # specific branch reports the reason.
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { tag: String }
          FN main() RETURNS Void ->
            b = Box{ tag: "a,b" } @shared:locked;
            WITH EXCLUSIVE b AS y GUARD y.tag.split(",")[0] == "a" {
              v = y.tag;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /must be pure.*'split'.*(allocates|can fail)/)
    end

    it "rejects a guard whose call mutates its receiver (e.g. `pop`)" do
      # `pop` returns a value AND mutates the list. allocates=0,
      # can_fail=0, mutates_receiver=1 — falls through to the last
      # impurity branch in predicate_impurity_reason.
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { items: Int64[] }
          FN main() RETURNS Void ->
            b = Box{ items: [1, 2] } @shared:locked;
            WITH EXCLUSIVE b AS y GUARD y.items.pop() > 0 {
              v = y.items;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /must be pure.*'pop' mutates its receiver/)
    end

    it "rejects a guard whose call can fail (e.g. `toInt`)" do
      # `toInt` parses a string -> Int64 and is `can_fail: true`.
      # The early call.can_fail check fires before the stdlib_def
      # block, so this exercises the top-of-method early-return.
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { tag: String }
          FN main() RETURNS Void ->
            b = Box{ tag: "1" } @shared:locked;
            WITH EXCLUSIVE b AS y GUARD y.tag.toInt() > 0 {
              v = y.tag;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /must be pure.*can fail/)
    end
  end

  describe "pure stdlib calls in a guard are accepted" do
    it "accepts a guard that calls a pure stdlib method (e.g. `length`)" do
      # `length` carries no impurity flags. predicate_impurity_reason
      # walks past every flag, falls through, and returns nil →
      # no error is raised.
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { tag: String }
          FN main() RETURNS Void ->
            b = Box{ tag: "abc" } @shared:locked;
            WITH EXCLUSIVE b AS y GUARD y.tag.length() > 0 {
              v = y.tag;
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "user-defined fn impurity" do
    it "rejects a guard whose user-fn predicate has a non-failing effect" do
      # An unbounded `WHILE TRUE` loop records the LOOP_UNBOUND
      # effect on the enclosing function without making it fallible.
      # This is the cleanest way to land in capabilities.rb:393's
      # "has effects" branch — the can_fail short-circuit at 390
      # doesn't fire.
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN spinny?(c: Counter) RETURNS Bool ->
            MUTABLE seen = FALSE;
            WHILE TRUE DO
              seen = TRUE;
              IF c.value > 0 THEN BREAK; END
            END
            RETURN seen;
          END
          FN main() RETURNS Void ->
            c = Counter{ value: 1 } @shared:locked;
            WITH EXCLUSIVE c AS y GUARD spinny?(y) {
              v = y.value;
            }
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /must be pure.*'spinny\?'.*has effects/m)
    end
  end
end

# Coverage for the structural error paths in WITH GUARD validation
# (capabilities.rb#validate_and_visit_with_guards!).
RSpec.describe "WITH GUARD structural errors" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "rejects WITH GUARD when one of multiple captures has no AS alias" do
    # Multi-binding WITH where the GUARD-bearing capture is named but
    # a sibling capture has no alias. `validate_and_visit_with_guards!`
    # rejects so guard predicates can never silently pin to an
    # unbound (and therefore unnameable) capture.
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          a = Counter{ value: 1 } @shared:locked;
          b = Counter{ value: 2 } @shared:locked;
          WITH EXCLUSIVE a, EXCLUSIVE b AS y GUARD y.value > 0 {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /WITH GUARD requires every participating binding to have an AS alias/)
  end
end

# Coverage for parser-level WITH GUARD validation (parser.rb:3124).
# The parser raises before the annotator gets a chance to see the
# malformed shape — without this test, line 3124 is uncovered.
RSpec.describe "WITH GUARD parser errors" do
  it "rejects WITH GUARD with no AS alias at the parser level" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        c = 1 @shared:locked;
        WITH EXCLUSIVE c GUARD c > 0 { v = 1; }
        RETURN;
      END
    CLEAR
    expect {
      tokens = Lexer.new(src).tokenize
      Parser.new(tokens, src).parse
    }.to raise_error(ParserError, /WITH GUARD requires an AS alias/)
  end
end
