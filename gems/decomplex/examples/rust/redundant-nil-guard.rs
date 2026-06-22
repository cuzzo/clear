fn check(value: Option<Item>) {
    if value.is_some() {
        value.is_none();
    }
}
