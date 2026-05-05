require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/mir/ownership_graph"

RSpec.describe OwnershipGraph do
  subject(:graph) { OwnershipGraph.new }

  describe "#declare" do
    it "adds a live node" do
      graph.declare("x", kind: :affine, type_info: nil)
      expect(graph["x"]).to be_live
      expect(graph.live?("x")).to be true
    end

    it "sets scope_depth and line" do
      graph.declare("x", scope_depth: 2, line: 10)
      node = graph["x"]
      expect(node.scope_depth).to eq(2)
      expect(node.line).to eq(10)
    end
  end

  describe "#transfer (move)" do
    before do
      graph.declare("x", kind: :affine)
    end

    it "creates target node and invalidates source" do
      graph.transfer("x", "y")
      expect(graph.live?("y")).to be true
      expect(graph.moved?("x")).to be true
    end

    it "invalidates children of source" do
      graph.declare("x.child")
      graph.declare("x.child.name")
      graph.transfer("x", "y")
      expect(graph.moved?("x.child")).to be true
      expect(graph.moved?("x.child.name")).to be true
    end

    it "records the move site and action on source and children" do
      token = Lexer::Token.new(:VAR_ID, "x", 7, 11)
      graph.declare("x.child")
      graph.transfer("x", "y", at_token: token, action: :share)

      expect(graph["x"].move_line).to eq(7)
      expect(graph["x"].move_col).to eq(11)
      expect(graph["x"].move_action).to eq(:share)
      expect(graph["x.child"].move_line).to eq(7)
      expect(graph["x.child"].move_action).to eq(:share)
    end

    it "records move metadata for direct mark_moved" do
      token = Lexer::Token.new(:VAR_ID, "x", 8, 5)
      graph.mark_moved("x", at_token: token, action: :give)

      expect(graph.moved?("x")).to be true
      expect(graph["x"].move_line).to eq(8)
      expect(graph["x"].move_col).to eq(5)
      expect(graph["x"].move_action).to eq(:give)
    end

    it "returns nil for undeclared source" do
      result = graph.transfer("ghost", "y")
      expect(result).to be_nil
      expect(graph["y"]).to be_nil
    end
  end

  describe "#borrow" do
    before do
      graph.declare("x", kind: :affine)
    end

    context "immutable borrow" do
      it "succeeds on live variable" do
        err = graph.borrow("y", "x", mutable: false)
        expect(err).to be_nil
        expect(graph.edges.count { |e| e.to == "x" && (e.kind == :borrows || e.kind == :borrows_mut) }).to eq(1)
      end

      it "allows multiple immutable borrows" do
        graph.borrow("y", "x", mutable: false)
        err = graph.borrow("z", "x", mutable: false)
        expect(err).to be_nil
        expect(graph.edges.count { |e| e.to == "x" && (e.kind == :borrows || e.kind == :borrows_mut) }).to eq(2)
      end

      it "fails if mutable borrow exists" do
        graph.borrow("y", "x", mutable: true)
        err = graph.borrow("z", "x", mutable: false)
        expect(err).to include("mutably borrowed")
      end
    end

    context "mutable borrow" do
      it "succeeds on live variable with no borrows" do
        err = graph.borrow("y", "x", mutable: true)
        expect(err).to be_nil
      end

      it "fails if immutable borrow exists" do
        graph.borrow("y", "x", mutable: false)
        err = graph.borrow("z", "x", mutable: true)
        expect(err).to include("already borrowed")
      end

      it "fails if another mutable borrow exists" do
        graph.borrow("y", "x", mutable: true)
        err = graph.borrow("z", "x", mutable: true)
        expect(err).to include("already borrowed")
      end
    end

    it "fails on moved variable" do
      graph.transfer("x", "y")
      err = graph.borrow("z", "x", mutable: false)
      expect(err).to include("already moved")
    end

    it "fails on undeclared variable" do
      err = graph.borrow("y", "ghost", mutable: false)
      expect(err).to include("not declared")
    end
  end

  describe "#release_borrow" do
    it "removes borrow edges from a borrower" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: false)
      expect(graph.edges.count { |e| e.to == "x" && (e.kind == :borrows || e.kind == :borrows_mut) }).to eq(1)

      graph.release_borrow("y")
      expect(graph.edges.select { |e| e.to == "x" && (e.kind == :borrows || e.kind == :borrows_mut) }).to be_empty
    end

    it "allows new mutable borrow after release" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: false)
      graph.release_borrow("y")
      err = graph.borrow("z", "x", mutable: true)
      expect(err).to be_nil
    end
  end

  describe "#drop" do
    it "drops a live node and returns cleanup paths" do
      graph.declare("x")
      paths = graph.drop("x")
      expect(paths).to eq(["x"])
      expect(graph["x"].dropped?).to be true
    end

    it "drops owned children in reverse order" do
      graph.declare("x")
      graph.declare("x.a")
      graph.declare("x.b")
      paths = graph.drop("x")
      expect(paths).to eq(["x.b", "x.a", "x"])
    end

    it "removes borrow edges involving dropped paths" do
      graph.declare("x")
      graph.declare("y")
      graph.borrow("y", "x", mutable: false)
      graph.drop("x")
      expect(graph.edges).to be_empty
    end

    it "returns empty for already-moved node" do
      graph.declare("x")
      graph.transfer("x", "y")
      expect(graph.drop("x")).to be_empty
    end

    it "returns empty for undeclared path" do
      expect(graph.drop("ghost")).to be_empty
    end
  end

  describe "#can_write?" do
    it "returns true with no borrows" do
      graph.declare("x")
      expect(graph.can_write?("x")).to be true
    end

    it "returns false with immutable borrow" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: false)
      expect(graph.can_write?("x")).to be false
    end

    it "returns false with mutable borrow" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: true)
      expect(graph.can_write?("x")).to be false
    end

    it "checks ancestor paths" do
      graph.declare("x")
      graph.declare("x.child")
      graph.borrow("y", "x", mutable: false)
      expect(graph.can_write?("x.child")).to be false
    end

    it "returns true after borrow release" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: false)
      graph.release_borrow("y")
      expect(graph.can_write?("x")).to be true
    end
  end


  describe "#fork_lightweight and #restore_lightweight" do
    it "captures and restores node states" do
      graph.declare("x")
      snapshot = graph.fork_lightweight
      graph.transfer("x", "y")
      expect(graph.moved?("x")).to be true
      graph.restore_lightweight(snapshot)
      expect(graph.live?("x")).to be true
    end

    it "restores move metadata from lightweight snapshots" do
      token = Lexer::Token.new(:VAR_ID, "x", 12, 4)
      graph.declare("x")
      graph.mark_moved("x", at_token: token, action: :share)
      snapshot = graph.fork_lightweight
      graph["x"].state = :live
      graph["x"].move_line = nil
      graph["x"].move_action = nil

      graph.restore_lightweight(snapshot)
      expect(graph.moved?("x")).to be true
      expect(graph["x"].move_line).to eq(12)
      expect(graph["x"].move_action).to eq(:share)
    end

    it "restores legacy state-only lightweight snapshots" do
      graph.declare("x")
      graph.restore_lightweight({ node_states: { "x" => :moved }, edge_count: 0 })
      expect(graph.moved?("x")).to be true
    end

    it "captures edge count for restoration" do
      graph.declare("x")
      snapshot = graph.fork_lightweight
      expect(snapshot[:edge_count]).to eq(graph.edges.size)
    end
  end

  describe "#merge" do
    it "merges cleanly when both branches agree" do
      other = OwnershipGraph.new
      other.declare("x")
      graph.declare("x")
      graph.transfer("x", "y")
      other.transfer("x", "z")
      errors = graph.merge(other)
      expect(errors).to be_empty
    end

    it "reports error when one branch moves and other doesn't" do
      other = OwnershipGraph.new
      other.declare("x")
      graph.declare("x")
      graph.transfer("x", "y")
      # other leaves x live
      errors = graph.merge(other)
      expect(errors.size).to eq(1)
      expect(errors.first).to include("moved in one branch")
    end

    it "takes the more restrictive state on merge" do
      other = OwnershipGraph.new
      other.declare("x")
      graph.declare("x")
      graph.transfer("x", "y")
      graph.merge(other)
      expect(graph.moved?("x")).to be true
    end

    it "copies move metadata from the moved branch on merge" do
      token = Lexer::Token.new(:VAR_ID, "x", 21, 9)
      other = OwnershipGraph.new
      graph.declare("x")
      other.declare("x")
      other.mark_moved("x", at_token: token, action: :share)

      graph.merge(other)
      expect(graph.moved?("x")).to be true
      expect(graph["x"].move_line).to eq(21)
      expect(graph["x"].move_col).to eq(9)
      expect(graph["x"].move_action).to eq(:share)
    end
  end

  describe "#owned_children" do
    it "returns direct and nested children" do
      graph.declare("x")
      graph.declare("x.a")
      graph.declare("x.a.b")
      graph.declare("y")
      expect(graph.owned_children("x")).to eq(["x.a", "x.a.b"])
    end

    it "returns empty for leaf nodes" do
      graph.declare("x")
      expect(graph.owned_children("x")).to be_empty
    end
  end
