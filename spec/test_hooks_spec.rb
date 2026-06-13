require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

# Tranche 3 of the test framework: BEFORE EACH / AFTER EACH /
# BEFORE ALL / AFTER ALL hooks. Hooks are valid at both TEST and
# WHEN level; lowering composes outer (TEST-level) hooks around
# inner (WHEN-level) hooks around each TEST THAT body.
#
# Execution order:
#
#   TEST::BEFORE EACH (outer-to-inner declaration order)
#     WHEN::BEFORE EACH (outer-to-inner)
#       test body
#     WHEN::AFTER EACH (defer, declared-last runs first)
#   TEST::AFTER EACH (defer, declared-last runs first)
#
# BEFORE ALL / AFTER ALL emit as standalone Zig `test` blocks ordered
# before / after the regular tests in their enclosing block. v1
# limitation: each ALL block runs in its own runtime — state isn't
# shared with TEST THATs (file-scope-var promotion deferred).

RSpec.describe "BEFORE EACH / AFTER EACH" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  describe "parser" do
    it "parses a WHEN-level BEFORE EACH hook" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            BEFORE EACH DO
              MUTABLE counter: Int64 = 0;
            END
            TEST THAT "uses counter" DO
              ASSERT counter == 0;
            END
          END
        END
      CLEAR
      when_block = ast.statements
        .find { |s| s.is_a?(AST::TestBlock) }
        .whens.first
      expect(when_block.before_each).to be_a(Array)
      expect(when_block.before_each.size).to eq(1)
    end

    it "parses a TEST-level BEFORE EACH hook" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          BEFORE EACH DO
            MUTABLE x: Int64 = 1;
          END
          WHEN "ctx" DO
            TEST THAT "uses x" DO
              ASSERT x == 1;
            END
          END
        END
      CLEAR
      test_block = ast.statements.find { |s| s.is_a?(AST::TestBlock) }
      expect(test_block.before_each.size).to eq(1)
    end

    it "parses both BEFORE and AFTER EACH" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            BEFORE EACH DO
              MUTABLE c: Int64 = 0;
            END
            AFTER EACH DO
              ASSERT c >= 0;
            END
            TEST THAT "in scope" DO
              c = c + 1;
            END
          END
        END
      CLEAR
      when_block = ast.statements
        .find { |s| s.is_a?(AST::TestBlock) }
        .whens.first
      expect(when_block.before_each.size).to eq(1)
      expect(when_block.after_each.size).to eq(1)
    end
  end

  describe "lowering — BEFORE EACH inlines into the test body" do
    it "places BEFORE EACH stmts before the test body in emitted Zig" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            BEFORE EACH DO
              MUTABLE counter: Int64 = 100;
            END
            TEST THAT "fresh counter" DO
              ASSERT counter == 100;
              counter = counter + 1;
            END
          END
        END
      CLEAR
      # The before-each `MUTABLE counter: Int64 = 100;` lowers to a
      # local declaration that must precede the assertion using it.
      test_idx = zig.index('test "Demo: ctx: fresh counter"')
      expect(test_idx).not_to be_nil
      body = zig[test_idx, 1000]
      # Mutated counter stays `var` (test reassigns counter); if it
      # weren't reassigned it would lower to `const`.
      counter_decl = body.index("var counter: i64 = 100")
      # `ASSERT counter == 100` lowers to expectEqualDeep (tranche 7).
      counter_use  = body.index("expectEqualDeep(counter, 100)")
      expect(counter_decl).not_to be_nil
      expect(counter_use).not_to be_nil
      expect(counter_decl).to be < counter_use
    end
  end

  describe "lowering — AFTER EACH wraps in defer (LIFO at exit)" do
    it "emits `defer { ... }` for each AFTER EACH body" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            AFTER EACH DO
              ASSERT 1 == 1, "after-each ran";
            END
            TEST THAT "demo" DO
              ASSERT 1 == 1;
            END
          END
        END
      CLEAR
      expect(zig).to include("defer {")
      expect(zig).to include("after-each ran")
    end

    it "registers defers AFTER the BEFORE EACH locals so the body can name them" do
      # Regression for the bug where defers got registered at the top
      # of the function before any var was declared, causing Zig to
      # complain about undeclared identifiers in the defer body.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            BEFORE EACH DO
              MUTABLE counter: Int64 = 7;
            END
            AFTER EACH DO
              ASSERT counter == 7;
            END
            TEST THAT "uses counter" DO
              ASSERT counter == 7;
              counter = counter + 1;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Demo: ctx: uses counter"')
      body = zig[test_idx, 2000]
      decl_idx  = body.index("var counter: i64 = 7")
      defer_idx = body.index("defer {")
      expect(decl_idx).not_to be_nil
      expect(defer_idx).not_to be_nil
      expect(decl_idx).to be < defer_idx
    end
  end

  describe "nesting — TEST-level outer + WHEN-level inner" do
    it "executes outer BEFORE then inner BEFORE then test then inner AFTER then outer AFTER" do
      # End-to-end execution ordering verified through Zig's runner.
      # The test body sees both `outer` and `inner` in scope; the
      # AFTER hooks see them too.
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Nested DO
          BEFORE EACH DO
            MUTABLE outer: Int64 = 1;
          END
          AFTER EACH DO
            ASSERT outer >= 1;
          END
          WHEN "with inner" DO
            BEFORE EACH DO
              MUTABLE inner: Int64 = outer + 10;
            END
            AFTER EACH DO
              ASSERT inner >= 11;
            END
            TEST THAT "both in scope" DO
              ASSERT outer == 1;
              ASSERT inner == 11;
              outer = outer + 1;
              inner = inner + 1;
            END
          END
        END
      CLEAR
      test_idx = zig.index('test "Nested: with inner: both in scope"')
      body = zig[test_idx, 3000]

      outer_decl = body.index("var outer: i64 = 1")
      inner_decl = body.index("var inner: i64 =")
      # `ASSERT outer == 1` lowers to expectEqualDeep (tranche 7).
      asserts    = body.index("expectEqualDeep(outer, 1)")
      expect(outer_decl).to be < inner_decl
      expect(inner_decl).to be < asserts
    end
  end
