pub fn check(input_value: i32) void {
    var input = input_value;
    const cached = input + 1;
    input = 2;
    print(cached);
}
