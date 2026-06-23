const MyClass = struct {
    field: i32,
    fn myMethod(self: *MyClass) void {
        self.field = 1;
    }
};
