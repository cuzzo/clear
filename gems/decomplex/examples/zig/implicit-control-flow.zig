const FlowExample = struct {
    status: i32,
    valid: bool,
    done: bool,

    pub fn prepare(self: *FlowExample) void { self.status = 1; }
    pub fn validate(self: *FlowExample) void { self.valid = self.status == 1; }
    pub fn commit(self: *FlowExample) void { self.done = self.valid; }

    pub fn ok1(self: *FlowExample) void { self.prepare(); self.validate(); self.commit(); }
    pub fn ok2(self: *FlowExample) void { self.prepare(); self.validate(); self.commit(); }
    pub fn ok3(self: *FlowExample) void { self.prepare(); self.validate(); self.commit(); }
    pub fn ok4(self: *FlowExample) void { self.prepare(); self.validate(); self.commit(); }
    pub fn drift(self: *FlowExample) void { self.validate(); self.prepare(); self.commit(); }
};
