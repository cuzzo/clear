pub fn classify(value: i32) []const u8 {
    if (value > 10) return "high";
    if (value > 0) return "positive";
    return "nonpositive";
}
