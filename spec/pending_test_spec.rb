require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

# Tranche 2 of the test framework: `PENDING TEST THAT` declares an
# expected-not-yet-implemented test. The body is type-checked at
# annotation time (so it stays in sync with the language) but never
# executed — the MIR lowering prepends `return error.SkipZigTest;`
# so Zig's runner reports it as skipped, distinct from pass/fail.

RSpec.describe "PENDING TEST THAT" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  describe "parser" do
    it "parses `PENDING TEST THAT \"...\" DO ... END` and stamps pending=true" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END

        TEST Demo DO
          WHEN "ctx" DO
            PENDING TEST THAT "future" DO
              ASSERT 1 == 2;
            END
          END
        END
      CLEAR

      test_block = ast.statements.find { |s| s.is_a?(AST::TestBlock) }
      tt = test_block.whens.first.tests.first
      expect(tt).to be_a(AST::TestThat)
      expect(tt.description).to eq("future")
      expect(tt.pending).to eq(true)
    end

    it "leaves regular TEST THAT declarations with pending=nil/false" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END

        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "regular" DO
              ASSERT 1 == 1;
            END
          END
        END
      CLEAR

      tt = ast.statements
        .find { |s| s.is_a?(AST::TestBlock) }
        .whens.first.tests.first
      expect(tt.pending).to be_falsey
    end
  end

  describe "type-checks the body even when pending" do
    it "rejects a PENDING test whose body has a real type error" do
      # The body of a PENDING test is still annotated. A type error
      # in the body fails compilation — we don't quietly accept
      # pending-tagged bad code.
      src = <<~CLEAR
        FN main() RETURNS Void -> RETURN; END

        TEST Demo DO
          WHEN "ctx" DO
            PENDING TEST THAT "broken types" DO
              x: Int64 = "not an int";
              ASSERT TRUE;
            END
          END
        END
      CLEAR
      expect { transpile(src) }.to raise_error(CompilerError)
    end
  end

  describe "MIR lowering" do
    it "emits `return error.SkipZigTest;` as the pending body" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END

        TEST Demo DO
          WHEN "ctx" DO
            PENDING TEST THAT "future" DO
              ASSERT 1 == 1;
            END
          END
        END
      CLEAR
      expect(zig).to include("return error.SkipZigTest;")
      # The pending body's ASSERT must NOT survive into emitted Zig —
      # if it did, the test would run and fail/pass instead of being
      # reported as skipped.
      pending_idx = zig.index("Demo: ctx: future")
      expect(pending_idx).not_to be_nil
      pending_block = zig[pending_idx, 500]
      expect(pending_block).to include("return error.SkipZigTest;")
      # The `1 == 1` assertion text shouldn't appear in the pending
      # test's body region.
      expect(pending_block).not_to include("CheatLib.assert")
    end

    it "still emits regular sibling tests in the same WHEN block" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END

        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "regular A" DO
              ASSERT TRUE;
            END
            PENDING TEST THAT "future B" DO
              ASSERT TRUE;
            END
            TEST THAT "regular C" DO
              ASSERT TRUE;
            END
          END
        END
      CLEAR
      expect(zig).to include("Demo: ctx: regular A")
      expect(zig).to include("Demo: ctx: future B")
      expect(zig).to include("Demo: ctx: regular C")
      # Only the pending test gets the skip marker.
      skip_count = zig.scan("return error.SkipZigTest;").size
      expect(skip_count).to eq(1)
    end
  end
end
