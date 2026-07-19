const std = @import("std");

pub fn build(b: *std.Build) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = b.graph.host,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the static mutation example");
    test_step.dependOn(&run_tests.step);
}
