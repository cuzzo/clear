fn method_two() void {
    const result = blk: {
        break :blk error.Err;
    };
    if (result) |value| {
        _ = value;
    } else |e| {
        log(e);
    }
    cleanup();
}
