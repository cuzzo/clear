require "rspec"
require "tmpdir"
require "open3"
require_relative "../ruby/backends/transpiler"

RSpec.describe "EASY automatic indirection" do
  def transpile(source, mode:)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: mode)
  end

  let(:recursive_source) do
    <<~CLEAR
      STRUCT Node { value: Int64, next: ?Node }
      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end

  it "requires an explicit topology choice for a unique recursive edge even in EASY" do
    expect { transpile(recursive_source, mode: :easy) }
      .to raise_error(/recursive field Node.next.*@node.*@indirect.*@multiowned.*@shared.*@link/m)
  end

  it "requires explicit recursive layout in DEFAULT and STRICT" do
    %i[default strict].each do |mode|
      expect { transpile(recursive_source, mode: mode) }
        .to raise_error(/recursive field Node.next.*@node.*@indirect/m)
    end
  end

  it "rejects performance-distinct recursive choices even in EASY" do
    source = <<~CLEAR
      STRUCT Node { left: ?Node, right: ?Node }
      FN main() RETURNS Void -> RETURN; END
    CLEAR
    expect { transpile(source, mode: :easy) }
      .to raise_error(/multiple cycle-breaking choices.*Node.left.*Node.right/m)
  end

  it "does not box recursion already bounded by a collection" do
    source = <<~CLEAR
      STRUCT Node { children: Node[]@list }
      FN main() RETURNS Void -> RETURN; END
    CLEAR
    zig = transpile(source, mode: :easy)
    expect(zig).to include("children: std.ArrayListUnmanaged(Node)")
    expect(zig).not_to include("std.ArrayListUnmanaged(*Node)")
  end

  it "elides construction only for an explicit indirect callee ABI in EASY" do
    source = <<~CLEAR
      STRUCT Foo { id: Int64 }
      FN read(x: Foo@indirect) RETURNS Int64 -> RETURN x.id; END
      FN main() RETURNS Void -> ASSERT read(Foo{ id: 1 }) == 1; END
    CLEAR
    expect { transpile(source, mode: :easy) }.not_to raise_error
    expect { transpile(source, mode: :default) }.to raise_error(/Layout Error.*argument 1/m)
  end

  it "moves a TAKES parameter into an inline list without a deep COPY" do
    source = <<~CLEAR
      STRUCT Foo { name: String }
      FN add!(TAKES f: Foo, MUTABLE items: Foo[]@list) RETURNS Void ->
        items.append(f);
      END
      FN main() RETURNS Void ->
        MUTABLE items: Foo[]@list = [];
        f = Foo{ name: COPY "owned" };
        add!(f, items);
        ASSERT items.length() == 1;
      END
    CLEAR

    zig = transpile(source, mode: :default)
    add_body = zig.split("fn add", 2).last.split("fn clearMain", 2).first
    expect(add_body).to include("items.append(rt.heapAlloc(), f)")
    expect(add_body).to include("f_moved = true")
    expect(add_body).not_to include("dupeValue")
  end

  it "distinguishes a boxed list header from boxed list elements" do
    source = <<~CLEAR
      STRUCT Foo { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: Foo[]@list:indirect = [];
        items.append(Foo{ value: 1 });
      END
    CLEAR

    zig = transpile(source, mode: :default)
    expect(zig).to include("*std.ArrayListUnmanaged(Foo)")
    expect(zig).not_to include("std.ArrayListUnmanaged(*Foo)")
  end

  it "models element-level @indirect independently from collection layout" do
    source = <<~CLEAR
      STRUCT Foo { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: Foo@indirect[]@list = [];
      END
    CLEAR

    zig = transpile(source, mode: :default)
    expect(zig).to include("std.ArrayListUnmanaged(*Foo)")
  end

  it "builds and runs recursive construction through an explicit unique-owner layout", :integration do
    Dir.mktmpdir("clear-auto-box") do |dir|
      source = File.join(dir, "main.clear")
      binary = File.join(dir, "main")
      File.write(source, <<~CLEAR)
        STRUCT Node { value: Int64, name: String, next: ?Node@indirect }
        FN main() RETURNS Void ->
          leaf = Node{ value: 1, name: COPY "leaf", next: NIL };
          root = Node{ value: 2, name: COPY "root", next: leaf };
          ASSERT root.next?.value == 1;
          snapshot = COPY root;
          ASSERT snapshot.next?.name == "leaf";
        END
      CLEAR
      clear = File.expand_path("../../clear", __dir__)
      build_out, build_status = Open3.capture2e(clear, "build", "--gradual", "--debug-allocator", "--no-cache", source, "-o", binary)
      expect(build_status).to be_success, build_out
      run_out, run_status = Open3.capture2e(binary)
      expect(run_status).to be_success, run_out
    end
  end
end
