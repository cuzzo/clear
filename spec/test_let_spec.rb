require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

# Tranche 5 of the test framework: `LET` fixtures.
#
#   TEST Counter DO
#     LET c = Counter{ value: 0 };
#
#     TEST THAT "starts at zero" DO
#       ASSERT c.value == 0;
#     END
#   END
#
# v1 semantics:
#   - LET binds `name` in the lexical scope of every TEST THAT below it,
#     including in nested WHEN blocks.
#   - Each TEST THAT sees a fresh evaluation of the RHS — the binding
#     resets between tests automatically because each TEST THAT lowers
#     to its own Zig `test` block with its own runtime.
#   - WHEN-level LET shadows TEST-level LET of the same name.
#   - Eager evaluation (RHS evaluates at the top of every test that
#     references the name). Lazy + memoized semantics deferred.

RSpec.describe "LET fixtures" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  describe "parser" do
    it "parses TEST-level LET" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET counter = 100;
          WHEN "ctx" DO
            TEST THAT "sees counter" DO
              ASSERT counter == 100;
            END
          END
        END
      CLEAR
      tb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }
      expect(tb.lets.size).to eq(1)
      expect(tb.lets.first.name).to eq("counter")
    end

    it "parses WHEN-level LET" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            LET inner = "hello";
            TEST THAT "sees inner" DO
              ASSERT inner == "hello";
            END
          END
        END
      CLEAR
      wb = ast.statements
        .find { |s| s.is_a?(AST::TestBlock) }
        .whens.first
      expect(wb.lets.size).to eq(1)
      expect(wb.lets.first.name).to eq("inner")
    end

    it "parses multiple LETs at the same level in declaration order" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET a = 1;
          LET b = 2;
          LET c = 3;
          WHEN "ctx" DO
            TEST THAT "sees all" DO
              ASSERT a + b + c == 6;
            END
          END
        END
      CLEAR
      tb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }
      expect(tb.lets.map(&:name)).to eq(%w[a b c])
    end
  end

  describe "type-checking" do
    it "infers the LET binding's type from its RHS" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET msg = "hello";
          WHEN "ctx" DO
            TEST THAT "treats msg as String" DO
              ASSERT msg == "hello";
            END
          END
        END
      CLEAR
      expect { SemanticAnnotator.new.annotate!(ast) }.not_to raise_error
    end

    it "rejects a LET-bound name used as an undeclared field path" do
      # The LET binding `n: Int64 = 5` doesn't have a `.foo` field, so
      # `n.foo` should fail field-resolution. Validates that LET names
      # are not auto-typed as :Any.
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET n = 5;
          WHEN "ctx" DO
            TEST THAT "field on Int" DO
              ASSERT n.foo == 1;
            END
          END
        END
      CLEAR
      expect { transpile(src) }.to raise_error(CompilerError)
    end

    it "later LETs at the same level can reference earlier ones" do
      # Sibling LETs are visible left-to-right within the same level.
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET base = 10;
          LET total = base * 2;
          WHEN "ctx" DO
            TEST THAT "computed lets work" DO
              ASSERT total == 20;
            END
          END
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end
  end

  describe "MIR lowering" do
    it "injects the LET decl at the top of every TEST THAT body" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET counter = 100;
          WHEN "ctx" DO
            TEST THAT "uses counter" DO
              ASSERT counter == 100;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses counter"')
      body = zig[test_idx, 1500]
      decl_idx = body.index("counter")
      # `ASSERT counter == 100` lowers to expectEqualDeep (tranche 7).
      assert_idx = body.index("expectEqualDeep(counter, 100)") ||
                   body.index("expectEqualDeep(100, counter)")
      expect(decl_idx).not_to be_nil
      expect(assert_idx).not_to be_nil
      expect(decl_idx).to be < assert_idx
    end

    it "injects LET decls into every TEST THAT independently (per-test isolation)" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET counter = 7;
          WHEN "ctx" DO
            TEST THAT "first" DO
              ASSERT counter == 7;
            END
            TEST THAT "second" DO
              ASSERT counter == 7;
            END
          END
        END
      CLEAR
      # Each test block has its own `counter` declaration (so per-test
      # isolation is structural, not relying on Zig's shared scope).
      first_idx  = zig.index('test "Demo: ctx: first"')
      second_idx = zig.index('test "Demo: ctx: second"')
      first_body  = zig[first_idx,  second_idx - first_idx]
      second_body = zig[second_idx, 1500]
      expect(first_body).to  match(/counter\s*[:=]/)
      expect(second_body).to match(/counter\s*[:=]/)
    end
  end

  describe "lazy semantics — RSpec parity" do
    it "does NOT emit a LET decl for tests that don't reference it" do
      # The killer property of RSpec's `let`: if a test doesn't
      # reference the fixture, the RHS never evaluates. CLEAR
      # achieves this at compile time by walking the test body for
      # references and only emitting referenced LETs.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET used_one = 100;
          LET unused_one = 999;
          WHEN "ctx" DO
            TEST THAT "uses only one" DO
              ASSERT used_one == 100;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses only one"')
      body = zig[test_idx, 1500]
      expect(body).to include("used_one")
      expect(body).not_to include("unused_one")
      expect(body).not_to include("999")
    end

    it "still emits the LET decl for tests that DO reference it" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET val = 42;
          WHEN "ctx" DO
            TEST THAT "uses val" DO
              ASSERT val == 42;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses val"')
      body = zig[test_idx, 1500]
      expect(body).to include("val")
      expect(body).to include("42")
    end

    it "transitively pulls in LETs whose RHS references other LETs" do
      # `LET total = base * 2;` references `base`, so a test that uses
      # `total` also needs `base` declared even though the test body
      # never names `base` directly.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET base = 10;
          LET total = base * 2;
          LET unrelated = 999;
          WHEN "ctx" DO
            TEST THAT "uses total" DO
              ASSERT total == 20;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses total"')
      body = zig[test_idx, 1500]
      expect(body).to include("base")
      expect(body).to include("total")
      expect(body).not_to include("unrelated")
      expect(body).not_to include("999")
    end

    it "preserves declaration order in the emitted Zig" do
      # `total` references `base`, so `base` must be declared first
      # in the emitted Zig (otherwise the `total = base * 2;` decl
      # would reference an undeclared name).
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET base = 10;
          LET total = base * 2;
          WHEN "ctx" DO
            TEST THAT "uses total" DO
              ASSERT total == 20;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses total"')
      body = zig[test_idx, 1500]
      base_idx  = body.index("const base = 10")
      total_idx = body.index("const total =")
      expect(base_idx).not_to be_nil
      expect(total_idx).not_to be_nil
      expect(base_idx).to be < total_idx
    end

    it "skips a LET that ONLY a hook references but the body doesn't" do
      # Conservative: hook bodies count as "referencing" since they
      # run as part of every test. So a hook-referenced LET is
      # emitted even if the body never names it.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET hook_only = 7;
          WHEN "ctx" DO
            BEFORE EACH DO
              ASSERT hook_only == 7;
            END
            TEST THAT "body unaware of hook_only" DO
              ASSERT 1 == 1;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: body unaware of hook_only"')
      body = zig[test_idx, 1500]
      expect(body).to include("hook_only")
    end
  end

  describe "shadowing" do
    it "WHEN-level LET overrides TEST-level LET of the same name" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET val = 1;
          WHEN "outer" DO
            TEST THAT "sees outer" DO
              ASSERT val == 1;
            END
          END
          WHEN "inner override" DO
            LET val = 99;
            TEST THAT "sees inner" DO
              ASSERT val == 99;
            END
          END
        END
      CLEAR
      # Only ONE `val` declaration per test body — no Zig redeclaration.
      first  = zig.index('test "Demo: outer: sees outer"')
      second = zig.index('test "Demo: inner override: sees inner"')
      first_body  = zig[first, second - first]
      second_body = zig[second, 1500]
      # Outer test compares against 1; inner against 99. Each body only
      # declares `val` once.
      expect(first_body.scan(/\bval\b/).size).to be > 0
      expect(second_body.scan(/\bval\b/).size).to be > 0
      # `ASSERT val == 1` / `ASSERT val == 99` lower to expectEqualDeep
      # (tranche 7); each body's expected-side carries the WHEN's
      # shadowed value.
      expect(first_body).to include("expectEqualDeep(val, 1)")
      expect(second_body).to include("expectEqualDeep(val, 99)")
    end
  end

  describe "interaction with hooks" do
    it "BEFORE EACH bodies can reference LET names" do
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET threshold = 10;
          WHEN "ctx" DO
            BEFORE EACH DO
              ASSERT threshold == 10;
            END
            TEST THAT "demo" DO
              ASSERT threshold == 10;
            END
          END
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end

    it "AFTER EACH bodies can reference LET names" do
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          LET sentinel = 42;
          WHEN "ctx" DO
            AFTER EACH DO
              ASSERT sentinel == 42;
            END
            TEST THAT "demo" DO
              ASSERT sentinel == 42;
            END
          END
        END
      CLEAR
      expect { transpile(src) }.not_to raise_error
    end
  end
end
