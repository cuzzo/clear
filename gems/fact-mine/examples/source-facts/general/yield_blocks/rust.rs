fn method_three<F>(f: F) where F: Fn(i32) {
    f(1);
}

fn method_with_empty_block() {
    let arr = [1];
    arr.iter().for_each(|_| {});
}