end

RSpec.describe "BEFORE ALL / AFTER ALL" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "emits a separate Zig test for BEFORE ALL, ordered first" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void -> RETURN; END
      TEST Demo DO
        BEFORE ALL DO
          print("suite-start");
        END
        WHEN "ctx" DO
          TEST THAT "first" DO
            ASSERT 1 == 1;
          END
        END
      END
    CLEAR
    expect(zig).to include('test "Demo: __before_all_1"')
    # Order: BEFORE ALL declaration must come before TEST THAT's Zig test.
    ba_idx = zig.index('test "Demo: __before_all_1"')
    tt_idx = zig.index('test "Demo: ctx: first"')
    expect(ba_idx).to be < tt_idx
  end

  it "emits a separate Zig test for AFTER ALL, ordered last" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void -> RETURN; END
      TEST Demo DO
        AFTER ALL DO
          print("suite-end");
        END
        WHEN "ctx" DO
          TEST THAT "first" DO
            ASSERT 1 == 1;
          END
        END
      END
    CLEAR
    expect(zig).to include('test "Demo: __after_all_1"')
    aa_idx = zig.index('test "Demo: __after_all_1"')
    tt_idx = zig.index('test "Demo: ctx: first"')
    expect(tt_idx).to be < aa_idx
  end

  it "supports BEFORE ALL / AFTER ALL at WHEN level" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void -> RETURN; END
      TEST Demo DO
        WHEN "ctx" DO
          BEFORE ALL DO
            print("ctx-start");
          END
          AFTER ALL DO
            print("ctx-end");
          END
          TEST THAT "middle" DO
            ASSERT 1 == 1;
          END
        END
      END
    CLEAR
    expect(zig).to include('test "Demo: ctx: __before_all_1"')
    expect(zig).to include('test "Demo: ctx: __after_all_1"')
    ba_idx = zig.index('test "Demo: ctx: __before_all_1"')
    tt_idx = zig.index('test "Demo: ctx: middle"')
    aa_idx = zig.index('test "Demo: ctx: __after_all_1"')
    expect(ba_idx).to be < tt_idx
    expect(tt_idx).to be < aa_idx
  end

  it "stacks TEST-level and WHEN-level ALL hooks in outer-around-inner order" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void -> RETURN; END
      TEST Outer DO
        BEFORE ALL DO
          print("outer-start");
        END
        AFTER ALL DO
          print("outer-end");
        END
        WHEN "inner" DO
          BEFORE ALL DO
            print("inner-start");
          END
          AFTER ALL DO
            print("inner-end");
          END
          TEST THAT "middle" DO
            ASSERT 1 == 1;
          END
        END
      END
    CLEAR
    outer_before = zig.index('test "Outer: __before_all_1"')
    inner_before = zig.index('test "Outer: inner: __before_all_1"')
    test_block   = zig.index('test "Outer: inner: middle"')
    inner_after  = zig.index('test "Outer: inner: __after_all_1"')
    outer_after  = zig.index('test "Outer: __after_all_1"')
    [outer_before, inner_before, test_block, inner_after, outer_after].each do |i|
      expect(i).not_to be_nil
    end
    expect(outer_before).to be < inner_before
    expect(inner_before).to be < test_block
    expect(test_block).to be < inner_after
    expect(inner_after).to be < outer_after
  end
end
