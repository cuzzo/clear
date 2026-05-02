require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"

# AtomicPtr M3.7 -- parser support for `WITH SNAPSHOT cell AS [MUTABLE]
# alias MATCH ... END`. Polymorphic VERSIONED | ATOMIC fns dispatch
# per-family because the mutate surfaces differ (Versioned requires
# `ON MvccConflict`, AtomicPtr forbids it).
#
# Grammar mirrors the generic `WITH ... MATCH` path: SNAPSHOT / AS /
# MUTABLE / alias / cell-list stay OUTSIDE the MATCH; per-arm bodies
# and per-arm trailing ON MvccConflict clauses live inside the arms.
RSpec.describe "WITH SNAPSHOT MATCH parser (M3.7)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    ast.statements.first
  end

  describe "single-cell SNAPSHOT MATCH" do
    it "parses VERSIONED + ATOMIC arms with per-arm ON MvccConflict on the VERSIONED arm" do
      src = <<~CLEAR
        FN bumpPort!(MUTABLE c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
            WHEN VERSIONED -> { x.port = x.port + 1; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { x.port = x.port + 1; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block).not_to be_nil
      expect(with_block.arms).not_to be_nil
      expect(with_block.arms.size).to eq(2)
      expect(with_block.arms[0][:family]).to eq(:VERSIONED)
      expect(with_block.arms[1][:family]).to eq(:ATOMIC)
    end

    it "VERSIONED arm preserves the ON MvccConflict clause" do
      src = <<~CLEAR
        FN f!(MUTABLE c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
            WHEN VERSIONED -> { _ = x.port; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      versioned_arm = with_block.arms.find { |a| a[:family] == :VERSIONED }
      expect(versioned_arm[:lock_error_clauses]).not_to be_empty
    end

    it "ATOMIC arm has NO ON MvccConflict clause" do
      src = <<~CLEAR
        FN f!(MUTABLE c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
            WHEN VERSIONED -> { _ = x.port; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      atomic_arm = with_block.arms.find { |a| a[:family] == :ATOMIC }
      expect(atomic_arm[:lock_error_clauses]).to be_empty
    end

    it "snapshot_mode is :transaction when alias is MUTABLE (regardless of MATCH)" do
      src = <<~CLEAR
        FN f!(MUTABLE c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
            WHEN VERSIONED -> { _ = x.port; } ON MvccConflict RAISE
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block.snapshot_mode).to eq(:transaction)
    end

    it "snapshot_mode is :read when alias has no MUTABLE" do
      src = <<~CLEAR
        FN f(c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS x MATCH
            WHEN VERSIONED -> { _ = x.port; }
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block.snapshot_mode).to eq(:read)
    end

    it "the body field is empty (arms own the per-family bodies)" do
      src = <<~CLEAR
        FN f(c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS x MATCH
            WHEN VERSIONED -> { _ = x.port; }
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block.body).to eq([])
    end

    it "each arm's body holds the inner statements" do
      src = <<~CLEAR
        FN f(c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS x MATCH
            WHEN VERSIONED -> { _ = x.port; _ = x.host; }
            WHEN ATOMIC    -> { _ = x.port; }
          END
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      versioned_arm = with_block.arms.find { |a| a[:family] == :VERSIONED }
      atomic_arm    = with_block.arms.find { |a| a[:family] == :ATOMIC }
      expect(versioned_arm[:body].size).to eq(2)
      expect(atomic_arm[:body].size).to eq(1)
    end
  end

  describe "non-MATCH path is unaffected" do
    it "parses single-cell SNAPSHOT (no MATCH) with ON MvccConflict trailing the body" do
      src = <<~CLEAR
        FN f!(MUTABLE c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS MUTABLE x { _ = x.port; } ON MvccConflict RAISE
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block.arms).to be_nil
      expect(with_block.body).not_to eq([])
      expect(with_block.lock_error_clause).not_to be_nil
    end

    it "parses single-cell SNAPSHOT read mode (no MATCH, no ON MvccConflict)" do
      src = <<~CLEAR
        FN f(c: Cfg) RETURNS Void ->
          WITH SNAPSHOT c AS x { _ = x.port; }
          RETURN;
        END
      CLEAR
      fn = parse(src)
      with_block = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      expect(with_block.arms).to be_nil
      expect(with_block.snapshot_mode).to eq(:read)
    end
  end
end
