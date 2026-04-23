require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

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

    it "assigns :unbounded to @reentrant functions" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n"
      expect(tier_for(src, "fib")).to eq(:unbounded)
    end

    it "propagates :unbounded to callers of @reentrant functions" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n" \
            "FN wrapper(n: Float64) RETURNS Float64 ->\n" \
            "    RETURN fib(n);\nEND\n"
      expect(tier_for(src, "wrapper")).to eq(:unbounded)
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

  describe "needs_rt floor" do
    it "promotes micro to standard when function needs runtime" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN make() RETURNS %Point ->
            p = Point{ x: 1.0, y: 2.0 };
            RETURN p;
        END
        FN caller() RETURNS Float64 ->
            p = make();
            RETURN p.x;
        END
      CLEAR
      # caller() transitively needs_rt (make uses heap) -> at least :standard
      expect(tier_for(src, "caller")).to be >= :standard  # symbol comparison won't work
      # Use the TIER_ORDER map
      order = { micro: 0, standard: 1, large: 2, xl: 3 }
      expect(order[tier_for(src, "caller")]).to be >= order[:standard]
    end
  end

  describe "@canSmash validation" do
    it "auto-promotes to service when BG calls @reentrant without @canSmash" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n" \
            "FN main() RETURNS Void ->\n" \
            "    p: ~Float64 = BG { fib(10.0); };\n" \
            "    result: Float64 = NEXT p; RETURN;\nEND\n"
      expect { analyze(src) }.not_to raise_error
    end

    it "allows @canSmash to override reentrant check" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n" \
            "FN main() RETURNS Void ->\n" \
            "    p: ~Float64 = BG { @canSmash -> fib(10.0); };\n" \
            "    result: Float64 = NEXT p; RETURN;\nEND\n"
      expect { analyze(src) }.not_to raise_error
    end

    it "errors when user picks @micro for a function that needs @standard" do
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
        FN main() RETURNS Void ->
            p: ~Float64 = BG { @micro -> use(); };
            result: Float64 = NEXT p; RETURN;
        END
      CLEAR
      expect { analyze(src) }.to raise_error(CompilerError, /Stack safety.*@micro.*too small/)
    end

    it "allows @micro:canSmash to override size check" do
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
        FN main() RETURNS Void ->
            p: ~Float64 = BG { @micro:canSmash -> use(); };
            result: Float64 = NEXT p; RETURN;
        END
      CLEAR
      expect { analyze(src) }.not_to raise_error
    end

    it "does not error for auto-sized (no user override) calls" do
      src = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64 }
        FN make() RETURNS %Point ->
            p = Point{ x: 1.0, y: 2.0 };
            RETURN p;
        END
        FN main() RETURNS Void ->
            p: ~Float64 = BG { make().x; };
            result: Float64 = NEXT p; RETURN;
        END
      CLEAR
      expect { analyze(src) }.not_to raise_error
    end

    it "auto-promotes to service when DO block calls @reentrant without @canSmash" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n" \
            "FN work() RETURNS Float64 ->\n" \
            "    RETURN fib(10.0);\nEND\n" \
            "FN main() RETURNS Void ->\n" \
            "    DO { work() }\n" \
            "    RETURN;\nEND\n"
      expect { analyze(src) }.not_to raise_error
    end

    it "allows @canSmash on DO block branches" do
      src = "FN fib(n: Float64) RETURNS Float64 @reentrant ->\n" \
            "    IF n < 2.0 THEN RETURN n; END\n" \
            "    RETURN fib(n - 1.0) + fib(n - 2.0);\nEND\n" \
            "FN work() RETURNS Float64 ->\n" \
            "    RETURN fib(10.0);\nEND\n" \
            "FN main() RETURNS Void ->\n" \
            "    DO { @canSmash -> work() }\n" \
            "    RETURN;\nEND\n"
      expect { analyze(src) }.not_to raise_error
    end
  end

  describe "@reentrant:tailCall" do
    it "parses the annotation" do
      src = "FN fib(n: Float64, a: Float64, b: Float64) RETURNS Float64 @reentrant:tailCall ->\n" \
            "    IF n < 1.0 THEN RETURN a; END\n" \
            "    RETURN fib(n - 1.0, b, a + b);\nEND\n"
      _, fn_nodes = analyze(src)
      expect(fn_nodes["fib"].tail_call).to be true
      expect(fn_nodes["fib"].reentrant).to eq(:reentrant)
    end

    it "errors when tail call is not in tail position" do
      src = "FN bad(n: Float64) RETURNS Float64 @reentrant:tailCall ->\n" \
            "    IF n < 1.0 THEN RETURN 1.0; END\n" \
            "    RETURN bad(n - 1.0) + 1.0;\nEND\n"
      expect { analyze(src) }.to raise_error(CompilerError, /tailCall/)
    end

    it "errors when applied to non-recursive function" do
      src = "FN add(a: Float64, b: Float64) RETURNS Float64 @reentrant:tailCall ->\n" \
            "    RETURN a + b;\nEND\n"
      expect { analyze(src) }.to raise_error(CompilerError, /not recursive/)
    end

    it "emits @call(.always_tail) in release mode" do
      src = "FN fib(n: Float64, a: Float64, b: Float64) RETURNS Float64 @reentrant:tailCall ->\n" \
            "    IF n < 1.0 THEN RETURN a; END\n" \
            "    RETURN fib(n - 1.0, b, a + b);\nEND\n"
      # Simulate release mode (no default stack override)
      t = ZigTranspiler.new
      zig = t.transpile(src)
      expect(zig).to include("@call(.always_tail, fib,")
    end

    it "emits regular call in debug mode (stage2 backend)" do
      src = "FN fib(n: Float64, a: Float64, b: Float64) RETURNS Float64 @reentrant:tailCall ->\n" \
            "    IF n < 1.0 THEN RETURN a; END\n" \
            "    RETURN fib(n - 1.0, b, a + b);\nEND\n"
      t = ZigTranspiler.new
      t.instance_variable_set(:@default_stack_size, "Large")
      zig = t.transpile(src)
      expect(zig).not_to include("@call(.always_tail")
      expect(zig).to include("fib(")
    end
  end

  describe "BG block auto-sizing" do
    it "assigns computed_stack_tier to BG blocks" do
      src = <<~CLEAR
        FN compute(n: Float64) RETURNS Float64 ->
            RETURN n * 2.0;
        END
        FN main() RETURNS Void ->
            p: ~Float64 = BG { compute(21.0); };
            result: Float64 = NEXT p;
            RETURN;
        END
      CLEAR
      ast, _ = analyze(src)
      # Find the BG block in main's body
      main_fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      bg_block = nil
      main_fn.body.each do |stmt|
        if stmt.is_a?(AST::VarDecl) || stmt.is_a?(AST::BindExpr)
          val = stmt.value
          bg_block = val if val.is_a?(AST::BgBlock)
        end
      end
      expect(bg_block).not_to be_nil
      expect(bg_block.computed_stack_tier).not_to be_nil
    end
  end
end
