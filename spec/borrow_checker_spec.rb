require "rspec"
require "set"
require_relative "../src/backends/transpiler"

# Tests the BorrowChecker -- AST-walk verification that borrowed variables
# (via WITH RESTRICT / WITH BORROWED) are not moved while borrowed, and
# that overlapping borrows don't violate aliasing rules.
#
# The annotator's OwnershipGraph already catches many borrow conflicts.
# These specs verify:
# 1. No false positives on valid programs with WITH blocks
# 2. Correct borrow tracking through nested/sequential WITH blocks
# 3. Defense-in-depth for move-while-borrowed and alias violations

RSpec.describe BorrowChecker do
  def token(line = 1)
    Lexer::Token.new(:VAR_ID, "u", line, 1)
  end

  def borrowed_identifier(name = "u", type: :User)
    node = AST::Identifier.new(token, name)
    node.full_type = Type.new(type)
    node
  end

  def direct_borrow_errors(body)
    cap = AST::Capability.new(
      capability: :BORROWED,
      var_node: borrowed_identifier("u"),
      alias: "ref",
      alias_mutable: false,
      guard_expr: nil,
    )
    with = AST::WithBlock.new(token, [cap], body, nil)
    attach_capability_plan!(with)
    fn = AST::FunctionDef.new(token, "main", [], [], Type.new(:Void), nil, [with], [], nil, :private, [], false)
    BorrowChecker.check(fn, schema_lookup: ->(_name) { nil })
  end

  def check_errors(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    BorrowChecker.check(fn_node, schema_lookup: schema_lookup)
  end

  def expect_no_error(src, fn_name = "main")
    errors = check_errors(src, fn_name)
    expect(errors).to be_empty, "Expected no errors but got: #{errors.inspect}"
  end

  # =========================================================================
  # No false positives on valid programs
  # =========================================================================

  describe "valid programs produce no errors" do
    it "WITH BORROWED -- immutable borrow, read-only use" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          WITH BORROWED name AS ref {
            n = ref.length();
          }
          RETURN;
        END
      CLEAR
    end

    it "WITH RESTRICT -- mutable borrow" do
      expect_no_error(<<~CLEAR)
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p = Point{ x: 1.0, y: 2.0 };
          WITH RESTRICT p AS MUTABLE ref {
            ref.x = 10.0;
          }
          RETURN;
        END
      CLEAR
    end

    it "sequential WITH blocks on same variable" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          WITH BORROWED name AS ref1 {
            n = ref1.length();
          }
          WITH BORROWED name AS ref2 {
            n = ref2.length();
          }
          RETURN;
        END
      CLEAR
    end

    it "nested BORROWED on different variables" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          a = "first";
          b = "second";
          WITH BORROWED a AS ra {
            WITH BORROWED b AS rb {
              n = ra.length();
              m = rb.length();
            }
          }
          RETURN;
        END
      CLEAR
    end

    it "multiple immutable borrows of same variable" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          WITH BORROWED name AS ref1 {
            WITH BORROWED name AS ref2 {
              n = ref1.length();
              m = ref2.length();
            }
          }
          RETURN;
        END
      CLEAR
    end

    it "move AFTER borrow released" do
      expect_no_error(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          MUTABLE u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            n = ref.id;
          }
          u2 = u;
          RETURN;
        END
      CLEAR
    end

    it "WITH blocks inside if/else branches" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          IF name.length() > 0 THEN
            WITH BORROWED name AS ref {
              n = ref.length();
            }
          END
          RETURN;
        END
      CLEAR
    end

    it "WITH block in loop" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          MUTABLE i = 0;
          WHILE i < 3 DO
            WITH BORROWED name AS ref {
              n = ref.length();
            }
            i = i + 1;
          END
          RETURN;
        END
      CLEAR
    end

    it "no WITH blocks at all" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          RETURN;
        END
      CLEAR
    end

    it "WITH on locked type (EXCLUSIVE -- runtime protection, no compile-time check)" do
      expect_no_error(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @locked;
          WITH c {
            n = c.value;
          }
          RETURN;
        END
      CLEAR
    end

    it "WITH on multiowned type (Rc -- no compile-time borrow check)" do
      expect_no_error(<<~CLEAR)
        STRUCT Node { value: Int64 }
        FN main() RETURNS Void ->
          n = Node{ value: 1 } @multiowned;
          WITH n {
            x = n.value;
          }
          RETURN;
        END
      CLEAR
    end
  end

  # =========================================================================
  # Borrow state tracking
  # =========================================================================

  describe "borrow state tracking" do
    it "returns empty errors for function without WITH blocks" do
      errors = check_errors(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          RETURN;
        END
      CLEAR
      expect(errors).to be_empty
    end

    it "returns empty errors for valid BORROWED use" do
      errors = check_errors(<<~CLEAR)
        FN main() RETURNS Void ->
          s = "hello";
          WITH BORROWED s AS ref {
            n = ref.length();
          }
          RETURN;
        END
      CLEAR
      expect(errors).to be_empty
    end

    it "returns empty errors for valid RESTRICT use" do
      errors = check_errors(<<~CLEAR)
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p = Point{ x: 1.0, y: 2.0 };
          WITH RESTRICT p AS MUTABLE ref {
            ref.x = 5.0;
          }
          RETURN;
        END
      CLEAR
      expect(errors).to be_empty
    end
  end

  # =========================================================================
  # Error detection: MOVE_WHILE_BORROWED
  # =========================================================================

  describe "MOVE_WHILE_BORROWED" do
    it "catches RETURN GIVE while the source is borrowed" do
      ret = AST::ReturnNode.new(token, AST::MoveNode.new(token, borrowed_identifier("u")))

      errors = direct_borrow_errors([ret])
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches standalone GIVE while the source is borrowed" do
      errors = direct_borrow_errors([AST::MoveNode.new(token, borrowed_identifier("u"))])

      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches BG resource captures while the source is borrowed" do
      bg = AST::BgBlock.new(token, [], nil, nil, false, false, nil, false)
      bg.capture_analysis = double(resource_captures: Set["u"])

      errors = direct_borrow_errors([bg])
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches GIVE of heap struct inside WITH BORROWED" do
      errors = check_errors(<<~CLEAR)
        FN consume(TAKES u: User @indirect) RETURNS Int64 ->
          RETURN u.id;
        END
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            n = consume(GIVE u);
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches non-Copy assignment inside WITH BORROWED" do
      errors = check_errors(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            v = u;
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches SHARE of a borrowed value" do
      errors = check_errors(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            shared = SHARE u;
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "catches SHARE of a complex expression that moves a borrowed value" do
      errors = check_errors(<<~CLEAR)
        STRUCT User { id: Int64 }
        STRUCT Box { user: User }
        FN main() RETURNS Void ->
          u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            shared = SHARE Box{ user: u };
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
      expect(errors.first).to include("u")
    end

    it "walks SHARE nodes while looking for explicit moved identifiers" do
      token = Lexer::Token.new(:VAR_ID, "u", 9, 7)
      ident = AST::Identifier.new(token, "u")
      ident.full_type = Type.new(:User)
      ident.was_moved = true
      share = AST::ShareNode.new(token, ident)
      fn = AST::FunctionDef.new(token, "main", [], [], Type.new(:Void), nil, [], [], nil, :private, [], false)
      checker = BorrowChecker.new(fn, schema_lookup: nil)
      seen = []

      checker.send(:walk_for_was_moved, share) { |node| seen << node.name.to_s }
      expect(seen).to eq(["u"])
    end

    it "allows GIVE on @list inside WITH BORROWED (CopyNode - frame stays alive)" do
      errors = check_errors(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          WITH BORROWED vals AS ref {
            n = consume(GIVE vals);
          }
          RETURN;
        END
      CLEAR
      # GIVE on @list creates CopyNode (frame-to-heap copy).
      # Frame original stays alive, borrow is still valid.
      expect(errors).to be_empty
    end

    it "catches move inside nested control flow within WITH" do
      errors = check_errors(<<~CLEAR)
        FN consume(TAKES u: User @indirect) RETURNS Int64 ->
          RETURN u.id;
        END
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          u: User @indirect = User{ id: 1 };
          WITH BORROWED u AS ref {
            IF ref.id > 0 THEN
              n = consume(GIVE u);
            END
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("MOVE_WHILE_BORROWED")
    end
  end

  # =========================================================================
  # Error detection: ALIAS_VIOLATION
  # =========================================================================

  describe "ALIAS_VIOLATION" do
    it "catches RESTRICT inside BORROWED (mutable while immutable)" do
      errors = check_errors(<<~CLEAR)
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p = Point{ x: 1.0, y: 2.0 };
          WITH BORROWED p AS ref {
            WITH RESTRICT p AS MUTABLE ref2 {
              ref2.x = 5.0;
            }
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("ALIAS_VIOLATION")
      expect(errors.first).to include("p")
      expect(errors.first).to include("RESTRICT")
    end

    it "catches BORROWED inside RESTRICT (immutable while mutable)" do
      errors = check_errors(<<~CLEAR)
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p = Point{ x: 1.0, y: 2.0 };
          WITH RESTRICT p AS MUTABLE ref {
            WITH BORROWED p AS ref2 {
              n = ref2.x;
            }
          }
          RETURN;
        END
      CLEAR
      expect(errors.length).to eq(1)
      expect(errors.first).to include("ALIAS_VIOLATION")
      expect(errors.first).to include("p")
    end

    it "allows multiple immutable borrows (shared reads)" do
      errors = check_errors(<<~CLEAR)
        FN main() RETURNS Void ->
          name = "hello";
          WITH BORROWED name AS ref1 {
            WITH BORROWED name AS ref2 {
              n = ref1.length();
              m = ref2.length();
            }
          }
          RETURN;
        END
      CLEAR
      expect(errors).to be_empty
    end

    it "allows sequential RESTRICT blocks (non-overlapping)" do
      errors = check_errors(<<~CLEAR)
        STRUCT Point { x: Float64, y: Float64 }
        FN main() RETURNS Void ->
          MUTABLE p = Point{ x: 1.0, y: 2.0 };
          WITH RESTRICT p AS MUTABLE ref1 {
            ref1.x = 5.0;
          }
          WITH RESTRICT p AS MUTABLE ref2 {
            ref2.y = 10.0;
          }
          RETURN;
        END
      CLEAR
      expect(errors).to be_empty
    end
  end
end
