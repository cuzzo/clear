const TemporalOrderExample = struct {
    a: i32,
    b: i32,

    pub fn one(self: *TemporalOrderExample) void {
        self.a = 1;
    }

    pub fn two(self: *TemporalOrderExample) void {
        self.a = 2;
        self.b = 3;
    }

    pub fn three(self: *TemporalOrderExample) void {
        self.b = 4;
    }

    pub fn reader(self: *TemporalOrderExample) i32 {
        return self.a;
    }
};
