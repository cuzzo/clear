pub fn original() void {
    const src = fetch(1);
    check(src);
    store(src);
    finalize(src);
}

pub fn pasted() void {
    const dst = fetch(2);
    check(dst);
    store(src);
    finalize(dst);
}
