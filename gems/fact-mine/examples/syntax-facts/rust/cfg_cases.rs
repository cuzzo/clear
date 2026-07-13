impl Matcher {
    fn dispatch(value: i32) {
        match value {
            0 => publish(value),
            1 | 2 => invite(value),
            _ => ignore(value),
        }
        finish(value);
    }
}
