require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "@shared:node runtime RAII", :integration do
  SHARED_NODE_CLEAR_BIN = File.expand_path("../../clear", __dir__)

  it "closes every cyclic managed payload exactly once after admitted tasks finish" do
    dir = Dir.mktmpdir("clear-shared-node-raii")
    source = File.join(dir, "main.clear")
    File.write(File.join(dir, "shared_node_probe.zig"), <<~ZIG)
      const std = @import("std");

      pub const Probe = struct {
          id: i64,

          pub fn deinit(self: *Probe) void {
              std.debug.print("SHARED_NODE_CLOSE:{}\\n", .{self.id});
          }
      };

      pub fn makeProbe(id: i64) Probe {
          return .{ .id = id };
      }
    ZIG
    File.write(source, <<~CLEAR)
      EXTERN STRUCT Probe { id: Int64 } CLOSE "deinit" FROM "shared_node_probe";
      EXTERN FN makeProbe(id: Int64) RETURNS Probe FROM "shared_node_probe";

      STRUCT Node {
        resource: Probe,
        peer: ?Node@shared:node
      }

      FN main() RETURNS Void ->
        MUTABLE first: Node@shared:node = Node{ resource: makeProbe(1) };
        MUTABLE second: Node@shared:node = Node{ resource: makeProbe(2) };
        first.peer = second;
        second.peer = first;
        task: ~Void = BG { @parallel ->
          ASSERT first.peer?.resource.id == 2;
        };
        NEXT task;
        print("SHARED_NODE_DONE");
      END
    CLEAR

    output, status = Open3.capture2e(SHARED_NODE_CLEAR_BIN, "run", source)
    expect(status.success?).to be(true), output
    expect(output).to include("SHARED_NODE_DONE")
    expect(output.scan(/SHARED_NODE_CLOSE:/).length).to eq(2), output
    expect(output.scan(/SHARED_NODE_CLOSE:1/).length).to eq(1), output
    expect(output.scan(/SHARED_NODE_CLOSE:2/).length).to eq(1), output
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
