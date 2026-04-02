require "rspec"
require_relative "../src/ownership_graph"

RSpec.describe OwnershipGraph do
  subject(:graph) { OwnershipGraph.new }

  describe "#declare" do
    it "adds a live node" do
      graph.declare("x", kind: :affine, type_info: nil)
      expect(graph["x"]).to be_live
      expect(graph.live?("x")).to be true
    end

    it "sets storage and scope_depth" do
      graph.declare("x", storage: :heap, scope_depth: 2, line: 10)
      node = graph["x"]
      expect(node.storage).to eq(:heap)
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

    it "records a :moves edge" do
      graph.transfer("x", "y")
      move_edge = graph.edges.find { |e| e.kind == :moves }
      expect(move_edge).not_to be_nil
      expect(move_edge.from).to eq("y")
      expect(move_edge.to).to eq("x")
    end

    it "invalidates children of source" do
      graph.declare("x.child")
      graph.declare("x.child.name")
      graph.transfer("x", "y")
      expect(graph.moved?("x.child")).to be true
      expect(graph.moved?("x.child.name")).to be true
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
        expect(graph.borrows_on("x").size).to eq(1)
      end

      it "allows multiple immutable borrows" do
        graph.borrow("y", "x", mutable: false)
        err = graph.borrow("z", "x", mutable: false)
        expect(err).to be_nil
        expect(graph.borrows_on("x").size).to eq(2)
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
      expect(graph.borrows_on("x").size).to eq(1)

      graph.release_borrow("y")
      expect(graph.borrows_on("x")).to be_empty
    end

    it "allows new mutable borrow after release" do
      graph.declare("x")
      graph.borrow("y", "x", mutable: false)
      graph.release_borrow("y")
      err = graph.borrow("z", "x", mutable: true)
      expect(err).to be_nil
    end
  end

  describe "#escape" do
    it "promotes storage to heap" do
      graph.declare("x", storage: :stack)
      graph.escape("x")
      expect(graph["x"].storage).to eq(:heap)
    end

    it "is a no-op for undeclared path" do
      graph.escape("ghost") # should not raise
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

  describe "#live_nodes_in_scope" do
    it "returns nodes at or deeper than min_depth" do
      graph.declare("a", scope_depth: 0)
      graph.declare("b", scope_depth: 1)
      graph.declare("c", scope_depth: 2)
      nodes = graph.live_nodes_in_scope(1)
      expect(nodes.map(&:path)).to contain_exactly("b", "c")
    end

    it "excludes moved nodes" do
      graph.declare("a", scope_depth: 1)
      graph.declare("b", scope_depth: 1)
      graph.transfer("a", "x")
      nodes = graph.live_nodes_in_scope(1)
      paths = nodes.map(&:path)
      expect(paths).to include("b")
      expect(paths).to include("x")  # x inherits a's scope_depth
      expect(paths).not_to include("a")  # a is moved
    end
  end

  describe "#fork and #merge" do
    it "creates an independent snapshot" do
      graph.declare("x")
      snapshot = graph.fork
      graph.transfer("x", "y")
      expect(snapshot.live?("x")).to be true
      expect(graph.moved?("x")).to be true
    end

    it "merges cleanly when both branches agree" do
      graph.declare("x")
      snapshot = graph.fork
      graph.transfer("x", "y")
      snapshot.transfer("x", "z")
      errors = graph.merge(snapshot)
      expect(errors).to be_empty
    end

    it "reports error when one branch moves and other doesn't" do
      graph.declare("x")
      snapshot = graph.fork
      graph.transfer("x", "y")
      # snapshot leaves x live
      errors = graph.merge(snapshot)
      expect(errors.size).to eq(1)
      expect(errors.first).to include("moved in one branch")
    end

    it "takes the more restrictive state on merge" do
      graph.declare("x")
      snapshot = graph.fork
      graph.transfer("x", "y")
      graph.merge(snapshot)
      expect(graph.moved?("x")).to be true
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
