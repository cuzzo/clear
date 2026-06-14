require "rspec"

require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# True-Sync-Polymorphism step 1 (parser): verifies the new
#   - top-level `SYNC POLICY START ... END` block
#   - per-WITH `WITH POLYMORPHIC ...` marker (with optional
#     POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE escape modifier)
#
# This spec is deliberately parse-only. Annotator-side checks
# (single-instance, main-file-only, completeness, polymorphic-iff-rule,
# inline-only-Deadlock-LockCycle guard) live in their own specs once
# tasks #325 / #326 land.
RSpec.describe "True-Sync-Polymorphism parser (step 1)" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    ClearParser.new(tokens, src).parse
  end

  def parse_first_stmt(src)
    parse(src).statements.first
  end

  # ── SYNC POLICY block ────────────────────────────────────────

  describe "SYNC POLICY START ... END" do
    it "parses a full policy with three handlers into AST::SyncPolicyDecl" do
      node = parse_first_stmt(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RETRY(3) THEN RAISE
            ON MvccConflict RAISE
            ON AtomicConflict RAISE
        END
      CLEAR

      expect(node).to be_a(AST::SyncPolicyDecl)
      expect(node.handlers.size).to eq(3)
    end

    it "carries each handler's selectors, retries, and action through" do
      node = parse_first_stmt(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RETRY(3) THEN RAISE
            ON MvccConflict RAISE
            ON AtomicConflict RAISE
        END
      CLEAR

      first  = node.handlers[0]
      second = node.handlers[1]
      third  = node.handlers[2]

      expect(first.selectors.first.name).to eq(:LockTimeout)
      expect(first.retries).to eq(3)
      expect(first.action).to eq(AST::ErrorActionKind::Raise)

      expect(second.selectors.first.name).to eq(:MvccConflict)
      expect(second.retries).to be_nil
      expect(second.action).to eq(AST::ErrorActionKind::Raise)

      expect(third.selectors.first.name).to eq(:AtomicConflict)
      expect(third.action).to eq(AST::ErrorActionKind::Raise)
    end

    it "accepts a single handler" do
      node = parse_first_stmt(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RAISE
        END
      CLEAR

      expect(node).to be_a(AST::SyncPolicyDecl)
      expect(node.handlers.size).to eq(1)
    end

    it "errors when the body is empty" do
      expect {
        parse(<<~CLEAR)
          SYNC POLICY START
          END
        CLEAR
      }.to raise_error(/at least one ON \/ RETRY handler/)
    end

    it "errors when END is missing" do
      expect {
        parse(<<~CLEAR)
          SYNC POLICY START
              ON LockTimeout RAISE
        CLEAR
      }.to raise_error(/Expected.*END/i)
    end

    it "errors when POLICY keyword is missing" do
      expect {
        parse(<<~CLEAR)
          SYNC START
              ON LockTimeout RAISE
          END
        CLEAR
      }.to raise_error(/Expected.*POLICY/i)
    end

    it "is locatable (carries the SYNC token's line)" do
      src = "SYNC POLICY START\n    ON LockTimeout RAISE\nEND\n"
      node = parse_first_stmt(src)
      expect(node.token.value).to eq("SYNC")
      expect(node.token.line).to eq(1)
    end

    it "two SYNC POLICY blocks parse fine; annotator (#325) rejects" do
      stmts = parse(<<~CLEAR).statements
        SYNC POLICY START
            ON LockTimeout RAISE
        END

        SYNC POLICY START
            ON MvccConflict RAISE
        END
      CLEAR
      expect(stmts.size).to eq(2)
      expect(stmts).to all(be_a(AST::SyncPolicyDecl))
    end
  end

  # ── WITH POLYMORPHIC ─────────────────────────────────────────

  describe "WITH POLYMORPHIC inside a function body" do
    it "sets WithBlock#polymorphic = true on the brace form" do
      prog = parse(<<~CLEAR)
        FN run(c: Counter) ->
            WITH POLYMORPHIC c AS x { x.value = x.value + 1; }
            RETURN;
        END
      CLEAR

      fn = prog.statements.first
      with_block = fn.body.first
      expect(with_block).to be_a(AST::WithBlock)
      expect(with_block.polymorphic).to be true
    end

    it "plain WITH leaves polymorphic falsy" do
      prog = parse(<<~CLEAR)
        FN run(c: Counter) ->
            WITH c AS x { x.value = x.value + 1; }
            RETURN;
        END
      CLEAR

      with_block = prog.statements.first.body.first
      expect(with_block.polymorphic).to be_falsey
    end

    it "WITH POLYMORPHIC POSSIBLE_DEADLOCK preserves both flags" do
      prog = parse(<<~CLEAR)
        FN run(a: Counter, b: Counter) ->
            WITH POLYMORPHIC POSSIBLE_DEADLOCK a AS x, b AS y {
                x.value = y.value;
            } ON Deadlock RAISE
            RETURN;
        END
      CLEAR

      with_block = prog.statements.first.body.first
      expect(with_block.polymorphic).to be true
      expect(with_block.deadlock_escape).to be_a(Hash)
      expect(with_block.deadlock_escape[:kind]).to eq(:deadlock)
    end

    it "WITH POLYMORPHIC POSSIBLE_LOCK_CYCLE preserves both flags" do
      prog = parse(<<~CLEAR)
        FN run(a: Counter, b: Counter) ->
            WITH POLYMORPHIC POSSIBLE_LOCK_CYCLE a AS x, b AS y {
                x.value = y.value;
            } ON LockCycle RAISE
            RETURN;
        END
      CLEAR

      with_block = prog.statements.first.body.first
      expect(with_block.polymorphic).to be true
      expect(with_block.deadlock_escape[:kind]).to eq(:lock_cycle)
    end

    it "POLYMORPHIC must come BEFORE POSSIBLE_DEADLOCK (left-to-right grammar)" do
      # `WITH POSSIBLE_DEADLOCK POLYMORPHIC ...` is rejected — the
      # parser sees POLYMORPHIC where it expects a capability/var_id.
      expect {
        parse(<<~CLEAR)
          FN run(c: Counter) ->
              WITH POSSIBLE_DEADLOCK POLYMORPHIC c AS x { x.value = 0; }
              RETURN;
          END
        CLEAR
      }.to raise_error(StandardError)
    end

    it "WITH POLYMORPHIC carries a per-WITH ON handler through" do
      prog = parse(<<~CLEAR)
        FN run(c: Counter) ->
            WITH POLYMORPHIC c AS x { x.value = x.value + 1; }
            ON MvccConflict RETRY(2) THEN RAISE
            RETURN;
        END
      CLEAR

      with_block = prog.statements.first.body.first
      expect(with_block.polymorphic).to be true
      expect(with_block.lock_error_clause).not_to be_nil
      expect(with_block.lock_error_clause.selectors.first.name).to eq(:MvccConflict)
      expect(with_block.lock_error_clause.retries).to eq(2)
    end
  end
end
