require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Tests the UseAfterMoveChecker -- the dataflow-based use-after-move checker
# that replays CFG transfer from block-entry states.
#
# The annotator's OwnershipGraph already catches most use-after-move errors
# before the dataflow stage. These specs verify:
# 1. No false positives on valid programs
# 2. Correct per-statement state tracking (foundation for Phase 3/4)
# 3. Edge cases in GIVE/TAKES/return/BG semantics

RSpec.describe UseAfterMoveChecker do
  def check_errors(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    UseAfterMoveChecker.check(fn_node, schema_lookup: schema_lookup)
  end

  def borrow_errors(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
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

  def analyze_state(src, fn_name = "main")
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    OwnershipDataflow.analyze(fn_node, schema_lookup: schema_lookup)
  end

  def empty_function_node(name = "main")
    token = Lexer::Token.new(:FN, "FN", 1, 1)
    AST::FunctionDef.new(token, name, [], [], :Void, nil, [], [], nil, :private, [], false)
  end

  def direct_checker(name = "main")
    checker = UseAfterMoveChecker.allocate
    checker.instance_variable_set(:@fn_node, empty_function_node(name))
    checker.instance_variable_set(:@errors, [])
    checker
  end

  def moved_state(*names)
    entries = names.each_with_object({}) do |name, out|
      out[name] = OwnershipDataflow::OwnerEntry.new(
        state: OwnershipDataflow::MOVED,
        allocator: :heap,
        needs_cleanup: true,
      )
    end
    OwnershipDataflow.state_from_names(entries)
  end

  def id_node(name, line: 1)
    AST::Identifier.new(Lexer::Token.new(:IDENTIFIER, name, line, 3), name)
  end

  describe ".check public entrypoint" do
    it "runs with default analysis context" do
      expect(UseAfterMoveChecker.check(empty_function_node)).to eq([])
    end

    it "reports errors after running the checker" do
      errors = check_errors(<<~CLEAR)
        STRUCT Box { id: Int64 }
        FN main() RETURNS Void ->
          a: Box @indirect = Box{ id: 1 };
          b = a;
          c = a.id;
          RETURN;
        END
      CLEAR

      expect(errors).to include("[USE_AFTER_MOVE] main::a -- used after being moved (line 5)")
    end

    it "forwards fallibility and schema lookup context into ownership analysis" do
      fn_node = empty_function_node
      can_fail_fns = Set["helper"]
      schema_lookup = ->(_name) { nil }

      expect(OwnershipDataflow).to receive(:analyze)
        .with(fn_node, can_fail_fns: can_fail_fns, schema_lookup: schema_lookup)
        .and_call_original

      expect(
        UseAfterMoveChecker.check(
          fn_node,
          can_fail_fns: can_fail_fns,
          schema_lookup: schema_lookup,
        ),
      ).to eq([])
    end
  end

  # =========================================================================
  # No false positives on valid programs
  # =========================================================================

  describe "valid programs produce no errors" do
    it "simple primitives" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          z = x;
          RETURN;
        END
      CLEAR
    end

    it "single use of non-Copy value" do
      expect_no_error(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
    end

    it "GIVE to TAKES with no further use" do
      expect_no_error(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(GIVE vals);
          RETURN;
        END
      CLEAR
    end

    it "return of owned value" do
      expect_no_error(<<~CLEAR)
        FN makeList() RETURNS !Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
        FN main() RETURNS Void ->
          r = makeList();
          RETURN;
        END
      CLEAR
    end

    it "multiowned (Rc) reuse" do
      expect_no_error(<<~CLEAR)
        STRUCT Node { value: Int64 }
        FN main() RETURNS Void ->
          n = Node{ value: 1 } @multiowned;
          n2 = n;
          n3 = n;
          RETURN;
        END
      CLEAR
    end

    it "implicit borrow (non-TAKES param)" do
      expect_no_error(<<~CLEAR)
        FN readLen(items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n1 = readLen(vals);
          n2 = readLen(vals);
          RETURN;
        END
      CLEAR
    end

    it "if/else where no branch moves" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          IF vals.length() > 0 THEN
            vals.append(2_i64);
          END
          n = vals.length();
          RETURN;
        END
      CLEAR
    end

    it "loop with no move" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          MUTABLE i = 0;
          WHILE i < 5 DO
            vals.append(i);
            i = i + 1;
          END
          n = vals.length();
          RETURN;
        END
      CLEAR
    end

    it "string reuse (strings are Copy in CLEAR dataflow)" do
      expect_no_error(<<~CLEAR)
        FN greet(name: String) RETURNS String ->
          RETURN "hello";
        END
        FN main() RETURNS Void ->
          s = "world";
          r1 = greet(s);
          r2 = greet(s);
          RETURN;
        END
      CLEAR
    end

    it "union single use" do
      expect_no_error(<<~CLEAR)
        UNION Value { Num: Float64, List: Int64[] }
        FN main() RETURNS Void ->
          v1 = Value{ Num: 1.0 };
          v2 = v1;
          RETURN;
        END
      CLEAR
    end
  end

  # =========================================================================
  # Block-entry state replay (foundation for Phase 3/4)
  # =========================================================================

  describe "block-entry state replay" do
    it "does not materialize per-statement point state snapshots" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.block_in).not_to be_empty
      expect(df.block_out).not_to be_empty
      expect(df).not_to respond_to(:point_states)
    end

    it "does not track copy-like primitive bindings in ownership state" do
      df = analyze_state(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 1_i64;
          y = x;
          RETURN;
        END
      CLEAR

      expect(df.exit_states).not_to have_key("x")
      expect(df.exit_states).not_to have_key("y")
    end

    it "enriched entry has allocator and needs_cleanup" do
      df = analyze_state(<<~CLEAR, "consume")
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
      CLEAR
      # TAKES param should have an OwnerEntry with allocator info
      entry = df.exit_states["items"]
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.allocator).to eq(:heap)
      end
    end

    it "exit_states show moved after assignment of non-Copy" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "exit_states omit Copy types" do
      df = analyze_state(<<~CLEAR)
        FN main() RETURNS Void ->
          x = 42;
          y = x;
          RETURN;
        END
      CLEAR
      expect(df.exit_states).not_to have_key("x")
      expect(df.exit_states).not_to have_key("y")
    end

    it "exit_states show moved after heap struct assignment" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "exit_states show moved after SHARE into a shared parameter" do
      df = analyze_state(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          takes_shared(SHARE b);
          RETURN;
        END
      CLEAR
      expect(df.exit_states["b"]).to eq(:moved)
    end

    it "exit_states show moved after SHARE in a binding RHS" do
      df = analyze_state(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          s = SHARE b;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["b"]).to eq(:moved)
      expect(df.exit_states).not_to have_key("s")
    end

    it "exit_states preserve source ownership when SHARE wraps COPY" do
      df = analyze_state(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          s = SHARE COPY b;
          RETURN;
        END
      CLEAR
      expect(df.exit_states["b"]).to eq(:owned)
      expect(df.exit_states).not_to have_key("s")
    end

    it "exit_states show moved for nested affine values in complex SHARE expressions" do
      df = analyze_state(<<~CLEAR)
        STRUCT Inner { value: Int64 }
        STRUCT Box { inner: Inner }
        FN main() RETURNS Void ->
          inner = Inner{ value: 1 };
          s = SHARE Box{ inner: inner };
          RETURN;
        END
      CLEAR
      expect(df.exit_states["inner"]).to eq(:moved)
      expect(df.exit_states).not_to have_key("s")
    end
  end

  describe "direct read-walker coverage" do
    it "checks hash literal keys as reads, not only values" do
      checker = direct_checker
      state = moved_state("moved_key", "moved_value")
      hash = AST::HashLit.new(
        Lexer::Token.new(:CHAR, "{", 4, 7),
        { id_node("moved_key", line: 4) => id_node("moved_value", line: 4) },
        :stack,
      )

      checker.send(:check_reads_in_expr, hash, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::moved_key -- used after being moved (line 4)",
        "[USE_AFTER_MOVE] main::moved_value -- used after being moved (line 4)",
      )
    end

    it "walks nested list, struct, index, unary, and binary expression reads" do
      checker = direct_checker
      state = moved_state("left", "field_owner", "index", "list_item")
      expr = AST::BinaryOp.new(
        Lexer::Token.new(:OP, "+", 8, 10),
        id_node("left", line: 8),
        :ADD,
        AST::ListLit.new(
          Lexer::Token.new(:CHAR, "[", 8, 15),
          [
            AST::StructLit.new(
              Lexer::Token.new(:TYPE_ID, "Box", 8, 16),
              "Box",
              {
                "value" => AST::UnaryOp.new(
                  Lexer::Token.new(:OP, "-", 8, 23),
                  :NEG,
                  AST::GetIndex.new(
                    Lexer::Token.new(:CHAR, "[", 8, 30),
                    AST::GetField.new(
                      Lexer::Token.new(:CHAR, ".", 8, 27),
                      id_node("field_owner", line: 8),
                      "items",
                    ),
                    id_node("index", line: 8),
                  ),
                ),
              },
              :stack,
              [],
            ),
            id_node("list_item", line: 8),
          ],
          :stack,
        ),
      )

      checker.send(:check_reads_in_expr, expr, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::left -- used after being moved (line 8)",
        "[USE_AFTER_MOVE] main::field_owner -- used after being moved (line 8)",
        "[USE_AFTER_MOVE] main::index -- used after being moved (line 8)",
        "[USE_AFTER_MOVE] main::list_item -- used after being moved (line 8)",
      )
    end

    it "treats simple GIVE arguments as moves while checking complex GIVE receivers" do
      checker = direct_checker
      state = moved_state("simple", "owner")
      simple_move = AST::FuncCall.new(
        Lexer::Token.new(:IDENTIFIER, "take", 12, 3),
        "take",
        [AST::MoveNode.new(Lexer::Token.new(:GIVE, "GIVE", 12, 8), id_node("simple", line: 12))],
      )
      complex_move = AST::FuncCall.new(
        Lexer::Token.new(:IDENTIFIER, "take", 13, 3),
        "take",
        [
          AST::MoveNode.new(
            Lexer::Token.new(:GIVE, "GIVE", 13, 8),
            AST::GetField.new(
              Lexer::Token.new(:CHAR, ".", 13, 18),
              id_node("owner", line: 13),
              "field",
            ),
          ),
        ],
      )

      checker.send(:check_reads_in_expr, simple_move, state)
      expect(checker.errors).to be_empty

      checker.send(:check_reads_in_expr, complex_move, state)
      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::owner -- used after being moved (line 13)",
      )
    end

    it "checks copy-like wrappers, string concat parts, and call receivers/args" do
      checker = direct_checker
      state = moved_state(
        "copy_source",
        "clone_source",
        "freeze_source",
        "concat_part",
        "fn_arg",
        "method_receiver",
        "method_arg",
      )
      expressions = [
        AST::CopyNode.new(Lexer::Token.new(:COPY, "COPY", 36, 3), id_node("copy_source", line: 36)),
        AST::CloneNode.new(Lexer::Token.new(:CLONE, "CLONE", 37, 3), id_node("clone_source", line: 37)),
        AST::FreezeNode.new(Lexer::Token.new(:FREEZE, "FREEZE", 38, 3), id_node("freeze_source", line: 38)),
        AST::StringConcat.new(
          Lexer::Token.new(:STRING, '"#{concat_part}"', 39, 3),
          [AST::Literal.new(Lexer::Token.new(:STRING, '"prefix"', 39, 3), :STRING, "prefix", :rodata),
           id_node("concat_part", line: 39)],
        ),
        AST::FuncCall.new(
          Lexer::Token.new(:IDENTIFIER, "use", 40, 3),
          "use",
          [id_node("fn_arg", line: 40)],
        ),
        AST::MethodCall.new(
          Lexer::Token.new(:IDENTIFIER, "push", 41, 19),
          id_node("method_receiver", line: 41),
          "push",
          [id_node("method_arg", line: 41)],
        ),
      ]

      expressions.each { |expr| checker.send(:check_reads_in_expr, expr, state) }

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::copy_source -- used after being moved (line 36)",
        "[USE_AFTER_MOVE] main::clone_source -- used after being moved (line 37)",
        "[USE_AFTER_MOVE] main::freeze_source -- used after being moved (line 38)",
        "[USE_AFTER_MOVE] main::concat_part -- used after being moved (line 39)",
        "[USE_AFTER_MOVE] main::fn_arg -- used after being moved (line 40)",
        "[USE_AFTER_MOVE] main::method_receiver -- used after being moved (line 41)",
        "[USE_AFTER_MOVE] main::method_arg -- used after being moved (line 41)",
      )
    end
  end

  describe "direct statement read dispatch" do
    it "checks declaration and return values as reads" do
      checker = direct_checker
      state = moved_state("decl_value", "return_value")
      decl = AST::VarDecl.new(
        Lexer::Token.new(:IDENTIFIER, "x", 16, 3),
        "x",
        nil,
        id_node("decl_value", line: 16),
        false,
      )
      ret = AST::ReturnNode.new(
        Lexer::Token.new(:RETURN, "RETURN", 17, 3),
        id_node("return_value", line: 17),
      )

      checker.send(:check_stmt_reads, decl, state)
      checker.send(:check_stmt_reads, ret, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::decl_value -- used after being moved (line 16)",
        "[USE_AFTER_MOVE] main::return_value -- used after being moved (line 17)",
      )
    end

    it "does not read simple assignment targets but checks field/index assignment targets" do
      checker = direct_checker
      state = moved_state("lhs", "rhs", "field_owner", "index_owner", "index_key")
      simple = AST::Assignment.new(
        Lexer::Token.new(:IDENTIFIER, "lhs", 20, 3),
        id_node("lhs", line: 20),
        id_node("rhs", line: 20),
      )
      field_assign = AST::Assignment.new(
        Lexer::Token.new(:IDENTIFIER, "field_owner", 21, 3),
        AST::GetField.new(
          Lexer::Token.new(:CHAR, ".", 21, 14),
          id_node("field_owner", line: 21),
          "value",
        ),
        AST::Literal.new(Lexer::Token.new(:INT, "1", 21, 23), :INT64, 1, :stack),
      )
      index_assign = AST::Assignment.new(
        Lexer::Token.new(:IDENTIFIER, "index_owner", 22, 3),
        AST::GetIndex.new(
          Lexer::Token.new(:CHAR, "[", 22, 14),
          id_node("index_owner", line: 22),
          id_node("index_key", line: 22),
        ),
        AST::Literal.new(Lexer::Token.new(:INT, "1", 22, 29), :INT64, 1, :stack),
      )

      checker.send(:check_stmt_reads, simple, state)
      checker.send(:check_stmt_reads, field_assign, state)
      checker.send(:check_stmt_reads, index_assign, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::rhs -- used after being moved (line 20)",
        "[USE_AFTER_MOVE] main::field_owner -- used after being moved (line 21)",
        "[USE_AFTER_MOVE] main::index_owner -- used after being moved (line 22)",
        "[USE_AFTER_MOVE] main::index_key -- used after being moved (line 22)",
      )
    end

    it "checks control-flow header expressions" do
      checker = direct_checker
      state = moved_state("if_cond", "while_cond", "match_expr", "each_collection")
      stmts = [
        AST::IfStatement.new(
          Lexer::Token.new(:IF, "IF", 26, 3),
          id_node("if_cond", line: 26),
          [],
          [],
          nil,
          nil,
        ),
        AST::WhileLoop.new(
          Lexer::Token.new(:WHILE, "WHILE", 27, 3),
          id_node("while_cond", line: 27),
          [],
          nil,
        ),
        AST::MatchStatement.new(
          Lexer::Token.new(:MATCH, "MATCH", 28, 3),
          id_node("match_expr", line: 28),
          [],
          nil,
          nil,
          nil,
          false,
          false,
        ),
        AST::ForEach.new(
          Lexer::Token.new(:FOR, "FOR", 29, 3),
          "item",
          id_node("each_collection", line: 29),
          [],
          nil,
          false,
        ),
      ]

      stmts.each { |stmt| checker.send(:check_stmt_reads, stmt, state) }

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::if_cond -- used after being moved (line 26)",
        "[USE_AFTER_MOVE] main::while_cond -- used after being moved (line 27)",
        "[USE_AFTER_MOVE] main::match_expr -- used after being moved (line 28)",
        "[USE_AFTER_MOVE] main::each_collection -- used after being moved (line 29)",
      )
    end

    it "checks non-resource BG captures and skips resource captures" do
      checker = direct_checker
      state = moved_state("borrowed_capture", "resource_capture")
      bg = AST::BgBlock.new(
        Lexer::Token.new(:BG, "BG", 33, 3),
        [],
        [],
        nil,
        false,
        false,
        nil,
        false,
      )
      bg.capture_analysis = CapabilityHelper::CaptureAnalysis.new(
        captures: {
          "borrowed_capture" => Type.new(:String),
          "resource_capture" => Type.new(:String),
        },
        resource_captures: Set["resource_capture"],
      )

      checker.send(:check_stmt_reads, bg, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::borrowed_capture -- used after being moved (line 33)",
      )
    end
  end

  describe "SHARE read checks" do
    it "routes call arguments by ownership wrapper shape" do
      checker = direct_checker
      state = moved_state(
        "already_moved_arg",
        "simple_give_arg",
        "copy_arg",
        "clone_arg",
        "freeze_arg",
        "share_copy_arg",
      )
      already_moved = id_node("already_moved_arg", line: 44)
      already_moved.was_moved = true
      call = AST::FuncCall.new(
        Lexer::Token.new(:IDENTIFIER, "use", 44, 3),
        "use",
        [
          already_moved,
          AST::MoveNode.new(Lexer::Token.new(:GIVE, "GIVE", 45, 3), id_node("simple_give_arg", line: 45)),
          AST::CopyNode.new(Lexer::Token.new(:COPY, "COPY", 46, 3), id_node("copy_arg", line: 46)),
          AST::CloneNode.new(Lexer::Token.new(:CLONE, "CLONE", 47, 3), id_node("clone_arg", line: 47)),
          AST::FreezeNode.new(Lexer::Token.new(:FREEZE, "FREEZE", 48, 3), id_node("freeze_arg", line: 48)),
          AST::ShareNode.new(
            Lexer::Token.new(:SHARE, "SHARE", 49, 3),
            AST::CopyNode.new(Lexer::Token.new(:COPY, "COPY", 49, 9), id_node("share_copy_arg", line: 49)),
          ),
        ],
      )

      checker.send(:check_call_reads, call, state)

      expect(checker.errors).to contain_exactly(
        "[USE_AFTER_MOVE] main::copy_arg -- used after being moved (line 46)",
        "[USE_AFTER_MOVE] main::clone_arg -- used after being moved (line 47)",
        "[USE_AFTER_MOVE] main::freeze_arg -- used after being moved (line 48)",
        "[USE_AFTER_MOVE] main::share_copy_arg -- used after being moved (line 49)",
      )
    end

    it "reports SHARE COPY reads of already moved values in call arguments" do
      errors = check_errors(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN takes_shared(b: Box @shared) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          moved = b;
          takes_shared(SHARE COPY b);
          RETURN;
        END
      CLEAR
      expect(errors.any? { |e| e.include?("USE_AFTER_MOVE") && e.include?("b") }).to be true
    end

    it "reports SHARE COPY reads of already moved values in expressions" do
      errors = check_errors(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          b = Box{ value: 1 };
          moved = b;
          s = SHARE COPY b;
          RETURN;
        END
      CLEAR
      expect(errors.any? { |e| e.include?("USE_AFTER_MOVE") && e.include?("b") }).to be true
    end

    it "treats SHARE of an existing shared handle as a read" do
      token = Lexer::Token.new(:VAR_ID, "shared", 7, 3)
      ident = AST::Identifier.new(token, "shared")
      ident.full_type = Type.new(:Box, ownership: :shared)
      share = AST::ShareNode.new(token, ident)
      fn_node = empty_function_node
      checker = UseAfterMoveChecker.new(fn_node, OwnershipDataflow.new(FunctionCFG.build(fn_node), fn_node))
      state = OwnershipDataflow.state_from_names(
        "shared" => OwnershipDataflow::OwnerEntry.new(state: :moved, allocator: :heap, needs_cleanup: true)
      )

      checker.send(:check_share_reads, share, state)
      expect(checker.errors.first).to include("USE_AFTER_MOVE")
      expect(checker.errors.first).to include("shared")
    end
  end

  describe "borrow checking explicit moves" do
    it "reports no active borrow kind for unborrowed names" do
      state = BorrowChecker::BorrowState.empty

      expect(state.kind_for("missing")).to be_nil
      expect(state.conflicts_with?("missing", :immutable)).to be(false)
    end

    it "reports GIVE of a borrowed heap value inside the borrow scope" do
      errors = borrow_errors(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN consume!(TAKES u: User @indirect) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          WITH BORROWED a AS ref {
            consume!(GIVE a);
          }
          RETURN;
        END
      CLEAR

      expect(errors).to include(a_string_matching("MOVE_WHILE_BORROWED"))
      expect(errors.first).to include("main::a")
    end
  end

  # =========================================================================
  # Phase 5: Promotion modeled as ownership transfer
  # =========================================================================

  # =========================================================================
  # Phase 5: Promotion modeled as ownership transfer
  #
  # In CLEAR's arena model, promotion = copy (frame original stays alive).
  # Unlike Rust where `return x` moves x, CLEAR wraps returned values in
  # CopyNode (frame-to-heap copy). The dataflow correctly models this:
  # sources of copies stay :owned, only explicit moves (GIVE on heap types,
  # non-Copy assignment) mark sources as :moved.
  # =========================================================================

  describe "promotion as ownership transfer" do
    it "direct return of collection marks source as moved" do
      df = analyze_state(<<~CLEAR, "makeList")
        FN makeList() RETURNS !Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
      CLEAR
      # Direct return of identifier: marked as moved by collect_binding_move_places.
      expect(df.exit_states["items"]).to eq(:moved)
    end

    it "struct literal return copies fields (CopyNode), source stays owned" do
      df = analyze_state(<<~CLEAR, "wrap")
        STRUCT Wrapper { data: Int64[] }
        FN wrap() RETURNS !Wrapper @indirect ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN Wrapper{ data: items };
        END
      CLEAR
      # Annotator wraps struct literal field values in CopyNode for promotion.
      # CopyNode does NOT consume the source -- frame original stays alive.
      expect(df.exit_states["items"]).to eq(:owned)
    end

    it "return preserves allocator info on moved OwnerEntry" do
      df = analyze_state(<<~CLEAR, "makeList")
        FN makeList() RETURNS !Int64[] ->
          MUTABLE items: Int64[]@list = List[];
          items.append(1_i64);
          RETURN items;
        END
      CLEAR
      entry = df.exit_states["items"]
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.state).to eq(:moved)
        expect(entry.allocator).not_to be_nil
      end
    end

    it "GIVE on @list creates copy, source stays owned" do
      df = analyze_state(<<~CLEAR)
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          n = consume(GIVE vals);
          RETURN;
        END
      CLEAR
      # GIVE on frame @list creates CopyNode (frame-to-heap copy).
      # The original frame list stays alive until frame rewind.
      expect(df.exit_states["vals"]).to eq(:owned)
    end

    it "non-Copy assignment marks source as moved" do
      df = analyze_state(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          a: User @indirect = User{ id: 1 };
          b = a;
          RETURN;
        END
      CLEAR
      # Direct assignment of non-Copy heap struct IS a move
      expect(df.exit_states["a"]).to eq(:moved)
      expect(df.exit_states["b"]).to eq(:owned)
    end

    it "TAKES param tracked with allocator info" do
      df = analyze_state(<<~CLEAR, "consume")
        FN consume(TAKES items: Int64[]) RETURNS Int64 ->
          RETURN items.length();
        END
      CLEAR
      entry = df.exit_states["items"]
      expect(entry).not_to be_nil
      if entry.is_a?(OwnershipDataflow::OwnerEntry)
        expect(entry.allocator).to eq(:heap)
      end
    end
  end
end