end

# Integration tests: verify the graph is populated when the annotator runs.
RSpec.describe "OwnershipGraph integration" do
  require_relative "../src/backends/transpiler"

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    [ast, annotator]
  end

  def graph_for(source)
    _, annotator = annotate(source)
    annotator.instance_variable_get(:@og)
  end

  it "declares variables in the graph" do
    og = graph_for(<<~CLEAR)
      FN test() ->
        x = 42;
      END
    CLEAR
    # x should have been declared (and dropped at scope end)
    expect(og.nodes.keys).to include("x")
  end

  it "declares function parameters in the graph" do
    og = graph_for(<<~CLEAR)
      FN test(a: Float64, b: Float64) RETURNS Float64 ->
        RETURN a;
      END
    CLEAR
    expect(og.nodes.keys).to include("a")
    expect(og.nodes.keys).to include("b")
  end

  it "marks moved non-Copy variables in the graph" do
    og = graph_for(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN test() ->
        p = Value { Num: 1.0 };
        q = p;
      END
    CLEAR
    expect(og["p"]&.moved?).to be true
    expect(og["q"]).not_to be_nil
  end

  it "tracks GIVE as a move" do
    og = graph_for(<<~CLEAR)
      STRUCT Data { value: Float64 }
      FN consume(TAKES d: Data) RETURNS Float64 ->
        RETURN d.value;
      END
      FN test() RETURNS Float64 ->
        d = Data { value: 42 };
        RETURN consume(GIVE d);
      END
    CLEAR
    expect(og["d"]&.moved?).to be true
  end

  it "drops variables at scope exit" do
    og = graph_for(<<~CLEAR)
      UNION Value { Num: Float64, List: Int64[] }
      FN test() ->
        o = Value { Num: 1.0 };
      END
    CLEAR
    expect(og["o"]&.dropped?).to be true
  end
end
