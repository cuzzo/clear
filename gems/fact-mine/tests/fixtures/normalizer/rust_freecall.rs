fn helper(a: &str, b: &mut Vec<String>) {
    b.push(a.to_string());
}

fn caller(a: &str) {
    let mut items = Vec::new();
    helper(a, &mut items);
}
