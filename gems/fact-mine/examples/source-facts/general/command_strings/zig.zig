fn method_four() void {
    _ = std::ChildProcess.exec(.{ .allocator = alloc, .argv = &[_][]const u8{"ls"} });
}
