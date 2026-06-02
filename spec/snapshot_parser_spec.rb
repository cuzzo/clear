require "rspec"

require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"

# MVCC L4 -- `WITH SNAPSHOT ...` parser + AST.
#
# Verifies the parser accepts the four shapes:
#   - single read:        WITH SNAPSHOT a AS y { ... }
#   - single transaction: WITH SNAPSHOT a AS MUTABLE va { ... } ON MvccConflict ...
#   - multi-cell read:    WITH SNAPSHOT a AS ya, SNAPSHOT b AS yb { ... }
#   - multi-cell mixed:   WITH SNAPSHOT a AS ya, SNAPSHOT b AS MUTABLE vb { ... } ON MvccConflict ...
#
# Also verifies the ON MvccConflict RETRY(N) THEN clause path. Annotator-
# level checks (ON MvccConflict required when MUTABLE; non-escape; impure-
# block) come in L5 and are NOT exercised here.
RSpec.describe "WITH SNAPSHOT parser" do
  def parse_block(src)
    full = "FN main() RETURNS Void -> #{src} END"
    tokens = Lexer.new(full).tokenize
    ast = Parser.new(tokens, full).parse
    fn = ast.statements.first
    fn.body.find { |s| s.is_a?(AST::WithBlock) }
  end

  describe "single-cell read" do
    it "parses `WITH SNAPSHOT a AS y { ... }`" do
      node = parse_block("WITH SNAPSHOT a AS y { x = 1; }")
      expect(node).to be_a(AST::WithBlock)
      expect(node.snapshot_mode).to eq(:read)
      expect(node.capabilities.size).to eq(1)
      cap = node.capabilities.first
      expect(cap[:capability]).to eq(:SNAPSHOT)
      expect(cap[:alias]).to eq("y")
      expect(cap[:alias_mutable]).to be false
    end

    it "binds the alias to the variable" do
      node = parse_block("WITH SNAPSHOT counter AS view { x = 1; }")
      cap = node.capabilities.first
      expect(cap[:var_node].name).to eq("counter")
      expect(cap[:alias]).to eq("view")
    end

    it "preserves the SNAPSHOT token (used for diagnostics)" do
      node = parse_block("WITH SNAPSHOT a AS y { x = 1; }")
      cap = node.capabilities.first
      expect(cap[:snapshot_token]).not_to be_nil
      expect(cap[:snapshot_token].value).to eq("SNAPSHOT")
    end
  end

  describe "single-cell transaction (MUTABLE)" do
    it "parses `WITH SNAPSHOT a AS MUTABLE va { ... } ON MvccConflict RAISE`" do
      node = parse_block("WITH SNAPSHOT a AS MUTABLE va { va.x = 1; } ON MvccConflict RAISE")
      expect(node.snapshot_mode).to eq(:transaction)
      cap = node.capabilities.first
      expect(cap[:alias]).to eq("va")
      expect(cap[:alias_mutable]).to be true
      expect(node.lock_error_clause).not_to be_nil
      expect(node.lock_error_clause.selectors.first.name).to eq(:MvccConflict)
    end

    it "parses ON MvccConflict RETRY(3) THEN PASS" do
      node = parse_block("WITH SNAPSHOT a AS MUTABLE va { va.x = 1; } ON MvccConflict RETRY(3) THEN PASS")
      expect(node.lock_error_clause.retries).to eq(3)
      expect(node.lock_error_clause.action).to eq(:pass)
    end

    it "parses ON MvccConflict with -> { ... } block action" do
      node = parse_block(<<~CLEAR)
        WITH SNAPSHOT a AS MUTABLE va { va.x = 1; }
          ON MvccConflict -> { y = 0; }
      CLEAR
      expect(node.lock_error_clause).not_to be_nil
      expect(node.lock_error_clause.action).to eq(:block)
    end

    it "RETRY(0) is rejected (RETRY(N) requires N > 0)" do
      expect {
        parse_block("WITH SNAPSHOT a AS MUTABLE va { va.x = 1; } ON MvccConflict RETRY(0) THEN PASS")
      }.to raise_error(/RETRY\(N\) requires N > 0/)
    end
  end

  describe "multi-cell" do
    it "parses two read-only SNAPSHOTs" do
      node = parse_block(<<~CLEAR)
        WITH SNAPSHOT a AS ya, SNAPSHOT b AS yb { x = 1; }
      CLEAR
      expect(node.snapshot_mode).to eq(:read)
      expect(node.capabilities.size).to eq(2)
      expect(node.capabilities.map { |c| c[:alias] }).to eq(%w[ya yb])
      expect(node.capabilities.map { |c| c[:alias_mutable] }).to eq([false, false])
    end

    it "parses two mutable SNAPSHOTs (ON MvccConflict required at L5)" do
      node = parse_block(<<~CLEAR)
        WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb {
          va.x = 1; vb.y = 2;
        } ON MvccConflict RAISE
      CLEAR
      expect(node.snapshot_mode).to eq(:transaction)
      expect(node.capabilities.size).to eq(2)
      expect(node.capabilities.map { |c| c[:alias_mutable] }).to eq([true, true])
    end

    it "parses mixed read + mutable -> snapshot_mode :transaction" do
      node = parse_block(<<~CLEAR)
        WITH SNAPSHOT a AS ya, SNAPSHOT b AS MUTABLE vb { ya.x = 1; vb.y = 2; }
          ON MvccConflict RAISE
      CLEAR
      expect(node.snapshot_mode).to eq(:transaction)
      cells = node.capabilities
      expect(cells[0][:alias_mutable]).to be false
      expect(cells[1][:alias_mutable]).to be true
    end

    it "parses three SNAPSHOTs" do
      node = parse_block(<<~CLEAR)
        WITH SNAPSHOT a AS MUTABLE va, SNAPSHOT b AS MUTABLE vb, SNAPSHOT c AS MUTABLE vc {
          va.x = 1; vb.y = 2; vc.z = 3;
        } ON MvccConflict RAISE
      CLEAR
      expect(node.capabilities.size).to eq(3)
      expect(node.capabilities.map { |c| c[:alias] }).to eq(%w[va vb vc])
    end
  end

  describe "regression: traditional WITH still works" do
    it "WITH EXCLUSIVE locked AS s { ... } unchanged by SNAPSHOT routing" do
      node = parse_block("WITH EXCLUSIVE c AS s { x = 1; }")
      expect(node).to be_a(AST::WithBlock)
      expect(node.snapshot_mode).to be_nil
      expect(node.capabilities.first[:capability]).to eq(:EXCLUSIVE)
    end
  end
end
