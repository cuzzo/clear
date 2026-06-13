require "rspec"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# Phase 2.2 — terminal inference: mark @observable for fold terminals.
# A fold terminal (SUM/MAX/MIN/COUNT/AVERAGE/ANY/ALL/FIND/DISTINCT/REDUCE-scalar)
# whose source is a tense streaming type stamps `observable_terminal = true`
# on the wrapping pipe BinaryOp. Plain arrays / ranges leave it nil.
RSpec.describe "fold-terminal observable inference (Phase 2.2)" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def last_pipe_node(ast)
    fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    body = fn ? fn.body : ast.statements
    found = nil
    visit = lambda do |n|
      return unless n
      found = n if n.is_a?(AST::BinaryOp) && n.op == :SMOOTH
      if n.is_a?(Struct)
        n.each { |v| visit.call(v) if v.is_a?(Struct) || v.is_a?(Array) }
      elsif n.is_a?(Array)
        n.each { |v| visit.call(v) }
      end
    end
    body.each { |s| visit.call(s) }
    found
  end

  context "tense stream source (open stream BG STREAM)" do
    it "stamps observable_terminal on SUM" do
      src = <<~F
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 1;
                WHILE i <= 4 DO YIELD i; i = i + 1; END
            };
            _ = gen |> SUM _ |> COLLECT;
        END
      F
      pipe = last_pipe_node(annotate(src))
      expect(pipe).not_to be_nil
      expect(pipe.observable_terminal).to be true
    end

    it "stamps observable_terminal on COUNT" do
      # COUNT on a tense stream now lifts to `~Int64@observable` (same
      # as SUM), so the binding must consume via COLLECT or carry the
      # observable annotation -- otherwise the unconsumed-promise check
      # fires.
      src = <<~F
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 1;
                WHILE i <= 4 DO YIELD i; i = i + 1; END
            };
            _ = gen |> COUNT _ > 2 |> COLLECT;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be true
    end

    it "stamps observable_terminal on DISTINCT" do
      src = <<~F
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 1;
                WHILE i <= 4 DO YIELD i; i = i + 1; END
            };
            uniq = gen |> DISTINCT _;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be true
    end
  end

  context "plain array source" do
    it "leaves observable_terminal nil on SUM" do
      src = <<~F
        FN main() RETURNS Void ->
            xs = [1, 2, 3, 4];
            total = xs |> SUM _;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be_nil
    end

    it "leaves observable_terminal nil on DISTINCT" do
      src = <<~F
        FN main() RETURNS Void ->
            xs = [1, 2, 3, 4, 1];
            uniq = xs |> DISTINCT _;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be_nil
    end
  end

  context "range source" do
    # Although RangeLit's type_info is `~Int64[]` (tense dynamic stream),
    # a range folds eagerly -- there's no concurrent producer for a reader
    # to observe. Phase 2.2 explicitly excludes RangeLit sources.
    it "leaves observable_terminal nil on SUM over a range (eager fold, no concurrent producer)" do
      src = <<~F
        FN main() RETURNS Void ->
            total = (1..<10) |> SUM _;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be_nil
    end
  end

  context "REDUCE on tense stream" do
    it "stamps observable_terminal for scalar accumulator" do
      # REDUCE-scalar on a tense stream now lifts to `~T@observable`
      # (matching SUM/COUNT/MAX/MIN/AVG/ANY/ALL/FIND), so consume via
      # COLLECT.
      src = <<~F
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 1;
                WHILE i <= 4 DO YIELD i; i = i + 1; END
            };
            _ = gen |> REDUCE(0) acc + _ |> COLLECT;
        END
      F
      expect(last_pipe_node(annotate(src)).observable_terminal).to be true
    end
  end
end
