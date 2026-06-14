require "rspec"
require_relative "../src/tools/predicate_rewriter" unless defined?(PredicateRewriter::CompareSpan)
require_relative "../src/tools/formatter" unless defined?(Formatter::Emitter)

# Unit tests for PredicateRewriter — the source-level preprocessor
# that canonicalizes hand-written null-comparison and length-comparison
# idioms into the predicate forms `clear fmt` prefers:
#
#   x == NIL              -> x.nil?()
#   x != NIL              -> x.present?()
#   coll.length() == 0    -> coll.empty?()
#   coll.length() != 0    -> coll.any?()
#   coll.length() >  0    -> coll.any?()
#   coll.length() >= 1    -> coll.any?()
#   coll.length() <  1    -> coll.empty?()
#
# Always-true / always-false patterns (`>= 0`, `< 0`) are NOT
# rewritten — those are bugs that surface as `clear fix` warnings.

RSpec.describe PredicateRewriter do
  def rw(src)
    PredicateRewriter.rewrite(src)
  end

  def fmt(src)
    Formatter.format(src)
  end

  describe "NIL comparisons" do
    it "rewrites `x == NIL` to `x.nil?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          IF x == NIL THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("x.nil?()")
      expect(rw(src)).not_to include("x == NIL")
    end

    it "rewrites `x != NIL` to `x.present?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = 5;
          IF x != NIL THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("x.present?()")
      expect(rw(src)).not_to include("x != NIL")
    end

    it "leaves the reversed `NIL == x` form alone (RHS-only rewrite in v1)" do
      # The reversed form is rare and bounding the right operand's
      # source span without a full expression parser is unreliable.
      # Users can flip the operands and re-fmt to get the canonical
      # rewrite.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          IF NIL == x THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("NIL == x")
    end
  end

  describe "length() comparisons — empty?" do
    it "`coll.length() == 0` -> `coll.empty?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [];
          IF xs.length() == 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.empty?()")
      expect(rw(src)).not_to include("xs.length() == 0")
    end

    it "`coll.length() < 1` -> `coll.empty?()` (== 0 for non-negative length)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [];
          IF xs.length() < 1 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.empty?()")
    end

    it "`coll.length() <= 0` -> `coll.empty?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [];
          IF xs.length() <= 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.empty?()")
    end
  end

  describe "length() comparisons — any?" do
    it "`coll.length() != 0` -> `coll.any?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          IF xs.length() != 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.any?()")
    end

    it "`coll.length() > 0` -> `coll.any?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          IF xs.length() > 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.any?()")
    end

    it "`coll.length() >= 1` -> `coll.any?()`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          IF xs.length() >= 1 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.any?()")
    end
  end

  describe "always-true / always-false NOT rewritten" do
    it "leaves `coll.length() >= 0` alone (always true — clear fix flags)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [];
          IF xs.length() >= 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.length() >= 0")
    end

    it "leaves `coll.length() < 0` alone (always false — clear fix flags)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [];
          IF xs.length() < 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.length() < 0")
    end
  end

  describe "idempotence" do
    it "no-op when the source already uses canonical predicates" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          xs: Int64[] = [];
          IF x.nil?() THEN RETURN; END
          IF xs.empty?() THEN RETURN; END
          RETURN;
        END
      CLEAR
      expect(rw(src)).to eq(src)
    end

    it "fmt(fmt(src)) == fmt(src) on rewritten source" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          xs: Int64[] = [];
          IF x == NIL THEN RETURN; END
          IF xs.length() == 0 THEN RETURN; END
          RETURN;
        END
      CLEAR
      once = fmt(src)
      twice = fmt(once)
      expect(twice).to eq(once)
    end
  end

  describe "string and comment safety" do
    it "leaves NIL / length() inside strings alone" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          msg = "x == NIL means absent";
          x: ?Int64 = NIL;
          IF x == NIL THEN RETURN; END
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include('"x == NIL means absent"')
      expect(out).to include("x.nil?()")
    end

    it "leaves NIL inside line comments alone" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          # legacy: x == NIL was the old idiom
          IF x == NIL THEN RETURN; END
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("# legacy: x == NIL was the old idiom")
      expect(out).to include("x.nil?()")
    end
  end

  describe "source helper edge cases" do
    it "rewrites NIL comparisons whose left side is a function call" do
      src = <<~CLEAR
        FN maybe() RETURNS ?Int64 -> RETURN NIL; END
        FN main() RETURNS Void ->
          IF maybe() == NIL THEN RETURN; END
          RETURN;
        END
      CLEAR

      expect(rw(src)).to include("(maybe()).nil?()")
    end

    it "wraps complex predicate receivers in parentheses" do
      expect(PredicateRewriter.paren_if_needed("a + b")).to eq("(a + b)")
    end

    it "walks expressions across escaped quotes in strings" do
      source = '"a\"; not done"; tail'
      expect(PredicateRewriter.send(:walk_to_expr_end, source, 0)).to eq('"a\"; not done"'.length)
    end

    it "walks expressions across triple-quoted strings" do
      source = '"""a; b) c"""; tail'
      expect(PredicateRewriter.send(:walk_to_expr_end, source, 0)).to eq('"""a; b) c"""'.length)
    end

    it "skips comments while walking expression ends" do
      source = "value # comment with ; and )\n"
      expect(PredicateRewriter.send(:walk_to_expr_end, source, 0)).to eq("value".length)
    end

    it "stops at newlines and returns the last non-whitespace offset" do
      source = "value  \nnext"
      expect(PredicateRewriter.send(:walk_to_expr_end, source, 0)).to eq("value".length)
    end

    it "returns the expression end when the source reaches EOF" do
      expect(PredicateRewriter.send(:walk_to_expr_end, "value", 0)).to eq("value".length)
    end
  end
end
