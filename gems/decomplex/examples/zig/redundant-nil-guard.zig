pub fn check(value: OptionalItem) void {
    if (value.isSome()) {
        value.isNull();
    }
}
