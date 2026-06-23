fn method_eight(x: i32) {
    match x {
        1 | 2 => action_one(),
        3 => action_two(),
        _ => action_three(),
    }
}

fn method_case_no_val(x: i32) {
    if x == 1 {
        action_one();
    }
}

fn method_case_one_pattern(x: i32) {
    match x {
        1 => action_one(),
        _ => {}
    }
}
