require "rspec"
require_relative "../src/transpiler"

# Tests the FlowChecker -- pre-lowering flow-based verification that
# checks MIRPass output against ownership dataflow state.
#
# FlowChecker runs inside MIRPass.transform_function! after all MIR nodes
# are inserted. It verifies:
#   LEAK          -- needs_cleanup binding without MIR::Drop
#   ORPHAN_DROP   -- MIR::Drop without needs_cleanup binding
#   ORPHAN_GUARD  -- SuppressCleanup for non-moved variable
#   FRAME_OVERFLOW -- loop with frame alloc without rewind

RSpec.describe FlowChecker do
  def compile_and_check(src)
    # Full pipeline: annotate + MIRPass (which runs FlowChecker internally).
    # If FlowChecker finds errors, MIRPass raises.
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)
    ast
  end

  def expect_no_error(src)
    expect { compile_and_check(src) }.not_to raise_error
  end

  describe "valid programs pass FlowChecker" do
    it "simple variable with cleanup" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          RETURN;
        END
      CLEAR
    end

    it "GIVE to TAKES" do
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

    it "return of collection (promotion)" do
      expect_no_error(<<~CLEAR)
        FN makeList() RETURNS Int64[] ->
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

    it "if/else branching" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE vals: Int64[]@list = List[];
          vals.append(1_i64);
          IF vals.length() > 0 THEN
            vals.append(2_i64);
          END
          RETURN;
        END
      CLEAR
    end

    it "loop with rewind" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE i = 0;
          WHILE i < 5 DO
            MUTABLE vals: Int64[]@list = List[];
            vals.append(1_i64);
            i = i + 1;
          END
          RETURN;
        END
      CLEAR
    end

    it "hashmap with cleanup" do
      expect_no_error(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["x"] = 1_i64;
          RETURN;
        END
      CLEAR
    end

    it "struct with heap fields" do
      expect_no_error(<<~CLEAR)
        STRUCT Container { data: HashMap<Int64> }
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["x"] = 1_i64;
          c = Container{ data: m };
          RETURN;
        END
      CLEAR
    end
  end
end
