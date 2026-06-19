struct StateMeshExample {
    a: i32,
    b: i32,
}

impl StateMeshExample {
    fn initialize(&mut self) {
        self.a = 1;
        self.b = 2;
    }

    fn writer(&mut self) {
        self.a = 3;
    }

    fn reader(&self) -> i32 {
        self.a + self.b
    }

    fn a_alias(&self) -> i32 {
        self.a
    }
}
