struct FlowExample {
    status: i32,
    valid: bool,
    done: bool,
}

impl FlowExample {
    fn prepare(&mut self) { self.status = 1; }
    fn validate(&mut self) { self.valid = self.status == 1; }
    fn commit(&mut self) { self.done = self.valid; }

    fn ok1(&mut self) { self.prepare(); self.validate(); self.commit(); }
    fn ok2(&mut self) { self.prepare(); self.validate(); self.commit(); }
    fn ok3(&mut self) { self.prepare(); self.validate(); self.commit(); }
    fn ok4(&mut self) { self.prepare(); self.validate(); self.commit(); }
    fn drift(&mut self) { self.validate(); self.prepare(); self.commit(); }
}
