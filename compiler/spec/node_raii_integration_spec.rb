require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "@node lexical RAII", :integration do
  CLEAR_BIN = File.expand_path("../../clear", __dir__)

  it "closes cyclic node payloads before control returns to the caller" do
    dir = Dir.mktmpdir("clear-node-raii")
    source = File.join(dir, "main.clear")
    File.write(File.join(dir, "node_probe.zig"), <<~ZIG)
      const std = @import("std");

      pub const Probe = struct {
          id: i64,

          pub fn deinit(self: *Probe) void {
              std.debug.print("NODE_CLOSE:{}\\n", .{self.id});
          }
      };

      pub fn makeProbe(id: i64) Probe {
          return .{ .id = id };
      }
    ZIG
    File.write(source, <<~CLEAR)
      EXTERN STRUCT Probe { id: Int64 } CLOSE "deinit" FROM "node_probe";
      EXTERN FN makeProbe(id: Int64) RETURNS Probe FROM "node_probe";

      STRUCT Node {
        resource: Probe,
        peer: ?Node@node
      }

      FN makeCycle() RETURNS Void ->
        MUTABLE first: Node@node = Node{ resource: makeProbe(1) };
        MUTABLE second: Node@node = Node{ resource: makeProbe(2) };
        first.peer = second;
        second.peer = first;
        print("INSIDE");
      END

      FN main() RETURNS Void ->
        makeCycle();
        print("AFTER");
      END
    CLEAR

    output, status = Open3.capture2e(CLEAR_BIN, "run", source)
    expect(status.success?).to be(true), output
    expect(output.scan(/NODE_CLOSE:/).length).to eq(2), output
    expect(output).to match(/INSIDE.*NODE_CLOSE:[12].*NODE_CLOSE:[12].*AFTER/m), output
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
