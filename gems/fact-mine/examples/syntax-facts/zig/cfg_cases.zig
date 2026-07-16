fn dispatch(value: u8) void {
    switch (value) {
        0 => publish(value),
        1, 2 => invite(value),
        else => ignore(value),
    }
    finish(value);
}
