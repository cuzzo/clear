fn original() {
    let src = fetch(1);
    check(src);
    store(src);
    finalize(src);
}

fn pasted() {
    let dst = fetch(2);
    check(dst);
    store(src);
    finalize(dst);
}
