pub struct TemporalOrderExample {
    a: i32,
    b: i32,
}

impl TemporalOrderExample {
    pub fn one(&mut self) {
        self.a = 1;
    }

    pub fn two(&mut self) {
        self.a = 2;
        self.b = 3;
    }

    pub fn three(&mut self) {
        self.b = 4;
    }

    pub fn reader(&self) -> i32 {
        self.a
    }
}
