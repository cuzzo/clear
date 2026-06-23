fn method_three(f: anytype) void {
    f(1);
}

fn method_with_empty_block() void {
    const arr = [_]i32{1};
    for (arr) |_| {}
}
