require "rspec"
require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe "Test Framework DSL" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  describe "TEST block parsing" do
    it "parses a basic TEST/WHEN/TEST THAT structure" do
      src = <<~CLEAR
        TEST MyModule DO
          WHEN "basic" DO
            TEST THAT "works" DO
              ASSERT 1 + 1 == 2;
            END
          END
        END
      CLEAR
      ast = parse(src)
      test_block = ast.statements.first
      expect(test_block).to be_a(AST::TestBlock)
      expect(test_block.name).to eq("MyModule")
      expect(test_block.whens.size).to eq(1)
      expect(test_block.whens.first.description).to eq("basic")
      expect(test_block.whens.first.tests.size).to eq(1)
      expect(test_block.whens.first.tests.first.description).to eq("works")
    end

    it "parses setup code before WHEN blocks" do
      src = <<~CLEAR
        TEST Setup DO
          x = 42.0;
          WHEN "test" DO
            TEST THAT "uses setup" DO
              ASSERT x == 42.0;
            END
          END
        END
      CLEAR
      ast = parse(src)
      test_block = ast.statements.first
      expect(test_block.setup.size).to eq(1)
      expect(test_block.whens.size).to eq(1)
    end

    it "parses multiple WHEN blocks" do
      src = <<~CLEAR
        TEST Multi DO
          WHEN "first" DO
            TEST THAT "a" DO ASSERT TRUE; END
          END
          WHEN "second" DO
            TEST THAT "b" DO ASSERT TRUE; END
          END
        END
      CLEAR
      ast = parse(src)
      expect(ast.statements.first.whens.size).to eq(2)
    end

    it "parses multiple TEST THAT blocks in one WHEN" do
      src = <<~CLEAR
        TEST Cases DO
          WHEN "group" DO
            TEST THAT "first" DO ASSERT TRUE; END
            TEST THAT "second" DO ASSERT TRUE; END
            TEST THAT "third" DO ASSERT TRUE; END
          END
        END
      CLEAR
      ast = parse(src)
      expect(ast.statements.first.whens.first.tests.size).to eq(3)
    end

    it "parses WHEN-level setup" do
      src = <<~CLEAR
        TEST WithSetup DO
          WHEN "setup" DO
            x = 10.0;
            TEST THAT "ok" DO ASSERT x == 10.0; END
          END
        END
      CLEAR
      ast = parse(src)
      when_block = ast.statements.first.whens.first
      expect(when_block.setup.size).to eq(1)
      expect(when_block.tests.size).to eq(1)
    end
  end

  describe "ASSERT_RAISES" do
    it "parses ASSERT_RAISES Kind, expr" do
      src = <<~CLEAR
        TEST Errors DO
          WHEN "raises" DO
            TEST THAT "catches input error" DO
              ASSERT_RAISES Input, doSomething();
            END
          END
        END
      CLEAR
      ast = parse(src)
      body = ast.statements.first.whens.first.tests.first.body
      ar = body.first
      expect(ar).to be_a(AST::AssertRaises)
      expect(ar.kind).to eq("Input")
      expect(ar.error_name).to be_nil
    end
  end

  describe "BENCHMARK" do
    it "parses BENCHMARK expr x<N>" do
      src = <<~CLEAR
        TEST Perf DO
          WHEN "bench" DO
            BENCHMARK compute(42.0) x1000;
          END
        END
      CLEAR
      ast = parse(src)
      bench = ast.statements.first.whens.first.benchmarks.first
      expect(bench).to be_a(AST::BenchmarkStmt)
      expect(bench.iterations).to eq(1000)
    end

    it "defaults to 1000 iterations when no count specified" do
      src = <<~CLEAR
        TEST Perf DO
          WHEN "bench" DO
            BENCHMARK compute(42.0);
          END
        END
      CLEAR
      ast = parse(src)
      bench = ast.statements.first.whens.first.benchmarks.first
      expect(bench.iterations).to eq(1000)
    end
  end

  describe "SMASH" do
    it "parses SMASH expr" do
      src = <<~CLEAR
        TEST Smash DO
          WHEN "adversarial" DO
            SMASH process(data);
          END
        END
      CLEAR
      ast = parse(src)
      smash = ast.statements.first.whens.first.benchmarks.first
      expect(smash).to be_a(AST::SmashStmt)
    end
  end

  describe "PROFILE" do
    it "parses PROFILE expr" do
      src = <<~CLEAR
        TEST Prof DO
          WHEN "profile" DO
            PROFILE analyze(data);
          END
        END
      CLEAR
      ast = parse(src)
      prof = ast.statements.first.whens.first.benchmarks.first
      expect(prof).to be_a(AST::ProfileStmt)
    end
  end

  describe "STUB" do
    it "parses STUB fn RETURNS value" do
      src = <<~CLEAR
        TEST Stubs DO
          WHEN "io" DO
            STUB tcpRead RETURNS "data";
            TEST THAT "works" DO ASSERT TRUE; END
          END
        END
      CLEAR
      ast = parse(src)
      stub = ast.statements.first.whens.first.setup.first
      expect(stub).to be_a(AST::StubDecl)
      expect(stub.function_name).to eq("tcpRead")
      expect(stub.kind).to eq(:returns)
    end

    it "parses STUB fn CAPTURES var" do
      src = <<~CLEAR
        TEST Stubs DO
          WHEN "capture" DO
            STUB tcpWrite CAPTURES output;
            TEST THAT "works" DO ASSERT TRUE; END
          END
        END
      CLEAR
      ast = parse(src)
      stub = ast.statements.first.whens.first.setup.first
      expect(stub.kind).to eq(:captures)
      expect(stub.value).to eq("output")
    end

    it "parses STUB fn WITH lambda" do
      src = <<~CLEAR
        TEST Stubs DO
          WHEN "custom" DO
            STUB readFile WITH %(path: String) -> "mock";
            TEST THAT "works" DO ASSERT TRUE; END
          END
        END
      CLEAR
      ast = parse(src)
      stub = ast.statements.first.whens.first.setup.first
      expect(stub.kind).to eq(:with)
      expect(stub.value).to be_a(AST::LambdaLit)
    end
  end

  describe "transpilation" do
    def transpile(source, test_mode: true)
      ZigTranspiler.new.transpile(source, test_mode: test_mode)
    end

    it "generates Zig test blocks for each TEST THAT" do
      src = <<~CLEAR
        FN add(a: Float64, b: Float64) RETURNS Float64 ->
            RETURN a + b;
        END
        FN main() RETURNS Void -> RETURN; END
        TEST Math DO
          WHEN "add" DO
            TEST THAT "works" DO
              ASSERT add(1.0, 2.0) == 3.0;
            END
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include('test "Math: add: works"')
      expect(zig).to include("GeneralPurposeAllocator")
    end

    it "makes private functions pub in test mode" do
      src = <<~CLEAR
        PRIVATE FN secret() RETURNS Float64 -> RETURN 42.0; END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      zig_test = transpile(src, test_mode: true)
      zig_prod = transpile(src, test_mode: false)
      expect(zig_test).to include("pub fn secret(")
      expect(zig_prod).not_to include("pub fn secret(")
    end

    it "emits separate test blocks with setup replay" do
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END
        TEST Setup DO
          WHEN "group" DO
            TEST THAT "first" DO ASSERT TRUE; END
            TEST THAT "second" DO ASSERT TRUE; END
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include('test "Setup: group: first"')
      expect(zig).to include('test "Setup: group: second"')
      # Each test should have its own runtime init
      expect(zig.scan("GeneralPurposeAllocator").count).to be >= 2
    end
  end

  describe "STUB transpilation" do
    def transpile(source)
      ZigTranspiler.new.transpile(source, test_mode: true)
    end

    it "emits const for STUB RETURNS" do
      src = <<~CLEAR
        FN getData() RETURNS String -> RETURN "real"; END
        FN main() RETURNS Void -> RETURN; END
        TEST Stubs DO
          WHEN "returns" DO
            STUB getData RETURNS "mock";
            TEST THAT "works" DO
              result = getData();
              ASSERT result == "mock";
            END
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("__stub_getData")
      expect(zig).to include('"mock"')
    end

    it "emits counter for STUB CAPTURES" do
      src = <<~CLEAR
        FN send(msg: String) RETURNS Void -> RETURN; END
        FN main() RETURNS Void -> RETURN; END
        TEST Stubs DO
          WHEN "capture" DO
            STUB send CAPTURES count;
            TEST THAT "works" DO
              send("hi");
              ASSERT count == 1;
            END
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("var count: i64 = 0")
    end

    it "stubs are scoped to their WHEN block" do
      src = <<~CLEAR
        FN getData() RETURNS String -> RETURN "real"; END
        FN main() RETURNS Void -> RETURN; END
        TEST Scope DO
          WHEN "stubbed" DO
            STUB getData RETURNS "mock";
            TEST THAT "uses mock" DO
              ASSERT getData() == "mock";
            END
          END
          WHEN "unstubbed" DO
            TEST THAT "uses real" DO
              ASSERT getData() == "real";
            END
          END
        END
      CLEAR
      zig = transpile(src)
      # The "unstubbed" test should call the real getData, not the stub
      expect(zig).to include('test "Scope: unstubbed: uses real"')
    end
  end

  describe "BENCHMARK transpilation" do
    def transpile(source)
      ZigTranspiler.new.transpile(source, test_mode: true)
    end

    it "emits CheatLib.benchmark wrapper for BENCHMARK in test blocks" do
      src = <<~CLEAR
        FN compute(n: Float64) RETURNS Float64 ->
            RETURN n * 2.0;
        END
        FN main() RETURNS Void -> RETURN; END
        TEST Perf DO
          WHEN "bench" DO
            BENCHMARK compute(100.0) x500;
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("CheatLib.benchmark(")
      expect(zig).to include("CheatLib.printBenchmarkResult(")
      expect(zig).to include("500")
    end

    it "emits SMASH stub for SMASH in test blocks" do
      src = <<~CLEAR
        FN process(n: Float64) RETURNS Float64 -> RETURN n; END
        FN main() RETURNS Void -> RETURN; END
        TEST Smash DO
          WHEN "adversarial" DO
            SMASH process(100.0);
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("SMASH process")
    end
  end

  describe "PROFILE transpilation" do
    def transpile(source)
      ZigTranspiler.new.transpile(source, test_mode: true)
    end

    it "emits timing and alloc profiling for PROFILE" do
      src = <<~CLEAR
        FN compute(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
        FN main() RETURNS Void -> RETURN; END
        TEST Prof DO
          WHEN "profile" DO
            PROFILE compute(100.0);
          END
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include("PROFILE compute")
      expect(zig).to include("totalAllocs")
      expect(zig).to include("Timer.start")
    end
  end

  describe "keyword lexing" do
    %w[TEST THAT STUB BENCHMARK SMASH PROFILE ASSERT_RAISES CAPTURES SEQUENCE].each do |kw|
      it "lexes #{kw} as a keyword" do
        tokens = Lexer.new(kw).tokenize
        expect(tokens.first.type).to eq(:KEYWORD)
        expect(tokens.first.value).to eq(kw)
      end
    end
  end
end
