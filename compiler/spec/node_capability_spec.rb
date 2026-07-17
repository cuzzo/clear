require "rspec"
require_relative "../ruby/backends/transpiler"

RSpec.describe "@node capability" do
  SOURCE = <<~CLEAR
    STRUCT Node {
      left: ?Node@node,
      right: ?Node@node,
      children: []Node@node,
      id: Int64
    }

    FN main() RETURNS Void ->
      MUTABLE root: Node@node = Node{ id: 1 };
      root.left = Node{ id: 2 };
      &root.children.append(Node{ id: 3 });
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
    expect(zig).to include("defer CheatLib.NodeStore(Node).releaseBound(__node_store_Node)")
    expect(zig).to include("CheatLib.NodeStore(Node).createBound(__node_store_Node, Node{")
    expect(zig).to include("CheatLib.NodeStore(Node).getBound(__node_store_Node, root).?.left")
    create_child = "const __eval_2 = try CheatLib.NodeStore(Node).createBound(__node_store_Node, Node{ .id = 3 });"
    append_child = "children.append(rt.heapAlloc(), __eval_2);"
    expect(zig).to include(create_child)
    expect(zig).to include(append_child)
    expect(zig.index(create_child)).to be < zig.index(append_child)
  end

  it "does not transfer copyable struct fields into node storage" do
    source = <<~CLEAR
      STRUCT Node { id: Int64 }
      FN main() RETURNS Void ->
        MUTABLE nodes: []Node@node = [];
        TIGHT FOR i IN (0_i64 ..< 8_i64) DO
          &nodes.append(Node{ id: i });
        END
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to include("createBound(__node_store_Node, Node{ .id = i })")
  end

  it "parses shared node composition in either order without Arc-wrapping the handle" do
    source = <<~CLEAR
      STRUCT Node { peer: ?Node@shared:node, id: Int64 }
      FN main() RETURNS Void ->
        MUTABLE roots: []Node@shared:node = [];
      END
    CLEAR

    ast = annotate(source)
    field = ast.statements.first.field_decls.fetch("peer").type
    roots = ast.statements.fetch(1).body.first.type

    expect(field.shared_node?).to be(true)
    expect(field.node_reference?).to be(true)
    expect(field.ownership_surface_name).to eq("@shared:node")
    expect(field.zig_type).to eq("CheatLib.NodeRef(Node)")
    expect(roots.element_type&.shared_node?).to be(true)
    expect(roots.zig_type).to eq("std.ArrayListUnmanaged(CheatLib.NodeRef(Node))")
  end

  it "guards the complete shared-node mutation and read statements" do
    source = <<~CLEAR
      STRUCT Node { peer: ?Node@shared:node, id: Int64 }
      FN main() RETURNS Void ->
        MUTABLE root: Node@shared:node = Node{ id: 1 };
        root.peer = Node{ id: 2 };
        ASSERT root.peer?.id == 2;
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to include("try CheatLib.SharedNodeStore(Node).lockWrite(rt)")
    expect(zig).to include("defer CheatLib.SharedNodeStore(Node).unlockWrite(__shared_node_guard_Node)")
    expect(zig).to include("SharedNodeStore(Node).createBound(__shared_node_guard_Node")
    expect(zig).to include("try CheatLib.SharedNodeStore(Node).lockRead(rt)")
    expect(zig).to include("defer CheatLib.SharedNodeStore(Node).unlockRead(__shared_node_guard_Node)")
    expect(zig).not_to include("CheatLib.Arc(Node)")
  end

  it "infers the shared-node binding from an expression capability" do
    source = <<~CLEAR
      STRUCT Node { id: Int64 }
      FN main() RETURNS Void ->
        root = Node{ id: 1 } @shared:node;
        ASSERT root.id == 1;
      END
    CLEAR

    ast = annotate(source)
    root = ast.statements.fetch(1).body.first
    expect(root.value.full_type!.shared_node?).to be(true)

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
    expect(zig).to include("SharedNodeStore(Node).createBound")
    expect(zig).to include("SharedNodeStore(Node).getBound")
  end
end
