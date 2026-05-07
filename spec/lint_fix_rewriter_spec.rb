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
end
