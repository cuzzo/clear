const StateMeshExample = struct {
    a: i32,
    b: i32,

    pub fn initialize(self: *StateMeshExample) void {
        self.a = 1;
        self.b = 2;
    }

    pub fn writer(self: *StateMeshExample) void {
        self.a = 3;
    }

    pub fn reader(self: *StateMeshExample) i32 {
        return self.a + self.b;
    }

    pub fn a_alias(self: *StateMeshExample) i32 {
        return self.a;
    }
};
