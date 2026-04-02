require "rspec"
require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe "Stack Tier Recommendations" do
  def analyze(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    fn_nodes = annotator.instance_variable_get(:@fn_nodes)
    [ast, fn_nodes]
  end

  def tier_for(source, fn_name)
    _, fn_nodes = analyze(source)
    fn_nodes[fn_name]&.stack_tier
  end

  def stack_bytes_for(source, fn_name)
    _, fn_nodes = analyze(source)
    fn_nodes[fn_name]&.stack_vars_bytes
  end

  describe "effect-based tier selection" do
    it "assigns :micro to pure functions with no effects" do
      src = <<~CLEAR
        FN add(a: Float64, b: Float64) RETURNS Float64 ->
            RETURN a + b;
        END
      CLEAR
      expect(tier_for(src, "add")).to eq(:micro)
    end

    it "assigns :standard to functions that use heap" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN make() RETURNS %Point ->
            p = Point{ x: 1.0, y: 2.0 };
            RETURN p;
        END
      CLEAR
      expect(tier_for(src, "make")).to eq(:standard)
    end

    it "assigns :large to @reentrant functions" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n"
      expect(tier_for(src, "fib")).to eq(:large)
    end

    it "assigns :standard to functions calling heap-using functions" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN make() RETURNS %Point ->
            p = Point{ x: 1.0, y: 2.0 };
            RETURN p;
        END
        FN use() RETURNS Float64 ->
            p = make();
            RETURN p.x;
        END
      CLEAR
      # use() transitively inherits HEAP from make()
      expect(tier_for(src, "use")).to eq(:standard)
    end
  end

  describe "stack variable byte tracking" do
    it "counts stack-local variable bytes" do
      src = <<~CLEAR
        FN test() RETURNS Float64 ->
            a = 1.0;
            b = 2.0;
            c = 3.0;
            RETURN a + b + c;
        END
      CLEAR
      bytes = stack_bytes_for(src, "test")
      # 3 Float64 variables = 3 * 8 = 24 bytes
      expect(bytes).to eq(24)
    end

    it "counts struct local bytes based on slot size" do
      src = <<~CLEAR
        STRUCT Vec3 { x: Float64, y: Float64, z: Float64 }
        FN test() RETURNS Float64 ->
            v = Vec3{ x: 1.0, y: 2.0, z: 3.0 };
            RETURN v.x;
        END
      CLEAR
      bytes = stack_bytes_for(src, "test")
      # Vec3 = 3 slots * 8 = 24 bytes
      expect(bytes).to eq(24)
    end

    it "does not count frame-allocated variables" do
      src = <<~CLEAR
        STRUCT Big { a: Float64[200] }
        FN test() RETURNS Float64 ->
            b = Big{ a: [0.0] };
            RETURN b.a[0];
        END
      CLEAR
      bytes = stack_bytes_for(src, "test")
      # Big has 200 slots (> 128 threshold) -> goes to frame, not stack
      expect(bytes).to eq(0)
    end

    it "promotes tier when stack vars exceed budget" do
      # Create a function with many stack-local variables that would
      # exceed the micro tier's budget (4KB / 2 = 2KB headroom)
      vars = (1..300).map { |i| "v#{i} = #{i}.0;" }.join("\n")
      sum = (1..300).map { |i| "v#{i}" }.join(" + ")
      src = <<~CLEAR
        FN heavy() RETURNS Float64 ->
            #{vars}
            RETURN #{sum};
        END
      CLEAR
      # 300 * 8 = 2400 bytes > 2048 (50% of micro's 4KB)
      # Should promote from :micro to :standard
      expect(tier_for(src, "heavy")).to eq(:standard)
    end
  end

  describe "main function" do
    it "assigns a tier to main" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            x = 42.0;
            RETURN;
        END
      CLEAR
      tier = tier_for(src, "main")
      expect(tier).not_to be_nil
    end
  end
end
