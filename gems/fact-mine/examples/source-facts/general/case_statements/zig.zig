fn method_eight(x: i32) void {
    switch (x) {
        1, 2 => action_one(),
        3 => action_two(),
        else => action_three(),
    }
}

fn method_case_no_val(x: i32) void {
    if (x == 1) {
        action_one();
    }
}

fn method_case_one_pattern(x: i32) void {
    switch (x) {
        1 => action_one(),
        else => {},
    }
}
