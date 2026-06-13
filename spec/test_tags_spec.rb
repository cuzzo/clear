require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/annotator" unless defined?(SemanticAnnotator)
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Tranche 6 of the test framework: WHEN-block TAGS.
#
#   WHEN "fast unit" TAGS [unit, fast] DO
#     TEST THAT "..." DO ... END
#   END
#
# Tags are bare identifiers (snake_case). Lowering encodes them as
# ` #tag1 #tag2` suffixes on every TEST THAT name in the WHEN, so
# `clear test --tag slow` translates to `zig test --test-filter "#slow"`
# and Zig's substring filter selects matching tests.
#
# Granularity caveat (v1): Zig's `--test-filter` only matches the
# OUTER `test "<filename>"` declaration, not the inner tests nested
# inside the gen.rb-emitted struct. gen.rb collects the union of
# tags from inner test names and appends them to the outer name, so
# filtering selects at FILE granularity — any tag in any WHEN of the
# file makes the whole file selectable. Per-WHEN granularity needs a
# custom Zig test runner (deferred).

RSpec.describe "WHEN TAGS" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  describe "parser" do
    it "parses a single tag" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" TAGS [slow] DO
            TEST THAT "..." DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      wb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }.whens.first
      expect(wb.tags).to eq(["slow"])
    end

    it "parses multiple comma-separated tags" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" TAGS [slow, integration, network] DO
            TEST THAT "..." DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      wb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }.whens.first
      expect(wb.tags).to eq(%w[slow integration network])
    end

    it "stores tags as bare-identifier strings" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" TAGS [unit] DO
            TEST THAT "..." DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      wb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }.whens.first
      expect(wb.tags).to all(be_a(String))
    end

    it "leaves tags=[] for WHEN blocks without a TAGS clause" do
      ast = parse(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "ctx" DO
            TEST THAT "..." DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      wb = ast.statements.find { |s| s.is_a?(AST::TestBlock) }.whens.first
      expect(wb.tags).to eq([])
    end
  end

  describe "MIR lowering" do
    it "appends ` #tag1 #tag2` to every TEST THAT name in the WHEN" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "fast" TAGS [unit, fast] DO
            TEST THAT "addition" DO ASSERT 1 + 1 == 2; END
            TEST THAT "subtraction" DO ASSERT 5 - 3 == 2; END
          END
        END
      CLEAR
      expect(zig).to include('test "Demo: fast: addition #unit #fast"')
      expect(zig).to include('test "Demo: fast: subtraction #unit #fast"')
    end

    it "leaves untagged WHEN tests without a tag suffix" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "no tags" DO
            TEST THAT "plain" DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      expect(zig).to include('test "Demo: no tags: plain"')
      expect(zig).not_to match(/test "Demo: no tags: plain[^"]*#/)
    end

    it "tags do not leak between sibling WHEN blocks" do
      zig = transpile(<<~CLEAR)
        FN main() RETURNS Void -> RETURN; END
        TEST Demo DO
          WHEN "tagged" TAGS [slow] DO
            TEST THAT "in tagged WHEN" DO ASSERT 1 == 1; END
          END
          WHEN "untagged" DO
            TEST THAT "in untagged WHEN" DO ASSERT 1 == 1; END
          END
        END
      CLEAR
      expect(zig).to include('test "Demo: tagged: in tagged WHEN #slow"')
      expect(zig).to include('test "Demo: untagged: in untagged WHEN"')
      # The untagged WHEN's test must NOT have a #slow suffix.
      expect(zig).not_to match(/test "Demo: untagged: in untagged WHEN #slow"/)
    end
  end
end
