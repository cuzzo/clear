require "rspec"
require "set"
require "tempfile"

require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/diagnostic_buckets" unless defined?(DiagnosticBuckets)
require_relative "../ruby/ast/diagnostic_examples" unless defined?(DiagnosticExamples::FixScan)
require_relative "../ruby/ast/diagnostic_registry" unless defined?(DiagnosticRegistry)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/std_lib" unless defined?(StdLibTypeBinding)
require_relative "../ruby/ast/symbol_entry" unless defined?(SymbolEntry::BindingLifecycleFacts)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/annotator/helpers/function_signature" unless defined?(FunctionSignature::AnalysisFacts)
require_relative "../ruby/annotator/helpers/prefixed_int_range" unless defined?(PrefixedIntRange)

RSpec.describe "AST coverage burndown" do
  def token(type = :VAR_ID, value = "x", line: 1, column: 1)
    Lexer::Token.new(type, value, line, column)
  end

  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse_expr(source)
    parser_for(source).send(:parse_expression)
  end

  def parse_program(source)
    parser_for(source).parse
  end

  describe "diagnostic helper modules" do
    it "reports bucket coverage, statuses, stars, and alien labels" do
      examples = {
        ARITY_MISMATCH: { bad: "bad", good: "good" },
        RETURN_MISMATCH: { bad: "bad" },
      }

      expect(DiagnosticBuckets.covered_codes).to include(:ARITY_MISMATCH)
      expect(DiagnosticBuckets.status_of(:ARITY_MISMATCH, examples)).to eq(:annotated)
      expect(DiagnosticBuckets.status_of(:RETURN_MISMATCH, examples)).to eq(:todo)

      pending_code = DiagnosticRegistry::DIAGNOSTICS.find { |_, entry| entry[:pending] == true }&.first
      expect(DiagnosticBuckets.status_of(pending_code, {})).to eq(:pending) if pending_code

      expect(DiagnosticBuckets.frequency_stars(3)).to eq("★★★☆☆")
      expect(DiagnosticBuckets.alien_label(:low)).to eq("Low")
      expect(DiagnosticBuckets.alien_label(:medium)).to eq("Med")
      expect(DiagnosticBuckets.alien_label(:high)).to eq("High")
      expect(DiagnosticBuckets.alien_label(:unknown)).to eq("?")
    end

    it "scans through comments after an example annotation that has no describe" do
      file = Tempfile.new(["diagnostic_examples", ".rb"])
      file.write(<<~RUBY)
        # @example_for: ARITY_MISMATCH
        # @fix: Add the missing argument.
        #
        # another comment before malformed content
        not_a_describe
      RUBY
      file.close

      expect(DiagnosticExamples.send(:load!, [file.path])).to eq({})
    ensure
      file&.unlink
    end

    it "checks pending registry entries directly" do
      pending_code = DiagnosticRegistry::DIAGNOSTICS.find { |_, entry| entry[:pending] == true }&.first
      expect(DiagnosticRegistry.pending?(pending_code)).to be(true) if pending_code
      expect(DiagnosticRegistry.pending?(:ARITY_MISMATCH)).to be(false)
      expect(DiagnosticRegistry.pending?(:NOT_REAL)).to be(false)
    end
  end

  describe "AST node predicates" do
    it "identifies SMOOTH binary operations without exposing the raw op check" do
      tok = token(:SMOOTH, "|>")
      left = AST::Identifier.new(tok, "xs")
      right = AST::Identifier.new(tok, "map")

      expect(AST::BinaryOp.new(tok, left, :SMOOTH, right).smooth?).to eq(true)
      expect(AST::BinaryOp.new(tok, left, :ADD, right).smooth?).to eq(false)
    end
  end

  describe "fixable diagnostics primitives" do
    it "serializes spans and validates fix confidence" do
      span = Span.new(file: "main.clear", line: 2, col: 4, length: 3)

      expect(span.to_h).to eq(
        file: "main.clear", line: 2, col: 4, length: 3,
        end_line: 2, end_col: 7
      )
      expect {
        Fix.new(description: "bad", confidence: :certain, edits: [
          Edit.new(span: span, replacement: "x"),
        ])
      }.to raise_error(ArgumentError, /confidence/)
    end

    it "tracks fatal findings while the collector is enabled" do
      FixCollector.enable!
      finding = FixableFinding.new(
        level: :error,
        message: "fatal",
        token: token,
        category: :type,
        fixes: []
      )

      FixCollector.push(finding)

      expect(FixCollector.has_fatal?).to be(true)
      expect(FixCollector.fatal_count).to eq(1)
    ensure
      FixCollector.disable!
    end
  end

  describe Lexer do
    it "covers binary suffixes, float suffix errors, escapes, and unclosed interpolation" do
      expect(Lexer.new("0b101_i8").tokenize.first).to have_attributes(type: :INT8, value: 5)
      expect(Lexer.new("1_f32").tokenize.first).to have_attributes(type: :FLOAT32, value: 1.0)
      expect(Lexer.new("\"a\\0b\"").tokenize.first.value).to eq("a\0b")
      expect(Lexer.new("\"a\\q\"").tokenize.first.value).to eq("a\\q")

      expect { Lexer.new("1.0_i8").tokenize }.to raise_error(/Unknown float suffix/)
      expect { Lexer.new("`").tokenize }.to raise_error(/Unexpected char/)
      expect { Lexer.new("\"unterminated").tokenize }.to raise_error(/Unclosed string/)
      expect { Lexer.new("\"${x\"").tokenize }.to raise_error(/Unclosed interpolation/)
    end
  end

  describe AST do
    it "exposes typed readers and writers for binding and pattern structs" do
      name_tok = token(:VAR_ID, "name")
      symbol = SymbolEntry.new(reg: nil, type: :Int64, mutable: false, storage: :frame)
      binding = AST::Binding.new(
        expr: AST::Identifier.new(name_tok, "value"),
        name: "name",
        name_token: name_tok,
        symbol: symbol,
        capture: "cap"
      )
      capability = AST::Capability.new(capability: :EXCLUSIVE)
      field = AST::PatternField.new(name: "x", value: :bind, name_token: name_tok)

      expect(binding.name_token).to eq(name_tok)
      expect(binding.symbol).to eq(symbol)
      expect(binding.capture).to eq("cap")
      capability.resolved_type = Type.new(:String)
      expect(capability.resolved_type.resolved).to eq(:String)
      expect(field.value).to eq(:bind)
      field.value = AST::Identifier.new(name_tok, "other")
      expect(field.expr.name).to eq("other")
    end

    it "classifies declaration nodes and exposes default child bodies" do
      tok = token(:KEYWORD, "STRUCT")
      struct_def = AST::StructDef.new(tok, "Point", {}, :package, nil)
      extern_struct = AST::ExternStructDecl.new(tok, "Native", {}, nil)
      enum_def = AST::EnumDef.new(tok, "Color", ["Red"], :package)
      union_def = AST::UnionDef.new(tok, "Shape", {}, :package)

      expect(AST.type_declaration?(struct_def)).to be(true)
      expect(AST.type_declaration?(extern_struct)).to be(true)
      expect(AST.type_declaration?(enum_def)).to be(true)
      expect(AST.type_declaration?(union_def)).to be(true)
      expect(AST.top_level_declaration?(AST::RequireNode.new(tok, "file.clear", "file", :local))).to be(true)
      expect(AST.top_level_declaration?(AST::ExternFnDecl.new(tok, "native", [], nil, "mod", {}))).to be(true)
      expect(Class.new { include AST::HasBodies }.new.child_bodies).to eq([])
    end

    it "walks return-node BG values and hash-valued child nodes" do
      tok = token
      bg = AST::BgBlock.new(tok, [], nil, nil, nil, nil, nil, nil)
      seen = []
      AST.each_bg_block_in_stmt(AST::ReturnNode.new(tok, bg)) { |node| seen << node }
      expect(seen).to eq([bg])

      lit = AST::Literal.new(tok, :INT64, 1, nil)
      struct_lit = AST::StructLit.new(tok, "Point", { "x" => lit }, nil, nil)
      children = []
      AST.each_child_node(struct_lit) { |child| children << child }
      expect(children).to include(lit)
    end

    it "covers Locatable storage helpers and derived binary types" do
      tok = token
      left = AST::Literal.new(tok, :INT64, 1, nil)
      right = AST::Literal.new(tok, :INT64, 2, nil)
      cmp = AST::BinaryOp.new(tok, left, :LT, right)
      expect(cmp.full_type.resolved).to eq(:Bool)

      ident = AST::Identifier.new(tok, "x")
      ident.full_type = Type.new(:String)
      expect(ident.base_type).to eq(:String)
      ident.storage = :frame
      expect(ident.frame_provenance?).to be(true)
      expect(ident.stack_storage?).to be(false)

      fn = AST::FunctionDef.new(tok, "f", [], nil, nil, nil, [], nil, nil, :package, nil, nil)
      expect(fn.finalize_storage!(Type.new(:Int64))).to eq(:stack)
      expect(fn.full_type.resolved).to eq(:Int64)
    end

    it "normalizes body-list writers on AST nodes" do
      tok = token
      fn = AST::FunctionDef.new(tok, "f", nil, nil, nil, nil, [], nil, nil, :package, nil, nil)
      lambda_node = AST::LambdaLit.new(tok, nil, nil, [], nil, nil)
      if_bind = AST::IfBind.new(tok, nil, [], nil)
      with_block = AST::WithBlock.new(tok, nil, [])
      pattern = AST::StructPattern.new(tok, nil, false)
      extern_fn = AST::ExternFnDecl.new(tok, "native", nil, nil, "mod", {})
      match_stmt = AST::MatchStatement.new(tok, nil, nil, nil, nil, nil, false, false)

      fn.params = [AST::Param.new(name: "x", type: :Int64)]
      lambda_node.params = nil
      if_bind.bindings = [AST::Binding.new(expr: AST::Identifier.new(tok, "x"), name: "x", name_token: tok)]
      with_block.capabilities = [AST::Capability.new(capability: :infer)]
      pattern.fields = [AST::PatternField.new(name: "x", value: :bind, name_token: tok)]
      extern_fn.params = nil
      match_stmt.cases = [AST::MatchCase.new(kind: :eq, value: AST::Literal.new(tok, :INT64, 1, nil), body: [])]

      expect(fn.params.length).to eq(1)
      expect(lambda_node.params).to eq([])
      expect(if_bind.bindings.length).to eq(1)
      expect(with_block.capabilities.length).to eq(1)
      expect(pattern.fields.length).to eq(1)
      expect(extern_fn.params).to eq([])
      expect(match_stmt.cases.length).to eq(1)
    end

    it "normalizes param and capture type slots to concrete Type objects" do
      explicit = Type.new(:String)
      typed_param = AST::Param.new(name: "name", type: explicit)
      nil_param = AST::Param.new(name: "fallback", type: nil)
      symbol_param = AST::Param.new(name: "count", type: :Int64)

      expect(typed_param.type.resolved).to eq(:String)
      expect(nil_param.type.resolved).to eq(:Any)
      expect(symbol_param.type.resolved).to eq(:Int64)

      typed_param.type = "Bool"
      nil_param.type = explicit
      symbol_param.type = nil

      expect(typed_param.type.resolved).to eq(:Bool)
      expect(nil_param.type.resolved).to eq(:String)
      expect(symbol_param.type.resolved).to eq(:Any)

      capture = AST::Capture.new(name: "cap", type: nil)
      expect(capture.type.resolved).to eq(:Any)
      capture.type = :Float64
      expect(capture.type.resolved).to eq(:Float64)
      capture.type = explicit
      expect(capture.type.resolved).to eq(:String)
    end

    it "names function and extern return type phase defaults explicitly" do
      tok = token
      implicit = AST::FunctionDef.new(tok, "implicit", [], [], nil, nil, [], [], nil, :package, [], false)
      declared = AST::FunctionDef.new(tok, "declared", [], [], :Int64, nil, [], [], nil, :package, [], false)

      expect(implicit.implicit_return_type?).to be(true)
      expect(implicit.declared_return_type).to be_nil
      expect(implicit.annotation_return_type.resolved).to eq(:Any)
      expect(implicit.lowering_return_type.resolved).to eq(:Void)
      expect(declared.implicit_return_type?).to be(false)
      expect(declared.declared_return_type.resolved).to eq(:Int64)
      expect(declared.annotation_return_type.resolved).to eq(:Int64)
      expect(declared.lowering_return_type.resolved).to eq(:Int64)

      extern = AST::ExternFnDecl.new(tok, "native", [], "Bool", "mod", {})
      expect(extern.return_type.resolved).to eq(:Bool)
      expect(extern.annotation_return_type.resolved).to eq(:Bool)
      extern.return_type = nil
      expect(extern.annotation_return_type.resolved).to eq(:Any)
      extern.return_type = :Float64
      expect(extern.return_type.resolved).to eq(:Float64)
    end

    it "normalizes schema field and union payload type boundaries" do
      explicit = Type.new(:String)
      field = AST::StructField.new(type: :Int64)
      nil_field = AST::StructField.new(type: nil)
      typed_field = AST::StructField.new(type: explicit, borrowed: true)

      expect(field.type.resolved).to eq(:Int64)
      expect(nil_field.type.resolved).to eq(:Any)
      expect(typed_field.type.resolved).to eq(:String)
      expect(typed_field.borrowed).to be(true)

      field.type = "Bool"
      nil_field.type = explicit
      typed_field.type = nil

      expect(field.type.resolved).to eq(:Bool)
      expect(nil_field.type.resolved).to eq(:String)
      expect(typed_field.type.resolved).to eq(:Any)

      inline = Schemas::InlineStructVariant.new(fields: { radius: :Float64, "name" => explicit })
      expect(inline.typed_fields["radius"].resolved).to eq(:Float64)
      expect(inline.typed_fields["name"].resolved).to eq(:String)
      expect(inline.typed_fields.keys).to contain_exactly("radius", "name")

      union = Schemas::UnionSchema.new(variants: {
        Some: :Int64,
        "Named" => "String",
        Existing: explicit,
        Unit: nil,
        Inline: inline
      })
      expect(Type.from_variant_input(union.variants[:Some]).resolved).to eq(:Int64)
      expect(Type.from_variant_input(union.variants["Named"]).resolved).to eq(:String)
      expect(Type.from_variant_input(union.variants[:Existing]).resolved).to eq(:String)
      expect(union.variants[:Unit]).to be_nil
      expect(union.variants[:Inline]).to equal(inline)
    end

    it "exposes stable semantic type ids at phase boundaries" do
      number_id = Type.new(:Number).send(:type_id)
      float_id = Type.new(:Float64).send(:type_id)
      shared_string_id = Type.new(:String, ownership: :shared).send(:type_id)
      plain_string_id = Type.new(:String).send(:type_id)

      expect(number_id.key).to eq(float_id.key)
      expect(number_id.to_s).to eq(float_id.key)
      expect(shared_string_id.key).not_to eq(plain_string_id.key)

      fn_sig = FunctionSignature.new(
        params: [AST::Param.new(name: "x", type: :Int64)],
        return_type: :String,
        reentrant: true
      )
      fn_id = Type.from_function_signature(fn_sig).send(:type_id).key

      expect(fn_id).to include("fn(")
      expect(fn_id).to include("Int64")
      expect(fn_id).to include("String")
      expect(fn_id).to include("reentrant")

      schemas = {
        Box: Schemas::StructSchema.new(fields: {
          "name" => AST::StructField.new(type: Type.new(:String, location: :heap)),
        }),
      }
      expect(Type.new(:Box).recursive_cleanup_shape?(->(name) { schemas[name] })).to be(true)
    end

    it "collects all test hook and test bodies from TestBlock" do
      tok = token
      setup = [AST::PassStmt.new(tok)]
      before_each = [AST::PassStmt.new(tok)]
      after_each = [AST::PassStmt.new(tok)]
      before_all = [AST::PassStmt.new(tok)]
      after_all = [AST::PassStmt.new(tok)]
      test_body = [AST::PassStmt.new(tok)]
      when_setup = [AST::PassStmt.new(tok)]
      when_block = AST::WhenBlock.new(tok, "case", when_setup, [AST::TestThat.new(tok, "works", test_body)], [])
      block = AST::TestBlock.new(tok, "suite", setup, [when_block])
      block.before_each = [before_each]
      block.after_each = [after_each]
      block.before_all = [before_all]
      block.after_all = [after_all]

      expect(block.child_bodies).to eq([setup, before_each, after_each, before_all, after_all, when_setup, test_body])
    end
  end

  describe ClearParser do
    it "covers token-level parser helpers and parser-only predicate suffixes" do
      underscore = ClearParser.new([
        token(:UNDERSCORE, "_"),
        token(:EOF, nil),
      ], "_").send(:consume_literal, "_")
      expect(underscore.type).to eq(:UNDERSCORE)

      parser = parser_for("x")
      expect(parser.send(:match_at?, 1, :EOF)).to be(true)
      expect(parser.send(:match_at?, 99, :EOF)).to be(false)
      expect { parser.send(:consume_number) }.to raise_error(ParserError, /Expected a number/)

      manual_tokens = [
        token(:VAR_ID, "obj"),
        token(:CHAR, "."),
        token(:VAR_ID, "check"),
        token(:CHAR, "?"),
        token(:CHAR, "("),
        token(:CHAR, ")"),
        token(:EOF, nil),
      ]
      method_call = ClearParser.new(manual_tokens, "obj.check?()").send(:parse_expression)
      expect(method_call).to be_a(AST::MethodCall)
      expect(method_call.name).to eq("check?")

      call_tokens = [
        token(:VAR_ID, "check"),
        token(:CHAR, "?"),
        token(:CHAR, "("),
        token(:CHAR, ")"),
        token(:EOF, nil),
      ]
      func_call = ClearParser.new(call_tokens, "check?()").send(:parse_expression)
      expect(func_call).to be_a(AST::FuncCall)
      expect(func_call.name).to eq("check?")
    end

    it "covers functor-call suffixes and bind backtracking" do
      expect(parse_expr("(f)()")).to be_a(AST::FuncCall)

      compound = parser_for("f() += 1;")
      expect(compound.send(:try_parse_bind_or_assign)).to be_nil

      assignment = parser_for("f() = 1;")
      expect(assignment.send(:try_parse_bind_or_assign)).to be_nil
    end

    it "parses TIGHT, EXIT, DIE, extern, method, and requires edge cases" do
      tight = parser_for("TIGHT WHILE true -> PASS;").send(:parse_statement)
      expect(tight).to be_a(AST::WhileLoop)
      expect(tight.tight).to be(true)
      expect { parser_for("TIGHT PASS;").send(:parse_statement) }.to raise_error(/Expected WHILE or FOR/)

      expect(parser_for("EXIT \"done\";").send(:parse_statement)).to be_a(AST::ThrowNode)
      expect(parser_for("DIE;").send(:parse_statement).status.value).to eq(1)
      expect(parser_for("DIE 7;").send(:parse_statement).status.value).to eq(7)

      extern_plain = parser_for('EXTERN FN Native<T>() RETURNS Int64 EFFECTS :alloc FROM "m";').parse.statements.first
      expect(extern_plain.name).to eq("Native")
      expect(extern_plain.fn_type_params).to eq([:T])
      expect(extern_plain.effects[:alloc]).to eq(:frame)

      method = parser_for("METHOD update() -> RETURN; END").send(:parse_function_def)
      expect(method.is_method).to be(true)

      expect {
        parser_for("REQUIRES cb: WRONG").send(:parse_requires_clauses, "f")
      }.to raise_error(ParserError, /Unknown REQUIRES kind/)
      expect {
        parser_for("REQUIRES cb: NON_REENTRANT REQUIRES cb: NON_REENTRANT").send(:parse_requires_clauses, "f")
      }.to raise_error(ParserError, /duplicate REQUIRES/)
    end

    it "parses OR_ELSE-rescue variants and IF bind validation paths" do
      return_fallback = parse_expr("call() OR_ELSE RETURN")
      expect(return_fallback.right).to be_a(AST::ReturnNode)
      exit_fallback = parse_expr("call() OR_ELSE EXIT")
      expect(exit_fallback.right).to be_a(AST::OrElseExit)
      else_fallback = parse_expr("call() OR_ELSE ELSE 0")
      expect(else_fallback.right.value).to eq(0)

      lhs = AST::Identifier.new(token, "value")
      op_tok = token(:KEYWORD, "AS")
      bad_rhs_parser = ClearParser.new([
        token(:VAR_ID, "fn"),
        token(:CHAR, "("),
        token(:CHAR, ")"),
        token(:EOF, nil),
      ], "value AS fn()")
      expect {
        bad_rhs_parser.send(:parse_binary_op, lhs, op_tok, 2)
      }.to raise_error(ParserError, /Expected identifier after 'AS'/)

      expect {
        parser_for("IF maybe AS a && other AS b THEN PASS; END").send(:parse_statement)
      }.to raise_error(ParserError, /Multiple optional bindings/)

      bare = AST::BinaryOp.new(token, AST::Identifier.new(token, "maybe"), :BIND_VAR, AST::Identifier.new(token, "a"))
      expect {
        parser_for("").send(:validate_no_bare_bind!, AST::BinaryOp.new(token, bare, :AND, AST::Identifier.new(token, "ok")), token(:KEYWORD, "IF"))
      }.to raise_error(ParserError, /Multiple optional bindings/)
      expect {
        parser_for("").send(:validate_no_bare_bind!, AST::BinaryOp.new(token, AST::Identifier.new(token, "ok"), :AND, bare), token(:KEYWORD, "IF"))
      }.to raise_error(ParserError, /Multiple optional bindings/)
    end

    it "parses match-expression arms, multi-pattern metadata, and while-bind shorthand" do
      match_expr = parser_for("MATCH x START WHEN true -> 1, { y } -> 2, 3, 4 AS v -> 5, DEFAULT -> 6 END").send(:parse_match_expr)
      expect(match_expr.cases.map(&:kind)).to include(:when, :struct_pattern, :eq)
      multi = match_expr.cases.find { |c| c.extra_values.any? }
      expect(multi.binding).to eq("v")

      destructure = parser_for("MATCH x START 3 { y } -> 5, DEFAULT -> 6 END").send(:parse_match_expr)
      expect(destructure.cases.first.destructure).to be_a(AST::StructPattern)

      loop = parser_for("WHILE maybe AS value -> PASS;").send(:parse_statement)
      expect(loop).to be_a(AST::WhileBindLoop)
      expect(loop.do_branch.first).to be_a(AST::PassStmt)

      plain_loop = parser_for("WHILE TRUE -> PASS;").send(:parse_statement)
      expect(plain_loop).to be_a(AST::WhileLoop)
      expect(plain_loop.do_branch.first).to be_a(AST::PassStmt)
    end

    it "covers generic lookahead, array type errors, type source rendering, and concurrent/tap errors" do
      lookahead = parser_for("<Box<Int64>>{")
      expect(lookahead.send(:peek_generic_angle_params?, "{")).to be(true)

      expect { parser_for("Int64[Bad]").send(:parse_type_annotation) }.to raise_error(ParserError, /array type/)
      expect(parser_for("Int64[2][3]").send(:parse_type_annotation).resolved).to eq(:"Int64[2][3]")
      expect { parser_for("Int64[2][Bad]").send(:parse_type_annotation) }.to raise_error(ParserError, /array size|Expected '\]' or size/)

      renderer = parser_for("")
      {
        multiowned: "@multiowned",
        link: "@link",
        split: "@split",
        frozen: "@frozen",
      }.each do |ownership, text|
        t = Type.new(:Int64)
        t.ownership = ownership
        expect(renderer.send(:type_annotation_source, t)).to include(text)
      end
      {
        write_locked: "@writeLocked",
        versioned: "@versioned",
        atomic: "@atomic",
        local: "@local",
        always_mutable: "@alwaysMutable",
      }.each do |sync, text|
        t = Type.new(:Int64)
        t.sync = sync
        expect(renderer.send(:type_annotation_source, t)).to include(text)
      end

      expect {
        parser_for("MEDIAN x").send(:parse_concurrent_inner_op, token(:KEYWORD, "CONCURRENT"))
      }.to raise_error(ParserError, /Expected SELECT/)
      concurrent = parser_for("CONCURRENT(workers: 2, capacity: 4) SELECT 1").send(:parse_concurrent_op)
      expect(concurrent.options.keys).to contain_exactly("workers", "capacity")
      tap = parser_for("TAP log").send(:parse_tap_op)
      expect(tap.body.first).to be_a(AST::FuncCall)
    end

    it "covers WITH MATCH escape flags, capability join/rank errors, ASSERT_RAISES, selectors, and STUB errors" do
      with_match = parser_for("WITH POSSIBLE_DEADLOCK c MATCH WHEN LOCKED -> { PASS; } END").send(:parse_statement)
      expect(with_match.deadlock_escape[:kind]).to eq(:deadlock)

      with_block = parser_for("WITH POLYMORPHIC POSSIBLE_LOCK_CYCLE c AS inner { PASS; }").send(:parse_statement)
      expect(with_block.polymorphic).to be(true)
      expect(with_block.deadlock_escape[:kind]).to eq(:lock_cycle)

      expect {
        parser_for("ON , RETURN 1").send(:parse_error_selectors)
      }.to raise_error(ParserError, /Expected error selector/)

      expect(parser_for("PASS").send(:parse_lock_action).action).to eq(AST::ErrorActionKind::Pass)

      expect {
        ClearParser.new([
          token(:CHAR, ":"),
          token(:KEYWORD, "RETURN"),
          token(:EOF, nil),
        ], ": RETURN").send(:parse_cap_join, token(:VAR_ID, "@shared"), { dim: :ownership, val: :shared })
      }.to raise_error(ParserError, /Expected a capability/)

      expect {
        parser_for("(rank: 1)(rank: 2)").tap do |p|
          dims = { ownership: nil, sync: nil, layout: nil, lock_rank: 1 }
          p.send(:parse_lock_rank_arg!, token(:VAR_ID, "@locked"), { dim: :sync, val: :locked }, dims)
        end
      }.to raise_error(ParserError, /Duplicate rank/)

      assert = parser_for("ASSERT_RAISES Input, MissingField, fail();").send(:parse_assert_raises)
      expect(assert.error_name).to eq("MissingField")
      benchmark = parser_for("BENCHMARK compute(42) x17;").send(:parse_statement)
      expect(benchmark.iterations).to eq(17)
      expect {
        parser_for("STUB call UNKNOWN 1;").send(:parse_stub)
      }.to raise_error(ParserError, /STUB call/)
    end

    it "covers bare mutable declarations and IF expressions" do
      expect {
        parser_for("MUTABLE x;").send(:parse_statement)
      }.to raise_error(ParserError, /explicit type annotation/)

      if_expr = parse_expr("IF TRUE THEN 1 ELSE 2 END")
      expect(if_expr).to be_a(AST::IfStatement)
      expect(if_expr.then_branch.first.value).to eq(1)
    end
  end

  describe Type do
    it "covers capability and shape copying plus raw shape resolution" do
      caps = TypeCapabilities.new(ownership: :shared)
      expect(caps.copy.ownership).to eq(caps.ownership)
      expect(caps.copy).not_to equal(caps)

      shape = TypeShape.from_core("Box<Int64>")
      copy = shape.copy
      expect(copy.generic_args_raw).to eq([:Int64])
      expect(copy.generic_args_raw).not_to equal(shape.generic_args_raw)

      fn_type = Type::FunctionType.new(
        params: [Type::FunctionTypeParam.new(type: Type.new(:Int64))],
        return_type: Type.new(:Bool)
      )
      expect(TypeShape.new(raw: fn_type).resolved).to eq(:Any)
      expect(TypeShape.new(raw: fn_type).fn_type?).to be(true)
      expect(TypeShape.new(raw: "Float64").resolved).to eq(:Float64)
    end

    it "covers binary-op numeric and unknown-operator branches" do
      float_result = Type.binary_op(:MUL, Type.new(:Float32), Type.new(:Float64))
      expect(float_result.type.resolved).to eq(:Float64)
      expect(float_result.left_coercion).to eq(:Float64)
      expect(float_result.right_coercion).to be_nil

      fallback_result = Type.binary_op(:MUL, Type.new(:String), Type.new(:Bool))
      expect(fallback_result.error).to include("numeric operands")
      expect(Type.binary_op(:NOPE, Type.new(:Int64), Type.new(:Int64)).error).to include("Unknown operator")
    end

    it "covers collection predicates, foreach descriptors, and heap backing" do
      expect(Type.new(:Int32).signed_integer?).to be(true)
      map = Type.new(:"HashMap<Int64>")
      expect(map.associative_collection?).to be(true)
      expect(map.indexed_container_borrow?).to be(true)

      list = Type.new(:"Int64[]")
      list.collection = :list
      expect(list.fsm_foreach_descriptor.slice_suffix).to eq(".items")
      dynamic_array = Type.new(:"Int64[]")
      expect(dynamic_array.fsm_foreach_descriptor.slice_suffix).to eq(".items")
      expect(list.needs_heap_backing?).to be(false)
      pool = Type.new(:"Int64[]")
      pool.collection = :pool
      expect(pool.needs_heap_backing?).to be(true)
    end

    it "covers copyability and BG capture schema refinements" do
      expect(Type.new(:Custom).copyable?).to be(false)
      expect(Type.new(:Void).copyable?).to be(false)

      generic_enum = Type.new(:"Box<Int64>")
      enum_lookup = ->(name) { name == :Box ? Schemas::EnumSchema.new(variants: Set[:A]) : nil }
      expect(generic_enum.bg_capture_is_value_copy?(enum_lookup)).to be(true)

      heap_union = Schemas::UnionSchema.new(variants: { A: Type.new(:String), B: Type.new(:Int64) })
      value_union = Schemas::UnionSchema.new(variants: { A: Type.new(:Int64) })
      expect(Type.new(:Heapy).bg_capture_is_value_copy?(->(name) { name == :Heapy ? heap_union : nil })).to be(false)
      expect(Type.new(:Plain).bg_capture_is_value_copy?(->(name) { name == :Plain ? value_union : nil })).to be(true)
    end

    it "handles defensive from_node coercion and future/array/zig type edges" do
      bad_type = Class.new do
        def to_s
          raise "bad type"
        end
      end.new

      expect(Type.from_node(bad_type)).to be_nil
      expect(Type.new(:"~String[]").accepts?(Type.new(:"~String[]"))).to be(true)
      expect(Type.new(:"~Float64[]").send(:accepts_future?, Type.new(:"~Int64[]"))).to be(true)
      expect(Type.new(:"Int64[4]").accepts?(Type.new(:"Int64[3]"))).to be(true)
      expect(Type.new(:"~Float64[]").zig_type(is_param: false, is_field: false)).to eq("CheatLib.Range")
      expect(Type.new(:"~String[]").zig_type(is_param: false, is_field: false)).to eq("CheatLib.Stream([]const u8)")
    end

    it "strips every capability suffix and checks prefixed int ranges through error-union payloads" do
      suffix = Type.new(:Int64).send(:strip_capability_suffix, "Int64@split@frozen@writeLocked@versioned@atomic@local@alwaysMutable")
      expect(suffix.base).to eq("Int64")
      expect(suffix.ownership).to eq(:frozen)
      expect(suffix.sync).to eq(:always_mutable)
      locked = Type.strip_capability_suffix_from("Counter@shared:locked")
      expect(locked.sync).to eq(:locked)

      host = Class.new do
        include TypeHelper
        include PrefixedIntRange
        attr_reader :error
        def error!(*args, **kwargs)
          @error = [args, kwargs]
          nil
        end
        def handle_prefixed_int_overflow!(_node, _val, target_type, min, max)
          error!(:INT_LITERAL_OVERFLOW, type: target_type, min: min, max: max)
        end
      end.new
      host.check_prefixed_int_range!(AST::Literal.new(token, :PREFIXED_INT, 300, nil), Type.new(:"!Int8"))
      expect(host.error.last[:type]).to eq(:Int8)
    end
  end

  describe "standard library validators" do
    Arg = Struct.new(:resolved_type)

    it "reports Set.insert and HashMap.put type mismatches" do
      errors = []
      SET_METHODS.fetch("insert").fetch(:validate).call(
        token, [Arg.new(:String)], Type.new(:"Int64[]").tap { |t| t.collection = :set },
        ->(_node, message) { errors << message }
      )
      expect(errors.last).to include("Set.insert")

      MAP_METHODS.fetch("put").fetch(:validate).call(
        token, [Arg.new(:Int64), Arg.new(:String)], Type.new(:"HashMap<String>"),
        ->(_node, message) { errors << message }
      )
      expect(errors.last).to include("key must be a String")

      MAP_METHODS.fetch("put").fetch(:validate).call(
        token, [Arg.new(:String), Arg.new(:Float64)], Type.new(:"HashMap<Int64,Float64>"),
        ->(_node, message) { errors << message }
      )
      expect(errors.last).to include("key must be a numeric type")
    end
  end

  describe SymbolEntry do
    it "covers provenance, flow snapshots, and lifetime normalization errors" do
      entry = SymbolEntry.new(reg: nil, type: :Int64, mutable: true, storage: :frame)
      expect(entry.provenance).to eq(:frame)
      expect(entry.frame_provenance?).to be(true)
      entry.storage = :sync_cell
      expect(entry.provenance).to be_nil

      entry.mark_read!
      snapshot = entry.send(:flow_snapshot)
      expect(snapshot.read).to be(true)

      source = SymbolEntry.new(reg: nil, type: :Int64, mutable: false, storage: :stack)
      tied = SymbolEntry.new(reg: nil, type: :Int64, mutable: false, storage: :stack)
      tied.lifetime = { sources: [source] }
      expect(tied.lifetime).to eq([source])
      expect {
        tied.lifetime = { sources: [:bad] }
      }.to raise_error(TypeError, /lifetime sources/)
    end
  end
end
