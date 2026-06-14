require "rspec"
require_relative "../src/tools/lint_fix_rewriter" unless defined?(LintFixRewriter)

# Direct unit tests for LintFixRewriter — the source-level pre-pass
# that drops unused MUTABLE keywords and redundant `: Type`
# annotations during fmt. End-to-end tests through Formatter.format
# live in spec/clear_fmt_spec.rb; this file targets the rewriter
# in isolation so failures point at the right code.

RSpec.describe LintFixRewriter do
  def rw(src)
    LintFixRewriter.rewrite(src)
  end

  def tok(value = "x", line: 1, column: 1)
    Lexer::Token.new(:IDENTIFIER, value, line, column)
  end

  def int_lit(value = 0)
    AST::Literal.new(tok(value.to_s), :INT64, value, nil)
  end

  def identifier(name)
    AST::Identifier.new(tok(name), name)
  end

  def var_decl(name, type, value, line: 1, column: 1)
    AST::VarDecl.new(tok(name, line: line, column: column), name, type, value, false)
  end

  describe "robustness on broken source" do
    it "returns source unchanged when annotation fails" do
      # `Node{}` with a required `val` field will raise a CompilerError.
      # The rewriter must still return the source — fmt has to format
      # files with errors.
      src = <<~CLEAR
        STRUCT Node {
          val: Int64,
        }
        FN main() RETURNS Void ->
          x = Node{};
          RETURN;
        END
      CLEAR
      expect(rw(src)).to eq(src)
    end

    it "returns source unchanged on a parse error" do
      src = "FN main() RETURNS Void ->\n  garbled (\n"
      expect(rw(src)).to eq(src)
    end
  end

  describe "MUTABLE-never-reassigned drop" do
    it "drops MUTABLE on a read-but-never-reassigned binding" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 5;
          RETURN n;
        END
      CLEAR
      expect(rw(src)).to include("n = 5;")
      expect(rw(src)).not_to include("MUTABLE")
    end

    it "keeps MUTABLE when the binding is reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 5;
          n = 7;
          RETURN n;
        END
      CLEAR
      expect(rw(src)).to include("MUTABLE n = 5;")
    end
  end

  describe "redundant `: Type` annotation drop" do
    it "drops `: Int64` when assigned an integer literal" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE total: Int64 = 0;
          total = 5;
          RETURN total;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE total = 0;")
    end

    it "drops `: Float64` when assigned a float literal" do
      src = <<~CLEAR
        FN main() RETURNS Float64 ->
          MUTABLE s: Float64 = 0.0;
          s = 1.5;
          RETURN s;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE s = 0.0;")
    end

    it "drops redundant annotations even when whitespace precedes the colon" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE total   : Int64 = 0;
          total = 5;
          RETURN total;
        END
      CLEAR
      out = rw(src)
      expect(out).not_to include(": Int64")
    end

    it "keeps `: HashMap<K, V>` (decorated type)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64, Float64> = {};
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": HashMap<Int64, Float64>")
    end

    it "keeps `: Float64[]@list` (collection type)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE xs: Float64[]@list = [];
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": Float64[]@list")
    end

    it "keeps `: ?Int64` (optional)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          x: ?Int64 = NIL;
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": ?Int64")
    end
  end

  describe "safety against false-positive MUTABLE drops" do
    # The annotator's MUTABLE-never-reassigned lint doesn't propagate
    # "mutably borrowed via callee" through BG-block captures —
    # dropping MUTABLE there breaks the next compile (the param's
    # mutability check fires at the call site). Defensively skip
    # MUTABLE-drop for any binding whose name appears inside a BG
    # block until the annotator is fixed.

    it "keeps MUTABLE on a binding referenced inside a BG block" do
      src = <<~CLEAR
        FN bar(MUTABLE xs: Int64[]) RETURNS Void ->
          xs.append(1);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE arr: Int64[] = [1_i64, 2_i64];
          MUTABLE tasks: ~Void[]@list = [];
          tasks.append(BG { bar(arr); });
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE arr")
    end

    it "drops MUTABLE normally on bindings NOT referenced inside any BG block" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n = 42;
          RETURN n;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = 42;")
      expect(out).not_to include("MUTABLE")
    end

    it "keeps MUTABLE when the binding is passed to a bang helper" do
      src = <<~CLEAR
        FN appendOne!(MUTABLE xs: Int64[]@list) RETURNS Void ->
          xs.append(1_i64);
          RETURN;
        END

        FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          appendOne!(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("MUTABLE xs: Int64[]@list = []")
    end
  end

  describe "redundant `: Type` annotation drop — sync awareness" do
    # `String@raw` and `String` resolve to the same base type but use
    # different indexing (byte vs UTF-8 codepoint). Dropping
    # `: String@raw` silently changes semantics. The rewriter's
    # decoration check uses `#sync` directly rather than `any_sync?`
    # (the latter excludes `:raw` since it's a data-access mode).

    it "keeps `: String@raw` annotation (sync stamp = decoration)" do
      src = <<~CLEAR
        FN tcpRead(fd: Int64) RETURNS String@raw ->
          RETURN "hi";
        END
        FN main() RETURNS Void ->
          data: String@raw = tcpRead(0_i64);
          print(data);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include(": String@raw")
    end
  end

  describe "both rules combined" do
    it "drops MUTABLE AND `: Type` independently when both apply" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE n: Int64 = 5;
          RETURN n;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = 5;")
      expect(out).not_to include("MUTABLE")
      expect(out).not_to include(": Int64")
    end
  end

  describe ".to_type" do
    it "returns an existing Type unchanged and coerces symbols" do
      type = Type.new(:Int64)

      expect(LintFixRewriter.to_type(type)).to equal(type)
      expect(LintFixRewriter.to_type(:Float64).raw).to eq(:Float64)
    end

    it "returns nil for values that cannot be coerced to a Type" do
      expect(LintFixRewriter.to_type(nil)).to be_nil
      expect(LintFixRewriter.to_type("~~Int64")).to be_nil
    end
  end

  describe "direct helper contracts" do
    it "classifies terminal values" do
      terminal_values = [nil, :name, "name", 1, 1.5, true, false]
      terminal_values.each do |value|
        expect(LintFixRewriter.send(:terminal?, value)).to eq(true)
      end
      expect(LintFixRewriter.send(:terminal?, identifier("x"))).to eq(false)
    end

    it "classifies mutating method names" do
      %w[append clear delete insert pop push remove reserve resize set shift swap truncate unshift].each do |name|
        expect(LintFixRewriter.send(:mutating_method_name?, name)).to eq(true)
      end
      expect(LintFixRewriter.send(:mutating_method_name?, "map")).to eq(false)
      expect(LintFixRewriter.send(:mutating_method_name?, "push!")).to eq(false)
    end

    it "detects all type decorations that make annotation removal unsafe" do
      decorated = [
        Type.array_of(Type.new(:Int64)),
        Type.optional_of(Type.new(:Int64)),
        Type.error_union_of(Type.new(:Int64)),
        Type.generic_instance_of(:Box, [Type.new(:Int64)]),
        Type.new("~Int64"),
        Type.new("HashMap<Int64, Int64>"),
        Type.new(:String, sync: :raw),
        Type.new(:String, ownership: :shared),
      ]

      decorated.each do |type|
        expect(LintFixRewriter.send(:any_decoration?, type)).to eq(true)
      end
      expect(LintFixRewriter.send(:any_decoration?, Type.new(:Int64))).to eq(false)
    end

    it "matches only identical undecorated types for annotation removal" do
      expect(LintFixRewriter.send(:types_match_for_drop?, Type.new(:Int64), Type.new(:Int64))).to eq(true)
      expect(LintFixRewriter.send(:types_match_for_drop?, Type.new(:Int64), Type.new(:Float64))).to eq(false)
      expect(LintFixRewriter.send(:types_match_for_drop?, Type.array_of(Type.new(:Int64)), Type.array_of(Type.new(:Int64)))).to eq(false)
    end

    it "detects declaration-mode bind expressions" do
      decl = AST::BindExpr.new(tok("x"), "x", Type.new(:Int64), int_lit)
      assign = AST::BindExpr.new(tok("x"), "x", Type.new(:Int64), int_lit)
      decl.mode = :decl
      assign.mode = :assign

      expect(LintFixRewriter.send(:decl_mode_bind_expr?, decl)).to eq(true)
      expect(LintFixRewriter.send(:decl_mode_bind_expr?, assign)).to eq(false)
      expect(LintFixRewriter.send(:decl_mode_bind_expr?, identifier("x"))).to eq(false)
    end

    it "converts fix spans into flat edits" do
      span = Span.new(file: nil, line: 3, col: 5, length: 7)

      expect(LintFixRewriter.send(:edit_from_span, span, "")).to eq(
        line: 3,
        col: 5,
        length: 7,
        replacement: "",
      )
    end

    it "filters mutable-unused findings by confidence and unsafe names" do
      span = Span.new(file: nil, line: 2, col: 3, length: 8)
      edit = Edit.new(span: span, replacement: "")
      auto = Fix.new(description: "drop mutable", confidence: :auto, edits: [edit])
      interactive = Fix.new(description: "manual", confidence: :interactive, edits: [edit])
      finding = FixableFinding.new(level: :warning, message: "MUTABLE 'n' is never reassigned", token: nil, category: :lint, fixes: [auto, interactive])

      expect(LintFixRewriter.send(:mutable_unused_finding?, finding)).to eq(true)
      expect(LintFixRewriter.send(:mentions_name_in_set?, finding, Set["n"])).to eq(true)
      expect(LintFixRewriter.send(:mentions_name_in_set?, finding, Set["other"])).to eq(false)
      expect(LintFixRewriter.send(:mutable_unused_edits, [finding], Set.new, Set.new)).to eq([{ line: 2, col: 3, length: 8, replacement: "" }])
      expect(LintFixRewriter.send(:mutable_unused_edits, [finding], Set["n"], Set.new)).to eq([])
      expect(LintFixRewriter.send(:mutable_unused_edits, [finding], Set.new, Set["n"])).to eq([])
    end

    it "rejects non-mutable findings" do
      span = Span.new(file: nil, line: 1, col: 1, length: 1)
      fix = Fix.new(description: "noop", confidence: :auto, edits: [Edit.new(span: span, replacement: "")])
      finding = FixableFinding.new(level: :warning, message: "other warning", token: nil, category: :lint, fixes: [fix])

      expect(LintFixRewriter.send(:mutable_unused_finding?, finding)).to eq(false)
      expect(LintFixRewriter.send(:mutable_unused_edits, [finding], Set.new, Set.new)).to eq([])
    end

    it "collects identifier names from nested expressions" do
      names = Set.new
      nested = [identifier("a"), AST::FuncCall.new(tok("f"), "f", [identifier("b")])]

      LintFixRewriter.send(:collect_identifier_names, nested, names)

      expect(names).to eq(Set["a", "b"])
    end

    it "collects mutation-sensitive names from bang functions and mutating methods" do
      program = AST::Program.new(tok, [
        AST::FuncCall.new(tok("appendOne!"), "appendOne!", [identifier("xs")]),
        AST::MethodCall.new(tok("push"), identifier("ys"), "push", [int_lit]),
        AST::MethodCall.new(tok("map"), identifier("zs"), "map", []),
      ])

      expect(LintFixRewriter.send(:collect_mutation_sensitive_names, program)).to eq(Set["xs", "ys"])
    end

    it "collects only names referenced inside BG bodies" do
      outside = identifier("outside")
      inside = identifier("inside")
      bg = AST::BgBlock.new(tok, [inside], [], nil, false, false, nil, false)
      program = AST::Program.new(tok, [outside, bg])

      expect(LintFixRewriter.send(:collect_bg_referenced_names, program)).to eq(Set["inside"])
    end

    it "finds redundant type annotation edits while walking AST nodes" do
      source = "FN main() RETURNS Int64 ->\n  total: Int64 = 0;\nEND\n"
      decl = var_decl("total", Type.new(:Int64), int_lit, line: 2, column: 3)
      program = AST::Program.new(tok, [decl])

      expect(LintFixRewriter.send(:redundant_type_annotation_edits, program, source)).to eq([
        { line: 2, col: 8, length: 7, replacement: "" },
      ])
    end

    it "finds redundant type annotation edits on declaration-mode bind expressions" do
      source = "FN main() RETURNS Int64 ->\n  total: Int64 = 0;\nEND\n"
      bind = AST::BindExpr.new(tok("total", line: 2, column: 3), "total", Type.new(:Int64), int_lit)
      bind.mode = :decl
      program = AST::Program.new(tok, [bind])

      expect(LintFixRewriter.send(:redundant_type_annotation_edits, program, source)).to eq([
        { line: 2, col: 8, length: 7, replacement: "" },
      ])
    end

    it "does not emit redundant type edits for mismatched or missing values" do
      source = "FN main() RETURNS Int64 ->\n  total: Float64 = 0;\n  missing: Int64;\nEND\n"
      mismatch = var_decl("total", Type.new(:Float64), int_lit, line: 2, column: 3)
      missing = var_decl("missing", Type.new(:Int64), nil, line: 3, column: 3)

      expect(LintFixRewriter.send(:compute_redundant_type_edit, mismatch, source)).to be_nil
      expect(LintFixRewriter.send(:compute_redundant_type_edit, missing, source)).to be_nil
    end

    it "locates type annotation spans with whitespace and nested type brackets" do
      source = "FN main() RETURNS Void ->\n  value   : Fixed[Int64] = 0;\nEND\n"
      decl = var_decl("value", Type.new(:Int64), int_lit, line: 2, column: 3)

      expect(LintFixRewriter.send(:locate_type_annotation_span, decl, source)).to eq(
        line: 2,
        col: 11,
        length: 14,
      )
    end

    it "locates type annotation spans after tab whitespace" do
      source = "FN main() RETURNS Void ->\n  value\t:\tInt64\t= 0;\nEND\n"
      decl = var_decl("value", Type.new(:Int64), int_lit, line: 2, column: 3)

      expect(LintFixRewriter.send(:locate_type_annotation_span, decl, source)).to eq(
        line: 2,
        col: 9,
        length: 7,
      )
    end

    it "returns nil when annotation span location is impossible" do
      source = "FN main() RETURNS Void ->\n  value Int64 = 0;\nEND\n"
      no_token = var_decl("value", Type.new(:Int64), int_lit)
      no_token.token = nil
      wrong_line = var_decl("value", Type.new(:Int64), int_lit, line: 99, column: 1)
      missing_colon = var_decl("value", Type.new(:Int64), int_lit, line: 2, column: 3)
      missing_assignment_source = "FN main() RETURNS Void ->\n  value: Int64;\nEND\n"
      missing_assignment = var_decl("value", Type.new(:Int64), int_lit, line: 2, column: 3)

      expect(LintFixRewriter.send(:locate_type_annotation_span, no_token, source)).to be_nil
      expect(LintFixRewriter.send(:locate_type_annotation_span, wrong_line, source)).to be_nil
      expect(LintFixRewriter.send(:locate_type_annotation_span, missing_colon, source)).to be_nil
      expect(LintFixRewriter.send(:locate_type_annotation_span, missing_assignment, missing_assignment_source)).to be_nil
    end

    it "applies edits right-to-left per line and ignores invalid edit positions" do
      source = "abcdef\nsecond\n"
      edits = [
        { line: 1, col: 2, length: 2, replacement: "XX" },
        { line: 1, col: 5, length: 99, replacement: "Y" },
        { line: 0, col: 1, length: 1, replacement: "bad" },
        { line: 2, col: 99, length: 1, replacement: "bad" },
      ]

      expect(LintFixRewriter.send(:apply_edits, source, edits)).to eq("aXXdY\nsecond\n")
    end

    it "preserves trailing blank lines while applying edits" do
      source = "first\nsecond\n\n"
      edits = [{ line: 2, col: 1, length: 6, replacement: "2nd" }]

      expect(LintFixRewriter.send(:apply_edits, source, edits)).to eq("first\n2nd\n\n")
    end

    it "converts between source offsets and line columns" do
      source = "ab\ncde\n"

      expect(LintFixRewriter.send(:offset_for, source, 1, 1)).to eq(0)
      expect(LintFixRewriter.send(:offset_for, source, 2, 2)).to eq(4)
      expect(LintFixRewriter.send(:offset_for, source, 2, 4)).to eq(6)
      expect(LintFixRewriter.send(:offset_for, source, 0, 1)).to be_nil
      expect(LintFixRewriter.send(:offset_for, source, 3, 1)).to eq(7)
      expect(LintFixRewriter.send(:offset_for, source, 4, 1)).to be_nil
      expect(LintFixRewriter.send(:line_col_for_offset, source, 4)).to eq([2, 2])
      expect(LintFixRewriter.send(:line_col_for_offset, source, source.length)).to eq([3, 1])
    end

    it "returns annotated AST and disables FixCollector after direct annotation" do
      source = "FN main() RETURNS Void -> RETURN; END\n"

      ast, findings = LintFixRewriter.send(:annotate, source)

      expect(ast).to be_a(AST::Program)
      expect(findings).to be_a(Array)
      expect(FixCollector.enabled?).to eq(false)
      expect(FixCollector.drain).to eq([])
    end
  end
end
