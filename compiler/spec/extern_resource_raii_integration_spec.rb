require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "EXTERN resource ownership", :integration do
  CLEAR_BIN = File.expand_path("../../clear", __dir__)

  it "closes every foreign resource exactly once through all ownership wrappers" do
    dir = Dir.mktmpdir("clear-extern-resource-raii")
    File.write(File.join(dir, "resource_probe.zig"), <<~ZIG)
      var created: i64 = 0;
      var closed: i64 = 0;
      var duplicate_closes: i64 = 0;
      var closed_ids = [_]bool{false} ** 512;

      pub const Probe = struct {
          id: i64,

          pub fn deinit(self: Probe) void {
              closed += 1;
              if (self.id >= 0 and self.id < closed_ids.len) {
                  const index: usize = @intCast(self.id);
                  if (closed_ids[index]) duplicate_closes += 1;
                  closed_ids[index] = true;
              }
          }
      };

      pub fn makeProbe(id: i64) Probe {
          created += 1;
          return .{ .id = id };
      }

      pub fn probeCreated() i64 { return created; }
      pub fn probeClosed() i64 { return closed; }
      pub fn probeDuplicateCloses() i64 { return duplicate_closes; }
      pub fn probeLabel(probe: Probe) []const u8 {
          _ = probe;
          return "probe";
      }
    ZIG

    source = File.join(dir, "main.clear")
    File.write(source, <<~CLEAR)
      EXTERN STRUCT Probe { id: Int64 } CLOSE "deinit" FROM "resource_probe";
      EXTERN FN makeProbe(id: Int64) RETURNS Probe FROM "resource_probe";
      EXTERN FN probeCreated() RETURNS Int64 FROM "resource_probe";
      EXTERN FN probeClosed() RETURNS Int64 FROM "resource_probe";
      EXTERN FN probeDuplicateCloses() RETURNS Int64 FROM "resource_probe";
      EXTERN FN probeLabel(probe: Probe) RETURNS probe:String FROM "resource_probe";

      STRUCT DirectOwner { marker: String@symbol, probe: Probe }
      STRUCT OptionalOwner { marker: String@symbol, probe: ?Probe }
      STRUCT NestedOwner { marker: String@symbol, owner: DirectOwner }
      STRUCT Box<T> { marker: String@symbol, value: T }
      UNION ResourceChoice { ProbeValue: Probe, Label: String@symbol, Count: Int64 }

      FN direct() RETURNS Void ->
        owner = DirectOwner{ marker: :direct, probe: makeProbe(1) };
        probeLabel(owner.probe);
        label = COPY probeLabel(owner.probe);
        print(label);
        print(owner.marker);
      END

      FN optional() RETURNS Void ->
        owner = OptionalOwner{ marker: :optional, probe: makeProbe(2) };
        print(owner.marker);
      END

      FN nested() RETURNS Void ->
        owner = NestedOwner{
          marker: :nested,
          owner: DirectOwner{ marker: :inner, probe: makeProbe(3) }
        };
        print(owner.marker);
      END

      FN replaceField() RETURNS Void ->
        MUTABLE owner = DirectOwner{ marker: :replace, probe: makeProbe(14) };
        owner.probe = makeProbe(15);
        print(owner.marker);
      END

      FN generic() RETURNS Void ->
        owner = Box<Probe>{ marker: :generic, value: makeProbe(4) };
        print(owner.marker);
      END

      FN unionValues() RETURNS Void ->
        resource: ResourceChoice = ResourceChoice{ ProbeValue: makeProbe(5) };
        label: ResourceChoice = ResourceChoice{ Label: :safe };
        PARTIAL MATCH label START
          ResourceChoice.Label AS text -> print(text);,
          DEFAULT -> PASS
        END
        PARTIAL MATCH resource START
          ResourceChoice.ProbeValue AS probe -> print(probe.id);,
          DEFAULT -> PASS
        END
      END

      FN returned() RETURNS Probe ->
        probe = makeProbe(6);
        RETURN probe;
      END

      FN returnTransfer() RETURNS Void ->
        probe = returned();
        print(probe.id);
      END

      FN consume(TAKES probe: Probe) RETURNS Void -> print(probe.id); END

      FN takesTransfer() RETURNS Void ->
        probe = makeProbe(7);
        consume(GIVE probe);
      END

      FN sharedOwner() RETURNS Void ->
        probe: Probe@multiowned = makeProbe(8) @multiowned;
        other: Probe@multiowned = CLONE probe;
        print(other.id);
      END

      FN tupleOwner() RETURNS Void ->
        owner = Tuple{makeProbe(9), :tuple};
        print(owner._1);
      END

      FN listOwner() RETURNS !Void ->
        MUTABLE probes: Probe[]@list = [];
        first = makeProbe(10);
        second = makeProbe(11);
        &probes.append(GIVE first);
        &probes.append(GIVE second);
      END

      FN earlyReturn() RETURNS Void ->
        probe = makeProbe(12);
        RETURN;
      END

      FN failResource() RETURNS !Void ->
        probe = makeProbe(13);
        RAISE;
      END

      FN errorExit() RETURNS Void -> failResource() OR_ELSE print("caught"); END

      FN repeated() RETURNS Void ->
        MUTABLE i = 0;
        WHILE i < 100 DO
          probe = makeProbe(100 + i);
          IF i == 99 THEN print(probe.id); END
          i += 1;
        END
      END

      FN main() RETURNS Void ->
        direct(); optional(); nested(); generic(); unionValues();
        returnTransfer(); takesTransfer(); sharedOwner(); tupleOwner();
        listOwner() OR_ELSE RAISE;
        earlyReturn(); errorExit(); replaceField(); repeated();
        print("RESOURCE_CREATED"); print(probeCreated());
        print("RESOURCE_CLOSED"); print(probeClosed());
        print("RESOURCE_DUPLICATES"); print(probeDuplicateCloses());
      END
    CLEAR

    output, status = Open3.capture2e({ "CLEAR_THREADS" => "0" }, CLEAR_BIN, "run", source)
    expect(status.success?).to be(true), output
    expect(output).to match(/RESOURCE_CREATED\s+115/), output
    expect(output).to match(/RESOURCE_CLOSED\s+115/), output
    expect(output).to match(/RESOURCE_DUPLICATES\s+0/), output
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
