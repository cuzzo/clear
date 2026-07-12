require "rspec"
require_relative "../ruby/tools/formatter" unless defined?(Formatter::Emitter)

# Verifies that prefix calls of stdlib functions tagged as METHODs
# in std_lib.rb / POOL_METHODS / SET_METHODS / MAP_METHODS get
# rewritten to UFCS form by `clear fmt`. Complements
# spec/clear_fmt_method_spec.rb (which covers user-declared METHOD).

RSpec.describe Formatter, "stdlib METHOD UFCS rewrite" do
  def fmt(src)
    Formatter.format(src)
  end

  describe "string conversions" do
    it "rewrites toInt(s) to s.toInt()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n = toInt("42") OR_ELSE 0;
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"42".toInt()')
    end

    it "rewrites toString(n) to n.toString()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          s = toString(42);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("42.toString()")
    end

    it "rewrites toFloat(s) to s.toFloat()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          f = toFloat("3.14") OR_ELSE 0.0;
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"3.14".toFloat()')
    end
  end

  describe "string predicates and ops" do
    it "rewrites contains?(haystack, needle) to haystack.contains?(needle)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          ok = contains?("hello world", "world");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"hello world".contains?("world")')
    end

    it "rewrites startsWith?(s, prefix) to s.startsWith?(prefix)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          ok = startsWith?("hello", "he");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"hello".startsWith?("he")')
    end

    it "rewrites split(s, delim) to s.split(delim)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          parts = split("a,b,c", ",");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"a,b,c".split(",")')
    end

    it "rewrites trim(s) to s.trim()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          s = trim("  hi  ");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"  hi  ".trim()')
    end

    it "rewrites downcase(s) to s.downcase()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          s = downcase("HELLO");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('"HELLO".downcase()')
    end
  end

  describe "list operations" do
    it "rewrites length(xs) to xs.length() for lists" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = length(xs);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("xs.length()")
    end

    it "rewrites push(xs, 5) to xs.push(5)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [];
          push(xs, 5);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("xs.push(5)")
    end

    it "rewrites pop(xs) to xs.pop()" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [1];
          v = pop(xs);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("xs.pop()")
    end
  end

  describe "negative cases — FN-only stdlib stays prefix" do
    it "leaves max(a, b) in prefix form" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n = max(1, 2);
          RETURN;
        END
      CLEAR
      out = fmt(src)
      expect(out).to include("n = max(1, 2)")
      expect(out).not_to match(/1\.max/)
    end

    it "leaves min(a, b) in prefix form" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n = min(1, 2);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("n = min(1, 2)")
    end

    it "leaves abs(x) in prefix form" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n = abs(-5);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("n = abs(-5)")
    end

    it "leaves print() in prefix form (varargs, no receiver)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          print("hello");
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include('print("hello")')
    end

    it "leaves sleep(ms) in prefix form" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          sleep(100);
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("sleep(100)")
    end
  end

  describe "chain emergence" do
    it "produces a chain when nesting METHOD calls" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          s = "Hello, World";
          n = length(downcase(s));
          RETURN;
        END
      CLEAR
      expect(fmt(src)).to include("s.downcase().length()")
    end
  end

  describe "idempotence on stdlib rewrites" do
    it "fmt(fmt(s)) == fmt(s) across stdlib rewrites" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          ok = contains?(downcase("HELLO WORLD"), "world");
          RETURN;
        END
      CLEAR
      once = fmt(src)
      twice = fmt(once)
      expect(twice).to eq(once)
      expect(once).to include('"HELLO WORLD".downcase().contains?("world")')
    end
  end
end
