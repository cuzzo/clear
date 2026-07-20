require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../../tools/fuzz/select_tense_semantics"
require_relative "../../tools/fuzz/generator"

RSpec.describe "SELECT tense assignment matrix" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def selected_type(source)
    function = annotate(source).statements.last
    function.body.find { |node| node.is_a?(AST::BindExpr) && node.name == "selected" }.full_type.to_s
  end

  def expect_selected_matches_declaration(source)
    function = annotate(source).statements.last
    selected = function.body.find { |node| node.is_a?(AST::BindExpr) && node.name == "selected" }
    inferred = TypeExpressionPrinter.inline(selected.full_type.shape.expression)
    declared = TypeExpressionPrinter.inline(selected.type.shape.expression)
    expect(inferred).to eq(declared)
  end

  let(:foo_prelude) { "STRUCT Foo { value: Int64 }\n" }

  it "defines a closed, non-overlapping modifier grammar" do
    expect(SelectTenseSemantics.validate!).to be true
    expect(SelectTenseSemantics::VALID_ORDERS.length).to eq(12)
    expect(SelectTenseSemantics::INVALID_ORDERS).to include("?!", "?~", "!?~")
  end

  it "registers the full source/cardinality/modifier assignment matrix" do
    cells = FuzzGenerator.new(seed: 1).full_matrix.select do |cell|
      cell.fetch(:template) == :select_tense_assignment_matrix
    end
    positives = cells.reject { |cell| cell.fetch(:params).fetch(:expected, :pass) == :compile_error }
    negatives = cells - positives

    expect(cells.length).to eq(56)
    expect(positives.length).to eq(49)
    expect(negatives.length).to eq(7)
    assignment_cells = positives.reject { |cell| cell[:params][:direct_pipe] }
    expect(assignment_cells.map { |cell| [cell[:params][:source_shape], cell[:params][:order]] }.uniq.length).to eq(48)
  end

  SelectTenseSemantics::SOURCE_SHAPES.each_key do |source_shape|
    SelectTenseSemantics::VALID_ORDERS.each do |order|
      label = order.empty? ? "plain" : order
      it "assigns the independent #{source_shape}/#{label} SELECT result type" do
        source_type = SelectTenseSemantics::SOURCE_SHAPES.fetch(source_shape).fetch(:type)
        source_expr = case source_shape
                      when :list then "[1_i64, 2_i64]"
                      when :finite then "BG STREAM { YIELD 1_i64; YIELD 2_i64; CLOSE; }"
                      when :bounded then "[BG { 1_i64; }, BG { 2_i64; }]"
                      when :infinite then "BG STREAM { WHILE TRUE DO YIELD 1_i64; END }"
                      end
        selector_type = SelectTenseSemantics.wrap(order, "Int64")
        expected = SelectTenseSemantics.expected_result(source_shape, order)
        code = <<~CLEAR
          #{SelectTenseSemantics.selector_helpers}
          FN project(value: Int64) RETURNS #{selector_type} ->
            RETURN #{SelectTenseSemantics.selector_expression(order)};
          END
          FN main() RETURNS !Void ->
            input: #{source_type} = #{source_expr};
            selected: #{expected} = input |> #{SelectTenseSemantics.modifier(order)} project(_);
            RETURN;
          END
        CLEAR
        expect_selected_matches_declaration(code)
      end
    end
  end

  SelectTenseSemantics::INVALID_ORDERS.each do |order|
    it "rejects SELECT:#{order}" do
      code = <<~CLEAR
        FN main() RETURNS Void ->
          input: []Int64 = [1_i64];
          selected = input |> SELECT:#{order} _;
          RETURN;
        END
      CLEAR
      expect { annotate(code) }.to raise_error(ParserError, /Invalid SELECT modifier order/)
    end
  end

  it "accepts an optional item inside a stream" do
    code = <<~CLEAR
      FN main() RETURNS Void ->
        value: [~]?Int64 = BG STREAM YIELDS ?Int64 { YIELD 1_i64; YIELD NIL; CLOSE; };
        RETURN;
      END
    CLEAR
    expect { annotate(code) }.not_to raise_error
  end

  it "rejects an optional wrapper outside a stream" do
    code = "FN main(value: ?[~]Int64) RETURNS Void -> RETURN; END"
    expect { annotate(code) }.to raise_error(ParserError, /optional stream item/)
  end

  it "rejects the obsolete question-mark stream cardinality" do
    code = "FN main(value: ~Int64[?]) RETURNS Void -> RETURN; END"
    expect { annotate(code) }.to raise_error(ParserError, /\[~\]T, \[~N\]T, or \[~INF\]T/)
  end

  {
    finite: ["[~]Foo", "BG STREAM { YIELD Foo{ value: 1_i64 }; CLOSE; }"],
    bounded: ["[~2]Foo", "[BG { Foo{ value: 1_i64 }; }, BG { Foo{ value: 2_i64 }; }]"],
    infinite: ["[~INF]Foo", "BG STREAM { WHILE TRUE DO YIELD Foo{ value: 1_i64 }; END }"],
  }.each do |shape, (type, source)|
    it "preserves #{shape} stream cardinality through SELECT" do
      code = foo_prelude + <<~CLEAR
        FN main() RETURNS !Void ->
          input: #{type} = #{source};
          selected: #{type} = input |> SELECT _;
          RETURN;
        END
      CLEAR
      expect(selected_type(code)).to eq(type)
    end
  end

  it "requires and applies SELECT:~ for list-to-stream projection" do
    code = <<~CLEAR
      FN streamBar(value: Int64) RETURNS ~Int64 -> RETURN BG { value * 2_i64; }; END
      FN main() RETURNS !Void ->
        input: []Int64 = [1_i64];
        selected: [~]Int64 = input |> SELECT:~ streamBar(_);
        RETURN;
      END
    CLEAR
    expect(selected_type(code)).to eq("[~]Int64")
  end

  it "allows a range to pipe into a function returning a tense scalar" do
    code = <<~CLEAR
      FN streamBar(input: [~]Int64) RETURNS ~Int64 -> RETURN BG { 9_i64; }; END
      FN main() RETURNS !Void ->
        selected: ~Int64 = (1_i64 ..< 10_i64) |> streamBar();
        resolved = NEXT selected;
        RETURN;
      END
    CLEAR
    expect { annotate(code) }.not_to raise_error
  end

  it "unwraps an outer selector failure before awaiting its promise" do
    code = <<~CLEAR
      FN start(value: Int64) RETURNS !~Int64 -> RETURN BG { value; }; END
      FN plainLater(value: Int64) RETURNS ~Int64 -> RETURN BG { value; }; END
      FN later(value: Int64) RETURNS ~!Int64 -> RETURN BG { risky(value); }; END
      FN risky(value: Int64) RETURNS !Int64 -> RETURN value; END
      FN main() RETURNS !Void ->
        input: []Int64 = [1_i64];
        outer: ![~]Int64 = input |> SELECT:!~ start(_);
        plain: [~]Int64 = input |> SELECT:~ plainLater(_);
        inner: [~]!Int64 = input |> SELECT:~! later(_);
        RETURN;
      END
    CLEAR

    out = ZigTranspiler.new.transpile(code)
    expect(out).to match(/const __select_promise\d+ = try start\(/)
    expect(out).to match(/const __tmp_\d+ = try __select_promise\d+\.next\(\)/)
    expect(out).to match(/const __select_promise\d+ = try plainLater\(/)
    expect(out).to match(/const __select_promise\d+ = try later\(/)
    expect(out).to match(/\(try __select_promise\d+\.next\(\)\)\.value/)
    expect(out).not_to include("try try")
  end

  it "rejects implicit list-to-stream projection" do
    code = <<~CLEAR
      FN streamBar(value: Int64) RETURNS ~Int64 -> RETURN BG { value * 2_i64; }; END
      FN main() RETURNS !Void ->
        input: []Int64 = [1_i64];
        selected: [~]Int64 = input |> SELECT streamBar(_);
        RETURN;
      END
    CLEAR
    expect { annotate(code) }.to raise_error(CompilerError, /SELECT:~/)
  end
end
