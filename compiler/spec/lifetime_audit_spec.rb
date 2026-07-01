require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# Atomics M2.6: lifetime escape audit matrix from
# docs/agents/atomics.md §8. Every cell has a POSITIVE case (the
# escape is safe; must compile) and a NEGATIVE case (the escape
# outlives the source's scope; must error with a clear diagnostic).
#
# The test vehicle is an atomic-captured BG handle (`bg`'s lifetime
# is tied to the captured `counter`), but each cell validates the
# lifetime checker IN GENERAL — a bug found here surfaces for any
# tied-lifetime binding (atomic-BG today, RETURNS-foo:T returns,
# multi-source returns from M2.5).
RSpec.describe "Lifetime escape audit matrix (M2.6)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  # ── Function escape (RETURN bg) ──────────────────────────────

  describe "RETURN bg escapes the function scope" do
    it "POS: declared `RETURNS counter:T` accepts" do
      # The `counter` param flows through the BG capture; the BG handle's
      # lifetime is `[counter]`, and the function's `RETURNS counter:~Void`
      # propagates that lifetime to the caller -- legal.
      expect {
        annotate(<<~CLEAR)
          FN spawn_bumper(counter: Int64) RETURNS counter:~Void
            REQUIRES counter: ATOMIC
          ->
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end

    it "NEG: no `RETURNS x:T` annotation errors" do
      expect {
        annotate(<<~CLEAR)
          FN make_handle() RETURNS ~Void ->
            MUTABLE counter: Int64 = 0 @shared:atomic;
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END

          FN main() RETURNS Void ->
            bg = make_handle();
            NEXT bg;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*tied to/i)
    end

    it "NEG: `RETURNS y:T` for the wrong param errors" do
      expect {
        annotate(<<~CLEAR)
          FN make_handle(other: Int64) RETURNS other:~Void
            REQUIRES other: ATOMIC
          ->
            MUTABLE counter: Int64 = 0 @shared:atomic;
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END

          FN main() RETURNS Void ->
            MUTABLE o: Int64 = 0 @shared:atomic;
            bg = make_handle(o);
            NEXT bg;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*tied to/i)
    end

    it "POS: wildcard `RETURNS *:T` accepts (with informational note at the decl)" do
      expect {
        annotate(<<~CLEAR)
          FN make_handle(counter: Int64) RETURNS *:~Void
            REQUIRES counter: ATOMIC
          ->
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end

    # NEG: `RETURN COPY bg` does NOT break the tied lifetime.
    # Originally written speculatively as POS for "M2.7+" but the
    # premise was wrong: COPY heap-dupes the BG handle's struct, but
    # the spawned BG fiber that captures `counter` is the same fiber
    # regardless of how many copies of the handle exist. Returning
    # the COPY is just as unsafe as returning the original -- the
    # fiber's captured `counter` reference still outlives the local
    # `counter` binding when the function returns. CLEAR's existing
    # behavior (the Promise-must-be-consumed check fires on the
    # original `bg`, plus the lifetime-tie check would fire on the
    # COPY result if the consumption check didn't get there first)
    # correctly rejects this pattern.
    it "NEG: `RETURN COPY bg` doesn't break the tied lifetime" do
      expect {
        annotate(<<~CLEAR)
          FN make_handle() RETURNS ~Void ->
            MUTABLE counter: Int64 = 0 @shared:atomic;
            bg = BG { v = counter; print(v.toString()); };
            RETURN COPY bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /Promise.*must be consumed|Lifetime Error/i)
    end
  end

  # ── Multi-source RETURN (the user-flagged partial-match case) ─

  describe "RETURN bg from a multi-source-tied BG" do
    it "POS: `RETURNS (a, b):T` accepts when bg ties to a OR b" do
      expect {
        annotate(<<~CLEAR)
          FN spawn(a: Int64, b: Int64) RETURNS (a, b):~Void
            REQUIRES a: ATOMIC, b: ATOMIC
          ->
            bg = BG { x = a; y = b; print(x.toString()); print(y.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end

    it "NEG: `RETURNS (a, b):T` declared but bg ties to neither (a third source)" do
      expect {
        annotate(<<~CLEAR)
          FN spawn(a: Int64, b: Int64, c: Int64) RETURNS (a, b):~Void
            REQUIRES a: ATOMIC, b: ATOMIC, c: ATOMIC
          ->
            bg = BG { x = c; print(x.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*tied to/i)
    end
  end

  describe "function return lifetime declarations" do
    it "rejects mutable borrowed return sources unless the argument is restricted" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { value: Int64 }
          FN borrow!(MUTABLE box: Box) RETURNS box:Box ->
            RETURN box;
          END
          FN main() RETURNS Void ->
            MUTABLE b = Box{ value: 1 };
            got = borrow!(b);
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /must be passed from a RESTRICT binding|mutable.*RESTRICT/i)
    end

    it "rejects returned lifetimes with ambiguous atomic and lock families" do
      expect {
        annotate(<<~CLEAR)
          FN mixed(x: Int64) RETURNS x:Int64
            REQUIRES x: ATOMIC | LOCKED
          ->
            RETURN x;
          END
        CLEAR
      }.to raise_error(CompilerError, /RETURNS x:T.*ATOMIC|ATOMIC.*RETURNS x:T/i)
    end

    it "allows mutable arguments that are not returned lifetime sources" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { value: Int64 }
          FN pass!(MUTABLE scratch: Box, source: Box) RETURNS source:Box ->
            RETURN source;
          END
          FN main() RETURNS Void ->
            MUTABLE a = Box{ value: 1 };
            b = Box{ value: 2 };
            got = pass!(a, b);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "applies wildcard return lifetimes to mutable parameters" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Box { value: Int64 }
          FN pass!(MUTABLE source: Box) RETURNS *:Box ->
            RETURN source;
          END
          FN main() RETURNS Void ->
            MUTABLE a = Box{ value: 1 };
            WITH RESTRICT a AS MUTABLE source {
              got = pass!(source);
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts non-atomic multi-family lifetime requirements" do
      fn = AST::FunctionDef.allocate
      allow(fn).to receive(:respond_to?).with(:requires).and_return(true)
      allow(fn).to receive(:requires).and_return({ "x" => Set[:LOCKED, :VERSIONED] })
      allow(fn).to receive(:name).and_return("locked")
      source = AST::Identifier.new(Lexer::Token.new(:IDENTIFIER, "x", 1, 1), "x")

      expect {
        SemanticAnnotator.new.send(:verify_no_mixed_atomic_returned_lifetime!, fn, [source])
      }.not_to raise_error
    end
  end

  # ── Direct assignment (struct field / index store) ───────────

  describe "a.field = bg (struct field assign)" do
    it "POS: same-scope struct accepts the BG handle" do
      # The struct `slot` and the BG handle's source `counter` are both
      # declared in main's scope (depth 1). Assigning bg into slot.bg is
      # safe because slot's scope_depth >= counter's scope_depth.
      expect {
        annotate(<<~CLEAR)
          STRUCT Slot { bg: ~Void }
          FN main() RETURNS Void ->
            MUTABLE counter: Int64 = 0 @shared:atomic;
            bg = BG { v = counter; print(v.toString()); };
            MUTABLE slot = Slot{ bg: bg };
            NEXT slot.bg;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "NEG: assigning bg into a struct field whose binding is at a SHALLOWER scope errors" do
      # `slot.next_bg` is declared in the OUTER fn scope (depth 1), but
      # the source binding `counter` is declared INSIDE the IF branch
      # (depth 2). Storing `bg` (tied to counter) into `slot.next_bg`
      # would make the BG outlive its source — error.
      expect {
        annotate(<<~CLEAR)
          STRUCT Slot { val: Int64 }
          FN main() RETURNS Void ->
            MUTABLE slot = Slot{ val: 0 };
            IF TRUE THEN
              MUTABLE counter: Int64 = 0 @shared:atomic;
              bg = BG { v = counter; print(v.toString()); };
              slot.val = counter;
              slot.val = bg;
            END
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Lifetime Error.*outlives the source/i)
    end
  end

  # ── Indexed assignment (arr[i] = bg) ─────────────────────────
  #
  # The lifetime check is wired at visit_Assignment uniformly, so it
  # fires for `arr[i] = bg` too (indexed assign dispatches AFTER the
  # check). Explicit indexed-assign POS/NEG fixtures are deferred:
  # the existing ~Void[N] init / array-literal-of-promise syntax
  # forces every slot to immediately have a NEXT'd promise, which
  # tangles with the "Promise must be consumed" check before the
  # lifetime check gets to fire. M2.7+ will revisit once the
  # ~Void-slot init shape is clearer.

  # ── No-op cases ──────────────────────────────────────────────

  describe "non-tied bindings flow freely" do
    it "POS: pure-compute BG (no captures) returns without annotation" do
      expect {
        annotate(<<~CLEAR)
          FN make() RETURNS ~Int64 ->
            bg = BG { 2 + 2; };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end

    it "POS: BG capturing only plain @shared (Arc-refcounted) returns without annotation" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN make() RETURNS ~Void ->
            c = C{ v: 0 } @shared;
            bg = BG { x = c.v; print(x.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
