//! Tests extracted from runtime/fiber-profile.zig.
//!
//! Pre-V33 these tests lived inline at the bottom of fiber-profile.zig.
//! Moving them here keeps production diffs free of test churn so
//! "what changed in production" is a clean `git diff zig/runtime/fiber-profile.zig`.

const std = @import("std");
const fp = @import("fiber-profile.zig");

test "fiber profile records per-site scheduler attribution" {
    fp.resetForTest();
    defer fp.resetForTest();

    fp.recordSiteSpawn(7, .local, .fsm);
    fp.recordSchedulerRun(3);
    fp.recordSiteRun(7, 3);
    fp.recordFiberExit(7, 100, 2100);

    try std.testing.expectEqual(@as(u64, 1), fp.total_fibers);
    try std.testing.expectEqual(@as(u64, 1), fp.sched_runs[3]);
    const site = fp.findSiteLocked(7).?;
    try std.testing.expectEqual(@as(u64, 1), site.spawns);
    try std.testing.expectEqual(@as(u64, 1), site.runs);
    try std.testing.expectEqual(@as(u64, 1), site.exits);
    try std.testing.expectEqual(fp.DispatchKind.local, site.dispatch);
    try std.testing.expectEqual(fp.TaskForm.fsm, site.form);
    try std.testing.expectEqual(@as(u64, 1), site.sched_runs[3]);
    try std.testing.expectEqual(@as(u64, 2000), site.total_lifetime_ns);
}

test "fiber profile handles site collisions and saturation" {
    fp.resetForTest();
    defer fp.resetForTest();

    fp.recordSiteSpawn(1, .local, .stack);
    fp.recordSiteSpawn(1 + fp.MAX_SITES, .parallel, .fsm);
    try std.testing.expect(fp.findSiteLocked(1) != null);
    try std.testing.expect(fp.findSiteLocked(1 + fp.MAX_SITES) != null);

    var i: u32 = 2;
    while (i <= fp.MAX_SITES) : (i += 1) {
        fp.recordSiteSpawn(i, .local, .stack);
    }
    fp.recordSiteSpawn(fp.MAX_SITES + 2, .parallel, .fsm);
    try std.testing.expectEqual(@as(u64, 2), fp.site_dropped);
}
