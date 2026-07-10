require "rspec"
require_relative "../ruby/backends/transpiler"

RSpec.describe "@node capability" do
  SOURCE = <<~CLEAR
    STRUCT Node {
      left: ?Node@node,
      right: ?Node@node,
      children: Node@node[]@list,
      id: Int64
    }

    FN main() RETURNS Void ->
      MUTABLE root: Node@node = Node{ id: 1 };
      root.left = Node{ id: 2 };
      root.children.append(Node{ id: 3 });
      ASSERT root.left?.id == 2;
      ASSERT root.children[0]?.id == 3;
    END
  CLEAR

  def annotate(source = SOURCE)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  it "parses direct, optional, and list-element node references" do
    struct = annotate.statements.first

    expect(struct.field_decls.fetch("left").type.node_reference?).to be(true)
    expect(struct.field_decls.fetch("left").type.zig_type).to eq("CheatLib.NodeRef(Node)")
    children = struct.field_decls.fetch("children").type
    expect(children.element_type&.node?).to be(true)
    expect(children.zig_type).to eq("std.ArrayListUnmanaged(CheatLib.NodeRef(Node))")
  end

  it "coerces plain struct values at node-typed destinations" do
    main = annotate.statements.fetch(1)
    root = main.body.fetch(0)
    left_assignment = main.body.fetch(1)
    append = main.body.fetch(2)

    expect(root.value.coerced_type_info&.node_reference?).to be(true)
    expect(left_assignment.value.coerced_type_info&.node_reference?).to be(true)
    expect(append.args.first.coerced_type_info&.node_reference?).to be(true)
  end

  it "lowers object-style code through the hidden NodeStore" do
    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(SOURCE, source_dir: Dir.pwd)

    expect(zig).to include("left: CheatLib.NodeRef(Node)")
    expect(zig).to include("const __node_store_Node = try CheatLib.NodeStore(Node).bind(rt)")
    expect(zig).to include("CheatLib.NodeStore(Node).createBound(__node_store_Node, Node{")
    expect(zig).to include("CheatLib.NodeStore(Node).getBound(__node_store_Node, root).?.left")
    expect(zig).to include("children.append(rt.heapAlloc(), try CheatLib.NodeStore(Node).createBound")
  end
end
