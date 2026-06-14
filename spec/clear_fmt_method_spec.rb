require "rspec"
require_relative "../src/tools/formatter" unless defined?(Formatter::Emitter)

# End-to-end: METHOD-flagged FNs have their prefix call sites
# rewritten to UFCS form when running through `Formatter.format`.
# The MethodRewriter unit suite (spec/method_rewriter_spec.rb) covers
# the rewrite logic in isolation; this file pins the integration:
# fmt is idempotent, preserves whitespace canonicalization, and the
# rewrite composes cleanly with the existing formatter passes.

RSpec.describe Formatter, "METHOD UFCS rewrite" do
  def fmt(src)
    Formatter.format(src)
  end

  it "rewrites a single-arg METHOD call site to UFCS" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        n = length(xs);
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to include("n = xs.length();")
    expect(out).not_to match(/n = length\(xs\)/)
  end

  it "leaves FN calls in prefix form" do
    src = <<~CLEAR
      FN add(a: Int64, b: Int64) RETURNS Int64 ->
        RETURN a + b;
      END

      FN main() RETURNS Void ->
        n = add(1, 2);
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to include("n = add(1, 2);")
  end

  it "rewrites multi-arg METHOD calls preserving arg order" do
    src = <<~CLEAR
      METHOD insertAt(MUTABLE xs: Int64[], idx: Int64, x: Int64) RETURNS Void ->
        RETURN;
      END

      FN main() RETURNS Void ->
        MUTABLE xs: Int64[] = [];
        insertAt(xs, 0, 42);
        RETURN;
      END
    CLEAR

    expect(fmt(src)).to include("xs.insertAt(0, 42);")
  end

  it "produces a method chain from nested METHOD calls" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      METHOD reversed(xs: Int64[]) RETURNS Int64[] ->
        RETURN xs;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        n = length(reversed(xs));
        RETURN;
      END
    CLEAR

    expect(fmt(src)).to include("n = xs.reversed().length();")
  end

  it "leaves pipelines alone" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        n = xs |> length;
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to match(/xs \|> length/)
  end

  it "leaves already-UFCS calls in UFCS form (idempotent)" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        n = xs.length();
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to include("n = xs.length();")
    # And running fmt again produces the same output
    expect(fmt(out)).to eq(out)
  end

  it "fmt(fmt(rewritten)) == fmt(rewritten) — idempotent on a rewrite" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        n = length(xs);
        RETURN;
      END
    CLEAR

    once = fmt(src)
    twice = fmt(once)
    expect(twice).to eq(once)
  end

  it "preserves comments around rewritten calls" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1, 2, 3];
        # comment about length
        n = length(xs);
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to include("# comment about length")
    expect(out).to include("n = xs.length();")
  end

  it "doesn't rewrite METHOD names that appear inside string literals" do
    src = <<~CLEAR
      METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1];
        msg = "length(xs) inside string";
        n = length(xs);
        RETURN;
      END
    CLEAR

    out = fmt(src)
    expect(out).to include('"length(xs) inside string"')
    expect(out).to include("n = xs.length();")
  end

  it "handles PUB METHOD declarations" do
    src = <<~CLEAR
      PUB METHOD length(xs: Any[]) RETURNS Int64 ->
        RETURN 0;
      END

      FN main() RETURNS Void ->
        xs: Int64[] = [1];
        n = length(xs);
        RETURN;
      END
    CLEAR

    expect(fmt(src)).to include("n = xs.length();")
  end
end
