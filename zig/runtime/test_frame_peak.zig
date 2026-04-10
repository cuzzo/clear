const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

test "framePeakBytes tracks arena high-water mark" {
    const alloc = std.testing.allocator;
    var ctx = EbrContext{};
    defer ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const before = rt.framePeakBytes();

    // Allocate some frame data
    const s1 = try rt.frameAlloc().alloc(u8, 1000);
    _ = s1;

    const after = rt.framePeakBytes();
    try std.testing.expect(after >= before + 1000);

    // Save mark, allocate more, rewind
    const mark = rt.saveFrameMark();
    const s2 = try rt.frameAlloc().alloc(u8, 5000);
    _ = s2;

    const peak_before_rewind = rt.framePeakBytes();
    try std.testing.expect(peak_before_rewind >= before + 6000);

    rt.restoreFrameMark(mark);

    // Peak should NOT decrease after rewind - it's a high-water mark
    const peak_after_rewind = rt.framePeakBytes();
    try std.testing.expect(peak_after_rewind >= peak_before_rewind);
}
