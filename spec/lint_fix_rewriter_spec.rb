require "rspec"
require_relative "../src/tools/lint_fix_rewriter"

# Direct unit tests for LintFixRewriter — the source-level pre-pass
# that drops unused MUTABLE keywords and redundant `: Type`
# annotations during fmt. End-to-end tests through Formatter.format
# live in spec/clear_fmt_spec.rb; this file targets the rewriter
# in isolation so failures point at the right code.

RSpec.describe LintFixRewriter do
  def rw(src)
    LintFixRewriter.rewrite(src)
  end

  describe "robustness on broken source" do
    it "returns source unchanged when annotation fails" do
      # `Node{}` with a required `val` field will raise a CompilerError.
      # The rewriter must still return the source — fmt has to format
      # files with errors.
      src = <<~CLEAR
        STRUCT Node {
          val: Int64,
        }
        FN main() RETURNS Void ->
          x = Node{};
          RETURN;
        END
      CLEAR
      expect(rw(src)).to eq(src)
    end

    it "returns source unchanged on a parse error" do
      src = "FN main() RETURNS Void ->\n  garbled (\n"
      expect(rw(src)).to eq(src)
    end
  end

  describe "MUTABLE-never-reassigned drop" do
    it "drops MUTABLE on a read-but-never-reassigned binding" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 5;
          RETURN n;
        END
      CLEAR
      expect(rw(src)).to include("n = 5;")
      expect(rw(src)).not_to include("MUTABLE")
    end

    it "keeps MUTABLE when the binding is reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 5;
          n = 7;
          RETURN n;
        END
      CLEAR
      expect(rw(src)).to include("MUTABLE n = 5;")
    end
  end

  describe "redundant `: Type` annotation drop" do
    it "drops `: Int64` when assigned an integer literal" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE total: Int64 = 0;
          total = 5;
          RETURN total;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE total = 0;")
    end

    it "drops `: Float64` when assigned a float literal" do
      src = <<~CLEAR
        FN main() RETURNS Float64 ->
          MUTABLE s: Float64 = 0.0;
          s = 1.5;
          RETURN s;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE s = 0.0;")
    end

    it "drops redundant annotations even when whitespace precedes the colon" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE total   : Int64 = 0;
          total = 5;
          RETURN total;
        END
      CLEAR
      out = rw(src)
      expect(out).not_to include(": Int64")
    end

    it "keeps `: HashMap<K, V>` (decorated type)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64, Float64> = {};
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": HashMap<Int64, Float64>")
    end

    it "keeps `: Float64[]@list` (collection type)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE xs: Float64[]@list = [];
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": Float64[]@list")
    end

    it "keeps `: ?Int64` (optional)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": ?Int64")
    end
  end

  describe "safety against false-positive MUTABLE drops" do
    # The annotator's MUTABLE-never-reassigned lint doesn't propagate
    # "mutably borrowed via callee" through BG-block captures —
    # dropping MUTABLE there breaks the next compile (the param's
    # mutability check fires at the call site). Defensively skip
    # MUTABLE-drop for any binding whose name appears inside a BG
    # block until the annotator is fixed.

    it "keeps MUTABLE on a binding referenced inside a BG block" do
      src = <<~CLEAR
        FN bar(MUTABLE xs: Int64[]) RETURNS Void ->
          xs.append(1);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE arr: Int64[] = [1_i64, 2_i64];
          MUTABLE tasks: ~Void[]@list = [];
          tasks.append(BG { bar(arr); });
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE arr")
    end

    it "drops MUTABLE normally on bindings NOT referenced inside any BG block" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 42;
          RETURN n;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = 42;")
      expect(out).not_to include("MUTABLE")
    end

    it "keeps MUTABLE when the binding is passed to a bang helper" do
      src = <<~CLEAR
        FN appendOne!(MUTABLE xs: Int64[]@list) RETURNS Void ->
          xs.append(1_i64);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          appendOne!(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE xs: Int64[]@list = []")
    end
  end

  describe "redundant `: Type` annotation drop — sync awareness" do
    # `String@raw` and `String` resolve to the same base type but use
    # different indexing (byte vs UTF-8 codepoint). Dropping
    # `: String@raw` silently changes semantics. The rewriter's
    # decoration check uses `#sync` directly rather than `any_sync?`
    # (the latter excludes `:raw` since it's a data-access mode).

    it "keeps `: String@raw` annotation (sync stamp = decoration)" do
      src = <<~CLEAR
        FN tcpRead(fd: Int64) RETURNS String@raw ->
          RETURN "hi";
        END
        FN main() RETURNS Void ->
          data: String@raw = tcpRead(0_i64);
          print(data);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": String@raw")
    end
  end

  describe "both rules combined" do
    it "drops MUTABLE AND `: Type` independently when both apply" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n: Int64 = 5;
          RETURN n;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = 5;")
      expect(out).not_to include("MUTABLE")
      expect(out).not_to include(": Int64")
    end
  end

  describe ".to_type" do
    it "returns nil for values that cannot be coerced to a Type" do
      expect(LintFixRewriter.to_type("~~Int64")).to be_nil
    end
  end
end
